import Foundation

struct ImportResult {
    var notesAdded = 0
    var notesUpdated = 0
    var notesSkipped = 0
    var cardsAdded = 0
    var mediaFiles = 0
    var decks: [String] = []

    var summary: String {
        var parts = ["\(notesAdded) notes added"]
        if notesUpdated > 0 { parts.append("\(notesUpdated) updated") }
        if notesSkipped > 0 { parts.append("\(notesSkipped) unchanged") }
        if mediaFiles > 0 { parts.append("\(mediaFiles) media files") }
        return parts.joined(separator: ", ")
    }
}

/// Reads `.apkg` and `.colpkg` packages in all three formats Anki writes:
/// legacy `collection.anki2`, `collection.anki21`, and zstd-compressed
/// `collection.anki21b` with a protobuf media map.
struct Package {
    let zip: ZipReader
    let isLatest: Bool

    init(url: URL) throws {
        zip = try ZipReader(url: url)
        if zip.contains("meta") {
            let meta = ProtoMessage(try zip.read("meta"))
            isLatest = meta.uint(1) >= 3
        } else {
            isLatest = false
        }
    }

    /// Extracts the collection as a schema 11 database at `destination`.
    func extractCollection(to destination: URL) throws {
        let tmp = destination.deletingLastPathComponent().appendingPathComponent("pkg-\(UUID().uuidString).anki2")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if isLatest || (zip.contains("collection.anki21b") && !zip.contains("collection.anki21")) {
            try Zstd.decompress(zip.read("collection.anki21b")).write(to: tmp)
        } else if zip.contains("collection.anki21") {
            try zip.read("collection.anki21").write(to: tmp)
        } else if zip.contains("collection.anki2") {
            try zip.read("collection.anki2").write(to: tmp)
        } else {
            throw CollectionError.invalid("This file does not contain an Anki collection.")
        }
        try SchemaConverter.convertToSchema11(source: tmp, destination: destination)
    }

    /// Media entries as (file name, name inside the zip).
    func mediaEntries() throws -> [(name: String, zipName: String)] {
        guard zip.contains("media") else { return [] }
        var data = try zip.read("media")
        if isLatest {
            data = try Zstd.decompress(data)
            return ProtoMessage(data).messages(1).enumerated().map { idx, entry in
                let legacy = entry.optionalUInt32(255)
                return (entry.string(1), String(legacy.map(Int.init) ?? idx))
            }
        }
        let map = try JSON.parse(data).object ?? [:]
        return map.compactMap { key, value in value.string.map { ($0, key) } }
    }

    func mediaData(zipName: String) throws -> Data {
        let data = try zip.read(zipName)
        return isLatest ? try Zstd.decompress(data) : data
    }
}

final class PackageImporter {
    let col: Collection
    let media: MediaManager?
    var progress: (String) -> Void = { _ in }

    init(collection: Collection, media: MediaManager?) {
        col = collection
        self.media = media
    }

    /// Merges an `.apkg` into the collection, like Anki's importer: notes are
    /// matched by GUID, notetypes and decks by id/name, and scheduling is
    /// kept.
    func importApkg(_ url: URL) throws -> ImportResult {
        progress("Reading package…")
        let pkg = try Package(url: url)
        let srcURL = col.url.deletingLastPathComponent().appendingPathComponent("import-\(UUID().uuidString).anki2")
        defer {
            try? FileManager.default.removeItem(at: srcURL)
        }
        try pkg.extractCollection(to: srcURL)
        let src = try Collection(url: srcURL, mediaFolder: col.mediaFolder.deletingLastPathComponent()
            .appendingPathComponent("import-media-unused"))
        defer {
            src.close()
            try? FileManager.default.removeItem(at: col.mediaFolder.deletingLastPathComponent().appendingPathComponent("import-media-unused"))
        }

        var result = ImportResult()
        progress("Importing notes…")
        try col.db.transaction {
            let notetypeMap = try mapNotetypes(from: src)
            let deckMap = try mapDecks(from: src, result: &result)
            let dayOffset = Int64((src.crt - col.crt) / 86_400)
            let positionOffset = col.conf["nextPos"].int(or: 1)
            var maxPos: Int64 = positionOffset

            var importedNotes = Set<Int64>()
            let notes = try src.db.query("select \(Note.columns) from notes").map(Note.init(row:))
            for var note in notes {
                guard let mid = notetypeMap[note.mid] else { continue }
                if let existing = try col.note(guid: note.guid) {
                    if existing.mid == mid, note.mod > existing.mod, existing.fields.count == note.fields.count {
                        var updated = existing
                        updated.fields = note.fields
                        updated.tags = note.tags
                        updated.mod = Time.nowSecs
                        updated.usn = -1
                        try col.writeNote(updated)
                        col.registerTags(updated.tags)
                        result.notesUpdated += 1
                    } else {
                        result.notesSkipped += 1
                    }
                    continue
                }
                let oldID = note.id
                if try col.db.int("select count() from notes where id = ?", note.id) > 0 {
                    note.id = try col.newID(table: "notes")
                }
                note.mid = mid
                note.usn = -1
                note.mod = Time.nowSecs
                let nt = col.notetype(mid)
                let fieldCount = nt?.fieldNames.count ?? note.fields.count
                if note.fields.count < fieldCount {
                    note.fields += Array(repeating: "", count: fieldCount - note.fields.count)
                }
                try col.writeNote(note)
                col.registerTags(note.tags)
                importedNotes.insert(note.id)
                result.notesAdded += 1

                for var card in try src.db.query("select \(Card.columns) from cards where nid = ?", oldID).map(Card.init(row:)) {
                    let oldCardID = card.id
                    if try col.db.int("select count() from cards where id = ?", card.id) > 0 {
                        card.id = try col.newID(table: "cards")
                    }
                    card.nid = note.id
                    // cards in filtered decks go back to their home deck
                    if card.odid != 0 {
                        card.did = card.odid
                        card.due = card.odue
                        card.odid = 0
                        card.odue = 0
                        if card.queue == CardQueue.preview { card.queue = card.type }
                    }
                    card.did = deckMap[card.did] ?? 1
                    switch card.queue {
                    case CardQueue.review, CardQueue.dayLearn:
                        card.due += dayOffset
                    case CardQueue.new:
                        card.due = positionOffset + (card.due - 1)
                        maxPos = max(maxPos, card.due + 1)
                    default:
                        if card.type == CardType.review { card.due += dayOffset }
                    }
                    card.usn = -1
                    card.mod = Time.nowSecs
                    try col.writeCard(card)
                    result.cardsAdded += 1
                    for var entry in try src.db.query("select \(RevlogEntry.columns) from revlog where cid = ?", oldCardID)
                        .map(RevlogEntry.init(row:))
                    {
                        entry.cid = card.id
                        entry.usn = -1
                        try col.db.execute("insert or ignore into revlog (\(RevlogEntry.columns)) values (?,?,?,?,?,?,?,?,?)",
                                           params: entry.params)
                    }
                }
            }
            col.conf["nextPos"] = .int(max(maxPos, positionOffset))
            try col.save()
        }

        progress("Importing media…")
        result.mediaFiles = try importMedia(pkg)
        return result
    }

    private func mapNotetypes(from src: Collection) throws -> [Int64: Int64] {
        var map: [Int64: Int64] = [:]
        let used = Set(try src.db.query("select distinct mid from notes").map { $0[0].int })
        for (id, json) in src.models where used.contains(id) {
            let srcNT = Notetype(json: json)
            if let existing = col.notetype(id), existing.fieldNames == srcNT.fieldNames,
               existing.templates.count == srcNT.templates.count
            {
                map[id] = id
                // keep templates/styling in step when the incoming copy is newer
                if srcNT.mod > existing.mod {
                    var updated = json
                    updated["usn"] = -1
                    col.models[id] = updated
                }
                continue
            }
            if let match = col.notetypes.first(where: {
                $0.name == srcNT.name && $0.fieldNames == srcNT.fieldNames && $0.templates.count == srcNT.templates.count
                    && $0.isCloze == srcNT.isCloze
            }) {
                map[id] = match.id
                continue
            }
            var json = json
            if col.models[id] != nil { json["id"] = .int(0) }
            map[id] = try col.addNotetype(json)
        }
        return map
    }

    private func mapDecks(from src: Collection, result: inout ImportResult) throws -> [Int64: Int64] {
        var map: [Int64: Int64] = [:]
        var confMap: [Int64: Int64] = [:]
        for (id, json) in src.dconf {
            if col.dconf[id] != nil {
                confMap[id] = id
            } else {
                var conf = json
                conf["usn"] = -1
                col.dconf[id] = conf
                confMap[id] = id
            }
        }
        let used = Set(try src.db.query("select distinct case when odid != 0 then odid else did end from cards").map { $0[0].int })
        for deck in src.allDecks {
            let needed = used.contains(deck.id) || src.childDecks(of: deck.id).contains { used.contains($0.id) }
            guard needed else { continue }
            if deck.id == 1, src.deck(1)?.name == "Default", !(used.contains(1)) { continue }
            if deck.isFiltered { continue }
            if let existing = col.deck(named: deck.name) {
                map[deck.id] = existing.id
                continue
            }
            var json = deck.json
            var id = deck.id
            if col.decks[id] != nil || id == 1 { id = Time.nowMillis }
            while col.decks[id] != nil { id += 1 }
            json["id"] = .int(id)
            json["usn"] = -1
            json["mod"] = .int(Time.nowSecs)
            json["conf"] = .int(confMap[deck.configID] ?? 1)
            for key in ["newToday", "revToday", "lrnToday", "timeToday"] { json[key] = [0, 0] }
            if let parent = deck.parentName { try col.addDeck(named: parent) }
            col.decks[id] = json
            map[deck.id] = id
            result.decks.append(deck.name)
        }
        // filtered decks' cards were mapped to their home decks above
        for deck in src.allDecks where map[deck.id] == nil && deck.isFiltered {
            map[deck.id] = 1
        }
        return map
    }

    private func importMedia(_ pkg: Package) throws -> Int {
        guard let media else { return 0 }
        var count = 0
        for entry in try pkg.mediaEntries() {
            let name = MediaManager.normalize(entry.name)
            guard MediaManager.isSafe(name), pkg.zip.contains(entry.zipName) else { continue }
            let data = try pkg.mediaData(zipName: entry.zipName)
            if media.fileExists(name), let existing = try? Data(contentsOf: media.url(for: name)), existing == data { continue }
            try media.addFile(name: name, data: data)
            count += 1
        }
        return count
    }

    /// Replaces the whole collection with a `.colpkg` backup. Returns the
    /// path of the new schema 11 file for the caller to swap in.
    static func extractColpkg(_ url: URL, besides collectionURL: URL, media: MediaManager?) throws -> URL {
        let pkg = try Package(url: url)
        let dest = collectionURL.deletingLastPathComponent().appendingPathComponent("colpkg-\(UUID().uuidString).anki2")
        try pkg.extractCollection(to: dest)
        let db = try Database(path: dest.path)
        // a restored backup must be uploaded or replaced on the next sync
        try db.execute("update col set scm = ?, ls = 0", Time.nowMillis)
        db.close()
        if let media {
            for entry in try pkg.mediaEntries() {
                let name = MediaManager.normalize(entry.name)
                guard MediaManager.isSafe(name), pkg.zip.contains(entry.zipName) else { continue }
                try media.addFile(name: name, data: try pkg.mediaData(zipName: entry.zipName))
            }
        }
        return dest
    }
}

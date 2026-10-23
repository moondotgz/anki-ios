import Foundation

struct ImportResult {
    var notesAdded = 0
    var notesUpdated = 0
    var notesSkipped = 0
    var cardsAdded = 0
    var mediaFiles = 0
    var decks: [String] = []
    /// The first top-level deck the package's cards went into, for "Study now".
    var primaryDeckID: Int64?

    var summary: String {
        var parts = ["\(notesAdded) note\(notesAdded == 1 ? "" : "s") added"]
        if notesUpdated > 0 { parts.append("\(notesUpdated) updated") }
        if notesSkipped > 0 { parts.append("\(notesSkipped) already present") }
        if mediaFiles > 0 { parts.append("\(mediaFiles) media file\(mediaFiles == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// How notes already in the collection (matched by GUID) are treated.
enum ImportUpdatePolicy: String, CaseIterable, Identifiable {
    case ifNewer
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ifNewer: return "If newer"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

struct ImportOptions {
    /// Keep review history and intervals; otherwise cards are imported as new.
    var includeScheduling = true
    var updateNotes: ImportUpdatePolicy = .ifNewer
}

/// What a package contains, shown before importing.
struct PackagePreview {
    var fileName: String
    var format: String
    var isCollectionPackage: Bool
    var decks: [String]
    var notetypes: [String]
    var notes: Int
    var cards: Int
    var newCards: Int
    var studiedCards: Int
    var revlogEntries: Int
    var mediaFiles: Int
    /// Notes whose GUID is already in the collection.
    var existingNotes: Int

    var hasScheduling: Bool { studiedCards > 0 || revlogEntries > 0 }
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

    var formatDescription: String {
        if isLatest { return "Anki 2.1.50+ package" }
        if zip.contains("collection.anki21") { return "Anki 2.1 package" }
        return "Legacy Anki package"
    }

    func mediaData(zipName: String) throws -> Data {
        let data = try zip.read(zipName)
        return isLatest ? try Zstd.decompress(data) : data
    }
}

/// An extracted package, opened once for previewing and then importing.
final class OpenedPackage {
    let package: Package
    let source: Collection
    let preview: PackagePreview
    private let workDir: URL

    init(url: URL, existingGUIDs: (([String]) throws -> Int)? = nil) throws {
        let pkg = try Package(url: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src: Collection
        do {
            let dbURL = dir.appendingPathComponent("collection.anki2")
            try pkg.extractCollection(to: dbURL)
            src = try Collection(url: dbURL, mediaFolder: dir.appendingPathComponent("media"))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        package = pkg
        source = src
        workDir = dir
        preview = try OpenedPackage.makePreview(url: url, package: pkg, source: src, existingGUIDs: existingGUIDs)
    }

    private static func makePreview(url: URL, package: Package, source: Collection,
                                    existingGUIDs: (([String]) throws -> Int)?) throws -> PackagePreview
    {
        let db = source.db
        let usedDecks = Set(try db.query("select distinct case when odid != 0 then odid else did end from cards").map { $0[0].int })
        let deckNames = source.allDecks.filter { d in
            usedDecks.contains(d.id) || source.childDecks(of: d.id).contains { usedDecks.contains($0.id) }
        }.map(\.name)
        let usedNotetypes = Set(try db.query("select distinct mid from notes").map { $0[0].int })
        let guids = try db.query("select guid from notes").map { $0[0].text }
        return PackagePreview(
            fileName: url.lastPathComponent,
            format: package.formatDescription,
            isCollectionPackage: url.pathExtension.lowercased() == "colpkg",
            decks: deckNames,
            notetypes: usedNotetypes.compactMap { source.notetype($0)?.name }.sorted(),
            notes: Int(try db.int("select count() from notes")),
            cards: Int(try db.int("select count() from cards")),
            newCards: Int(try db.int("select count() from cards where type = 0")),
            studiedCards: Int(try db.int("select count() from cards where type != 0")),
            revlogEntries: Int(try db.int("select count() from revlog")),
            mediaFiles: (try? package.mediaEntries().count) ?? 0,
            existingNotes: try existingGUIDs?(guids) ?? 0)
    }

    private var closed = false

    func close() {
        guard !closed else { return }
        closed = true
        source.close()
        try? FileManager.default.removeItem(at: workDir)
    }

    deinit { close() }
}

final class PackageImporter {
    let col: Collection
    let media: MediaManager?
    /// Reports a stage description and overall progress from 0 to 1.
    var progress: (String, Double) -> Void = { _, _ in }

    init(collection: Collection, media: MediaManager?) {
        col = collection
        self.media = media
    }

    /// How many of `guids` are already in the collection.
    func countExisting(guids: [String]) throws -> Int {
        var count = 0
        for chunk in stride(from: 0, to: guids.count, by: 500) {
            let slice = Array(guids[chunk..<min(chunk + 500, guids.count)])
            let marks = slice.map { _ in "?" }.joined(separator: ",")
            count += Int(try col.db.int("select count() from notes where guid in (\(marks))", params: slice))
        }
        return count
    }

    /// Opens, imports and closes an `.apkg` in one step.
    func importApkg(_ url: URL, options: ImportOptions = ImportOptions()) throws -> ImportResult {
        let opened = try OpenedPackage(url: url)
        defer { opened.close() }
        return try importPackage(opened, options: options)
    }

    /// Merges a package into the collection like Anki's importer: notes are
    /// matched by GUID, notetypes by id or name and fields, and decks by name.
    func importPackage(_ opened: OpenedPackage, options: ImportOptions) throws -> ImportResult {
        let src = opened.source
        var result = ImportResult()

        // media first, so renamed files can be rewritten in incoming notes
        progress("Importing media…", 0)
        let renames = try importMedia(opened.package, result: &result)

        progress("Importing notes…", 0.3)
        try col.db.transaction {
            let notetypeMap = try mapNotetypes(from: src)
            let deckMap = try mapDecks(from: src, result: &result)
            let dayOffset = Int64((Double(src.crt - col.crt) / 86_400).rounded())
            var nextPos = col.conf["nextPos"].int(or: 1)
            // new cards keep their relative order, packed after existing ones
            var positionMap: [Int64: Int64] = [:]
            for pos in try src.db.query("select distinct due from cards where type = 0 order by due").map({ $0[0].int }) {
                positionMap[pos] = nextPos
                nextPos += 1
            }

            let notes = try src.db.query("select \(Note.columns) from notes").map(Note.init(row:))
            for (index, srcNote) in notes.enumerated() {
                if index % 200 == 0 {
                    progress("Importing notes… \(index)/\(notes.count)", 0.3 + 0.7 * Double(index) / Double(max(1, notes.count)))
                }
                var note = srcNote
                guard let mid = notetypeMap[note.mid] else { continue }
                if !renames.isEmpty {
                    note.fields = note.fields.map { PackageImporter.rewriteMedia($0, renames) }
                }
                if let existing = try col.note(guid: note.guid) {
                    let update: Bool
                    switch options.updateNotes {
                    case .always: update = existing.fields != note.fields || existing.tags != note.tags
                    case .ifNewer: update = note.mod > existing.mod
                    case .never: update = false
                    }
                    if update, existing.mid == mid, existing.fields.count == note.fields.count {
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
                let fieldCount = col.notetype(mid)?.fieldNames.count ?? note.fields.count
                if note.fields.count < fieldCount {
                    note.fields += Array(repeating: "", count: fieldCount - note.fields.count)
                }
                try col.writeNote(note)
                col.registerTags(note.tags)
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
                    if result.primaryDeckID == nil { result.primaryDeckID = card.did }
                    if !options.includeScheduling && card.type != CardType.new {
                        PackageImporter.resetToNew(&card, position: nextPos)
                        nextPos += 1
                    } else if card.type == CardType.new {
                        card.due = positionMap[card.due] ?? nextPos
                    } else if card.queue == CardQueue.review || card.queue == CardQueue.dayLearn
                        || (card.queue < 0 && card.type == CardType.review)
                    {
                        card.due += dayOffset
                    }
                    if !options.includeScheduling {
                        card.flags = 0
                        if card.queue < 0 { card.queue = CardQueue.new }
                    }
                    card.usn = -1
                    card.mod = Time.nowSecs
                    try col.writeCard(card)
                    result.cardsAdded += 1
                    guard options.includeScheduling else { continue }
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
            col.conf["nextPos"] = .int(nextPos)
            try col.save()
        }
        progress("Done", 1)
        return result
    }

    static func resetToNew(_ card: inout Card, position: Int64) {
        card.type = CardType.new
        card.queue = CardQueue.new
        card.due = position
        card.ivl = 0
        card.factor = 0
        card.reps = 0
        card.lapses = 0
        card.left = 0
        card.data = "{}"
    }

    /// Replaces references to renamed media files in a field.
    static func rewriteMedia(_ field: String, _ renames: [String: String]) -> String {
        var out = field
        for (old, new) in renames where out.contains(old) {
            out = out.replacingOccurrences(of: "\"\(old)\"", with: "\"\(new)\"")
                .replacingOccurrences(of: "'\(old)'", with: "'\(new)'")
                .replacingOccurrences(of: "src=\(old)", with: "src=\(new)")
                .replacingOccurrences(of: "[sound:\(old)]", with: "[sound:\(new)]")
        }
        return out
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

    /// Copies package media into the media folder. A different file that
    /// already uses a name gets the incoming file renamed; the returned map
    /// lists those renames.
    private func importMedia(_ pkg: Package, result: inout ImportResult) throws -> [String: String] {
        guard let media else { return [:] }
        var renames: [String: String] = [:]
        let entries = try pkg.mediaEntries()
        for (i, entry) in entries.enumerated() {
            if i % 50 == 0 { progress("Importing media… \(i)/\(entries.count)", 0.3 * Double(i) / Double(max(1, entries.count))) }
            let name = MediaManager.normalize(entry.name)
            guard MediaManager.isSafe(name), pkg.zip.contains(entry.zipName) else { continue }
            let data = try pkg.mediaData(zipName: entry.zipName)
            guard !data.isEmpty else { continue }
            let (stored, exists) = media.resolveName(name, data: data)
            if stored != entry.name { renames[entry.name] = stored }
            if exists { continue }
            try media.addFile(name: stored, data: data)
            result.mediaFiles += 1
        }
        return renames
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
                try media.replaceFile(name: name, data: try pkg.mediaData(zipName: entry.zipName))
            }
        }
        return dest
    }
}

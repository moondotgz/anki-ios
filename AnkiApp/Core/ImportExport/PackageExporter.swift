import Foundation

/// Writes `.apkg` files in the "legacy 2" format (a schema 11
/// `collection.anki21` plus a JSON media map), which every current Anki
/// client can import.
enum PackageExporter {
    static func exportDeck(_ deckID: Int64, from col: Collection, includeScheduling: Bool, includeMedia: Bool,
                           to output: URL) throws
    {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let dbURL = workDir.appendingPathComponent("collection.anki21")

        let deckIDs = col.deckTreeIDs(deckID)
        let list = deckIDs.map(String.init).joined(separator: ",")
        let cards = try col.db.query("select \(Card.columns) from cards where did in (\(list)) or odid in (\(list))")
            .map(Card.init(row:))
        let noteIDs = Set(cards.map(\.nid))
        let notes = try noteIDs.compactMap { try col.note($0) }

        let out = try Database(path: dbURL.path)
        try out.transaction {
            try out.executeBatch(Collection.schema11)
            for note in notes {
                let nt = col.notetype(note.mid)
                let first = HTML.stripPreservingMediaFilenames(note.fields.first ?? "")
                let idx = min(nt?.sortIndex ?? 0, max(0, note.fields.count - 1))
                try out.execute("insert into notes values (?,?,?,?,?,?,?,?,?,?,?)",
                                note.id, note.guid, note.mid, note.mod, 0, note.joinedTags, note.joinedFields,
                                HTML.stripPreservingMediaFilenames(note.fields[idx]), Collection.fieldChecksum(first), 0, "")
            }
            var position: Int64 = 1
            for var card in cards.sorted(by: { ($0.type == CardType.new ? $0.due : 0, $0.id) < ($1.type == CardType.new ? $1.due : 0, $1.id) }) {
                if card.odid != 0 {
                    card.did = card.odid
                    card.due = card.odue
                    card.odid = 0
                    card.odue = 0
                }
                if !includeScheduling {
                    card.type = CardType.new
                    card.queue = CardQueue.new
                    card.due = position
                    card.ivl = 0
                    card.factor = 0
                    card.reps = 0
                    card.lapses = 0
                    card.left = 0
                    card.flags = 0
                    card.data = "{}"
                    position += 1
                } else if card.queue < 0 {
                    card.queue = Collection.restoredQueue(for: card)
                }
                card.usn = 0
                try out.execute("insert into cards values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", params: card.params)
            }
            if includeScheduling {
                for card in cards {
                    for var entry in try col.db.query("select \(RevlogEntry.columns) from revlog where cid = ?", card.id)
                        .map(RevlogEntry.init(row:))
                    {
                        entry.usn = 0
                        try out.execute("insert or ignore into revlog values (?,?,?,?,?,?,?,?,?)", params: entry.params)
                    }
                }
            }

            var models: [String: JSON] = [:]
            for mid in Set(notes.map(\.mid)) {
                if var nt = col.models[mid] {
                    nt["usn"] = 0
                    models[String(mid)] = nt
                }
            }
            var decks: [String: JSON] = [:]
            var dconf: [String: JSON] = [:]
            var exportDecks = deckIDs.compactMap { col.deck($0) }
            if let root = col.deck(deckID) { exportDecks += col.parents(of: root) }
            for deck in exportDecks {
                var json = deck.json
                json["usn"] = 0
                for key in ["newToday", "revToday", "lrnToday", "timeToday"] { json[key] = [0, 0] }
                decks[String(deck.id)] = json
                if !deck.isFiltered, var conf = col.dconf[deck.configID] {
                    conf["usn"] = 0
                    dconf[String(deck.configID)] = conf
                }
            }
            if decks["1"] == nil { decks["1"] = Defaults.deck(id: 1, name: "Default") }
            if dconf["1"] == nil { dconf["1"] = col.dconf[1] ?? Defaults.deckConfig(id: 1, name: "Default") }
            var conf = Defaults.conf(creationOffset: -TimeZone.current.secondsFromGMT() / 60)
            conf["nextPos"] = .int(position)
            try out.execute("update col set crt=?, mod=?, scm=?, ver=11, usn=0, ls=0, conf=?, models=?, decks=?, dconf=?, tags=?",
                            col.crt, Time.nowMillis, Time.nowMillis, conf.serialized(), JSON.object(models).serialized(),
                            JSON.object(decks).serialized(), JSON.object(dconf).serialized(), "{}")
        }
        out.close()

        var zip = ZipWriter()
        zip.add(name: "collection.anki21", data: try Data(contentsOf: dbURL))
        var mediaMap: [String: JSON] = [:]
        if includeMedia {
            var names = Set<String>()
            for note in notes {
                for field in note.fields { names.formUnion(HTML.mediaReferences(field)) }
            }
            for (idx, name) in names.sorted().enumerated() {
                let fileURL = col.mediaFolder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                zip.add(name: String(idx), data: data)
                mediaMap[String(idx)] = .string(name)
            }
        }
        zip.add(name: "media", data: JSON.object(mediaMap).data())
        try? fm.removeItem(at: output)
        try zip.finish().write(to: output)
    }
}

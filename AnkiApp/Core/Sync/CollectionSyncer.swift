import Foundation

enum SyncRequired: Equatable {
    case noChanges
    case normal
    case full(uploadOK: Bool, downloadOK: Bool)
}

struct SyncOutcome {
    var required: SyncRequired
    var serverMessage: String
    var newEndpoint: URL?
    var serverMediaUSN: Int
}

/// Client side of Anki's collection sync (rslib/src/sync/collection).
final class CollectionSyncer {
    let col: Collection
    let client: SyncClient
    var progress: (String) -> Void = { _ in }

    static let chunkSize = 250

    init(collection: Collection, client: SyncClient) {
        col = collection
        self.client = client
    }

    // MARK: Meta

    func remoteMeta() async throws -> (JSON, URL?) {
        let body: JSON = ["v": JSON(SyncClient.syncVersion), "cv": .string(SyncClient.clientVersion)]
        do {
            return (try await client.json("sync/meta", body), nil)
        } catch let redirect as SyncClient.PermanentRedirect {
            client.endpoint = redirect.location
            return (try await client.json("sync/meta", body), redirect.location)
        }
    }

    /// Determines what kind of sync is needed, then performs a normal sync
    /// if possible. Full syncs are reported back so the user can choose.
    func sync() async throws -> SyncOutcome {
        progress("Checking…")
        let (remote, newEndpoint) = try await remoteMeta()
        if !remote["cont"].bool(or: true) {
            throw SyncError.serverMessage(remote["msg"].string(or: "The server asked to stop syncing."))
        }
        let delta = remote["ts"].int(or: Time.nowSecs) - Time.nowSecs
        if abs(delta) > 300 { throw SyncError.clockIncorrect }

        let remoteMod = remote["mod"].int(or: 0)
        let remoteSchema = remote["scm"].int(or: 0)
        let remoteEmpty = remote["empty"].bool(or: false)
        let localEmpty = col.isEmpty
        var outcome = SyncOutcome(required: .noChanges, serverMessage: remote["msg"].string(or: ""),
                                  newEndpoint: newEndpoint, serverMediaUSN: remote["media_usn"].intValue)
        if remoteMod == col.mod {
            outcome.required = .noChanges
        } else if remoteSchema != col.scm {
            outcome.required = .full(uploadOK: !localEmpty || remoteEmpty, downloadOK: !remoteEmpty || localEmpty)
        } else {
            outcome.required = .normal
            try await normalSync(serverUSN: remote["usn"].intValue, localIsNewer: col.mod > remoteMod)
            outcome.required = .noChanges
        }
        return outcome
    }

    // MARK: Normal sync

    private func normalSync(serverUSN: Int, localIsNewer: Bool) async throws {
        let scheduler = Scheduler(collection: col)
        try scheduler.unburyIfDayRolledOver()
        try col.db.begin()
        do {
            try await start(serverUSN: serverUSN, localIsNewer: localIsNewer)
            try await unchunkedChanges(serverUSN: serverUSN, localIsNewer: localIsNewer)
            try await chunksFromServer()
            try await chunksToServer(serverUSN: serverUSN)
            progress("Finalizing…")
            try await sanityCheck()
            let finished = try await client.json("sync/finish", [:])
            guard let stamp = finished.int else { throw SyncError.invalidResponse("finish") }
            try col.save(modified: false)
            try col.setSyncState(usn: serverUSN + 1, mod: stamp, ls: stamp)
            try col.db.commit()
        } catch {
            col.db.rollback()
            try? col.reload()
            _ = try? await client.request("sync/abort", body: JSON.object([:]).data())
            if case SyncError.sanityCheckFailed = error { try? col.setSchemaModified() }
            throw error
        }
    }

    private func start(serverUSN: Int, localIsNewer: Bool) async throws {
        progress("Syncing deletions…")
        let remote = try await client.json("sync/start", ["minUsn": JSON(col.usn), "lnewer": .bool(localIsNewer)])

        // send local deletions
        var cards: [Int64] = [], notes: [Int64] = [], decks: [Int64] = []
        for r in try col.db.query("select oid, type from graves where usn = -1") {
            switch r[1].int {
            case Int64(GraveType.card): cards.append(r[0].int)
            case Int64(GraveType.note): notes.append(r[0].int)
            default: decks.append(r[0].int)
            }
        }
        try col.db.execute("update graves set usn = ? where usn = -1", serverUSN)
        while !cards.isEmpty || !notes.isEmpty || !decks.isEmpty {
            var limit = CollectionSyncer.chunkSize
            var chunk: (c: [Int64], n: [Int64], d: [Int64]) = ([], [], [])
            while limit > 0, let id = cards.popLast() { chunk.c.append(id); limit -= 1 }
            while limit > 0, let id = notes.popLast() { chunk.n.append(id); limit -= 1 }
            while limit > 0, let id = decks.popLast() { chunk.d.append(id); limit -= 1 }
            let graves: JSON = [
                "cards": .array(chunk.c.map(JSON.int)),
                "decks": .array(chunk.d.map(JSON.int)),
                "notes": .array(chunk.n.map(JSON.int)),
            ]
            _ = try await client.request("sync/applyGraves", body: JSON.object(["chunk": graves]).data())
        }

        // apply remote deletions
        for nid in remote["notes"].array?.compactMap(\.int) ?? [] {
            try col.db.execute("delete from notes where id = ?", nid)
            try col.addGrave(nid, type: GraveType.note, usn: serverUSN)
        }
        for cid in remote["cards"].array?.compactMap(\.int) ?? [] {
            try col.db.execute("delete from cards where id = ?", cid)
            try col.addGrave(cid, type: GraveType.card, usn: serverUSN)
        }
        for did in remote["decks"].array?.compactMap(\.int) ?? [] {
            col.decks.removeValue(forKey: did)
            try col.addGrave(did, type: GraveType.deck, usn: serverUSN)
        }
    }

    /// Collects JSON objects pending sync, marking them with the server usn.
    private func pending(_ map: inout [Int64: JSON], serverUSN: Int) -> [JSON] {
        var out: [JSON] = []
        for (id, var obj) in map where obj["usn"].int(or: 0) == -1 {
            obj["usn"] = JSON(serverUSN)
            map[id] = obj
            out.append(obj)
        }
        return out
    }

    private func unchunkedChanges(serverUSN: Int, localIsNewer: Bool) async throws {
        progress("Syncing note types and decks…")
        var changes: JSON = [
            "models": .array(pending(&col.models, serverUSN: serverUSN)),
            "decks": [
                .array(pending(&col.decks, serverUSN: serverUSN)),
                .array(pending(&col.dconf, serverUSN: serverUSN)),
            ],
            "tags": .array(col.tags.filter { $0.value == -1 }.map { JSON.string($0.key) }),
        ]
        for (tag, usn) in col.tags where usn == -1 { col.tags[tag] = serverUSN }
        if localIsNewer {
            changes["conf"] = col.conf
            changes["crt"] = .int(col.crt)
        }
        let remote = try await client.json("sync/applyChanges", ["changes": changes])

        for nt in remote["models"].array ?? [] {
            guard let id = nt["id"].int else { continue }
            if let existing = col.models[id] {
                guard existing["mod"].int(or: 0) <= nt["mod"].int(or: 0) else { continue }
                if existing["flds"].array?.count != nt["flds"].array?.count
                    || existing["tmpls"].array?.count != nt["tmpls"].array?.count
                {
                    throw SyncError.resyncRequired
                }
            }
            col.models[id] = nt
        }
        let decksAndConfig = remote["decks"]
        for var deck in decksAndConfig[0].array ?? [] {
            guard let id = deck["id"].int else { continue }
            if let existing = col.decks[id], existing["mod"].int(or: 0) > deck["mod"].int(or: 0) { continue }
            if case .bool(let b) = deck["dyn"] { deck["dyn"] = JSON(b ? 1 : 0) }
            col.decks[id] = deck
        }
        for conf in decksAndConfig[1].array ?? [] {
            guard let id = conf["id"].int else { continue }
            if let existing = col.dconf[id], existing["mod"].int(or: 0) > conf["mod"].int(or: 0) { continue }
            col.dconf[id] = conf
        }
        for tag in remote["tags"].array?.compactMap(\.string) ?? [] {
            if let existing = col.tags.keys.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                col.tags[existing] = serverUSN
            } else {
                col.tags[tag] = serverUSN
            }
        }
        if let crt = remote["crt"].int { try col.setCreationStamp(crt) }
        if case .object = remote["conf"] { col.conf = remote["conf"] }
        try col.save(modified: false)
    }

    private func chunksFromServer() async throws {
        var received = 0
        while true {
            progress("Receiving changes… \(received)")
            let chunk = try await client.json("sync/chunk", [:])
            for entry in chunk["revlog"].array ?? [] {
                guard let r = RevlogEntry(syncJSON: entry) else { continue }
                try col.db.execute("insert or ignore into revlog (\(RevlogEntry.columns)) values (?,?,?,?,?,?,?,?,?)", params: r.params)
            }
            for entry in chunk["cards"].array ?? [] {
                guard let card = Card(syncJSON: entry) else { continue }
                if let existing = try col.db.first("select mod, usn from cards where id = ?", card.id) {
                    let pending = existing[1].int == -1
                    if pending && existing[0].int >= card.mod { continue }
                }
                try col.writeCard(card)
            }
            for entry in chunk["notes"].array ?? [] {
                guard let note = Note(syncJSON: entry) else { continue }
                if let existing = try col.db.first("select mod, usn from notes where id = ?", note.id) {
                    let pending = existing[1].int == -1
                    if pending && existing[0].int >= note.mod { continue }
                }
                try col.writeNote(note)
            }
            for key in ["revlog", "cards", "notes"] { received += chunk[key].array?.count ?? 0 }
            if chunk["done"].bool(or: false) { break }
        }
    }

    private func chunksToServer(serverUSN: Int) async throws {
        var revlog = try col.db.query("select id from revlog where usn = -1").map { $0[0].int }
        var cards = try col.db.query("select id from cards where usn = -1").map { $0[0].int }
        var notes = try col.db.query("select id from notes where usn = -1").map { $0[0].int }
        var sent = 0
        while true {
            progress("Sending changes… \(sent)")
            var limit = CollectionSyncer.chunkSize
            var rIDs: [Int64] = [], cIDs: [Int64] = [], nIDs: [Int64] = []
            while limit > 0 {
                let last = limit
                if let id = revlog.popLast() { rIDs.append(id); limit -= 1 }
                if let id = notes.popLast() { nIDs.append(id); limit -= 1 }
                if let id = cards.popLast() { cIDs.append(id); limit -= 1 }
                if limit == last { break }
            }
            let done = limit > 0
            var chunk: [String: JSON] = ["done": .bool(done)]
            var revEntries: [JSON] = []
            for id in rIDs {
                try col.db.execute("update revlog set usn = ? where id = ?", serverUSN, id)
                if let row = try col.db.first("select \(RevlogEntry.columns) from revlog where id = ?", id) {
                    revEntries.append(RevlogEntry(row: row).syncJSON)
                }
            }
            var cardEntries: [JSON] = []
            for id in cIDs {
                try col.db.execute("update cards set usn = ? where id = ?", serverUSN, id)
                if let c = try col.card(id) { cardEntries.append(c.syncJSON) }
            }
            var noteEntries: [JSON] = []
            for id in nIDs {
                try col.db.execute("update notes set usn = ? where id = ?", serverUSN, id)
                if let n = try col.note(id) { noteEntries.append(n.syncJSON) }
            }
            if !revEntries.isEmpty { chunk["revlog"] = .array(revEntries) }
            if !cardEntries.isEmpty { chunk["cards"] = .array(cardEntries) }
            if !noteEntries.isEmpty { chunk["notes"] = .array(noteEntries) }
            _ = try await client.request("sync/applyChunk", body: JSON.object(["chunk": .object(chunk)]).data())
            sent += rIDs.count + cIDs.count + nIDs.count
            if done { break }
        }
    }

    private func sanityCheck() async throws {
        let counts: JSON = [
            [0, 0, 0],
            .int(try col.db.int("select count() from cards")),
            .int(try col.db.int("select count() from notes")),
            .int(try col.db.int("select count() from revlog")),
            .int(try col.db.int("select count() from graves")),
            JSON(col.models.count),
            JSON(col.decks.count),
            JSON(col.dconf.count),
        ]
        let resp = try await client.json("sync/sanityCheck2", ["client": counts])
        guard resp["status"].string == "ok" else { throw SyncError.sanityCheckFailed }
    }

    // MARK: Full sync

    /// Prepares the collection and uploads it, replacing AnkiWeb's copy.
    func fullUpload() async throws {
        progress("Uploading…")
        try col.db.transaction {
            try col.db.execute("delete from graves")
            for table in ["notes", "cards", "revlog"] {
                try col.db.execute("update \(table) set usn = 0 where usn = -1")
            }
            for (k, v) in col.tags where v == -1 { col.tags[k] = 0 }
            for (id, var obj) in col.models where obj["usn"].int(or: 0) == -1 { obj["usn"] = 0; col.models[id] = obj }
            for (id, var obj) in col.decks where obj["usn"].int(or: 0) == -1 { obj["usn"] = 0; col.decks[id] = obj }
            for (id, var obj) in col.dconf where obj["usn"].int(or: 0) == -1 { obj["usn"] = 0; col.dconf[id] = obj }
            try col.setUSN(col.usn + 1)
            try col.setSchemaModified()
            try col.save()
            try col.setLastSync(col.scm)
        }
        try col.db.executeBatch("vacuum")
        let data = try Data(contentsOf: col.url)
        if client.endpoint.host?.contains("ankiweb") == true, data.count >= 250 * 1024 * 1024 {
            throw SyncError.uploadTooLarge(String(format: "%.1f MB", Double(data.count) / 1_048_576))
        }
        let resp = try await client.request("sync/upload", body: data)
        let text = String(decoding: resp, as: UTF8.self)
        guard text == "OK" else { throw SyncError.serverMessage(text) }
    }

    /// Downloads AnkiWeb's copy into a new schema 11 file next to the
    /// collection and returns its location. The caller swaps it in.
    static func fullDownload(client: SyncClient, collectionURL: URL, progress: (String) -> Void) async throws -> URL {
        progress("Downloading…")
        let data = try await client.request("sync/download", body: JSON.object([:]).data())
        let dir = collectionURL.deletingLastPathComponent()
        let raw = dir.appendingPathComponent("download-\(UUID().uuidString).anki2")
        let converted = dir.appendingPathComponent("download-\(UUID().uuidString)-11.anki2")
        try data.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        do {
            let check = try Database(path: raw.path)
            let result = try check.scalar("pragma integrity_check").text
            check.close()
            guard result == "ok" else { throw SyncError.invalidResponse("downloaded collection is corrupt") }
        }
        progress("Converting…")
        try SchemaConverter.convertToSchema11(source: raw, destination: converted)
        let db = try Database(path: converted.path)
        try db.execute("update col set ls = mod")
        db.close()
        return converted
    }
}

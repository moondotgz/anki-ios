import Foundation

/// Tracks the media folder for syncing, like Anki's media database.
final class MediaManager {
    let folder: URL
    let db: Database

    init(folder: URL, dbURL: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        db = try Database(path: dbURL.path)
        try db.executeBatch("""
            create table if not exists media (fname text primary key not null, csum text, mtime int not null, dirty int not null);
            create index if not exists idx_media_dirty on media (dirty) where dirty = 1;
            create table if not exists meta (dirMod int, lastUsn int);
            """)
        if try db.int("select count() from meta") == 0 {
            try db.execute("insert into meta values (0, 0)")
        }
    }

    var lastUSN: Int {
        get { Int((try? db.int("select lastUsn from meta")) ?? 0) }
        set { _ = try? db.execute("update meta set lastUsn = ?", newValue) }
    }

    static func normalize(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    func url(for name: String) -> URL { folder.appendingPathComponent(name) }

    func fileExists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(for: name).path) }

    private func mtime(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Int64((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    /// Picks the name a file should be stored under: its own name, or a
    /// name with a hash suffix if a different file already uses it.
    /// `exists` is true when a file with the same content is already there.
    func resolveName(_ rawName: String, data: Data) -> (name: String, exists: Bool) {
        var name = MediaManager.normalize((rawName as NSString).lastPathComponent)
        if name.isEmpty { name = "pasted-\(UUID().uuidString)" }
        let sha = SHA1.hex(data)
        func sameContent(_ n: String) -> Bool {
            guard let existing = try? Data(contentsOf: url(for: n)) else { return false }
            return existing.count == data.count && SHA1.hex(existing) == sha
        }
        guard fileExists(name) else { return (name, false) }
        if sameContent(name) { return (name, true) }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let alt = "\(base)-\(sha.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
        return (alt, fileExists(alt) && sameContent(alt))
    }

    /// Adds a file to the media folder, renaming it if a different file
    /// already has that name. Returns the name actually used.
    @discardableResult
    func addFile(name rawName: String, data: Data) throws -> String {
        let (name, exists) = resolveName(rawName, data: data)
        if exists { return name }
        try data.write(to: url(for: name), options: .atomic)
        try db.execute("insert or replace into media values (?, ?, ?, 1)", name, SHA1.hex(data), mtime(url(for: name)))
        return name
    }

    /// Writes a file under exactly this name, replacing any existing file,
    /// and marks it for upload. Used when restoring a backup.
    func replaceFile(name: String, data: Data) throws {
        let fileURL = url(for: name)
        try data.write(to: fileURL, options: .atomic)
        try db.execute("insert or replace into media values (?, ?, ?, 1)", name, SHA1.hex(data), mtime(fileURL))
    }

    /// Writes a file received from the server, without marking it for upload.
    func writeSynced(name: String, data: Data) throws {
        let fileURL = url(for: name)
        try data.write(to: fileURL, options: .atomic)
        try db.execute("insert or replace into media values (?, ?, ?, 0)", name, SHA1.hex(data), mtime(fileURL))
    }

    func removeSynced(name: String) throws {
        try? FileManager.default.removeItem(at: url(for: name))
        try db.execute("delete from media where fname = ?", name)
    }

    /// Scans the folder for files added, changed or removed outside the app.
    func registerChanges() throws {
        let fm = FileManager.default
        let dirMod = mtime(folder)
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var known: [String: (csum: String?, mtime: Int64)] = [:]
        for r in try db.query("select fname, csum, mtime from media") {
            known[r[0].text] = (r[1].isNull ? nil : r[1].text, r[2].int)
        }
        try db.transaction {
            var seen = Set<String>()
            for raw in names where !raw.hasPrefix(".") {
                let fileURL = folder.appendingPathComponent(raw)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let name = MediaManager.normalize(raw)
                seen.insert(name)
                let m = mtime(fileURL)
                if let k = known[name], k.mtime == m, k.csum != nil { continue }
                guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }
                let sha = SHA1.hex(data)
                if let k = known[name], k.csum == sha {
                    try db.execute("update media set mtime = ? where fname = ?", m, name)
                } else {
                    try db.execute("insert or replace into media values (?, ?, ?, 1)", name, sha, m)
                }
            }
            for (name, k) in known where k.csum != nil && !seen.contains(name) {
                try db.execute("update media set csum = null, mtime = 0, dirty = 1 where fname = ?", name)
            }
            try db.execute("update meta set dirMod = ?", dirMod)
        }
    }

    var count: Int { Int((try? db.int("select count() from media where csum is not null")) ?? 0) }

    func forceResync() throws {
        try db.executeBatch("delete from media; update meta set lastUsn = 0, dirMod = 0;")
    }
}

/// Client side of Anki's media sync (rslib/src/sync/media).
final class MediaSyncer {
    let media: MediaManager
    let client: SyncClient
    var progress: (String) -> Void = { _ in }

    static let maxFilesInZip = 25

    init(media: MediaManager, client: SyncClient) {
        self.media = media
        self.client = client
    }

    func sync(serverUSN knownUSN: Int? = nil) async throws {
        progress("Checking media…")
        try media.registerChanges()
        let clientUSN = media.lastUSN
        let serverUSN: Int
        if let knownUSN {
            serverUSN = knownUSN
        } else {
            serverUSN = try await client.media("begin", ["v": .string(SyncClient.clientVersion)])["usn"].intValue
        }
        var acted = false
        if clientUSN != serverUSN {
            try await fetchChanges()
            acted = true
        }
        if try media.db.int("select count() from media where dirty = 1") > 0 {
            try await sendChanges()
            acted = true
        }
        if acted {
            let result = try await client.media("mediaSanity", ["local": JSON(media.count)])
            if result.string != "OK" {
                try media.forceResync()
                throw SyncError.resyncRequired
            }
        }
    }

    private func fetchChanges() async throws {
        var lastUSN = media.lastUSN
        var downloaded = 0
        while true {
            let batch = try await client.media("mediaChanges", ["lastUsn": JSON(lastUSN)]).array ?? []
            if batch.isEmpty { break }
            lastUSN = batch.last?[1].intValue ?? lastUSN
            var toDownload: [String] = []
            var toDelete: [String] = []
            var toClean: [String] = []
            for change in batch {
                let fname = change[0].string(or: "")
                let remoteSHA = change[2].string(or: "")
                guard MediaManager.isSafe(fname) else { continue }
                let local = try media.db.first("select csum, dirty from media where fname = ?", fname)
                let localSHA = local.map { $0[0].isNull ? "" : $0[0].text } ?? ""
                let pending = local.map { $0[1].int == 1 } ?? false
                switch (localSHA.isEmpty, remoteSHA.isEmpty) {
                case (true, true):
                    if local != nil { toDelete.append(fname) }
                case (true, false):
                    toDownload.append(fname)
                case (false, true):
                    if !pending { toDelete.append(fname) }
                case (false, false):
                    if localSHA == remoteSHA {
                        if pending { toClean.append(fname) }
                    } else {
                        toDownload.append(fname)
                    }
                }
            }
            for name in toDelete { try media.removeSynced(name: name) }
            var remaining = toDownload[...]
            while !remaining.isEmpty {
                let names = Array(remaining.prefix(MediaSyncer.maxFilesInZip))
                progress("Downloading media… \(downloaded)")
                let zipData = try await client.mediaRaw("downloadFiles", body: JSON.object(["files": .array(names.map(JSON.string))]).data())
                let zip = try ZipReader(data: zipData)
                let meta = try JSON.parse(zip.read("_meta"))
                var count = 0
                for (zipName, real) in meta.object ?? [:] {
                    guard let realName = real.string, MediaManager.isSafe(realName) else { continue }
                    let data = try zip.read(zipName)
                    try media.writeSynced(name: MediaManager.normalize(realName), data: data)
                    count += 1
                }
                guard count > 0 else { throw SyncError.invalidResponse("empty media zip") }
                remaining = remaining.dropFirst(count)
                downloaded += count
            }
            for name in toClean { try media.db.execute("update media set dirty = 0 where fname = ?", name) }
            media.lastUSN = lastUSN
        }
    }

    private func sendChanges() async throws {
        var uploaded = 0
        while true {
            let pending = try media.db.query(
                "select fname, csum from media where dirty = 1 limit \(MediaSyncer.maxFilesInZip)")
            if pending.isEmpty { break }
            progress("Uploading media… \(uploaded)")
            var zip = ZipWriter()
            var entries: [JSON] = []
            var included: [String] = []
            for (idx, row) in pending.enumerated() {
                let name = row[0].text
                if row[1].isNull {
                    entries.append([.string(name), .null])
                    included.append(name)
                    continue
                }
                guard let data = try? Data(contentsOf: media.url(for: name)), !data.isEmpty,
                      data.count <= 100 * 1024 * 1024
                else {
                    try media.db.execute("delete from media where fname = ?", name)
                    continue
                }
                zip.add(name: String(idx), data: data)
                entries.append([.string(name), .string(String(idx))])
                included.append(name)
            }
            if included.isEmpty { continue }
            zip.add(name: "_meta", data: JSON.array(entries).data())
            let reply = try await client.mediaUpload(zip.finish())
            let processed = reply[0].intValue
            let currentUSN = reply[1].intValue
            for name in included.prefix(processed) {
                try media.db.execute("update media set dirty = 0 where fname = ?", name)
                try media.db.execute("delete from media where fname = ? and csum is null", name)
            }
            if media.lastUSN + processed == currentUSN { media.lastUSN = currentUSN }
            uploaded += processed
            if processed == 0 { break }
        }
    }
}

extension SyncClient {
    /// Media upload sends a raw zip body but returns a JSON result.
    func mediaUpload(_ zip: Data) async throws -> JSON {
        let data = try await request("msync/uploadChanges", body: zip)
        let resp = try JSON.parse(data)
        if let err = resp["err"].string, !err.isEmpty { throw SyncError.serverMessage(err) }
        return resp["data"]
    }
}

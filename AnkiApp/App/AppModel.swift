import Foundation
import Observation
import SwiftUI

struct FullSyncPrompt: Identifiable {
    let id = UUID()
    let uploadOK: Bool
    let downloadOK: Bool
}

/// Owns the open collection and coordinates syncing, importing and
/// refreshing the UI.
@MainActor
@Observable
final class AppModel {
    private(set) var col: Collection?
    private(set) var media: MediaManager?
    private(set) var deckTree: [DeckTreeNode] = []
    /// Bumped after any change so views can reload.
    private(set) var revision = 0

    var busyMessage: String?
    var errorMessage: String?
    var infoMessage: String?
    var fullSyncPrompt: FullSyncPrompt?
    var isSyncing = false
    var syncProgress = ""
    var pendingImport: URL?

    // Preferences live in UserDefaults; access/withMutation keep them observable.
    var username: String {
        get { access(keyPath: \.username); return UserDefaults.standard.string(forKey: "syncUsername") ?? "" }
        set { withMutation(keyPath: \.username) { UserDefaults.standard.set(newValue, forKey: "syncUsername") } }
    }
    var customServer: String {
        get { access(keyPath: \.customServer); return UserDefaults.standard.string(forKey: "customSyncServer") ?? "" }
        set { withMutation(keyPath: \.customServer) { UserDefaults.standard.set(newValue, forKey: "customSyncServer") } }
    }
    var syncMedia: Bool {
        get { access(keyPath: \.syncMedia); return UserDefaults.standard.object(forKey: "syncMedia") as? Bool ?? true }
        set { withMutation(keyPath: \.syncMedia) { UserDefaults.standard.set(newValue, forKey: "syncMedia") } }
    }
    var autoSync: Bool {
        get { access(keyPath: \.autoSync); return UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true }
        set { withMutation(keyPath: \.autoSync) { UserDefaults.standard.set(newValue, forKey: "autoSync") } }
    }
    private(set) var hostKey: String? = Keychain.get("hostKey")
    var isLoggedIn: Bool { hostKey != nil }

    /// Endpoint learned from a server redirect, kept until logout.
    private var redirectedEndpoint: String? {
        get { UserDefaults.standard.string(forKey: "syncEndpoint") }
        set { UserDefaults.standard.set(newValue, forKey: "syncEndpoint") }
    }

    static var baseFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Anki", isDirectory: true)
    }
    static var collectionURL: URL { baseFolder.appendingPathComponent("collection.anki2") }
    static var mediaFolder: URL { baseFolder.appendingPathComponent("collection.media", isDirectory: true) }
    static var mediaDBURL: URL { baseFolder.appendingPathComponent("collection.media.db") }

    init() {
        open()
    }

    func open() {
        do {
            try FileManager.default.createDirectory(at: AppModel.baseFolder, withIntermediateDirectories: true)
            col = try Collection(url: AppModel.collectionURL, mediaFolder: AppModel.mediaFolder)
            media = try MediaManager(folder: AppModel.mediaFolder, dbURL: AppModel.mediaDBURL)
            refresh()
        } catch {
            errorMessage = "Couldn't open the collection: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let col else { return }
        deckTree = Scheduler(collection: col).deckTree()
        revision += 1
    }

    /// Runs a collection change, reporting errors and refreshing.
    func perform(_ body: (Collection) throws -> Void) {
        guard let col else { return }
        do {
            try body(col)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    var hasUnsyncedChanges: Bool {
        _ = revision
        return col.map { $0.hasUnsyncedChanges || $0.needsFullSync } ?? false
    }

    // MARK: Sync

    private var endpoint: URL? {
        let custom = customServer.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            return URL(string: custom.hasSuffix("/") ? custom : custom + "/")
        }
        return redirectedEndpoint.flatMap(URL.init(string:))
    }

    func login(username: String, password: String) async -> Bool {
        busyMessage = "Signing in…"
        defer { busyMessage = nil }
        do {
            let client = SyncClient(endpoint: endpoint)
            let key = try await client.login(username: username, password: password)
            Keychain.set(key, for: "hostKey")
            hostKey = key
            self.username = username
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func logout() {
        Keychain.set(nil, for: "hostKey")
        hostKey = nil
        redirectedEndpoint = nil
    }

    func sync() async {
        guard let col, let hostKey, !isSyncing else { return }
        isSyncing = true
        syncProgress = "Syncing…"
        defer {
            isSyncing = false
            syncProgress = ""
            refresh()
        }
        let client = SyncClient(hostKey: hostKey, endpoint: endpoint)
        let syncer = CollectionSyncer(collection: col, client: client)
        syncer.progress = { [weak self] msg in Task { @MainActor in self?.syncProgress = msg } }
        do {
            let outcome = try await syncer.sync()
            if let newEndpoint = outcome.newEndpoint { redirectedEndpoint = newEndpoint.absoluteString }
            if !outcome.serverMessage.isEmpty { infoMessage = outcome.serverMessage }
            if case .full(let up, let down) = outcome.required {
                fullSyncPrompt = FullSyncPrompt(uploadOK: up, downloadOK: down)
                return
            }
            try await syncMediaIfEnabled(client: client, serverUSN: outcome.serverMediaUSN)
        } catch SyncError.authFailed {
            logout()
            errorMessage = SyncError.authFailed.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncMediaIfEnabled(client: SyncClient, serverUSN: Int?) async throws {
        guard syncMedia, let media else { return }
        let syncer = MediaSyncer(media: media, client: client)
        syncer.progress = { [weak self] msg in Task { @MainActor in self?.syncProgress = msg } }
        do {
            try await syncer.sync()
        } catch SyncError.resyncRequired {
            try await syncer.sync()
        }
    }

    /// Completes a one-way sync after the user chose a direction.
    func fullSync(upload: Bool) async {
        guard let col, let hostKey else { return }
        fullSyncPrompt = nil
        isSyncing = true
        busyMessage = upload ? "Uploading to AnkiWeb…" : "Downloading from AnkiWeb…"
        defer {
            isSyncing = false
            busyMessage = nil
            refresh()
        }
        let client = SyncClient(hostKey: hostKey, endpoint: endpoint)
        do {
            if upload {
                try await CollectionSyncer(collection: col, client: client).fullUpload()
            } else {
                let newURL = try await CollectionSyncer.fullDownload(client: client, collectionURL: col.url) { _ in }
                replaceCollection(with: newURL)
            }
            busyMessage = "Syncing media…"
            try await syncMediaIfEnabled(client: client, serverUSN: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceCollection(with newURL: URL) {
        col?.close()
        col = nil
        let fm = FileManager.default
        let target = AppModel.collectionURL
        let backup = target.deletingLastPathComponent().appendingPathComponent("collection-backup.anki2")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: newURL, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            errorMessage = error.localizedDescription
        }
        open()
    }

    // MARK: Import / export

    func importPackage(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        if url.pathExtension.lowercased() == "colpkg" {
            busyMessage = "Restoring collection…"
            defer { busyMessage = nil }
            do {
                let media = self.media
                let colURL = AppModel.collectionURL
                let newURL = try await Task.detached {
                    try PackageImporter.extractColpkg(tmp, besides: colURL, media: media)
                }.value
                replaceCollection(with: newURL)
                infoMessage = "Collection restored. Your next sync will ask whether to upload it to AnkiWeb."
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        guard let col else { return }
        busyMessage = "Importing…"
        defer {
            busyMessage = nil
            refresh()
        }
        do {
            let media = self.media
            let result = try await Task.detached {
                try PackageImporter(collection: col, media: media).importApkg(tmp)
            }.value
            infoMessage = "Import complete: \(result.summary)."
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportDeck(_ deckID: Int64, includeScheduling: Bool, includeMedia: Bool) -> URL? {
        guard let col, let deck = col.deck(deckID) else { return nil }
        let safeName = deck.name.replacingOccurrences(of: "::", with: " - ")
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).apkg")
        do {
            try PackageExporter.exportDeck(deckID, from: col, includeScheduling: includeScheduling,
                                           includeMedia: includeMedia, to: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func checkDatabase() {
        guard let col else { return }
        do {
            let result = try col.db.scalar("pragma integrity_check").text
            // cards whose note is missing are removed, like Anki's Check Database
            let orphans = try col.db.query("select id from cards where nid not in (select id from notes)").map { $0[0].int }
            if !orphans.isEmpty { try col.removeCards(orphans) }
            try col.db.executeBatch("vacuum; analyze")
            infoMessage = result == "ok"
                ? "Database rebuilt and optimized." + (orphans.isEmpty ? "" : " Removed \(orphans.count) orphaned cards.")
                : "Database problems found: \(result)"
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}

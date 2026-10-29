import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable {
    case decks, browse, stats, settings
}

/// A package file chosen for import, copied into the app's temporary folder.
struct ImportRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
    let displayName: String
    var isCollectionPackage: Bool { fileURL.pathExtension.lowercased() == "colpkg" }
}

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
    var importRequest: ImportRequest?
    /// Shows the system file picker for packages.
    var showFilePicker = false
    /// Set while an import writes to the collection; sync and refresh wait.
    private(set) var isImporting = false
    var selectedTab: AppTab = .decks
    /// A deck to start studying, e.g. after importing it.
    var studyRequest: Int64?

    // MARK: Profiles

    private(set) var profiles: [Profile] = ProfileStore.load()
    private(set) var profile: Profile = ProfileStore.current(in: ProfileStore.load())

    // Preferences live in UserDefaults, per profile; access/withMutation keep
    // them observable.
    private func string(_ name: String) -> String? { UserDefaults.standard.string(forKey: profile.key(name)) }
    private func bool(_ name: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: profile.key(name)) as? Bool ?? fallback
    }
    private func setDefault(_ value: Any?, _ name: String) { UserDefaults.standard.set(value, forKey: profile.key(name)) }

    var username: String {
        get { access(keyPath: \.username); return string("syncUsername") ?? "" }
        set { withMutation(keyPath: \.username) { setDefault(newValue, "syncUsername") } }
    }
    var customServer: String {
        get { access(keyPath: \.customServer); return string("customSyncServer") ?? "" }
        set { withMutation(keyPath: \.customServer) { setDefault(newValue, "customSyncServer") } }
    }
    var syncMedia: Bool {
        get { access(keyPath: \.syncMedia); return bool("syncMedia", true) }
        set { withMutation(keyPath: \.syncMedia) { setDefault(newValue, "syncMedia") } }
    }
    var autoSync: Bool {
        get { access(keyPath: \.autoSync); return bool("autoSync", true) }
        set { withMutation(keyPath: \.autoSync) { setDefault(newValue, "autoSync") } }
    }
    private(set) var hostKey: String?
    var isLoggedIn: Bool { hostKey != nil }

    /// Endpoint learned from a server redirect, kept until logout.
    private var redirectedEndpoint: String? {
        get { string("syncEndpoint") }
        set { setDefault(newValue, "syncEndpoint") }
    }

    var collectionURL: URL { profile.collectionURL }

    init() {
        hostKey = Keychain.get(profile.key("hostKey"))
        open()
    }

    /// Closes the current collection and opens another profile's.
    func switchProfile(to id: String) {
        guard id != profile.id, let next = profiles.first(where: { $0.id == id }) else { return }
        guard !isSyncing, !isImporting else {
            errorMessage = "Wait for the current sync or import to finish before switching profiles."
            return
        }
        col?.close()
        col = nil
        media = nil
        deckTree = []
        profile = next
        ProfileStore.currentID = next.id
        hostKey = Keychain.get(next.key("hostKey"))
        // re-read the per-profile preferences
        withMutation(keyPath: \.username) {}
        withMutation(keyPath: \.customServer) {}
        withMutation(keyPath: \.syncMedia) {}
        withMutation(keyPath: \.autoSync) {}
        selectedTab = .decks
        open()
        if autoSync && isLoggedIn { Task { await sync() } }
    }

    @discardableResult
    func addProfile(named rawName: String) -> Profile? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "A profile named “\(name)” already exists."
            return nil
        }
        let new = Profile(id: UUID().uuidString, name: name)
        profiles.append(new)
        ProfileStore.save(profiles)
        return new
    }

    func renameProfile(_ id: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "A profile named “\(name)” already exists."
            return
        }
        profiles[idx].name = name
        ProfileStore.save(profiles)
        if profile.id == id { profile = profiles[idx] }
    }

    /// Deletes another profile with its collection, media and login.
    func deleteProfile(_ id: String) {
        guard id != profile.id, let victim = profiles.first(where: { $0.id == id }) else { return }
        let fm = FileManager.default
        if victim.isLegacy {
            for url in [victim.collectionURL, victim.mediaFolder, victim.mediaDBURL,
                        victim.folder.appendingPathComponent("collection-backup.anki2")] {
                try? fm.removeItem(at: url)
            }
        } else {
            try? fm.removeItem(at: victim.folder)
        }
        Keychain.set(nil, for: victim.key("hostKey"))
        for key in ProfileStore.settingKeys { UserDefaults.standard.removeObject(forKey: victim.key(key)) }
        profiles.removeAll { $0.id == id }
        ProfileStore.save(profiles)
    }

    func open() {
        do {
            try FileManager.default.createDirectory(at: profile.folder, withIntermediateDirectories: true)
            col = try Collection(url: profile.collectionURL, mediaFolder: profile.mediaFolder)
            media = try MediaManager(folder: profile.mediaFolder, dbURL: profile.mediaDBURL)
            refresh()
        } catch {
            errorMessage = "Couldn't open the collection: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let col, !isImporting else { return }
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
            Keychain.set(key, for: profile.key("hostKey"))
            hostKey = key
            self.username = username
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func logout() {
        Keychain.set(nil, for: profile.key("hostKey"))
        hostKey = nil
        redirectedEndpoint = nil
    }

    func sync() async {
        guard let col, let hostKey, !isSyncing, !isImporting else { return }
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
        let target = profile.collectionURL
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

    /// Starts importing a file from the file picker, Files, AirDrop, Safari or
    /// another app. The file is copied right away, while access is granted.
    func beginImport(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        let ext = url.pathExtension.isEmpty ? "apkg" : url.pathExtension.lowercased()
        let copy = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copy)
        } catch {
            errorMessage = "Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        // copies handed over by other apps or the picker live in our Inbox
        // folders; don't keep them around
        if url.path.contains("/Documents/Inbox/") || url.path.contains("-Inbox/") { try? fm.removeItem(at: url) }
        if let old = importRequest { try? fm.removeItem(at: old.fileURL) }
        selectedTab = .decks
        importRequest = ImportRequest(fileURL: copy, displayName: url.lastPathComponent)
    }

    func finishImport(_ request: ImportRequest) {
        try? FileManager.default.removeItem(at: request.fileURL)
        if importRequest?.id == request.id { importRequest = nil }
        refresh()
    }

    /// Extracts a package off the main thread for previewing.
    func openPackage(_ request: ImportRequest) async throws -> OpenedPackage {
        let url = request.fileURL
        return try await Task.detached(priority: .userInitiated) {
            try OpenedPackage(url: url)
        }.value
    }

    /// How many notes in the package are already in the collection.
    func existingNoteCount(in opened: OpenedPackage) -> Int {
        guard let col else { return 0 }
        let guids = (try? opened.source.db.query("select guid from notes").map { $0[0].text }) ?? []
        return (try? PackageImporter(collection: col, media: nil).countExisting(guids: guids)) ?? 0
    }

    /// Merges an opened `.apkg` into the collection.
    func runImport(_ opened: OpenedPackage, options: ImportOptions,
                   progress: @escaping @MainActor (String, Double) -> Void) async -> ImportResult?
    {
        guard let col, !isImporting else { return nil }
        isImporting = true
        defer {
            isImporting = false
            refresh()
        }
        let media = self.media
        do {
            return try await Task.detached(priority: .userInitiated) {
                let importer = PackageImporter(collection: col, media: media)
                importer.progress = { stage, fraction in
                    Task { @MainActor in progress(stage, fraction) }
                }
                return try importer.importPackage(opened, options: options)
            }.value
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Replaces the whole collection with a `.colpkg` backup.
    func restoreCollection(_ request: ImportRequest) async -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        defer { isImporting = false }
        do {
            let media = self.media
            let colURL = profile.collectionURL
            let source = request.fileURL
            let newURL = try await Task.detached(priority: .userInitiated) {
                try PackageImporter.extractColpkg(source, besides: colURL, media: media)
            }.value
            isImporting = false
            replaceCollection(with: newURL)
            return true
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
            return false
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

import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Sync with AnkiWeb")
                        .font(.title2.bold())
                    Text("Use your free AnkiWeb account to keep your cards in sync with Anki on your computer and other devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Email", text: $username)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } footer: {
                if !app.customServer.isEmpty {
                    Text("Using custom sync server \(app.customServer)")
                } else {
                    Link("Create an AnkiWeb account", destination: URL(string: "https://ankiweb.net/account/signup")!)
                }
            }
            Section {
                Button {
                    working = true
                    Task {
                        if await app.login(username: username, password: password) {
                            dismiss()
                            await app.sync()
                        }
                        working = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if working { ProgressView() } else { Text("Sign In").bold() }
                        Spacer()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(username.isEmpty || password.isEmpty || working)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("AnkiWeb")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
        }
        .onAppear { username = app.username }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showLogin = false
    @State private var confirmUpload = false
    @State private var confirmDownload = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                ProfilesSection()

                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                }

                Section("AnkiWeb") {
                    if app.isLoggedIn {
                        LabeledContent("Account", value: app.username)
                        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await app.sync() }
                        }
                        .disabled(app.isSyncing)
                        Toggle("Sync media", isOn: $app.syncMedia)
                        Toggle("Sync when opening the app", isOn: $app.autoSync)
                        Menu("One-Way Sync", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                            Button("Upload to AnkiWeb", systemImage: "icloud.and.arrow.up") { confirmUpload = true }
                            Button("Download from AnkiWeb", systemImage: "icloud.and.arrow.down") { confirmDownload = true }
                        }
                        Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            app.logout()
                        }
                    } else {
                        Button("Sign In to AnkiWeb", systemImage: "person.crop.circle") { showLogin = true }
                    }
                }

                Section {
                    TextField("https://sync.example.com/", text: $app.customServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Self-Hosted Sync Server")
                } footer: {
                    Text("Leave empty to use AnkiWeb. Works with Anki's built-in sync server. Log out and in again after changing it.")
                }

                if let col = app.col {
                    SchedulingSettings(col: col)
                }

                Section("Collection") {
                    Button("Import Deck (.apkg)", systemImage: "square.and.arrow.down") { app.showFilePicker = true }
                    Button("Restore Backup (.colpkg)", systemImage: "archivebox") { app.showFilePicker = true }
                    Button("Check Database", systemImage: "stethoscope") { app.checkDatabase() }
                    LabeledContent("Cards", value: "\(app.col?.cardCount ?? 0)")
                    LabeledContent("Notes", value: "\(app.col?.noteCount ?? 0)")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("Sync protocol", value: "v\(SyncClient.syncVersion)")
                } footer: {
                    Text("An independent client compatible with Anki and AnkiWeb. Anki is a trademark of Ankitects Pty Ltd.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogin) {
                NavigationStack { LoginView() }
            }
            .confirmationDialog("Replace AnkiWeb's copy with this device's collection?",
                                isPresented: $confirmUpload, titleVisibility: .visible) {
                Button("Upload", role: .destructive) { Task { await app.fullSync(upload: true) } }
            }
            .confirmationDialog("Replace this device's collection with AnkiWeb's copy?",
                                isPresented: $confirmDownload, titleVisibility: .visible) {
                Button("Download", role: .destructive) { Task { await app.fullSync(upload: false) } }
            }
        }
    }
}

private struct SchedulingSettings: View {
    @Environment(AppModel.self) private var app
    let col: Collection
    @State private var rollover = 4
    @State private var learnAhead = 20
    @State private var showIntervals = true
    @State private var showCounts = true
    @State private var newSpread = 0
    @State private var loaded = false

    var body: some View {
        Section("Review") {
            Stepper("Next day starts at \(rollover):00", value: $rollover, in: 0...23)
            Stepper("Learn ahead limit: \(learnAhead) min", value: $learnAhead, in: 0...120, step: 5)
            Picker("New cards", selection: $newSpread) {
                Text("Mix with reviews").tag(0)
                Text("After reviews").tag(1)
                Text("Before reviews").tag(2)
            }
            Toggle("Show answer times on buttons", isOn: $showIntervals)
            Toggle("Show remaining card count", isOn: $showCounts)
        }
        .onAppear {
            rollover = col.rolloverHour
            learnAhead = Int(col.learnAheadSecs / 60)
            showIntervals = col.conf["estTimes"].bool(or: true)
            showCounts = col.conf["dueCounts"].bool(or: true)
            newSpread = Int(col.conf["newSpread"].int(or: 0))
            loaded = true
        }
        .onChange(of: rollover) { _, v in update("rollover", JSON(v)) }
        .onChange(of: learnAhead) { _, v in update("collapseTime", JSON(v * 60)) }
        .onChange(of: showIntervals) { _, v in update("estTimes", .bool(v)) }
        .onChange(of: showCounts) { _, v in update("dueCounts", .bool(v)) }
        .onChange(of: newSpread) { _, v in update("newSpread", JSON(v)) }
    }

    private func update(_ key: String, _ value: JSON) {
        guard loaded, col.conf[key] != value else { return }
        app.perform { try $0.setConfig(key, value) }
    }
}

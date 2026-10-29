import SwiftUI

@main
struct AnkiApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { url in
                    app.beginImport(url)
                }
                .task {
                    if app.autoSync && app.isLoggedIn { await app.sync() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.refresh()
            case .background:
                if app.autoSync && app.isLoggedIn && app.hasUnsyncedChanges && !app.isSyncing {
                    Task { await app.sync() }
                }
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(ThemeKey.appearance) private var appearance = AppearanceMode.system
    @AppStorage(ThemeKey.accent) private var accent = AccentChoice.blue

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Decks", systemImage: "rectangle.stack.fill", value: AppTab.decks) {
                DeckListView()
            }
            Tab("Browse", systemImage: "magnifyingglass", value: AppTab.browse) {
                BrowseView()
            }
            Tab("Stats", systemImage: "chart.bar.fill", value: AppTab.stats) {
                StatsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(accent.color)
        .preferredColorScheme(appearance.colorScheme)
        .overlay {
            if let message = app.busyMessage {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(message)
                            .font(.headline)
                        if !app.syncProgress.isEmpty && app.syncProgress != message {
                            Text(app.syncProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(28)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: app.busyMessage)
        .alert("Error", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .alert("Anki", isPresented: Binding(get: { app.infoMessage != nil }, set: { if !$0 { app.infoMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.infoMessage ?? "")
        }
        .sheet(isPresented: $app.showFilePicker) {
            DocumentPicker { url in
                app.showFilePicker = false
                // let the picker finish dismissing before the import sheet appears
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    app.beginImport(url)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $app.importRequest) { request in
            ImportView(request: request)
                .presentationDetents([.large])
        }
        .sheet(item: $app.fullSyncPrompt) { prompt in
            FullSyncSheet(prompt: prompt)
                .presentationDetents([.medium])
        }
    }
}

struct FullSyncSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let prompt: FullSyncPrompt

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("One-Way Sync Required")
                .font(.title2.bold())
            Text("Your collection was changed in a way that can't be merged (for example, a note type was modified, or this device has never synced). Choose which copy to keep. The other will be replaced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    if prompt.downloadOK {
                        Button {
                            Task { await app.fullSync(upload: false) }
                        } label: {
                            Label("Download from AnkiWeb", systemImage: "icloud.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if prompt.uploadOK {
                        Button {
                            Task { await app.fullSync(upload: true) }
                        } label: {
                            Label("Upload to AnkiWeb", systemImage: "icloud.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
        .padding(24)
    }
}

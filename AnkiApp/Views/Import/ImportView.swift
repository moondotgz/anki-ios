import SwiftUI

/// Previews a package, lets the user choose options, and imports it.
struct ImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: ImportRequest

    private enum Phase {
        case reading
        case ready(OpenedPackage)
        case importing(OpenedPackage)
        case done(ImportResult)
        case failed(String)
    }

    @State private var phase: Phase = .reading
    @State private var existingNotes = 0
    @State private var options = ImportOptions()
    @State private var stage = ""
    @State private var fraction = 0.0
    @State private var confirmRestore = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .reading:
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Reading “\(request.displayName)”…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready(let opened):
                    previewForm(opened)
                case .importing:
                    importingView
                case .done(let result):
                    doneView(result)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Can't Import", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Close") { close() }
                            .buttonStyle(.glass)
                    }
                }
            }
            .navigationTitle(request.isCollectionPackage ? "Restore Collection" : "Import Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isImporting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { close() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .task { await load() }
        .onDisappear {
            // swiping the sheet away also cleans up
            if case .ready(let opened) = phase { opened.close() }
            if !isImporting { app.finishImport(request) }
        }
    }

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    // MARK: Preview

    private func previewForm(_ opened: OpenedPackage) -> some View {
        let p = opened.preview
        return Form {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: p.isCollectionPackage ? "archivebox.fill" : "shippingbox.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    VStack(spacing: 4) {
                        Text(p.fileName)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(p.format)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            tile("Notes", p.notes)
                            tile("Cards", p.cards)
                            tile("Media", p.mediaFiles)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            if !p.decks.isEmpty {
                Section("Decks") {
                    ForEach(p.decks, id: \.self) { name in
                        let depth = name.components(separatedBy: "::").count - 1
                        Label(name.components(separatedBy: "::").last ?? name, systemImage: "rectangle.stack")
                            .padding(.leading, CGFloat(depth) * 16)
                    }
                }
            }

            if !p.notetypes.isEmpty {
                Section("Note Types") {
                    Text(p.notetypes.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }

            if p.isCollectionPackage {
                Section {
                    Label("Restoring replaces every deck, note and review on this device with the contents of this backup.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("Your next sync will ask whether to upload the restored collection to AnkiWeb.")
                }
            } else {
                Section {
                    Toggle("Include learning progress", isOn: $options.includeScheduling)
                        .disabled(!p.hasScheduling)
                } footer: {
                    if p.hasScheduling {
                        Text("Keeps \(p.studiedCards) studied cards’ intervals and \(p.revlogEntries) reviews. Turn off to start every card as new.")
                    } else {
                        Text("All cards in this package are new.")
                    }
                }

                if existingNotes > 0 {
                    Section {
                        Picker("Update existing notes", selection: $options.updateNotes) {
                            ForEach(ImportUpdatePolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                    } footer: {
                        Text("\(existingNotes) of these notes are already in your collection. Their scheduling is never changed.")
                    }
                }
            }

            Section {
                Button {
                    if p.isCollectionPackage {
                        confirmRestore = true
                    } else {
                        Task { await runImport(opened) }
                    }
                } label: {
                    Text(p.isCollectionPackage ? "Replace Collection" : "Import \(p.notes) Note\(p.notes == 1 ? "" : "s")")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(p.isCollectionPackage ? .orange : .accentColor)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .confirmationDialog("Replace your collection with this backup?", isPresented: $confirmRestore,
                            titleVisibility: .visible) {
            Button("Replace Collection", role: .destructive) { Task { await restore(opened) } }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func tile(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    // MARK: Progress and result

    private var importingView: some View {
        VStack(spacing: 18) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            Text(stage.isEmpty ? "Importing…" : stage)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func doneView(_ result: ImportResult) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: true)
            Text(request.isCollectionPackage ? "Collection Restored" : "Import Complete")
                .font(.title2.bold())
            if !request.isCollectionPackage {
                Text(result.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !result.decks.isEmpty {
                    Text("New decks: \(result.decks.joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    if let deckID = studyDeck(result) {
                        Button {
                            app.studyRequest = deckID
                            close()
                        } label: {
                            Label("Study Now", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button("Done") { close() }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 320)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The top-level deck the imported cards went into, if it has cards due.
    private func studyDeck(_ result: ImportResult) -> Int64? {
        guard let col = app.col, let id = result.primaryDeckID, let deck = col.deck(id) else { return nil }
        let root = col.deck(named: deck.components.first ?? deck.name) ?? deck
        return Scheduler(collection: col).counts(for: root.id).total > 0 ? root.id : nil
    }

    // MARK: Actions

    private func load() async {
        guard case .reading = phase else { return }
        do {
            let opened = try await app.openPackage(request)
            existingNotes = app.existingNoteCount(in: opened)
            options.includeScheduling = opened.preview.hasScheduling
            phase = .ready(opened)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runImport(_ opened: OpenedPackage) async {
        phase = .importing(opened)
        let result = await app.runImport(opened, options: options) { s, f in
            stage = s
            fraction = f
        }
        opened.close()
        if let result {
            phase = .done(result)
        } else {
            phase = .failed(app.errorMessage ?? "The import failed.")
            app.errorMessage = nil
        }
    }

    private func restore(_ opened: OpenedPackage) async {
        phase = .importing(opened)
        stage = "Restoring collection…"
        opened.close()
        if await app.restoreCollection(request) {
            phase = .done(ImportResult())
        } else {
            phase = .failed(app.errorMessage ?? "The restore failed.")
            app.errorMessage = nil
        }
    }

    private func close() {
        if case .ready(let opened) = phase { opened.close() }
        app.finishImport(request)
        dismiss()
    }
}

import SwiftUI

struct DeckOverviewView: View {
    @Environment(AppModel.self) private var app
    let deckID: Int64
    let onStudy: () -> Void
    @State private var exportURL: URL?
    @State private var showOptions = false
    @State private var showCustomStudy = false
    @State private var editFiltered = false
    @State private var includeScheduling = true

    private var deck: Deck? {
        _ = app.revision
        return app.col?.deck(deckID)
    }

    private var counts: DeckCounts {
        _ = app.revision
        guard let col = app.col else { return DeckCounts() }
        return Scheduler(collection: col).counts(for: deckID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let deck {
                    VStack(spacing: 6) {
                        if let parent = deck.parentName {
                            Text(parent.replacingOccurrences(of: "::", with: " › "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(deck.baseName)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            tile("New", counts.new, .blue)
                            tile("Learning", counts.learn, .red)
                            tile("To Review", counts.review, .green)
                        }
                    }

                    Button(action: onStudy) {
                        Label(counts.total > 0 ? "Study Now" : "Nothing Due", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(counts.total == 0)

                    if !deck.description.isEmpty {
                        Text(HTML.toPlainText(deck.description))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }

                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            if !deck.isFiltered {
                                Button {
                                    showCustomStudy = true
                                } label: {
                                    Label("Custom Study", systemImage: "sparkles")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                Button {
                                    showOptions = true
                                } label: {
                                    Label("Deck Options", systemImage: "slider.horizontal.3")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            } else {
                                Button {
                                    app.perform { _ = try $0.rebuildFilteredDeck(deckID) }
                                } label: {
                                    Label("Rebuild", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                Button {
                                    app.perform { try $0.emptyFilteredDeck(deckID) }
                                } label: {
                                    Label("Empty", systemImage: "tray")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                Button {
                                    editFiltered = true
                                } label: {
                                    Label("Edit Filter", systemImage: "line.3.horizontal.decrease.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                            Toggle("Include scheduling in export", isOn: $includeScheduling)
                                .font(.subheadline)
                                .padding(.horizontal, 4)
                            Button {
                                exportURL = app.exportDeck(deckID, includeScheduling: includeScheduling, includeMedia: true)
                            } label: {
                                Label("Export as .apkg", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCustomStudy) {
            NavigationStack {
                CustomStudyView(deckID: deckID) { target in
                    if target == deckID { onStudy() } else { app.studyRequest = target }
                }
            }
        }
        .sheet(isPresented: $editFiltered) {
            NavigationStack { FilteredDeckEditor(deckID: deckID) }
        }
        .sheet(isPresented: $showOptions) {
            NavigationStack { DeckOptionsView(deckID: deckID) }
        }
        .sheet(item: Binding(get: { exportURL.map(ExportFile.init) }, set: { if $0 == nil { exportURL = nil } })) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    private func tile(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassEffect(.regular.tint(color.opacity(0.1)), in: .rect(cornerRadius: 24))
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

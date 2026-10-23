import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let apkg = UTType(importedAs: "net.ankiweb.apkg", conformingTo: .zip)
    static let colpkg = UTType(importedAs: "net.ankiweb.colpkg", conformingTo: .zip)
}

struct DeckListView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [Int64] = []
    @State private var showImporter = false
    @State private var addingNote = false
    @State private var newDeckName = ""
    @State private var showNewDeck = false
    @State private var renaming: Deck?
    @State private var renameText = ""
    @State private var deleting: Deck?
    @State private var studying: StudyTarget?

    struct StudyTarget: Identifiable { let id: Int64 }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if app.deckTree.isEmpty {
                    ContentUnavailableView {
                        Label("No Decks", systemImage: "rectangle.stack")
                    } description: {
                        Text("Sync with AnkiWeb, import a deck, or add a note to get started.")
                    }
                } else {
                    Section {
                        TodaySummary(tree: app.deckTree)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(app.deckTree) { node in
                            DeckRow(node: node, depth: 0, onStudy: { studying = StudyTarget(id: $0) },
                                    onOpen: { path.append($0) }, onRename: startRename, onDelete: { deleting = $0 })
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Decks")
            .navigationDestination(for: Int64.self) { id in
                DeckOverviewView(deckID: id) { studying = StudyTarget(id: id) }
            }
            .refreshable { await app.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SyncButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Note", systemImage: "square.and.pencil") { addingNote = true }
                        Button("New Deck", systemImage: "folder.badge.plus") {
                            newDeckName = ""
                            showNewDeck = true
                        }
                        Button("Import File", systemImage: "square.and.arrow.down") { showImporter = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $addingNote) {
                NavigationStack { NoteEditorView(mode: .add(deckID: nil)) }
            }
            .fullScreenCover(item: $studying) { target in
                StudyView(app: app, deckID: target.id)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.apkg, .colpkg, .zip, .data]) { result in
                if case .success(let url) = result {
                    Task { await app.importPackage(url) }
                }
            }
            .alert("New Deck", isPresented: $showNewDeck) {
                TextField("Name", text: $newDeckName)
                Button("Create") { app.perform { _ = try $0.addDeck(named: newDeckName) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use :: to make a subdeck, e.g. Languages::Spanish.")
            }
            .alert("Rename Deck", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let deck = renaming { app.perform { try $0.renameDeck(deck.id, to: renameText) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible)
            {
                Button("Delete Deck and Cards", role: .destructive) {
                    if let deck = deleting { app.perform { try $0.removeDeck(deck.id) } }
                }
            } message: {
                Text("All cards in this deck and its subdecks will be deleted.")
            }
        }
    }

    private func startRename(_ deck: Deck) {
        renameText = deck.name
        renaming = deck
    }
}

struct SyncButton: View {
    @Environment(AppModel.self) private var app
    @State private var showLogin = false

    var body: some View {
        Button {
            if app.isLoggedIn {
                Task { await app.sync() }
            } else {
                showLogin = true
            }
        } label: {
            if app.isSyncing {
                ProgressView()
            } else {
                Image(systemName: app.hasUnsyncedChanges ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(app.hasUnsyncedChanges ? Color.accentColor : Color.primary)
            }
        }
        .disabled(app.isSyncing)
        .accessibilityLabel("Sync")
        .sheet(isPresented: $showLogin) {
            NavigationStack { LoginView() }
        }
    }
}

struct TodaySummary: View {
    let tree: [DeckTreeNode]

    var body: some View {
        let total = tree.reduce(DeckCounts()) { acc, n in
            DeckCounts(new: acc.new + n.counts.new, learn: acc.learn + n.counts.learn, review: acc.review + n.counts.review)
        }
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                stat("New", total.new, .blue)
                stat("Learn", total.learn, .red)
                stat("Review", total.review, .green)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(color.opacity(0.08)), in: .rect(cornerRadius: 20))
    }
}

struct DeckRow: View {
    @Environment(AppModel.self) private var app
    let node: DeckTreeNode
    let depth: Int
    let onStudy: (Int64) -> Void
    let onOpen: (Int64) -> Void
    let onRename: (Deck) -> Void
    let onDelete: (Deck) -> Void
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? !node.deck.collapsed }

    var body: some View {
        Group {
            HStack(spacing: 10) {
                if !node.children.isEmpty {
                    Button {
                        withAnimation(.snappy) { toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 28)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 20, height: 28)
                }
                Text(node.deck.baseName)
                    .font(depth == 0 ? .body.weight(.medium) : .body)
                    .lineLimit(2)
                Spacer(minLength: 8)
                CountsView(counts: node.counts)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(.rect)
            .onTapGesture { onStudy(node.deck.id) }
            .contextMenu {
                Button("Study", systemImage: "play.fill") { onStudy(node.deck.id) }
                Button("Overview & Options", systemImage: "info.circle") { onOpen(node.deck.id) }
                Button("Rename", systemImage: "pencil") { onRename(node.deck) }
                if node.deck.id != 1 {
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete(node.deck) }
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Options", systemImage: "gearshape") { onOpen(node.deck.id) }
                    .tint(.gray)
            }

            if isExpanded {
                ForEach(node.children) { child in
                    DeckRow(node: child, depth: depth + 1, onStudy: onStudy, onOpen: onOpen,
                            onRename: onRename, onDelete: onDelete)
                }
            }
        }
    }

    private func toggle() {
        let newValue = !isExpanded
        expanded = newValue
        var deck = node.deck
        deck.json["collapsed"] = .bool(!newValue)
        // collapsing is a UI preference; like Anki, it is saved and synced
        app.perform { try $0.updateDeck(deck) }
    }
}

struct CountsView: View {
    let counts: DeckCounts

    var body: some View {
        HStack(spacing: 10) {
            number(counts.new, .blue)
            number(counts.learn, .red)
            number(counts.review, .green)
        }
        .font(.subheadline.monospacedDigit().weight(.semibold))
    }

    private func number(_ n: Int, _ color: Color) -> some View {
        Text("\(n)")
            .foregroundStyle(n == 0 ? Color.secondary.opacity(0.4) : color)
            .frame(minWidth: 24, alignment: .trailing)
    }
}

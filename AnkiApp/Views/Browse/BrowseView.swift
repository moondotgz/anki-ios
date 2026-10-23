import SwiftUI

struct BrowseView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var rows: [BrowserRow] = []
    @State private var editing: Note?
    @State private var selection = Set<Int64>()
    @State private var editMode: EditMode = .inactive
    @State private var moveTarget: MoveRequest?

    struct MoveRequest: Identifiable {
        let ids: [Int64]
        var id: String { ids.map(String.init).joined(separator: ",") }
    }

    private let presets: [(String, String, String)] = [
        ("Due today", "is:due", "clock"),
        ("New", "is:new", "sparkles"),
        ("Learning", "is:learn", "graduationcap"),
        ("Suspended", "is:suspended", "pause.circle"),
        ("Added today", "added:1", "plus.circle"),
        ("Reviewed today", "rated:1", "checkmark.circle"),
        ("Flagged", "-flag:0", "flag"),
        ("Leeches", "tag:leech", "exclamationmark.triangle"),
    ]

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(rows) { row in
                    Button {
                        if editMode == .inactive { open(row) }
                    } label: {
                        BrowserRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .tag(row.id)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            app.perform { try $0.removeNotes([row.noteID]) }
                            reload()
                        }
                        Button(row.queue == CardQueue.suspended ? "Unsuspend" : "Suspend", systemImage: "pause.circle") {
                            app.perform { try $0.suspend(cardIDs: [row.id], row.queue != CardQueue.suspended) }
                            reload()
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Flag", systemImage: "flag") {
                            app.perform { try $0.setFlag(cardIDs: [row.id], flag: row.flag == 0 ? 1 : 0) }
                            reload()
                        }
                        .tint(.red)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Browse")
            .searchable(text: $query, prompt: "Search, e.g. deck:French is:due")
            .onSubmit(of: .search, reload)
            .onChange(of: query) { _, _ in reload() }
            .onChange(of: app.revision) { _, _ in reload() }
            .onAppear(perform: reload)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(presets, id: \.1) { preset in
                            Button(preset.0, systemImage: preset.2) { query = preset.1 }
                        }
                        Divider()
                        ForEach(app.col?.allDecks ?? []) { deck in
                            Button(deck.name) { query = "\"deck:\(deck.name)\"" }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Filters")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if editMode == .active && !selection.isEmpty {
                        Menu {
                            Button("Change Deck", systemImage: "folder") { moveTarget = MoveRequest(ids: Array(selection)) }
                            Button("Suspend", systemImage: "pause.circle") { bulk { try $0.suspend(cardIDs: $1, true) } }
                            Button("Unsuspend", systemImage: "play.circle") { bulk { try $0.suspend(cardIDs: $1, false) } }
                            Button("Forget", systemImage: "arrow.counterclockwise") { bulk { try $0.forget(cardIDs: $1) } }
                            Button("Delete Notes", systemImage: "trash", role: .destructive) {
                                let nids = Set(rows.filter { selection.contains($0.id) }.map(\.noteID))
                                bulk { col, _ in try col.removeNotes(Array(nids)) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                            selection.removeAll()
                        }
                    }
                }
            }
            .sheet(item: $editing) { note in
                NavigationStack {
                    NoteEditorView(mode: .edit(note)) { reload() }
                }
            }
            .sheet(item: $moveTarget) { req in
                NavigationStack {
                    List(app.col?.allDecks.filter { !$0.isFiltered } ?? []) { deck in
                        Button(deck.name) {
                            app.perform { try $0.setDeck(cardIDs: req.ids, deckID: deck.id) }
                            moveTarget = nil
                            reload()
                        }
                    }
                    .navigationTitle("Move to Deck")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func bulk(_ body: (Collection, [Int64]) throws -> Void) {
        let ids = Array(selection)
        app.perform { try body($0, ids) }
        selection.removeAll()
        reload()
    }

    private func open(_ row: BrowserRow) {
        editing = try? app.col?.note(row.noteID)
    }

    private func reload() {
        guard let col = app.col else { return }
        do {
            rows = try col.searchCards(query)
        } catch {
            rows = []
        }
    }
}

struct BrowserRowView: View {
    let row: BrowserRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let color = Flag.color(row.flag) {
                Capsule().fill(color).frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(row.sortField.isEmpty ? "(empty)" : row.sortField)
                    .lineLimit(2)
                    .foregroundStyle(row.queue == CardQueue.suspended ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(row.deckName)
                        .lineLimit(1)
                    if !row.tags.isEmpty {
                        Text("· \(row.tags)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.due)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.vertical, 2)
        .background(row.queue == CardQueue.suspended ? Color.yellow.opacity(0.08) : .clear)
    }
}

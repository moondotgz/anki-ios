import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    enum Mode {
        case add(deckID: Int64?)
        case edit(Note)
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var onSave: () -> Void = {}

    @State private var notetypeID: Int64 = 0
    @State private var deckID: Int64 = 1
    @State private var fields: [String] = []
    @State private var tags = ""
    @State private var original: Note?
    @State private var loaded = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoTarget = 0
    @State private var addedMessage: String?
    @FocusState private var focused: Int?

    private var isEditing: Bool { original != nil }
    private var notetype: Notetype? { app.col?.notetype(notetypeID) }

    var body: some View {
        Form {
            if !isEditing {
                Section {
                    Picker("Type", selection: $notetypeID) {
                        ForEach(app.col?.notetypes ?? []) { nt in
                            Text(nt.name).tag(nt.id)
                        }
                    }
                    Picker("Deck", selection: $deckID) {
                        ForEach((app.col?.allDecks ?? []).filter { !$0.isFiltered }) { deck in
                            Text(deck.name).tag(deck.id)
                        }
                    }
                }
            }

            if let nt = notetype {
                ForEach(Array(nt.fieldNames.enumerated()), id: \.offset) { idx, name in
                    Section {
                        TextField(name, text: binding(idx), axis: .vertical)
                            .lineLimit(2...12)
                            .focused($focused, equals: idx)
                            .textInputAutocapitalization(.sentences)
                    } header: {
                        HStack {
                            Text(name)
                            Spacer()
                            if nt.isCloze, idx == 0 {
                                Button("Cloze") { insertCloze(idx) }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                            }
                            PhotosPicker(selection: Binding(
                                get: { photoItem },
                                set: { photoTarget = idx; photoItem = $0 }
                            ), matching: .images) {
                                Image(systemName: "photo.badge.plus")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Tags") {
                TextField("space separated", text: $tags)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let addedMessage {
                Section {
                    Label(addedMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(isEditing ? "Edit Note" : "Add Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add", systemImage: "checkmark") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .onAppear(perform: load)
        .onChange(of: notetypeID) { old, new in
            guard loaded, old != new, let nt = app.col?.notetype(new) else { return }
            fields = Array(fields.prefix(nt.fieldNames.count)) + Array(repeating: "", count: max(0, nt.fieldNames.count - fields.count))
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await insertImage(item) }
        }
    }

    private func binding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { idx < fields.count ? fields[idx] : "" },
            set: { value in
                while fields.count <= idx { fields.append("") }
                fields[idx] = value
                addedMessage = nil
            })
    }

    private func load() {
        guard !loaded, let col = app.col else { return }
        switch mode {
        case .edit(let note):
            original = note
            notetypeID = note.mid
            fields = note.fields.map(NoteEditorView.htmlToEditable)
            tags = note.tags.joined(separator: " ")
        case .add(let did):
            let current = col.conf["curModel"].int ?? col.notetypes.first?.id ?? 0
            notetypeID = col.notetype(current) != nil ? current : (col.notetypes.first?.id ?? 0)
            let defaultDeck = did ?? col.currentDeckID
            deckID = col.deck(defaultDeck).map { $0.isFiltered ? 1 : $0.id } ?? 1
            fields = Array(repeating: "", count: notetype?.fieldNames.count ?? 2)
        }
        loaded = true
    }

    /// Fields are HTML; simple line breaks are shown as newlines while editing.
    static func htmlToEditable(_ html: String) -> String {
        html.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func editableToHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }

    private func insertCloze(_ idx: Int) {
        guard idx < fields.count else { return }
        let used = Cloze.ordinals(in: fields[idx])
        let next = (used.max() ?? 0) + 1
        fields[idx] += "{{c\(next)::}}"
    }

    private func insertImage(_ item: PhotosPickerItem) async {
        guard let media = app.media, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        do {
            let name = try media.addFile(name: "paste-\(SHA1.hex(data).prefix(16)).\(ext)", data: data)
            let tag = "<img src=\"\(name)\">"
            if photoTarget < fields.count {
                fields[photoTarget] += fields[photoTarget].isEmpty ? tag : " " + tag
            }
        } catch {
            app.errorMessage = error.localizedDescription
        }
        photoItem = nil
    }

    private func save() {
        guard let col = app.col, let nt = notetype else { return }
        let html = fields.map(NoteEditorView.editableToHTML)
        let tagList = Note.splitTags(tags)
        do {
            if var note = original {
                note.fields = html + Array(repeating: "", count: max(0, nt.fieldNames.count - html.count))
                note.tags = tagList
                try col.updateNote(note)
                onSave()
                app.refresh()
                dismiss()
            } else {
                var note = Note(id: 0, mid: nt.id, fieldCount: nt.fieldNames.count)
                note.fields = Array((html + Array(repeating: "", count: nt.fieldNames.count)).prefix(nt.fieldNames.count))
                note.tags = tagList
                let count = try col.addNote(&note, deckID: deckID)
                col.currentDeckID = deckID
                try col.save()
                onSave()
                app.refresh()
                addedMessage = "Added \(count) card\(count == 1 ? "" : "s")"
                // keep sticky fields, clear the rest
                fields = nt.fields.enumerated().map { idx, f in
                    f["sticky"].bool(or: false) && idx < fields.count ? fields[idx] : ""
                }
                focused = 0
            }
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI
import WebKit

@MainActor
@Observable
final class StudyModel {
    let app: AppModel
    let deckID: Int64
    private(set) var session: StudySession?
    private(set) var card: Card?
    private(set) var note: Note?
    private(set) var rendered: RenderedCard?
    private(set) var showingAnswer = false
    private(set) var intervals: [String] = ["", "", "", ""]
    private(set) var counts = DeckCounts()
    private(set) var finished = false
    private(set) var nextLearningDue: Date?
    var typedAnswer = ""
    private var shownAt = Date()

    init(app: AppModel, deckID: Int64) {
        self.app = app
        self.deckID = deckID
        guard let col = app.col else { return }
        do {
            session = try StudySession(scheduler: Scheduler(collection: col), deckID: deckID)
        } catch {
            app.errorMessage = error.localizedDescription
        }
        next()
    }

    /// Rebuilds the queue, e.g. after today's limits were increased.
    func restart() {
        guard let col = app.col else { return }
        do {
            session = try StudySession(scheduler: Scheduler(collection: col), deckID: deckID)
        } catch {
            app.errorMessage = error.localizedDescription
        }
        next()
    }

    var isMarked: Bool { note?.hasTag("marked") ?? false }

    func toggleMark() {
        guard let card, let col = app.col else { return }
        do {
            try col.toggleMark(noteID: card.nid)
            reloadCurrent()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    var config: DeckConfig? {
        guard let card, let col = app.col else { return nil }
        return col.config(forDeck: card.odid != 0 ? card.odid : card.did)
    }

    var showIntervals: Bool { app.col?.conf["estTimes"].bool(or: true) ?? true }
    var showCounts: Bool { app.col?.conf["dueCounts"].bool(or: true) ?? true }

    func next() {
        guard let session, let col = app.col else { return }
        SoundPlayer.shared.stop()
        showingAnswer = false
        typedAnswer = ""
        if let c = session.nextCard(), let n = try? col.note(c.nid) {
            card = c
            note = n
            rendered = CardRenderer.render(card: c, note: n, collection: col)
            intervals = Scheduler(collection: col).intervalLabels(for: c)
            finished = false
            shownAt = Date()
            if config?.autoplay ?? true, let r = rendered, !r.questionSounds.isEmpty {
                SoundPlayer.shared.play(r.questionSounds, folder: col.mediaFolder)
            }
        } else {
            card = nil
            note = nil
            rendered = nil
            finished = true
            nextLearningDue = session.nextLearningDue
        }
        counts = session.counts
    }

    func showAnswer() {
        guard let r = rendered, let col = app.col, !showingAnswer else { return }
        showingAnswer = true
        if config?.autoplay ?? true, !r.answerSounds.isEmpty {
            SoundPlayer.shared.play(r.answerSounds, folder: col.mediaFolder)
        } else {
            SoundPlayer.shared.stop()
        }
    }

    func answer(_ rating: Int) {
        guard let session, showingAnswer else { return }
        let ms = Int(Date().timeIntervalSince(shownAt) * 1000)
        do {
            try session.answer(rating: rating, millisecondsTaken: ms)
        } catch {
            app.errorMessage = error.localizedDescription
        }
        next()
    }

    var canUndo: Bool { session?.canUndo ?? false }

    func undo() {
        guard let session else { return }
        do { try session.undo() } catch { app.errorMessage = error.localizedDescription }
        next()
    }

    func bury() { act { try $0.bury(cardIDs: [$1.id]) } }
    func suspend() { act { try $0.suspend(cardIDs: [$1.id], true) } }
    func buryNote() { act { col, card in try col.bury(cardIDs: try col.cards(ofNote: card.nid).map(\.id)) } }
    func suspendNote() { act { col, card in try col.suspend(cardIDs: try col.cards(ofNote: card.nid).map(\.id), true) } }
    func deleteNote() { act { col, card in try col.removeNotes([card.nid]) } }

    func setFlag(_ flag: Int) {
        guard let card, let col = app.col else { return }
        do {
            try col.setFlag(cardIDs: [card.id], flag: card.flag == flag ? 0 : flag)
            self.card = try col.card(card.id)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func act(_ body: (Collection, Card) throws -> Void) {
        guard let card, let col = app.col else { return }
        do {
            try body(col, card)
            session?.skipCurrent()
        } catch {
            app.errorMessage = error.localizedDescription
        }
        next()
    }

    /// Re-renders after the note was edited.
    func reloadCurrent() {
        guard let card, let col = app.col, let n = try? col.note(card.nid) else { return }
        note = n
        rendered = CardRenderer.render(card: card, note: n, collection: col)
    }

    func html(nightMode: Bool, compare: String?) -> String {
        guard let r = rendered else { return "" }
        var body = showingAnswer ? r.answerHTML : r.questionHTML
        if showingAnswer, let compare {
            body = body.replacingOccurrences(of: "<div id=typeansCompare></div>", with: compare)
        }
        return CardHTML.page(body: body, css: r.css, ord: r.ord, nightMode: nightMode)
    }
}

struct StudyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var model: StudyModel
    @State private var webView: WKWebView?
    @State private var typeCompare: String?
    @State private var editingNote: Note?
    @State private var confirmDelete = false
    @State private var showCustomStudy = false
    @State private var infoCardID: CardInfoTarget?

    struct CardInfoTarget: Identifiable { let id: Int64 }
    @Namespace private var glass

    init(app: AppModel, deckID: Int64) {
        _model = State(initialValue: StudyModel(app: app, deckID: deckID))
    }

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color.white)
                .ignoresSafeArea()
            if model.finished {
                CongratsView(nextLearningDue: model.nextLearningDue, onCustomStudy: { showCustomStudy = true }) { dismiss() }
            } else if let folder = app.col?.mediaFolder {
                CardWebView(html: model.html(nightMode: colorScheme == .dark, compare: typeCompare),
                            mediaFolder: folder, onMessage: handleMessage, webViewRef: $webView)
                    .ignoresSafeArea(edges: .bottom)
            }
            VStack {
                topBar
                Spacer()
                if !model.finished { answerBar }
            }
        }
        .statusBarHidden(false)
        .sheet(item: $editingNote) { note in
            NavigationStack {
                NoteEditorView(mode: .edit(note)) { model.reloadCurrent() }
            }
        }
        .sheet(isPresented: $showCustomStudy) {
            NavigationStack {
                CustomStudyView(deckID: model.deckID) { target in
                    if target == model.deckID {
                        model.restart()
                    } else {
                        dismiss()
                        app.studyRequest = target
                    }
                }
            }
        }
        .sheet(item: $infoCardID) { target in
            NavigationStack { CardInfoView(cardID: target.id) }
        }
        .confirmationDialog("Delete this note and all its cards?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) { model.deleteNote() }
        }
        .onDisappear {
            SoundPlayer.shared.stop()
            app.refresh()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close")

                Spacer()

                if model.showCounts, !model.finished {
                    HStack(spacing: 14) {
                        countLabel(model.counts.new, .blue, active: model.card?.queue == CardQueue.new)
                        countLabel(model.counts.learn, .red,
                                   active: model.card?.queue == CardQueue.learn || model.card?.queue == CardQueue.dayLearn)
                        countLabel(model.counts.review, .green, active: model.card?.queue == CardQueue.review)
                    }
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                }

                Spacer()

                if model.canUndo {
                    Button {
                        typeCompare = nil
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Undo")
                }

                if !model.finished { moreMenu }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func countLabel(_ n: Int, _ color: Color, active: Bool) -> some View {
        Text("\(n)")
            .foregroundStyle(color)
            .underline(active, color: color)
    }

    private var moreMenu: some View {
        Menu {
            Button("Edit Note", systemImage: "pencil") { editingNote = model.note }
            Button(model.isMarked ? "Unmark Note" : "Mark Note", systemImage: model.isMarked ? "star.slash" : "star") {
                model.toggleMark()
            }
            Button("Card Info", systemImage: "info.circle") {
                if let id = model.card?.id { infoCardID = CardInfoTarget(id: id) }
            }
            Menu("Flag", systemImage: "flag") {
                ForEach(Flag.all) { flag in
                    Button {
                        model.setFlag(flag.value)
                    } label: {
                        Label(flag.name, systemImage: model.card?.flag == flag.value ? "flag.fill" : "flag")
                    }
                }
            }
            Divider()
            Button("Bury Card", systemImage: "eye.slash") { model.bury() }
            Button("Bury Note", systemImage: "eye.slash.circle") { model.buryNote() }
            Button("Suspend Card", systemImage: "pause.circle") { model.suspend() }
            Button("Suspend Note", systemImage: "pause.rectangle") { model.suspendNote() }
            Divider()
            if let r = model.rendered, !(r.questionSounds.isEmpty && r.answerSounds.isEmpty) {
                Button("Replay Audio", systemImage: "speaker.wave.2") {
                    if let folder = app.col?.mediaFolder {
                        SoundPlayer.shared.play(model.showingAnswer ? r.answerSounds : r.questionSounds, folder: folder)
                    }
                }
            }
            Button("Delete Note", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: model.card.map { $0.flag != 0 ? "flag.fill" : "ellipsis" } ?? "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(model.card.flatMap { Flag.color($0.flag) } ?? .primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("More")
    }

    // MARK: Answer bar

    private var answerBar: some View {
        GlassEffectContainer(spacing: 10) {
            if model.showingAnswer {
                HStack(spacing: 8) {
                    answerButton(1, "Again", .red, key: "1")
                    answerButton(2, "Hard", .orange, key: "2")
                    answerButton(3, "Good", .green, key: "3")
                    answerButton(4, "Easy", .blue, key: "4")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Button {
                    reveal()
                } label: {
                    Text("Show Answer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("answer", in: glass)
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.smooth(duration: 0.25), value: model.showingAnswer)
        .sensoryFeedback(.impact(weight: .light), trigger: model.card?.id)
    }

    private func answerButton(_ rating: Int, _ title: String, _ color: Color, key: KeyEquivalent) -> some View {
        Button {
            typeCompare = nil
            withAnimation(.smooth(duration: 0.2)) { model.answer(rating) }
        } label: {
            VStack(spacing: 2) {
                if model.showIntervals {
                    Text(model.intervals[rating - 1])
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(color.opacity(0.18)).interactive(), in: .rect(cornerRadius: 22))
        .glassEffectID("answer\(rating)", in: glass)
        .keyboardShortcut(key, modifiers: [])
    }

    private func reveal() {
        guard let expected = model.rendered?.typeAnswerExpected, let webView else {
            withAnimation(.smooth(duration: 0.2)) { model.showAnswer() }
            return
        }
        webView.evaluateJavaScript("_getTypedAnswer()") { result, _ in
            let typed = (result as? String) ?? ""
            typeCompare = "<center>" + CardRenderer.compareTyped(typed, expected: expected) + "</center>"
            withAnimation(.smooth(duration: 0.2)) { model.showAnswer() }
        }
    }

    private func handleMessage(_ message: String) {
        if message.hasPrefix("play:"), let folder = app.col?.mediaFolder {
            SoundPlayer.shared.play([String(message.dropFirst(5))], folder: folder)
        } else if message == "ans" {
            if model.showingAnswer { model.answer(3) } else { reveal() }
        }
    }
}

struct CongratsView: View {
    let nextLearningDue: Date?
    var onCustomStudy: (() -> Void)?
    let done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, value: true)
            Text("Congratulations!")
                .font(.largeTitle.bold())
            Text("You have finished this deck for now.")
                .foregroundStyle(.secondary)
            if let due = nextLearningDue {
                Text("More learning cards are due \(due, style: .relative) from now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    if let onCustomStudy {
                        Button(action: onCustomStudy) {
                            Label("Custom Study", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button(action: done) {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 300)
            .padding(.top, 8)
            if onCustomStudy != nil {
                Text("Keep practicing: study more new or review cards, review ahead, go over forgotten cards, or cram by tag.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(32)
    }
}

struct Flag: Identifiable {
    let value: Int
    let name: String
    var id: Int { value }

    static let all = [
        Flag(value: 1, name: "Red"), Flag(value: 2, name: "Orange"), Flag(value: 3, name: "Green"),
        Flag(value: 4, name: "Blue"), Flag(value: 5, name: "Pink"), Flag(value: 6, name: "Turquoise"),
        Flag(value: 7, name: "Purple"),
    ]

    static func color(_ value: Int) -> Color? {
        switch value {
        case 1: return .red
        case 2: return .orange
        case 3: return .green
        case 4: return .blue
        case 5: return .pink
        case 6: return .teal
        case 7: return .purple
        default: return nil
        }
    }
}

import SwiftUI

/// Anki desktop's Custom Study dialog.
struct CustomStudyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64
    /// Called with the deck to study next.
    let onStart: (Int64) -> Void

    private enum Option: String, CaseIterable, Identifiable {
        case increaseNew, increaseReview, forgotten, reviewAhead, previewNew, cram
        var id: String { rawValue }

        var title: String {
            switch self {
            case .increaseNew: return "Increase today's new card limit"
            case .increaseReview: return "Increase today's review card limit"
            case .forgotten: return "Review forgotten cards"
            case .reviewAhead: return "Review ahead"
            case .previewNew: return "Preview new cards"
            case .cram: return "Study by card state or tag"
            }
        }

        var icon: String {
            switch self {
            case .increaseNew: return "plus.circle"
            case .increaseReview: return "plus.square.on.square"
            case .forgotten: return "arrow.uturn.backward.circle"
            case .reviewAhead: return "calendar.badge.clock"
            case .previewNew: return "eye"
            case .cram: return "tag"
            }
        }

        var unit: String {
            switch self {
            case .increaseNew, .increaseReview: return "cards"
            case .cram: return "cards max"
            default: return "days"
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .increaseNew, .increaseReview: return 1...9999
            case .cram: return 1...9999
            default: return 1...365
            }
        }

        var defaultValue: Int {
            switch self {
            case .increaseNew: return 10
            case .increaseReview: return 50
            case .forgotten, .previewNew: return 1
            case .reviewAhead: return 1
            case .cram: return 100
            }
        }
    }

    @State private var option: Option = .increaseNew
    @State private var amount = 10
    @State private var cramState: CustomStudyKind.CramState = .dueCards
    @State private var selectedTags = Set<String>()
    @State private var error: String?

    private var deck: Deck? { app.col?.deck(deckID) }

    private var deckTags: [String] {
        guard let col = app.col else { return [] }
        let ids = col.deckTreeIDs(deckID).map(String.init).joined(separator: ",")
        let rows = (try? col.db.query(
            "select distinct n.tags from notes n join cards c on c.nid = n.id where c.did in (\(ids)) or c.odid in (\(ids))"
        )) ?? []
        var tags = Set<String>()
        for r in rows { tags.formUnion(Note.splitTags(r[0].text)) }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var available: String? {
        guard let col = app.col else { return nil }
        let ids = col.deckTreeIDs(deckID).map(String.init).joined(separator: ",")
        switch option {
        case .increaseNew:
            let n = (try? col.db.int("select count() from cards where did in (\(ids)) and queue = 0")) ?? 0
            return "\(n) new cards available"
        case .increaseReview:
            let today = Scheduler(collection: col).today
            let n = (try? col.db.int("select count() from cards where did in (\(ids)) and queue = 2 and due <= ?", today)) ?? 0
            return "\(n) review cards due"
        default:
            return nil
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Option", selection: $option) {
                    ForEach(Option.allCases) { o in
                        Label(o.title, systemImage: o.icon).tag(o)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(deck?.name ?? "")
            }

            Section {
                Stepper(value: $amount, in: option.range) {
                    HStack {
                        Text(option == .increaseNew || option == .increaseReview ? "Increase by" : option == .cram ? "Select" : "Last / next")
                        Spacer()
                        TextField("", value: $amount, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70)
                        Text(option.unit).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if let available { Text(available) } else { Text(footer) }
            }

            if option == .cram {
                Section("Cards") {
                    Picker("State", selection: $cramState) {
                        ForEach(CustomStudyKind.CramState.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                let tags = deckTags
                if !tags.isEmpty {
                    Section {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                            } label: {
                                HStack {
                                    Text(tag).foregroundStyle(Color.primary)
                                    Spacer()
                                    if selectedTags.contains(tag) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Require one of these tags")
                    } footer: {
                        Text(selectedTags.isEmpty ? "No tags selected: all cards in the deck are included." : "\(selectedTags.count) selected")
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Custom Study")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Study", systemImage: "play.fill") { start() }
                    .buttonStyle(.glassProminent)
            }
        }
        .onChange(of: option) { _, o in
            amount = o.defaultValue
            error = nil
        }
    }

    private var footer: String {
        switch option {
        case .forgotten: return "Cards you answered Again on in the last \(amount) day\(amount == 1 ? "" : "s"). Answers are rescheduled."
        case .reviewAhead: return "Review cards due in the next \(amount) day\(amount == 1 ? "" : "s")."
        case .previewNew: return "New cards added in the last \(amount) day\(amount == 1 ? "" : "s"). Previewing doesn't change their schedule."
        case .cram: return cramState == .allRandom ? "Answers won't change the schedule." : "Answers are rescheduled as usual."
        default: return ""
        }
    }

    private func start() {
        guard let col = app.col else { return }
        let kind: CustomStudyKind
        switch option {
        case .increaseNew: kind = .increaseNew(amount)
        case .increaseReview: kind = .increaseReview(amount)
        case .forgotten: kind = .forgotten(days: amount)
        case .reviewAhead: kind = .reviewAhead(days: amount)
        case .previewNew: kind = .previewNew(days: amount)
        case .cram: kind = .cram(cramState, limit: amount, tags: Array(selectedTags))
        }
        do {
            let target = try col.customStudy(deckID: deckID, kind: kind)
            app.refresh()
            dismiss()
            onStart(target)
        } catch {
            app.refresh()
            self.error = error.localizedDescription
        }
    }
}

/// Creates or edits a filtered deck, like Anki's Tools → Create Filtered Deck.
struct FilteredDeckEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64?
    var initialSearch = ""
    var onSaved: (Int64) -> Void = { _ in }

    @State private var name = ""
    @State private var search = ""
    @State private var limit = 100
    @State private var order: FilteredOrder = .random
    @State private var useSecond = false
    @State private var search2 = ""
    @State private var limit2 = 20
    @State private var order2: FilteredOrder = .orderDue
    @State private var reschedule = true
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Name") {
                TextField("Filtered Deck 1", text: $name)
            }
            Section {
                searchFields(search: $search, limit: $limit, order: $order)
            } header: {
                Text("Filter")
            } footer: {
                Text("Uses the same search syntax as the browser, e.g. deck:French is:due, tag:verbs, rated:7:1, prop:ivl>=10.")
            }
            Section {
                Toggle("Second filter", isOn: $useSecond.animation())
                if useSecond { searchFields(search: $search2, limit: $limit2, order: $order2) }
            }
            Section {
                Toggle("Reschedule cards based on my answers", isOn: $reschedule)
            } footer: {
                Text(reschedule
                    ? "Answers update the cards' schedule, as in a normal deck."
                    : "Preview mode: answers don't change the schedule. Again shows a card again; other answers return it to its deck.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(deckID == nil ? "New Filtered Deck" : "Filtered Deck")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(deckID == nil ? "Build" : "Rebuild", systemImage: "checkmark") { save() }
                    .buttonStyle(.glassProminent)
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func searchFields(search: Binding<String>, limit: Binding<Int>, order: Binding<FilteredOrder>) -> some View {
        TextField("Search", text: search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Stepper(value: limit, in: 1...99999) {
            HStack {
                Text("Limit to")
                Spacer()
                TextField("", value: limit, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                Text("cards").foregroundStyle(.secondary)
            }
        }
        Picker("Order", selection: order) {
            ForEach(FilteredOrder.allCases) { o in Text(o.title).tag(o) }
        }
    }

    private func load() {
        guard !loaded, let col = app.col else { return }
        loaded = true
        if let deckID, let deck = col.deck(deckID) {
            name = deck.name
            let terms = col.filteredTerms(deck)
            if let t = terms.first { search = t.search; limit = t.limit; order = t.order }
            if terms.count > 1 { useSecond = true; search2 = terms[1].search; limit2 = terms[1].limit; order2 = terms[1].order }
            reschedule = deck.json["resched"].bool(or: true)
        } else {
            var n = 1
            while col.deck(named: "Filtered Deck \(n)") != nil { n += 1 }
            name = "Filtered Deck \(n)"
            if !initialSearch.isEmpty {
                search = initialSearch
            } else if let current = col.deck(col.currentDeckID), !current.isFiltered {
                search = "\"deck:\(current.name)\" is:due"
            } else {
                search = "is:due"
            }
        }
    }

    private func save() {
        guard let col = app.col else { return }
        var terms = [FilteredSearchTerm(search: search, limit: limit, order: order)]
        if useSecond { terms.append(FilteredSearchTerm(search: search2, limit: limit2, order: order2)) }
        do {
            let id = try col.saveFilteredDeck(id: deckID, name: name, terms: terms, reschedule: reschedule)
            app.refresh()
            if try col.db.int("select count() from cards where did = ?", id) == 0 {
                error = "No cards matched. The deck was saved; change the search and rebuild it."
                return
            }
            dismiss()
            onSaved(id)
        } catch {
            app.refresh()
            self.error = error.localizedDescription
        }
    }
}

/// Anki's Card Info: dates, properties and review history.
struct CardInfoView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let cardID: Int64

    var body: some View {
        let col = app.col
        let card = try? col?.card(cardID)
        let note = card.flatMap { try? col?.note($0.nid) }
        let log = (try? col?.revlog(cardID: cardID)) ?? []
        let today = col.map { Scheduler(collection: $0).today } ?? 0
        List {
            if let card, let col {
                Section {
                    LabeledContent("Added", value: Self.date(card.id / 1000))
                    if let first = log.last { LabeledContent("First review", value: Self.date(first.id / 1000)) }
                    if let latest = log.first { LabeledContent("Latest review", value: Self.date(latest.id / 1000)) }
                    LabeledContent("Due", value: dueText(card, today: today))
                    if card.type == CardType.review || card.type == CardType.relearn {
                        LabeledContent("Interval", value: Scheduler.describe(card.ivl * 86_400))
                        LabeledContent("Ease", value: "\(card.factor / 10)%")
                    }
                    LabeledContent("Reviews", value: "\(card.reps)")
                    LabeledContent("Lapses", value: "\(card.lapses)")
                    let total = log.reduce(0) { $0 + $1.time }
                    if !log.isEmpty {
                        LabeledContent("Average time", value: String(format: "%.1fs", Double(total) / Double(log.count) / 1000))
                        LabeledContent("Total time", value: String(format: "%.0fs", Double(total) / 1000))
                    }
                    LabeledContent("Card type", value: col.notetype(note?.mid ?? 0).map { nt in
                        nt.isCloze ? "Cloze \(card.ord + 1)" : (card.ord < nt.templateNames.count ? nt.templateNames[card.ord] : "")
                    } ?? "")
                    LabeledContent("Note type", value: col.notetype(note?.mid ?? 0)?.name ?? "")
                    LabeledContent("Deck", value: col.deck(card.odid != 0 ? card.odid : card.did)?.name ?? "")
                    LabeledContent("Card ID", value: String(card.id))
                    LabeledContent("Note ID", value: String(card.nid))
                }
                if !log.isEmpty {
                    Section("Review History") {
                        ForEach(log, id: \.id) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.date(entry.id / 1000, time: true)).font(.subheadline)
                                    Text(Self.kind(entry.type)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Self.rating(entry.ease))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Self.ratingColor(entry.ease))
                                    Text(entry.ivl < 0 ? Scheduler.describe(-entry.ivl) : Scheduler.describe(entry.ivl * 86_400))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("This card no longer exists.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Card Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }
            }
        }
    }

    private func dueText(_ c: Card, today: Int) -> String {
        switch c.queue {
        case CardQueue.new: return "New #\(c.odid != 0 ? c.odue : c.due)"
        case CardQueue.suspended: return "Suspended"
        case CardQueue.userBuried, CardQueue.schedBuried: return "Buried"
        case CardQueue.learn: return Self.date(c.due, time: true)
        default:
            let due = c.odid != 0 && c.odue != 0 ? c.odue : c.due
            return Self.date(Time.nowSecs + (due - Int64(today)) * 86_400)
        }
    }

    static func date(_ secs: Int64, time: Bool = false) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(secs))
        return time ? d.formatted(date: .abbreviated, time: .shortened) : d.formatted(date: .abbreviated, time: .omitted)
    }

    static func rating(_ ease: Int) -> String {
        switch ease {
        case 1: return "Again"
        case 2: return "Hard"
        case 3: return "Good"
        case 4: return "Easy"
        default: return "Manual"
        }
    }

    static func ratingColor(_ ease: Int) -> Color {
        switch ease {
        case 1: return .red
        case 2: return .orange
        case 3: return .green
        case 4: return .blue
        default: return .secondary
        }
    }

    static func kind(_ type: Int) -> String {
        switch type {
        case 0: return "Learning"
        case 1: return "Review"
        case 2: return "Relearning"
        case 3: return "Filtered"
        case 4: return "Manual"
        default: return "Rescheduled"
        }
    }
}

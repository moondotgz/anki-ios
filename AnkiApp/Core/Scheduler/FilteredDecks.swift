import Foundation

/// Card orders for filtered decks, numbered as in Anki.
enum FilteredOrder: Int, CaseIterable, Identifiable {
    case oldestSeenFirst = 0
    case random = 1
    case intervalsAscending = 2
    case intervalsDescending = 3
    case mostLapses = 4
    case orderAdded = 5
    case orderDue = 6
    case latestAddedFirst = 7
    case relativeOverdueness = 10

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oldestSeenFirst: return "Oldest seen first"
        case .random: return "Random"
        case .intervalsAscending: return "Increasing intervals"
        case .intervalsDescending: return "Decreasing intervals"
        case .mostLapses: return "Most lapses"
        case .orderAdded: return "Order added"
        case .orderDue: return "Order due"
        case .latestAddedFirst: return "Latest added first"
        case .relativeOverdueness: return "Relative overdueness"
        }
    }

    func sql(today: Int) -> String {
        switch self {
        case .oldestSeenFirst: return "(select max(id) from revlog where cid = c.id)"
        case .random: return "random()"
        case .intervalsAscending: return "c.ivl asc"
        case .intervalsDescending: return "c.ivl desc"
        case .mostLapses: return "c.lapses desc"
        case .orderAdded: return "n.id, c.ord"
        case .orderDue: return "c.type, c.due"
        case .latestAddedFirst: return "n.id desc"
        case .relativeOverdueness:
            return "(case when c.queue = 2 and c.ivl > 0 then -1.0 * (\(today) - c.due) / c.ivl else 0 end)"
        }
    }
}

struct FilteredSearchTerm: Equatable {
    var search: String
    var limit: Int
    var order: FilteredOrder
}

/// The options Anki desktop offers in its Custom Study dialog.
enum CustomStudyKind: Hashable {
    case increaseNew(Int)
    case increaseReview(Int)
    case forgotten(days: Int)
    case reviewAhead(days: Int)
    case previewNew(days: Int)
    case cram(CramState, limit: Int, tags: [String])

    enum CramState: String, CaseIterable, Identifiable {
        case newCards, dueCards, allReview, allRandom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newCards: return "New cards only"
            case .dueCards: return "Due cards only"
            case .allReview: return "All review cards in random order"
            case .allRandom: return "All cards in random order (don't reschedule)"
            }
        }
    }
}

extension Collection {
    static let customStudyDeckName = "Custom Study Session"

    func filteredTerms(_ deck: Deck) -> [FilteredSearchTerm] {
        (deck.json["terms"].array ?? []).map { t in
            FilteredSearchTerm(search: t[0].string(or: ""), limit: t[1].intValue,
                               order: FilteredOrder(rawValue: t[2].intValue) ?? .orderDue)
        }
    }

    /// Creates or updates a filtered deck and fills it. Returns its id.
    @discardableResult
    func saveFilteredDeck(id existingID: Int64?, name rawName: String, terms: [FilteredSearchTerm],
                          reschedule: Bool, previewAgainSecs: Int = 60) throws -> Int64
    {
        let name = Collection.normalizeDeckName(rawName)
        guard !name.isEmpty else { throw CollectionError.invalid("Please enter a deck name.") }
        if let other = deck(named: name), other.id != existingID {
            throw CollectionError.invalid("A deck named “\(name)” already exists.")
        }
        return try db.transaction {
            var id = existingID ?? 0
            if let existingID, let d = deck(existingID) {
                guard d.isFiltered else { throw CollectionError.invalid("That deck is not a filtered deck.") }
                try emptyFilteredDeck(existingID)
            } else {
                id = Time.nowMillis
                while decks[id] != nil { id += 1 }
                if let parent = Deck(json: ["name": .string(name)]).parentName { try addDeck(named: parent) }
            }
            var json: JSON = decks[id] ?? Defaults.deck(id: id, name: name)
            json["name"] = .string(name)
            json["dyn"] = 1
            json["resched"] = .bool(reschedule)
            json["terms"] = .array(terms.map { [.string($0.search), JSON($0.limit), JSON($0.order.rawValue)] })
            json["separate"] = true
            json["delays"] = .null
            json["previewDelay"] = 0
            json["previewAgainSecs"] = JSON(previewAgainSecs)
            json["previewHardSecs"] = 600
            json["previewGoodSecs"] = 0
            for key in ["conf", "extendNew", "extendRev", "reviewLimit", "newLimit", "reviewLimitToday", "newLimitToday"] {
                json[key] = .null
            }
            json["mod"] = .int(Time.nowSecs)
            json["usn"] = -1
            decks[id] = json
            try save()
            _ = try rebuildFilteredDeck(id)
            return id
        }
    }

    /// Moves matching cards into a filtered deck. Returns how many were moved.
    @discardableResult
    func rebuildFilteredDeck(_ id: Int64) throws -> Int {
        guard let d = deck(id), d.isFiltered else { return 0 }
        let today = Scheduler(collection: self).today
        return try db.transaction {
            try emptyFilteredDeck(id)
            var moved = Set<Int64>()
            var position: Int64 = -100_000
            for term in filteredTerms(d) where term.limit > 0 {
                let clause = SearchQuery(text: term.search).clause(collection: self, today: today)
                let sql = """
                    select c.id from cards c join notes n on c.nid = n.id
                    where (\(clause.sql)) and c.queue >= 0 and c.odid = 0
                      and c.did not in (\(filteredDeckIDs.map(String.init).joined(separator: ",")))
                    order by \(term.order.sql(today: today)) limit \(term.limit)
                    """
                for cid in try db.query(sql, params: clause.params).map({ $0[0].int }) where !moved.contains(cid) {
                    guard var card = try card(cid) else { continue }
                    card.odid = card.did
                    card.odue = card.due
                    card.did = id
                    // new and review cards are shown in the order they were gathered;
                    // learning cards keep their due times
                    if card.queue == CardQueue.new || card.queue == CardQueue.review {
                        card.due = position
                        position += 1
                    }
                    card.mod = Time.nowSecs
                    card.usn = -1
                    try writeCard(card)
                    moved.insert(cid)
                }
            }
            currentDeckID = id
            try save()
            return moved.count
        }
    }

    var filteredDeckIDs: [Int64] {
        let ids = decks.values.filter { $0["dyn"].bool(or: false) }.compactMap { $0["id"].int }
        return ids.isEmpty ? [0] : ids
    }

    /// Returns every card in a filtered deck to its home deck.
    func emptyFilteredDeck(_ id: Int64) throws {
        let cids = try db.query("select id from cards where did = ? and odid != 0", id).map { $0[0].int }
        try returnToHomeDeck(cardIDs: cids)
    }

    func returnToHomeDeck(cardIDs: [Int64]) throws {
        guard !cardIDs.isEmpty else { return }
        try db.transaction {
            for cid in cardIDs {
                guard var card = try card(cid), card.odid != 0 else { continue }
                card.did = card.odid
                if card.odue != 0 { card.due = card.odue }
                card.odid = 0
                card.odue = 0
                if card.queue == CardQueue.preview { card.queue = card.type == CardType.new ? CardQueue.new : CardQueue.review }
                if card.queue == CardQueue.dayLearn, card.due > 1_000_000_000 { card.queue = CardQueue.learn }
                if card.queue == CardQueue.learn, card.due < 1_000_000_000 { card.queue = CardQueue.dayLearn }
                card.mod = Time.nowSecs
                card.usn = -1
                try writeCard(card)
            }
            try setModified()
        }
    }

    // MARK: Custom study

    private func searchDeck(_ deck: Deck) -> String {
        "\"deck:\(deck.name.replacingOccurrences(of: "\"", with: ""))\""
    }

    /// Runs one of Anki's custom study options. Returns the deck to study:
    /// the same deck for limit increases, or a "Custom Study Session"
    /// filtered deck.
    func customStudy(deckID: Int64, kind: CustomStudyKind) throws -> Int64 {
        guard var deck = deck(deckID) else { throw CollectionError.notFound("deck") }
        let today = Scheduler(collection: self).today
        let d = searchDeck(deck)
        switch kind {
        case .increaseNew(let n), .increaseReview(let n):
            let isNew: Bool
            if case .increaseNew = kind { isNew = true } else { isNew = false }
            let conf = config(forDeck: deckID)
            let key = isNew ? "newLimitToday" : "reviewLimitToday"
            var current = isNew ? conf.newPerDay : conf.reviewsPerDay
            if let own = deck.json[isNew ? "newLimit" : "reviewLimit"].int { current = Int(own) }
            if deck.json[key]["today"].intValue == today, let l = deck.json[key]["limit"].int { current = Int(l) }
            deck.json[key] = ["limit": JSON(current + n), "today": JSON(today)]
            deck.json[isNew ? "extendNew" : "extendRev"] = JSON(n)
            try updateDeck(deck)
            return deckID
        case .forgotten(let days):
            return try customSession([FilteredSearchTerm(search: "\(d) rated:\(days):1", limit: 9999, order: .random)], resched: true)
        case .reviewAhead(let days):
            return try customSession([FilteredSearchTerm(search: "\(d) prop:due<=\(days)", limit: 9999, order: .orderDue)], resched: true)
        case .previewNew(let days):
            return try customSession([FilteredSearchTerm(search: "\(d) is:new added:\(days)", limit: 9999, order: .orderAdded)], resched: false)
        case .cram(let state, let limit, let tags):
            var search = d
            if !tags.isEmpty {
                search += " (" + tags.map { "tag:\"\($0)\"" }.joined(separator: " or ") + ")"
            }
            switch state {
            case .newCards:
                return try customSession([FilteredSearchTerm(search: search + " is:new", limit: limit, order: .orderAdded)], resched: true)
            case .dueCards:
                return try customSession([FilteredSearchTerm(search: search + " is:due", limit: limit, order: .random)], resched: true)
            case .allReview:
                return try customSession([FilteredSearchTerm(search: search + " -is:new", limit: limit, order: .random)], resched: true)
            case .allRandom:
                return try customSession([FilteredSearchTerm(search: search, limit: limit, order: .random)], resched: false)
            }
        }
    }

    private func customSession(_ terms: [FilteredSearchTerm], resched: Bool) throws -> Int64 {
        let existing = deck(named: Collection.customStudyDeckName)
        if let existing, !existing.isFiltered {
            throw CollectionError.invalid("Rename the existing “\(Collection.customStudyDeckName)” deck first.")
        }
        let id = try saveFilteredDeck(id: existing?.id, name: Collection.customStudyDeckName, terms: terms, reschedule: resched)
        if try db.int("select count() from cards where did = ?", id) == 0 {
            throw CollectionError.invalid("No cards matched the criteria you provided.")
        }
        return id
    }

    // MARK: Browser tools from Anki desktop

    /// Anki's "Set Due Date": "0" is today, "3" is in three days, "1-7"
    /// picks a random day in the range. A trailing "!" also sets the interval.
    func setDueDate(cardIDs: [Int64], spec: String) throws {
        var text = spec.trimmingCharacters(in: .whitespaces)
        let setInterval = text.hasSuffix("!")
        if setInterval { text.removeLast() }
        let bounds = text.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let low = bounds.first, low >= 0 else {
            throw CollectionError.invalid("Enter a number of days, like 0, 3 or 1-7.")
        }
        let high = max(low, bounds.count > 1 ? bounds[1] : low)
        let today = Scheduler(collection: self).today
        try db.transaction {
            for cid in cardIDs {
                guard var c = try card(cid) else { continue }
                if c.odid != 0 { try returnToHomeDeck(cardIDs: [cid]); c = try card(cid) ?? c }
                let days = Int.random(in: low...high)
                if c.type == CardType.new || setInterval || c.ivl == 0 {
                    c.ivl = max(1, days)
                }
                if c.factor == 0 { c.factor = Int(config(forDeck: c.did).initialEase * 1000) }
                c.type = CardType.review
                c.queue = CardQueue.review
                c.due = Int64(today + days)
                c.left = 0
                try updateCard(c)
            }
        }
    }

    func toggleMark(noteID: Int64) throws {
        guard var n = try note(noteID) else { return }
        if n.hasTag("marked") {
            n.tags.removeAll { $0.caseInsensitiveCompare("marked") == .orderedSame }
        } else {
            n.tags.append("marked")
            registerTags(["marked"])
        }
        n.mod = Time.nowSecs
        n.usn = -1
        try writeNote(n)
        try save()
    }

    func revlog(cardID: Int64) throws -> [RevlogEntry] {
        try db.query("select \(RevlogEntry.columns) from revlog where cid = ? order by id desc", cardID).map(RevlogEntry.init(row:))
    }
}

import Foundation

struct SchedTiming {
    let now: Int64
    let daysElapsed: Int
    let nextDayAt: Int64
    var secsUntilRollover: Int { Int(max(0, nextDayAt - now)) }
}

struct DeckCounts: Equatable {
    var new = 0
    var learn = 0
    var review = 0
    var total: Int { new + learn + review }
}

struct DeckTreeNode: Identifiable {
    let deck: Deck
    var counts: DeckCounts
    var children: [DeckTreeNode]
    var id: Int64 { deck.id }
    var childrenOrNil: [DeckTreeNode]? { children.isEmpty ? nil : children }
}

/// Everything needed to undo the last answer.
struct AnswerUndo {
    let cardBefore: Card
    let revlogID: Int64
    let decksBefore: [Int64: JSON]
    let notesBefore: [Note]
    let siblingsBefore: [Card]
    let tagsBefore: [String: Int]
}

final class Scheduler {
    let col: Collection

    init(collection: Collection) { col = collection }

    // MARK: Timing

    static func v1CreationDate(now: Int64) -> Int64 {
        let cal = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(now))
        guard let fourAM = cal.date(bySettingHour: 4, minute: 0, second: 0, of: date) else { return now }
        let stamp = Int64(fourAM.timeIntervalSince1970)
        return stamp > now ? stamp - 86_400 : stamp
    }

    func timing(now: Int64 = Time.nowSecs) -> SchedTiming {
        let rollover = col.rolloverHour % 24
        let nowDate = Date(timeIntervalSince1970: TimeInterval(now))
        let currentMinsWest = -TimeZone.current.secondsFromGMT(for: nowDate) / 60
        let current = Scheduler.calendar(minutesWest: currentMinsWest)

        if let creationOffset = col.conf["creationOffset"].int {
            let creation = Scheduler.calendar(minutesWest: Int(max(-23 * 60, min(23 * 60, creationOffset))))
            let rolloverToday = current.date(bySettingHour: rollover, minute: 0, second: 0, of: nowDate) ?? nowDate
            let passed = rolloverToday <= nowDate
            let nextDay = passed ? rolloverToday.addingTimeInterval(86_400) : rolloverToday
            let createdDate = Date(timeIntervalSince1970: TimeInterval(col.crt))
            var days = Scheduler.dayNumber(nowDate, current) - Scheduler.dayNumber(createdDate, creation)
            if !passed { days -= 1 }
            return SchedTiming(now: now, daysElapsed: max(0, days), nextDayAt: Int64(nextDay.timeIntervalSince1970))
        }

        // legacy v2 timing, for collections without a stored creation offset
        let crtDate = Date(timeIntervalSince1970: TimeInterval(col.crt))
        let crtAtRollover = current.date(bySettingHour: rollover, minute: 0, second: 0, of: crtDate) ?? crtDate
        let days = (now - Int64(crtAtRollover.timeIntervalSince1970)) / 86_400
        var next = Int64((current.date(bySettingHour: rollover, minute: 0, second: 0, of: nowDate) ?? nowDate).timeIntervalSince1970)
        if next < now { next += 86_400 }
        return SchedTiming(now: now, daysElapsed: Int(max(0, days)), nextDayAt: next)
    }

    private static func calendar(minutesWest: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: -minutesWest * 60) ?? .current
        return cal
    }

    private static func dayNumber(_ date: Date, _ cal: Calendar) -> Int {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let d = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? date
        return Int((d.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    var today: Int { timing().daysElapsed }

    /// Unburies cards when a new day starts, as Anki's v3 scheduler does.
    func unburyIfDayRolledOver() throws {
        let day = today
        guard col.conf["lastUnburied"].int(or: 0) < Int64(day) else { return }
        try col.db.transaction {
            try col.db.execute("""
                update cards set queue = (case when type in (1, 3) then (case when due > 1000000000 then 1 else 3 end) else type end),
                  mod = ?, usn = -1 where queue in (-2, -3)
                """, Time.nowSecs)
            col.conf["lastUnburied"] = JSON(day)
            try col.save()
        }
    }

    // MARK: Limits

    private func remaining(_ deck: Deck, today: Int) -> (new: Int, review: Int) {
        if deck.isFiltered { return (Int.max / 4, Int.max / 4) }
        let conf = col.config(forDeck: deck.id)
        var newLimit = conf.newPerDay
        var revLimit = conf.reviewsPerDay
        if let n = deck.json["newLimit"].int { newLimit = Int(n) }
        if let r = deck.json["reviewLimit"].int { revLimit = Int(r) }
        if deck.json["newLimitToday"]["today"].intValue == today, let n = deck.json["newLimitToday"]["limit"].int {
            newLimit = Int(n)
        }
        if deck.json["reviewLimitToday"]["today"].intValue == today, let r = deck.json["reviewLimitToday"]["limit"].int {
            revLimit = Int(r)
        }
        let newDone = deck.today("newToday", day: today)
        let revDone = deck.today("revToday", day: today)
        return (max(0, newLimit - newDone), max(0, revLimit - revDone))
    }

    // MARK: Deck list counts

    func deckTree() -> [DeckTreeNode] {
        let t = timing()
        let today = t.daysElapsed
        let learnCutoff = t.now + col.learnAheadSecs
        var newBy: [Int64: Int] = [:], revBy: [Int64: Int] = [:], lrnBy: [Int64: Int] = [:]
        do {
            for r in try col.db.query("select did, count() from cards where queue = 0 group by did") {
                newBy[r[0].int] = Int(r[1].int)
            }
            for r in try col.db.query("select did, count() from cards where queue = 2 and due <= ? group by did", today) {
                revBy[r[0].int] = Int(r[1].int)
            }
            for r in try col.db.query("""
                select did, count() from cards where (queue = 1 and due < ?) or (queue = 3 and due <= ?) group by did
                """, learnCutoff, today) {
                lrnBy[r[0].int] = Int(r[1].int)
            }
        } catch {
            return []
        }

        let decks = col.allDecks
        func build(_ deck: Deck) -> DeckTreeNode {
            let prefix = deck.name + "::"
            let children = decks.filter { $0.name.hasPrefix(prefix) && $0.depth == deck.depth + 1 }.map(build)
            let rem = remaining(deck, today: today)
            var counts = DeckCounts()
            counts.new = min(rem.new, (newBy[deck.id] ?? 0) + children.reduce(0) { $0 + $1.counts.new })
            counts.review = min(rem.review, (revBy[deck.id] ?? 0) + children.reduce(0) { $0 + $1.counts.review })
            counts.learn = (lrnBy[deck.id] ?? 0) + children.reduce(0) { $0 + $1.counts.learn }
            return DeckTreeNode(deck: deck, counts: counts, children: children)
        }
        var roots = decks.filter { $0.depth == 0 }.map(build)
        // hide an empty Default deck when other decks exist, as Anki does
        if roots.count > 1, let idx = roots.firstIndex(where: { $0.deck.id == 1 }) {
            let hasCards = ((try? col.db.int("select exists(select 1 from cards where did = 1)")) ?? 0) != 0
            if !hasCards && roots[idx].children.isEmpty { roots.remove(at: idx) }
        }
        return roots
    }

    func counts(for deckID: Int64) -> DeckCounts {
        func find(_ nodes: [DeckTreeNode]) -> DeckCounts? {
            for n in nodes {
                if n.deck.id == deckID { return n.counts }
                if let c = find(n.children) { return c }
            }
            return nil
        }
        return find(deckTree()) ?? DeckCounts()
    }

    // MARK: Queue building

    /// Gathers cards per deck, honouring each deck's limit and the limits
    /// of its parents within the selected tree.
    private func gather(deckID: Int64, today: Int, sql: String, limitKey: (Deck) -> Int) throws -> [Card] {
        guard let root = col.deck(deckID) else { return [] }
        let tree = [root] + col.childDecks(of: deckID)
        var rem: [Int64: Int] = [:]
        for d in tree { rem[d.id] = limitKey(d) }
        var out: [Card] = []
        for d in tree {
            let chain = [d] + col.parents(of: d).filter { rem[$0.id] != nil }
            let allowance = chain.map { rem[$0.id] ?? 0 }.min() ?? 0
            guard allowance > 0 else { continue }
            let cards = try col.db.query(sql + " limit ?", d.id, today, allowance).map(Card.init(row:))
            out += cards
            for c in chain { rem[c.id] = (rem[c.id] ?? 0) - cards.count }
        }
        return out
    }

    func buildQueue(deckID: Int64) throws -> (learning: [Card], main: [Card]) {
        try unburyIfDayRolledOver()
        let t = timing()
        let today = t.daysElapsed
        let dids = col.deckTreeIDs(deckID).map(String.init).joined(separator: ",")

        let learning = try col.db.query("""
            select \(Card.columns) from cards where did in (\(dids)) and queue = 1 and due < ? order by due
            """, t.nextDayAt).map(Card.init(row:))
        let dayLearn = try col.db.query("""
            select \(Card.columns) from cards where did in (\(dids)) and queue = 3 and due <= ? order by due, id
            """, today).map(Card.init(row:))
        let reviews = try gather(
            deckID: deckID, today: today,
            sql: "select \(Card.columns) from cards where did = ? and queue = 2 and due <= ? order by due, random()",
            limitKey: { self.remaining($0, today: today).review })
            .sorted { $0.due < $1.due }
        let newCards = try gather(
            deckID: deckID, today: today,
            sql: "select \(Card.columns) from cards where did = ? and queue = 0 and ? >= 0 order by due, ord",
            limitKey: { self.remaining($0, today: today).new })

        var main: [Card] = []
        let dayLearnFirst = col.conf["dayLearnFirst"].bool(or: false)
        let revs = dayLearnFirst ? dayLearn + reviews : reviews + dayLearn
        // new cards are spread evenly between reviews by default
        switch col.conf["newSpread"].int(or: 0) {
        case 1:
            main = revs + newCards
        case 2:
            main = newCards + revs
        default:
            if revs.isEmpty || newCards.isEmpty {
                main = revs + newCards
            } else {
                let every = max(1, (revs.count + newCards.count) / newCards.count)
                var n = newCards[...]
                for (i, c) in revs.enumerated() {
                    if i % every == 0, let first = n.popFirst() { main.append(first) }
                    main.append(c)
                }
                main += n
            }
        }
        return (learning, main)
    }

    // MARK: Answering

    private func currentState(_ card: Card, today: Int, config: DeckConfig) -> CardState {
        var due = card.due
        if card.odid != 0 {
            if card.odue != 0 { due = card.odue }
        } else if card.type == CardType.review {
            due = min(due, Int64(today))
        }
        let ease = card.factor > 0 ? Double(card.factor) / 1000 : config.initialEase
        switch card.type {
        case CardType.new:
            return .new(position: Int(max(0, due)))
        case CardType.learn:
            let steps = LearningSteps(steps: config.learnSteps)
            return .learning(LearnState(remainingSteps: card.left, scheduledSecs: steps.currentDelaySecs(card.left)))
        case CardType.review:
            let elapsed = max(0, card.ivl - Int(due - Int64(today)))
            return .review(ReviewState(scheduledDays: card.ivl, elapsedDays: elapsed, easeFactor: ease, lapses: card.lapses))
        default:
            let steps = LearningSteps(steps: config.relearnSteps)
            return .relearning(
                LearnState(remainingSteps: card.left, scheduledSecs: steps.currentDelaySecs(card.left)),
                ReviewState(scheduledDays: card.ivl, elapsedDays: card.ivl, easeFactor: ease, lapses: card.lapses))
        }
    }

    private func homeConfig(_ card: Card) -> DeckConfig {
        col.config(forDeck: card.odid != 0 ? card.odid : card.did)
    }

    func nextStates(for card: Card) -> SchedulingStates {
        let config = homeConfig(card)
        let ctx = StateContext(config: config, fuzzFactor: Fuzz.factor(cardID: card.id, reps: card.reps))
        return ctx.nextStates(currentState(card, today: today, config: config))
    }

    /// Labels for the four answer buttons, e.g. "<1m", "10m", "4d".
    func intervalLabels(for card: Card) -> [String] {
        let states = nextStates(for: card)
        let t = timing()
        let collapse = Int(col.learnAheadSecs)
        return [states.again, states.hard, states.good, states.easy].map {
            Scheduler.describe($0.intervalKind.maybeAsDays(t.secsUntilRollover).seconds, collapse: collapse)
        }
    }

    static func describe(_ secs: Int, collapse: Int = 0) -> String {
        let prefix = secs < collapse && secs > 0 && secs < 60 ? "<" : ""
        let s = Double(secs)
        switch secs {
        case ..<60: return prefix.isEmpty ? (secs == 0 ? "<1m" : "\(secs)s") : "<1m"
        case ..<3600: return "\(Int((s / 60).rounded()))m"
        case ..<86_400: return trim(s / 3600) + "h"
        case ..<(86_400 * 30): return "\(Int((s / 86_400).rounded()))d"
        case ..<(86_400 * 365): return trim(s / 86_400 / 30) + "mo"
        default: return trim(s / 86_400 / 365) + "y"
        }
    }

    private static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// Applies an answer (1 = Again … 4 = Easy) and returns undo data.
    @discardableResult
    func answer(cardID: Int64, rating: Int, millisecondsTaken: Int) throws -> AnswerUndo {
        guard var card = try col.card(cardID) else { throw CollectionError.notFound("card") }
        let original = card
        let config = homeConfig(card)
        let t = timing()
        let today = t.daysElapsed
        let ctx = StateContext(config: config, fuzzFactor: Fuzz.factor(cardID: card.id, reps: card.reps))
        let current = currentState(card, today: today, config: config)
        let next = ctx.nextStates(current).state(for: rating)
        let decksBefore = col.decks
        let tagsBefore = col.tags
        var notesBefore: [Note] = []
        var siblingsBefore: [Card] = []
        let usn = -1

        return try col.db.transaction {
            // apply state
            card.reps += 1
            let secsUntilRollover = t.secsUntilRollover
            var data = card.dataJSON
            if case .new(let pos) = current { data["pos"] = JSON(pos) }
            var revlogFactor = 0.0
            switch next {
            case .new(let pos):
                card.type = CardType.new
                card.queue = CardQueue.new
                card.due = Int64(pos)
            case .learning(let l):
                card.left = l.remainingSteps
                card.type = CardType.learn
                applyLearningDue(&card, secs: l.scheduledSecs, timing: t)
            case .review(let r):
                card.queue = CardQueue.review
                card.type = CardType.review
                card.ivl = r.scheduledDays
                card.due = Int64(today + r.scheduledDays)
                card.factor = Int((r.easeFactor * 1000).rounded())
                card.lapses = r.lapses
                card.left = 0
                revlogFactor = r.easeFactor
            case .relearning(let l, let r):
                card.ivl = r.scheduledDays
                card.left = l.remainingSteps
                card.type = CardType.relearn
                card.lapses = r.lapses
                card.factor = Int((r.easeFactor * 1000).rounded())
                applyLearningDue(&card, secs: l.scheduledSecs, timing: t)
                revlogFactor = r.easeFactor
            }
            if next.leeched && config.leechSuspends { card.queue = CardQueue.suspended }

            // filtered decks: graduate back home, otherwise remember due
            if card.odid != 0 {
                if card.type == CardType.review && card.queue != CardQueue.learn && card.queue != CardQueue.dayLearn {
                    card.did = card.odid
                    card.odid = 0
                    card.odue = 0
                } else {
                    card.odue = card.due
                }
            }
            data["lrt"] = .int(t.now)
            card.dataJSON = data
            card.mod = t.now
            card.usn = usn
            try col.writeCard(card)

            // revlog
            let entry = RevlogEntry(
                id: Time.nowMillis, cid: card.id, usn: usn, ease: rating,
                ivl: next.intervalKind.maybeAsDays(secsUntilRollover).revlogInterval,
                lastIvl: current.intervalKind.maybeAsDays(secsUntilRollover).revlogInterval,
                factor: Int((revlogFactor * 1000).rounded()),
                time: min(millisecondsTaken, max(1, config.maxAnswerSecs) * 1000),
                type: current.revlogKind)
            try col.addRevlog(entry)
            let revlogID = try col.db.int("select max(id) from revlog where cid = ?", card.id)

            // deck stats for this deck and its parents
            if let deck = col.deck(original.did) {
                for var d in [deck] + col.parents(of: deck) {
                    if original.queue == CardQueue.new { Scheduler.bump(&d, "newToday", 1, today) }
                    if original.queue == CardQueue.review || original.queue == CardQueue.dayLearn {
                        Scheduler.bump(&d, "revToday", 1, today)
                    }
                    if original.queue == CardQueue.learn { Scheduler.bump(&d, "lrnToday", 1, today) }
                    Scheduler.bump(&d, "timeToday", millisecondsTaken, today)
                    d.json["mod"] = .int(t.now)
                    d.json["usn"] = JSON(usn)
                    col.decks[d.id] = d.json
                }
            }

            // bury siblings
            let buryNew = config.buryNew, buryRev = config.buryReviews, buryLrn = config.buryInterdayLearning
            if buryNew || buryRev || buryLrn {
                let siblings = try col.db.query("""
                    select \(Card.columns) from cards where nid = ? and id != ? and queue in (0, 2, 3)
                    """, card.nid, card.id).map(Card.init(row:))
                for var s in siblings {
                    let shouldBury = (s.queue == CardQueue.new && buryNew)
                        || (s.queue == CardQueue.review && buryRev && s.due <= Int64(today))
                        || (s.queue == CardQueue.dayLearn && buryLrn && s.due <= Int64(today))
                    guard shouldBury else { continue }
                    siblingsBefore.append(s)
                    s.queue = CardQueue.schedBuried
                    s.mod = t.now
                    s.usn = usn
                    try col.writeCard(s)
                }
            }

            // leech tag
            if next.leeched, var note = try col.note(card.nid) {
                notesBefore.append(note)
                if !note.hasTag("leech") { note.tags.append("leech") }
                note.mod = t.now
                note.usn = usn
                try col.writeNote(note)
                col.registerTags(["leech"])
            }

            try col.save()
            return AnswerUndo(cardBefore: original, revlogID: revlogID, decksBefore: decksBefore,
                              notesBefore: notesBefore, siblingsBefore: siblingsBefore, tagsBefore: tagsBefore)
        }
    }

    private static func bump(_ d: inout Deck, _ key: String, _ by: Int, _ today: Int) {
        let current = d.today(key, day: today)
        d.json[key] = [JSON(today), JSON(current + by)]
    }

    private func applyLearningDue(_ card: inout Card, secs: Int, timing t: SchedTiming) {
        let kind = IntervalKind.secs(secs).maybeAsDays(t.secsUntilRollover)
        switch kind {
        case .secs(let s):
            card.queue = CardQueue.learn
            let upper = s + min(Int(Double(s) * 0.25), 300)
            let fuzzed = upper > s ? Int.random(in: s..<upper) : s
            card.due = t.now + Int64(fuzzed)
        case .days(let d):
            card.queue = CardQueue.dayLearn
            card.due = Int64(t.daysElapsed + d)
        }
    }

    func undo(_ u: AnswerUndo) throws {
        try col.db.transaction {
            var card = u.cardBefore
            card.usn = -1
            card.mod = Time.nowSecs
            try col.writeCard(card)
            try col.db.execute("delete from revlog where id = ?", u.revlogID)
            for var s in u.siblingsBefore {
                s.usn = -1
                s.mod = Time.nowSecs
                try col.writeCard(s)
            }
            for var n in u.notesBefore {
                n.usn = -1
                n.mod = Time.nowSecs
                try col.writeNote(n)
            }
            for (id, json) in u.decksBefore where col.decks[id] != json {
                var j = json
                j["usn"] = -1
                j["mod"] = .int(Time.nowSecs)
                col.decks[id] = j
            }
            col.tags = u.tagsBefore
            try col.save()
        }
    }
}

/// A study session over one deck tree.
final class StudySession {
    let scheduler: Scheduler
    let deckID: Int64
    private(set) var learning: [Card] = []
    private(set) var main: [Card] = []
    private(set) var current: Card?
    private var undoStack: [AnswerUndo] = []

    init(scheduler: Scheduler, deckID: Int64) throws {
        self.scheduler = scheduler
        self.deckID = deckID
        try rebuild()
    }

    func rebuild() throws {
        let q = try scheduler.buildQueue(deckID: deckID)
        learning = q.learning
        main = q.main
        current = nil
    }

    var counts: DeckCounts {
        let now = Time.nowSecs + scheduler.col.learnAheadSecs
        return DeckCounts(
            new: main.filter { $0.queue == CardQueue.new }.count,
            learn: learning.filter { $0.due < now }.count + main.filter { $0.queue == CardQueue.dayLearn }.count,
            review: main.filter { $0.queue == CardQueue.review }.count)
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// The next due learning card time, when nothing else is left today.
    var nextLearningDue: Date? {
        learning.map(\.due).min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    func nextCard() -> Card? {
        let col = scheduler.col
        let now = Time.nowSecs
        learning.sort { $0.due < $1.due }
        let preview = isPreview
        func fresh(_ c: Card) -> Card? {
            guard let f = try? col.card(c.id), f.did == c.did else { return nil }
            // preview re-shows keep their session-only due time
            if preview, c.odid != 0 { return c }
            guard f.queue == c.queue else { return nil }
            return f
        }
        while let first = learning.first, first.due <= now {
            if let f = fresh(first) { current = f; return f }
            learning.removeFirst()
        }
        while let first = main.first {
            if let f = fresh(first) { current = f; return f }
            main.removeFirst()
        }
        let ahead = now + col.learnAheadSecs
        while let first = learning.first, first.due <= ahead {
            if let f = fresh(first) { current = f; return f }
            learning.removeFirst()
        }
        current = nil
        return nil
    }

    /// In a filtered deck with rescheduling off, answers don't change the
    /// card's schedule: Again shows it again shortly, anything else returns
    /// it to its home deck, like Anki's preview mode.
    var isPreview: Bool {
        guard let deck = scheduler.col.deck(deckID), deck.isFiltered else { return false }
        return !deck.json["resched"].bool(or: true)
    }

    func answer(rating: Int, millisecondsTaken: Int) throws {
        guard let card = current else { return }
        if isPreview && card.odid != 0 {
            learning.removeAll { $0.id == card.id }
            main.removeAll { $0.id == card.id }
            if rating == 1 {
                var again = card
                let delay = scheduler.col.deck(deckID)?.json["previewAgainSecs"].int(or: 60) ?? 60
                again.due = Time.nowSecs + max(1, delay)
                learning.append(again)
            } else {
                try scheduler.col.returnToHomeDeck(cardIDs: [card.id])
            }
            current = nil
            return
        }
        let undo = try scheduler.answer(cardID: card.id, rating: rating, millisecondsTaken: millisecondsTaken)
        undoStack.append(undo)
        if undoStack.count > 30 { undoStack.removeFirst() }
        learning.removeAll { $0.id == card.id }
        main.removeAll { $0.id == card.id }
        if let updated = try scheduler.col.card(card.id), updated.queue == CardQueue.learn,
           updated.due < scheduler.timing().nextDayAt
        {
            learning.append(updated)
        }
        current = nil
    }

    func undo() throws {
        guard let u = undoStack.popLast() else { return }
        try scheduler.undo(u)
        learning.removeAll { $0.id == u.cardBefore.id }
        main.removeAll { $0.id == u.cardBefore.id }
        if u.cardBefore.queue == CardQueue.learn {
            learning.insert(u.cardBefore, at: 0)
        } else {
            main.insert(u.cardBefore, at: 0)
        }
        for s in u.siblingsBefore where !main.contains(where: { $0.id == s.id }) {
            main.append(s)
        }
        current = nil
    }

    /// Removes the current card from the session (after bury/suspend/delete).
    func skipCurrent() {
        guard let c = current else { return }
        learning.removeAll { $0.id == c.id }
        main.removeAll { $0.id == c.id }
        current = nil
    }
}

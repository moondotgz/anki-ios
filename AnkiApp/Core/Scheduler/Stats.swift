import Foundation

struct DayValue: Identifiable, Hashable {
    let day: Int
    let count: Int
    var id: Int { day }
}

struct CollectionStats {
    var todayReviews = 0
    var todaySeconds = 0
    var todayAgain = 0
    var todayCorrectPercent: Double { todayReviews == 0 ? 0 : Double(todayReviews - todayAgain) / Double(todayReviews) * 100 }
    var newCards = 0
    var learningCards = 0
    var youngCards = 0
    var matureCards = 0
    var suspendedCards = 0
    var reviewsByDay: [DayValue] = []
    var forecast: [DayValue] = []
    var streak = 0
    var totalReviews = 0

    /// Stats for a deck tree, or the whole collection when `deckID` is nil.
    static func compute(_ col: Collection, deckID: Int64?) throws -> CollectionStats {
        let sched = Scheduler(collection: col)
        let t = sched.timing()
        var s = CollectionStats()
        let deckFilter: String
        if let deckID {
            let ids = col.deckTreeIDs(deckID).map(String.init).joined(separator: ",")
            deckFilter = "(did in (\(ids)) or odid in (\(ids)))"
        } else {
            deckFilter = "1"
        }
        let dayStartMs = (t.nextDayAt - 86_400) * 1000
        if let r = try col.db.first("""
            select count(), coalesce(sum(time), 0), coalesce(sum(case when ease = 1 then 1 else 0 end), 0)
            from revlog where id > ? and cid in (select id from cards where \(deckFilter))
            """, dayStartMs)
        {
            s.todayReviews = Int(r[0].int)
            s.todaySeconds = Int(r[1].int / 1000)
            s.todayAgain = Int(r[2].int)
        }
        for r in try col.db.query("select type, queue, ivl, count() from cards where \(deckFilter) group by type, queue, ivl >= 21") {
            let count = Int(r[3].int)
            if r[1].int == Int64(CardQueue.suspended) { s.suspendedCards += count }
            switch Int(r[0].int) {
            case CardType.new: s.newCards += count
            case CardType.learn, CardType.relearn: s.learningCards += count
            default:
                if r[2].int >= 21 { s.matureCards += count } else { s.youngCards += count }
            }
        }
        // reviews per day, last 30 days
        var byDay: [Int: Int] = [:]
        let since = (t.nextDayAt - 30 * 86_400) * 1000
        for r in try col.db.query("""
            select (id / 1000 - ?) / 86400, count() from revlog
            where id > ? and cid in (select id from cards where \(deckFilter)) group by 1
            """, t.nextDayAt, since)
        {
            byDay[Int(r[0].int)] = Int(r[1].int)
        }
        s.reviewsByDay = (-29...0).map { DayValue(day: $0, count: byDay[$0] ?? 0) }
        // forecast, next 30 days
        var due: [Int: Int] = [:]
        for r in try col.db.query("""
            select due - ?, count() from cards where queue in (2, 3) and \(deckFilter) and due < ? group by due
            """, t.daysElapsed, t.daysElapsed + 30)
        {
            due[max(0, Int(r[0].int))] = (due[max(0, Int(r[0].int))] ?? 0) + Int(r[1].int)
        }
        s.forecast = (0..<30).map { DayValue(day: $0, count: due[$0] ?? 0) }
        // streak of days with reviews
        let days = Set(try col.db.query("select distinct (id / 1000 - ?) / 86400 from revlog where id > ?",
                                        t.nextDayAt, (t.nextDayAt - 400 * 86_400) * 1000).map { Int($0[0].int) })
        // integer division truncates, so today is bucket 0 and yesterday -1
        var d = 0
        if !days.contains(d) { d = -1 }
        while days.contains(d) { s.streak += 1; d -= 1 }
        s.totalReviews = Int(try col.db.int("select count() from revlog"))
        return s
    }
}

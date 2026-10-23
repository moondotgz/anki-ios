import Foundation

/// A subset of Anki's search syntax: words and "quoted phrases",
/// negation with `-`, `or`, parentheses, and `deck:`, `tag:`, `is:`, `flag:`, `note:`,
/// `card:`, `added:`, `rated:`, `prop:ivl`/`prop:due`, `nid:`, `cid:` and
/// `field:value` searches.
struct SearchQuery {
    let text: String

    struct Clause {
        var sql: String
        var params: [SQLBindable]
    }

    /// Splits a search into terms. Quotes group words; parentheses
    /// outside quotes become their own tokens, as do `-(`.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for ch in text {
            if ch == "\"" {
                inQuote.toggle()
                continue
            }
            if inQuote {
                current.append(ch)
            } else if ch.isWhitespace {
                flush()
            } else if ch == "(" {
                if current == "-" { current = ""; tokens.append("-(") } else { flush(); tokens.append("(") }
            } else if ch == ")" {
                flush()
                tokens.append(")")
            } else {
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    private static func like(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped.replacingOccurrences(of: "*", with: "%")
    }

    func clause(collection col: Collection, today: Int) -> Clause {
        var index = 0
        let tokens = SearchQuery.tokenize(text)
        return SearchQuery.group(tokens, &index, col: col, today: today)
    }

    /// Parses terms up to a closing parenthesis: adjacent terms are ANDed,
    /// `or` separates alternatives.
    private static func group(_ tokens: [String], _ i: inout Int, col: Collection, today: Int) -> Clause {
        var groups: [[Clause]] = [[]]
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            switch token.lowercased() {
            case ")":
                return combine(groups)
            case "or":
                groups.append([])
                continue
            case "and":
                continue
            default:
                break
            }
            var c: Clause
            if token == "(" || token == "-(" {
                c = group(tokens, &i, col: col, today: today)
                if token == "-(" { c.sql = "not (\(c.sql))" }
            } else {
                var negate = false
                var term = token
                if term.hasPrefix("-"), term.count > 1 {
                    negate = true
                    term.removeFirst()
                }
                guard let t = SearchQuery.term(term, col: col, today: today) else { continue }
                c = t
                if negate { c.sql = "not (\(c.sql))" }
            }
            groups[groups.count - 1].append(c)
        }
        return combine(groups)
    }

    private static func combine(_ groups: [[Clause]]) -> Clause {
        let parts = groups.filter { !$0.isEmpty }.map { g in
            Clause(sql: "(" + g.map(\.sql).joined(separator: " and ") + ")", params: g.flatMap(\.params))
        }
        guard !parts.isEmpty else { return Clause(sql: "1", params: []) }
        return Clause(sql: "(" + parts.map(\.sql).joined(separator: " or ") + ")", params: parts.flatMap(\.params))
    }

    private static func term(_ term: String, col: Collection, today: Int) -> Clause? {
        guard let colon = term.firstIndex(of: ":"), colon != term.startIndex else {
            return Clause(sql: "n.flds like ? escape '\\'", params: ["%" + like(term) + "%"])
        }
        let key = term[..<colon].lowercased()
        let value = String(term[term.index(after: colon)...])
        switch key {
        case "deck":
            if value == "*" { return Clause(sql: "1", params: []) }
            if value.lowercased() == "current" {
                let ids = col.deckTreeIDs(col.currentDeckID).map(String.init).joined(separator: ",")
                return Clause(sql: "(c.did in (\(ids)) or c.odid in (\(ids)))", params: [])
            }
            let escaped = NSRegularExpression.escapedPattern(for: value).replacingOccurrences(of: "\\*", with: ".*")
            let re = try? NSRegularExpression(pattern: "^\(escaped)(::.*)?$", options: .caseInsensitive)
            let ids = col.allDecks.filter { d in
                re?.firstMatch(in: d.name, range: NSRange(d.name.startIndex..., in: d.name)) != nil
            }.map { String($0.id) }
            guard !ids.isEmpty else { return Clause(sql: "0", params: []) }
            let list = ids.joined(separator: ",")
            return Clause(sql: "(c.did in (\(list)) or c.odid in (\(list)))", params: [])
        case "tag":
            if value == "none" { return Clause(sql: "n.tags = ''", params: []) }
            return Clause(sql: "(' ' || lower(n.tags) || ' ') like ? escape '\\'",
                          params: ["% " + like(value.lowercased()) + " %"])
        case "is":
            switch value.lowercased() {
            case "new": return Clause(sql: "c.type = 0", params: [])
            case "learn": return Clause(sql: "c.queue in (1, 3)", params: [])
            case "review": return Clause(sql: "c.type in (2, 3)", params: [])
            case "due":
                return Clause(sql: "((c.queue in (2, 3) and c.due <= ?) or (c.queue = 1 and c.due <= ?))",
                              params: [today, Time.nowSecs])
            case "suspended": return Clause(sql: "c.queue = -1", params: [])
            case "buried": return Clause(sql: "c.queue in (-2, -3)", params: [])
            default: return nil
            }
        case "flag":
            guard let f = Int(value) else { return nil }
            return Clause(sql: "(c.flags & 7) = ?", params: [f])
        case "note":
            let ids = col.notetypes.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }.map { String($0.id) }
            return Clause(sql: ids.isEmpty ? "0" : "n.mid in (\(ids.joined(separator: ",")))", params: [])
        case "card":
            if let n = Int(value) { return Clause(sql: "c.ord = ?", params: [n - 1]) }
            return nil
        case "added":
            guard let days = Int(value) else { return nil }
            let cutoff = (Scheduler(collection: col).timing().nextDayAt - Int64(days) * 86_400) * 1000
            return Clause(sql: "c.id > ?", params: [cutoff])
        case "rated":
            // rated:DAYS or rated:DAYS:EASE
            let parts = value.split(separator: ":")
            guard let days = Int(parts.first ?? "") else { return nil }
            let cutoff = (Scheduler(collection: col).timing().nextDayAt - Int64(days) * 86_400) * 1000
            if parts.count > 1, let ease = Int(parts[1]) {
                return Clause(sql: "c.id in (select cid from revlog where id > ? and ease = ?)", params: [cutoff, ease])
            }
            return Clause(sql: "c.id in (select cid from revlog where id > ? and ease > 0)", params: [cutoff])
        case "nid":
            let ids = value.split(separator: ",").compactMap { Int64($0) }.map(String.init).joined(separator: ",")
            return Clause(sql: "n.id in (\(ids.isEmpty ? "0" : ids))", params: [])
        case "cid":
            let ids = value.split(separator: ",").compactMap { Int64($0) }.map(String.init).joined(separator: ",")
            return Clause(sql: "c.id in (\(ids.isEmpty ? "0" : ids))", params: [])
        case "prop":
            for op in [">=", "<=", "!=", ">", "<", "="] {
                guard let r = value.range(of: op) else { continue }
                let prop = value[..<r.lowerBound].lowercased()
                guard let num = Double(value[r.upperBound...]) else { return nil }
                switch prop {
                case "ivl": return Clause(sql: "c.ivl \(op) ?", params: [num])
                case "due": return Clause(sql: "c.queue in (2, 3) and c.due \(op) ?", params: [Double(today) + num])
                case "reps": return Clause(sql: "c.reps \(op) ?", params: [num])
                case "lapses": return Clause(sql: "c.lapses \(op) ?", params: [num])
                case "ease": return Clause(sql: "c.factor \(op) ?", params: [num * 1000])
                default: return nil
                }
            }
            return nil
        default:
            // field:value
            var clauses: [String] = []
            var params: [SQLBindable] = []
            for nt in col.notetypes {
                guard let idx = nt.fieldIndex(String(term[..<colon])) else { continue }
                clauses.append("(n.mid = ? and field_at_index(n.flds, ?) like ? escape '\\')")
                params += [nt.id, idx, like(value)]
            }
            if clauses.isEmpty {
                return Clause(sql: "n.flds like ? escape '\\'", params: ["%" + like(term) + "%"])
            }
            return Clause(sql: "(" + clauses.joined(separator: " or ") + ")", params: params)
        }
    }
}

struct BrowserRow: Identifiable, Hashable {
    let id: Int64
    let noteID: Int64
    let sortField: String
    let deckName: String
    let due: String
    let queue: Int
    let flag: Int
    let tags: String
}

extension Collection {
    func searchCards(_ text: String, limit: Int = 2000) throws -> [BrowserRow] {
        let sched = Scheduler(collection: self)
        let today = sched.today
        let clause = SearchQuery(text: text).clause(collection: self, today: today)
        let sql = """
            select c.id, c.nid, n.sfld, c.did, c.odid, c.type, c.queue, c.due, c.flags, n.tags
            from cards c join notes n on c.nid = n.id where \(clause.sql)
            order by n.sfld collate nocase, c.ord limit \(limit)
            """
        let deckNames = Dictionary(uniqueKeysWithValues: allDecks.map { ($0.id, $0.name) })
        return try db.query(sql, params: clause.params).map { r in
            let queue = Int(r[6].int)
            let type = Int(r[5].int)
            let due: String
            switch queue {
            case CardQueue.new: due = "New #\(r[7].int)"
            case CardQueue.review, CardQueue.dayLearn:
                let days = Int(r[7].int) - today
                due = days <= 0 ? "Due" : "in \(days)d"
            case CardQueue.learn: due = "Learning"
            case CardQueue.suspended: due = "Suspended"
            case CardQueue.userBuried, CardQueue.schedBuried: due = "Buried"
            default: due = type == CardType.new ? "New" : ""
            }
            let did = r[4].int != 0 ? r[4].int : r[3].int
            return BrowserRow(id: r[0].int, noteID: r[1].int, sortField: r[2].text,
                              deckName: deckNames[did] ?? "", due: due, queue: queue,
                              flag: Int(r[8].int) & 7, tags: r[9].text.trimmingCharacters(in: .whitespaces))
        }
    }
}

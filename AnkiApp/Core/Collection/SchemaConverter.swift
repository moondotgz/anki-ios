import Foundation

/// Converts a schema 18 collection (what AnkiWeb sends on a full download
/// with sync protocol v11, and what `.anki21b` packages contain) into the
/// schema 11 layout this app stores. This mirrors rslib's
/// `downgrade_to_schema_11`, including the protobuf → legacy JSON mapping.
enum SchemaConverter {
    /// Returns the schema version (`col.ver`) of the SQLite file at `url`.
    static func version(of url: URL) throws -> Int {
        let db = try Database(path: url.path)
        defer { db.close() }
        return Int(try db.int("select ver from col"))
    }

    /// Writes a schema 11 copy of `source` to `destination`.
    static func convertToSchema11(source: URL, destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let ver = try version(of: source)
        if ver == 11 {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard ver >= 15 else {
            throw CollectionError.invalid("Collection version \(ver) is not supported")
        }
        let src = try Database(path: source.path)
        defer { src.close() }
        let dst = try Database(path: destination.path)
        defer { dst.close() }

        try dst.transaction {
            try dst.executeBatch(Collection.schema11)
            try dst.executeBatch("delete from col")
            try copyRows(src, dst, table: "notes", columns: "id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data")
            try copyRows(src, dst, table: "cards", columns: Card.columns)
            try copyRows(src, dst, table: "revlog", columns: RevlogEntry.columns)
            try copyRows(src, dst, table: "graves", columns: "usn, oid, type")

            guard let col = try src.first("select crt, mod, scm, dty, usn, ls from col") else {
                throw CollectionError.invalid("missing col row")
            }
            let models = try notetypes(src)
            let decks = try self.decks(src)
            let dconf = try deckConfigs(src)
            let conf = try config(src)
            let tags = try self.tags(src)
            try dst.execute(
                "insert into col values (1, ?, ?, ?, 11, ?, ?, ?, ?, ?, ?, ?, ?)",
                col[0], col[1], col[2], col[3], col[4], col[5],
                conf.serialized(), models.serialized(), decks.serialized(), dconf.serialized(), tags.serialized())
        }
    }

    private static func copyRows(_ src: Database, _ dst: Database, table: String, columns: String) throws {
        let placeholders = columns.split(separator: ",").map { _ in "?" }.joined(separator: ",")
        let insert = "insert or ignore into \(table) (\(columns)) values (\(placeholders))"
        try src.forEach("select \(columns) from \(table)") { row in
            try dst.execute(insert, params: row.map { $0 as SQLBindable? })
        }
    }

    private static func parseOther(_ data: Data, reserved: Set<String>) -> [String: JSON] {
        guard !data.isEmpty, let obj = (try? JSON.parse(data))?.object else { return [:] }
        return obj.filter { !reserved.contains($0.key) }
    }

    private static func merge(_ base: [String: JSON], _ other: [String: JSON]) -> JSON {
        var out = other
        for (k, v) in base { out[k] = v }
        return .object(out)
    }

    private static func floats(_ v: [Float]) -> JSON { .array(v.map { JSON.double(Double($0)) }) }
    private static func float(_ v: Float) -> JSON { .double(Double(v)) }

    // MARK: Notetypes

    private static let reservedNotetype: Set<String> = [
        "latexPost", "flds", "css", "originalStockKind", "originalId", "id", "usn", "mod", "req", "latexPre",
        "name", "did", "tmpls", "type", "sortf", "latexsvg",
    ]
    private static let reservedField: Set<String> = [
        "name", "ord", "sticky", "rtl", "plainText", "font", "size", "collapsed", "description",
        "excludeFromSearch", "id", "tag", "preventDeletion",
    ]
    private static let reservedTemplate: Set<String> = [
        "name", "ord", "did", "afmt", "bafmt", "qfmt", "bqfmt", "bfont", "bsize", "id",
    ]

    private static func notetypes(_ db: Database) throws -> JSON {
        var out: [String: JSON] = [:]
        for row in try db.query("select id, name, mtime_secs, usn, config from notetypes") {
            let id = row[0].int
            let c = ProtoMessage(row[4].blob)
            var fields: [JSON] = []
            for f in try db.query("select ord, name, config from fields where ntid = ? order by ord", id) {
                let fc = ProtoMessage(f[2].blob)
                let base: [String: JSON] = [
                    "name": .string(f[1].text),
                    "ord": .int(f[0].int),
                    "sticky": .bool(fc.bool(1)),
                    "rtl": .bool(fc.bool(2)),
                    "font": .string(fc.string(3)),
                    "size": .int(Int64(fc.uint(4))),
                    "description": .string(fc.string(5)),
                    "plainText": .bool(fc.bool(6)),
                    "collapsed": .bool(fc.bool(7)),
                    "excludeFromSearch": .bool(fc.bool(8)),
                    "id": fc.optionalInt64(9).map(JSON.int) ?? .null,
                    "tag": fc.optionalUInt32(10).map { JSON.int(Int64($0)) } ?? .null,
                    "preventDeletion": .bool(fc.bool(11)),
                ]
                fields.append(merge(base, parseOther(fc.bytes(255), reserved: reservedField)))
            }
            var templates: [JSON] = []
            for t in try db.query("select ord, name, config from templates where ntid = ? order by ord", id) {
                let tc = ProtoMessage(t[2].blob)
                let did = tc.int64(5)
                let base: [String: JSON] = [
                    "name": .string(t[1].text),
                    "ord": .int(t[0].int),
                    "qfmt": .string(tc.string(1)),
                    "afmt": .string(tc.string(2)),
                    "bqfmt": .string(tc.string(3)),
                    "bafmt": .string(tc.string(4)),
                    "did": did > 0 ? .int(did) : .null,
                    "bfont": .string(tc.string(6)),
                    "bsize": .int(Int64(UInt8(truncatingIfNeeded: tc.uint(7)))),
                    "id": tc.optionalInt64(8).map(JSON.int) ?? .null,
                ]
                templates.append(merge(base, parseOther(tc.bytes(255), reserved: reservedTemplate)))
            }
            let reqs: [JSON] = c.messages(8).map { r in
                let kind: String
                switch r.uint(2) {
                case 1: kind = "any"
                case 2: kind = "all"
                default: kind = "none"
                }
                return [.int(Int64(r.uint(1))), .string(kind), .array(r.uints(3).map { JSON.int(Int64($0)) })]
            }
            let targetDeck = c.int64(4)
            var base: [String: JSON] = [
                "id": .int(id),
                "name": .string(row[1].text),
                "type": .int(c.uint(1) == 1 ? 1 : 0),
                "mod": .int(row[2].int),
                "usn": .int(row[3].int),
                "sortf": .int(Int64(c.uint(2))),
                "did": targetDeck == 0 ? .null : .int(targetDeck),
                "tmpls": .array(templates),
                "flds": .array(fields),
                "css": .string(c.string(3)),
                "latexPre": .string(c.string(5)),
                "latexPost": .string(c.string(6)),
                "latexsvg": .bool(c.bool(7)),
                "req": .array(reqs),
            ]
            let stockKind = c.int64(9)
            if stockKind != 0 { base["originalStockKind"] = .int(stockKind) }
            if let original = c.optionalInt64(10) { base["originalId"] = .int(original) }
            out[String(id)] = merge(base, parseOther(c.bytes(255), reserved: reservedNotetype))
        }
        return .object(out)
    }

    // MARK: Decks

    private static let reservedDeck: Set<String> = [
        "usn", "revToday", "newLimit", "dyn", "reviewLimit", "newToday", "timeToday", "reviewLimitToday",
        "extendNew", "mod", "newLimitToday", "desc", "name", "lrnToday", "conf", "browserCollapsed",
        "extendRev", "id", "collapsed", "desiredRetention",
    ]

    private static func dayLimit(_ m: ProtoMessage?) -> JSON {
        guard let m else { return .null }
        return ["limit": .int(Int64(m.uint(1))), "today": .int(Int64(m.uint(2)))]
    }

    private static func decks(_ db: Database) throws -> JSON {
        var out: [String: JSON] = [:]
        for row in try db.query("select id, name, mtime_secs, usn, common, kind from decks") {
            let id = row[0].int
            let common = ProtoMessage(row[4].blob)
            let kind = ProtoMessage(row[5].blob)
            let day = JSON.int(Int64(common.uint(3)))
            var base: [String: JSON] = [
                "id": .int(id),
                "mod": .int(row[2].int),
                "name": .string(row[1].text.replacingOccurrences(of: "\u{1f}", with: "::")),
                "usn": .int(row[3].int),
                "lrnToday": [day, .int(Int64(common.int32(6)))],
                "revToday": [day, .int(Int64(common.int32(5)))],
                "newToday": [day, .int(Int64(common.int32(4)))],
                "timeToday": [day, .int(Int64(common.int32(7)))],
                "collapsed": .bool(common.bool(1)),
                "browserCollapsed": .bool(common.bool(2)),
            ]
            if let filtered = kind.message(2) {
                base["dyn"] = 1
                base["desc"] = ""
                base["resched"] = .bool(filtered.bool(1))
                base["terms"] = .array(filtered.messages(2).map { t in
                    [.string(t.string(1)), .int(Int64(t.uint(2))), .int(Int64(t.uint(3)))]
                })
                base["separate"] = true
                let delays = filtered.floats(3)
                base["delays"] = delays.isEmpty ? .null : floats(delays)
                base["previewDelay"] = .int(Int64(filtered.uint(4)))
                base["previewAgainSecs"] = .int(Int64(filtered.uint(7)))
                base["previewHardSecs"] = .int(Int64(filtered.uint(5)))
                base["previewGoodSecs"] = .int(Int64(filtered.uint(6)))
            } else {
                let normal = kind.message(1) ?? ProtoMessage()
                base["dyn"] = 0
                base["conf"] = .int(normal.int64(1))
                base["extendNew"] = .int(Int64(normal.uint(2)))
                base["extendRev"] = .int(Int64(normal.uint(3)))
                base["desc"] = .string(normal.string(4))
                if normal.bool(5) { base["md"] = true }
                base["reviewLimit"] = normal.optionalUInt32(6).map { JSON.int(Int64($0)) } ?? .null
                base["newLimit"] = normal.optionalUInt32(7).map { JSON.int(Int64($0)) } ?? .null
                base["reviewLimitToday"] = dayLimit(normal.message(8))
                base["newLimitToday"] = dayLimit(normal.message(9))
                base["desiredRetention"] = normal.optionalFloat(10).map { JSON.int(Int64(($0 * 100).rounded())) } ?? .null
            }
            out[String(id)] = merge(base, parseOther(common.bytes(255), reserved: reservedDeck))
        }
        return .object(out)
    }

    // MARK: Deck options

    private static let reservedDeckConfig: Set<String> = [
        "id", "newSortOrder", "replayq", "newPerDayMinimum", "usn", "autoplay", "dyn", "maxTaken", "reviewOrder",
        "buryInterdayLearning", "newMix", "mod", "timer", "name", "interdayLearningMix", "newGatherPriority",
        "fsrsWeights", "fsrsParams5", "fsrsParams6", "desiredRetention", "stopTimerOnAnswer",
        "secondsToShowQuestion", "secondsToShowAnswer", "questionAction", "answerAction", "waitForAudio",
        "sm2Retention", "weightSearch", "ignoreRevlogsBeforeDate", "easyDaysPercentages",
    ]

    private static func deckConfigs(_ db: Database) throws -> JSON {
        var out: [String: JSON] = [:]
        for row in try db.query("select id, name, mtime_secs, usn, config from deck_config") {
            let id = row[0].int
            let c = ProtoMessage(row[4].blob)
            var top = parseOther(c.bytes(255), reserved: [])
            let newOther = top.removeValue(forKey: "new")?.object?.filter {
                !["order", "delays", "bury", "perDay", "initialFactor", "ints"].contains($0.key)
            } ?? [:]
            let revOther = top.removeValue(forKey: "rev")?.object?.filter {
                !["maxIvl", "hardFactor", "ease4", "ivlFct", "perDay", "bury"].contains($0.key)
            } ?? [:]
            let lapseOther = top.removeValue(forKey: "lapse")?.object?.filter {
                !["leechFails", "mult", "leechAction", "delays", "minInt"].contains($0.key)
            } ?? [:]
            top = top.filter { !reservedDeckConfig.contains($0.key) }

            let answerAction = c.uint(43)
            let newConf = merge([
                "bury": .bool(c.bool(27)),
                "delays": floats(c.floats(1)),
                "initialFactor": .int(Int64(c.float(11) * 1000)),
                "ints": [.int(Int64(c.uint(18))), .int(Int64(c.uint(19))), 0],
                "order": .int(c.uint(20) == 1 ? 0 : 1),
                "perDay": .int(Int64(c.uint(9))),
            ], newOther)
            let revConf = merge([
                "bury": .bool(c.bool(28)),
                "ease4": float(c.float(12)),
                "ivlFct": float(c.float(15)),
                "maxIvl": .int(Int64(c.uint(16))),
                "perDay": .int(Int64(c.uint(10))),
                "hardFactor": float(c.float(13)),
            ], revOther)
            let lapseConf = merge([
                "delays": floats(c.floats(2)),
                "leechAction": .int(c.uint(21) == 1 ? 1 : 0),
                "leechFails": .int(Int64(c.uint(22))),
                "minInt": .int(Int64(c.uint(17))),
                "mult": float(c.float(14)),
            ], lapseOther)
            let base: [String: JSON] = [
                "id": .int(id),
                "mod": .int(row[2].int),
                "name": .string(row[1].text),
                "usn": .int(row[3].int),
                "maxTaken": .int(Int64(c.uint(24))),
                "autoplay": .bool(!c.bool(23)),
                "timer": .int(c.bool(25) ? 1 : 0),
                "replayq": .bool(!c.bool(26)),
                "new": newConf,
                "rev": revConf,
                "lapse": lapseConf,
                "dyn": false,
                "newMix": .int(Int64(c.int32(30))),
                "newPerDayMinimum": .int(Int64(c.uint(35))),
                "interdayLearningMix": .int(Int64(c.int32(31))),
                "reviewOrder": .int(Int64(c.int32(33))),
                "newSortOrder": .int(Int64(c.int32(32))),
                "newGatherPriority": .int(Int64(c.int32(34))),
                "buryInterdayLearning": .bool(c.bool(29)),
                "fsrsWeights": floats(c.floats(3)),
                "fsrsParams5": floats(c.floats(5)),
                "fsrsParams6": floats(c.floats(6)),
                "desiredRetention": float(c.float(37)),
                "sm2Retention": float(c.float(40)),
                "weightSearch": .string(c.string(45)),
                "ignoreRevlogsBeforeDate": .string(c.string(46)),
                "easyDaysPercentages": floats(c.floats(4)),
                "stopTimerOnAnswer": .bool(c.bool(38)),
                "secondsToShowQuestion": float(c.float(41)),
                "secondsToShowAnswer": float(c.float(42)),
                "questionAction": .int(c.uint(36) == 1 ? 1 : 0),
                "answerAction": .int(answerAction <= 4 ? Int64(answerAction) : 0),
                "waitForAudio": .bool(c.bool(44)),
            ]
            out[String(id)] = merge(base, top)
        }
        return .object(out)
    }

    // MARK: Config and tags

    private static func config(_ db: Database) throws -> JSON {
        var out: [String: JSON] = [:]
        for row in try db.query("select key, val from config") {
            out[row[0].text] = (try? JSON.parse(row[1].blob)) ?? .null
        }
        return .object(out)
    }

    private static func tags(_ db: Database) throws -> JSON {
        var out: [String: JSON] = [:]
        for row in try db.query("select tag, usn from tags") {
            out[row[0].text] = .int(row[1].int)
        }
        return .object(out)
    }
}

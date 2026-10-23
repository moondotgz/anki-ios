import Foundation

enum CardType {
    static let new = 0
    static let learn = 1
    static let review = 2
    static let relearn = 3
}

enum CardQueue {
    static let userBuried = -2
    static let schedBuried = -3
    static let suspended = -1
    static let new = 0
    static let learn = 1
    static let review = 2
    static let dayLearn = 3
    static let preview = 4
}

enum GraveType {
    static let card = 0
    static let note = 1
    static let deck = 2
}

enum Time {
    static var nowSecs: Int64 { Int64(Date().timeIntervalSince1970) }
    static var nowMillis: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

struct Card: Identifiable, Equatable {
    var id: Int64
    var nid: Int64
    var did: Int64
    var ord: Int
    var mod: Int64
    var usn: Int
    var type: Int
    var queue: Int
    var due: Int64
    var ivl: Int
    var factor: Int
    var reps: Int
    var lapses: Int
    var left: Int
    var odue: Int64
    var odid: Int64
    var flags: Int
    var data: String

    static let columns = "id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data"

    init(row r: SQLRow) {
        id = r[0].int; nid = r[1].int; did = r[2].int; ord = Int(r[3].int)
        mod = r[4].int; usn = Int(r[5].int); type = Int(r[6].int); queue = Int(r[7].int)
        due = r[8].int; ivl = Int(r[9].int); factor = Int(r[10].int); reps = Int(r[11].int)
        lapses = Int(r[12].int); left = Int(r[13].int); odue = r[14].int; odid = r[15].int
        flags = Int(r[16].int); data = r[17].text
    }

    init(id: Int64, nid: Int64, did: Int64, ord: Int, due: Int64) {
        self.id = id; self.nid = nid; self.did = did; self.ord = ord
        mod = Time.nowSecs; usn = -1; type = CardType.new; queue = CardQueue.new
        self.due = due; ivl = 0; factor = 0; reps = 0; lapses = 0; left = 0
        odue = 0; odid = 0; flags = 0; data = "{}"
    }

    var params: [SQLBindable?] {
        [id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data]
    }

    /// JSON-encoded extra card data (`pos`, FSRS memory state, `lrt`, `cd`).
    var dataJSON: JSON {
        get { JSON.parseOr(data, [:]) }
        set {
            if let obj = newValue.object, !obj.isEmpty {
                data = newValue.serialized()
            } else {
                data = "{}"
            }
        }
    }

    /// Sync wire format: a JSON array in column order.
    var syncJSON: JSON {
        [.int(id), .int(nid), .int(did), JSON(ord), .int(mod), JSON(usn), JSON(type), JSON(queue),
         .int(due), JSON(ivl), JSON(factor), JSON(reps), JSON(lapses), JSON(left), .int(odue), .int(odid),
         JSON(flags), .string(data)]
    }

    init?(syncJSON a: JSON) {
        guard let arr = a.array, arr.count >= 18 else { return nil }
        id = arr[0].int(or: 0); nid = arr[1].int(or: 0); did = arr[2].int(or: 0); ord = arr[3].intValue
        mod = arr[4].int(or: 0); usn = arr[5].intValue; type = arr[6].intValue; queue = arr[7].intValue
        due = arr[8].int(or: 0); ivl = arr[9].intValue; factor = arr[10].intValue; reps = arr[11].intValue
        lapses = arr[12].intValue; left = arr[13].intValue; odue = arr[14].int(or: 0); odid = arr[15].int(or: 0)
        flags = arr[16].intValue; data = arr[17].string(or: "")
    }

    var flag: Int { flags & 0b111 }
}

struct Note: Identifiable, Equatable {
    var id: Int64
    var guid: String
    var mid: Int64
    var mod: Int64
    var usn: Int
    var tags: [String]
    var fields: [String]
    var flags: Int
    var data: String

    static let columns = "id, guid, mid, mod, usn, tags, flds, flags, data"

    init(row r: SQLRow) {
        id = r[0].int; guid = r[1].text; mid = r[2].int; mod = r[3].int; usn = Int(r[4].int)
        tags = Note.splitTags(r[5].text)
        fields = r[6].text.components(separatedBy: "\u{1f}")
        flags = Int(r[7].int); data = r[8].text
    }

    init(id: Int64, mid: Int64, fieldCount: Int) {
        self.id = id
        guid = Note.newGUID()
        self.mid = mid
        mod = Time.nowSecs
        usn = -1
        tags = []
        fields = Array(repeating: "", count: max(1, fieldCount))
        flags = 0
        data = ""
    }

    var joinedFields: String { fields.joined(separator: "\u{1f}") }
    var joinedTags: String { tags.isEmpty ? "" : " \(tags.joined(separator: " ")) " }

    static func splitTags(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    var syncJSON: JSON {
        [.int(id), .string(guid), .int(mid), .int(mod), JSON(usn), .string(joinedTags), .string(joinedFields),
         "", "", JSON(flags), .string(data)]
    }

    init?(syncJSON a: JSON) {
        guard let arr = a.array, arr.count >= 11 else { return nil }
        id = arr[0].int(or: 0); guid = arr[1].string(or: ""); mid = arr[2].int(or: 0)
        mod = arr[3].int(or: 0); usn = arr[4].intValue
        tags = Note.splitTags(arr[5].string(or: ""))
        fields = arr[6].string(or: "").components(separatedBy: "\u{1f}")
        flags = arr[9].intValue; data = arr[10].string(or: "")
    }

    static func newGUID() -> String {
        let table = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        var n = UInt64.random(in: 1...UInt64.max)
        var out: [Character] = []
        while n > 0 {
            out.append(table[Int(n % UInt64(table.count))])
            n /= UInt64(table.count)
        }
        return String(out.reversed())
    }

    func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

struct RevlogEntry: Equatable {
    var id: Int64
    var cid: Int64
    var usn: Int
    var ease: Int
    var ivl: Int
    var lastIvl: Int
    var factor: Int
    var time: Int
    var type: Int

    static let columns = "id, cid, usn, ease, ivl, lastIvl, factor, time, type"

    init(id: Int64, cid: Int64, usn: Int, ease: Int, ivl: Int, lastIvl: Int, factor: Int, time: Int, type: Int) {
        self.id = id; self.cid = cid; self.usn = usn; self.ease = ease; self.ivl = ivl
        self.lastIvl = lastIvl; self.factor = factor; self.time = time; self.type = type
    }

    init(row r: SQLRow) {
        id = r[0].int; cid = r[1].int; usn = Int(r[2].int); ease = Int(r[3].int); ivl = Int(r[4].int)
        lastIvl = Int(r[5].int); factor = Int(r[6].int); time = Int(r[7].int); type = Int(r[8].int)
    }

    var params: [SQLBindable?] { [id, cid, usn, ease, ivl, lastIvl, factor, time, type] }

    var syncJSON: JSON {
        [.int(id), .int(cid), JSON(usn), JSON(ease), JSON(ivl), JSON(lastIvl), JSON(factor), JSON(time), JSON(type)]
    }

    init?(syncJSON a: JSON) {
        guard let arr = a.array, arr.count >= 9 else { return nil }
        id = arr[0].int(or: 0); cid = arr[1].int(or: 0); usn = arr[2].intValue; ease = arr[3].intValue
        ivl = arr[4].intValue; lastIvl = arr[5].intValue; factor = arr[6].intValue; time = arr[7].intValue
        type = arr[8].intValue
    }
}

// MARK: - Notetype

/// A view over a schema 11 notetype JSON object.
struct Notetype: Identifiable, Hashable {
    var json: JSON

    var id: Int64 { json["id"].int(or: 0) }
    var name: String {
        get { json["name"].string(or: "") }
        set { json["name"] = .string(newValue) }
    }
    var isCloze: Bool { json["type"].int(or: 0) == 1 }
    var css: String {
        get { json["css"].string(or: "") }
        set { json["css"] = .string(newValue) }
    }
    var sortIndex: Int { json["sortf"].intValue }
    var mod: Int64 { json["mod"].int(or: 0) }

    var fields: [JSON] { json["flds"].array ?? [] }
    var templates: [JSON] { json["tmpls"].array ?? [] }
    var fieldNames: [String] { fields.map { $0["name"].string(or: "") } }
    var templateNames: [String] { templates.map { $0["name"].string(or: "") } }

    func fieldIndex(_ name: String) -> Int? {
        fieldNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    mutating func setTemplate(_ index: Int, qfmt: String, afmt: String) {
        guard var tmpls = json["tmpls"].array, index < tmpls.count else { return }
        tmpls[index]["qfmt"] = .string(qfmt)
        tmpls[index]["afmt"] = .string(afmt)
        json["tmpls"] = .array(tmpls)
    }
}

// MARK: - Deck

struct Deck: Identifiable, Hashable {
    var json: JSON

    var id: Int64 { json["id"].int(or: 0) }
    var name: String {
        get { json["name"].string(or: "") }
        set { json["name"] = .string(newValue) }
    }
    var isFiltered: Bool { json["dyn"].bool(or: false) }
    var configID: Int64 { json["conf"].int(or: 1) }
    var description: String { json["desc"].string(or: "") }
    var components: [String] { name.components(separatedBy: "::") }
    var baseName: String { components.last ?? name }
    var depth: Int { components.count - 1 }
    var parentName: String? {
        let c = components
        return c.count > 1 ? c.dropLast().joined(separator: "::") : nil
    }
    var collapsed: Bool { json["collapsed"].bool(or: false) }

    /// Studied counts are stored as `[day, amount]` pairs.
    func today(_ key: String, day: Int) -> Int {
        let pair = json[key]
        return pair[0].intValue == day ? pair[1].intValue : 0
    }
}

// MARK: - Deck options

/// Typed view of the parts of a deck options group the scheduler uses.
struct DeckConfig: Identifiable {
    var json: JSON

    var id: Int64 { json["id"].int(or: 1) }
    var name: String { json["name"].string(or: "Default") }

    var learnSteps: [Double] { json["new"]["delays"].doubleArray }
    var relearnSteps: [Double] { json["lapse"]["delays"].doubleArray }
    var newPerDay: Int { json["new"]["perDay"].intValue }
    var reviewsPerDay: Int { json["rev"]["perDay"].intValue }
    var graduatingGood: Int { json["new"]["ints"][0].int.map(Int.init) ?? 1 }
    var graduatingEasy: Int { json["new"]["ints"][1].int.map(Int.init) ?? 4 }
    var initialEase: Double { Double(json["new"]["initialFactor"].int(or: 2500)) / 1000 }
    var easyMultiplier: Double { json["rev"]["ease4"].double(or: 1.3) }
    var hardMultiplier: Double { json["rev"]["hardFactor"].double(or: 1.2) }
    var intervalMultiplier: Double { json["rev"]["ivlFct"].double(or: 1.0) }
    var maximumInterval: Int { Int(json["rev"]["maxIvl"].int(or: 36500)) }
    var lapseMultiplier: Double { json["lapse"]["mult"].double(or: 0) }
    var minimumLapseInterval: Int { Int(json["lapse"]["minInt"].int(or: 1)) }
    var leechThreshold: Int { Int(json["lapse"]["leechFails"].int(or: 8)) }
    var leechSuspends: Bool { json["lapse"]["leechAction"].int(or: 1) == 0 }
    var buryNew: Bool { json["new"]["bury"].bool(or: false) }
    var buryReviews: Bool { json["rev"]["bury"].bool(or: false) }
    var buryInterdayLearning: Bool { json["buryInterdayLearning"].bool(or: false) }
    var maxAnswerSecs: Int { Int(json["maxTaken"].int(or: 60)) }
    var autoplay: Bool { json["autoplay"].bool(or: true) }
    var showTimer: Bool { json["timer"].int(or: 0) != 0 }
    var newInsertRandom: Bool { json["new"]["order"].int(or: 1) == 0 }
}

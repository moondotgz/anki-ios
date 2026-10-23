import Foundation

enum CollectionError: Error, LocalizedError {
    case invalid(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        case .notFound(let m): return "Not found: \(m)"
        }
    }
}

/// An Anki collection stored in the schema 11 SQLite format, which every
/// Anki client and AnkiWeb can read. Notetypes, decks, deck options,
/// config and tags live as JSON in the `col` table.
final class Collection {
    let db: Database
    let url: URL
    let mediaFolder: URL

    private(set) var crt: Int64 = 0
    private(set) var mod: Int64 = 0
    private(set) var scm: Int64 = 0
    private(set) var usn: Int = 0
    private(set) var ls: Int64 = 0

    var conf: JSON = [:]
    var models: [Int64: JSON] = [:]
    var decks: [Int64: JSON] = [:]
    var dconf: [Int64: JSON] = [:]
    var tags: [String: Int] = [:]

    // MARK: Opening

    static let schema11 = """
        CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null,
          ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null,
          models text not null, decks text not null, dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null,
          usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null,
          flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null,
          mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null,
          ivl integer not null, factor integer not null, reps integer not null, lapses integer not null,
          left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null,
          ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn ON notes (usn);
        CREATE INDEX ix_cards_usn ON cards (usn);
        CREATE INDEX ix_revlog_usn ON revlog (usn);
        CREATE INDEX ix_cards_nid ON cards (nid);
        CREATE INDEX ix_cards_sched ON cards (did, queue, due);
        CREATE INDEX ix_revlog_cid ON revlog (cid);
        CREATE INDEX ix_notes_csum ON notes (csum);
        INSERT INTO col VALUES (1, 0, 0, 0, 11, 0, 0, 0, '{}', '{}', '{}', '{}', '{}');
        """

    init(url: URL, mediaFolder: URL) throws {
        self.url = url
        self.mediaFolder = mediaFolder
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: url.path)
        db = try Database(path: url.path)
        try db.executeBatch("pragma journal_mode = delete; pragma foreign_keys = off;")
        let hasCol = try db.int("select count() from sqlite_master where name = 'col'") > 0
        if !exists || !hasCol {
            try Collection.initialize(db: db)
        }
        let ver = try db.int("select ver from col")
        guard ver == 11 else {
            throw CollectionError.invalid("Unsupported collection version \(ver)")
        }
        try reload()
    }

    /// Writes an empty schema 11 collection with the stock notetypes.
    static func initialize(db: Database) throws {
        try db.transaction {
            try db.executeBatch(schema11)
            let now = Time.nowSecs
            let crt = Scheduler.v1CreationDate(now: now)
            let offset = -TimeZone.current.secondsFromGMT() / 60
            var models: [String: JSON] = [:]
            let baseID = Time.nowMillis
            for nt in Defaults.stockNotetypes(startID: baseID) {
                var nt = nt
                nt["usn"] = 0
                models[String(nt["id"].int(or: 0))] = nt
            }
            var conf = Defaults.conf(creationOffset: offset)
            conf["curModel"] = .int(baseID)
            var deck = Defaults.deck(id: 1, name: "Default")
            deck["usn"] = 0
            var dc = Defaults.deckConfig(id: 1, name: "Default")
            dc["usn"] = 0
            try db.execute(
                "update col set crt=?, mod=?, scm=?, ver=11, dty=0, usn=0, ls=0, conf=?, models=?, decks=?, dconf=?, tags=?",
                crt, Time.nowMillis, Time.nowMillis, conf.serialized(), JSON.object(models).serialized(),
                JSON.object(["1": deck]).serialized(), JSON.object(["1": dc]).serialized(), "{}")
        }
    }

    func reload() throws {
        guard let row = try db.first("select crt, mod, scm, usn, ls, conf, models, decks, dconf, tags from col") else {
            throw CollectionError.invalid("Collection is missing its col row")
        }
        crt = row[0].int
        mod = row[1].int
        scm = row[2].int
        usn = Int(row[3].int)
        ls = row[4].int
        conf = JSON.parseOr(row[5].text, [:])
        models = Collection.idMap(row[6].text)
        decks = Collection.idMap(row[7].text)
        dconf = Collection.idMap(row[8].text)
        tags = [:]
        for (k, v) in JSON.parseOr(row[9].text, [:]).object ?? [:] { tags[k] = v.intValue }
        if decks[1] == nil {
            decks[1] = Defaults.deck(id: 1, name: "Default")
        }
        if dconf[1] == nil {
            dconf[1] = Defaults.deckConfig(id: 1, name: "Default")
        }
    }

    private static func idMap(_ text: String) -> [Int64: JSON] {
        var out: [Int64: JSON] = [:]
        for (k, v) in JSON.parseOr(text, [:]).object ?? [:] {
            if let id = Int64(k) ?? v["id"].int { out[id] = v }
        }
        return out
    }

    private static func encode(_ map: [Int64: JSON]) -> String {
        var obj: [String: JSON] = [:]
        for (k, v) in map { obj[String(k)] = v }
        return JSON.object(obj).serialized()
    }

    /// Persists the JSON objects in the col row. `modified` updates the
    /// collection modification time, which signals the change to sync.
    func save(modified: Bool = true) throws {
        if modified { mod = max(Time.nowMillis, mod + 1) }
        var tagObj: [String: JSON] = [:]
        for (k, v) in tags { tagObj[k] = JSON(v) }
        try db.execute(
            "update col set mod=?, conf=?, models=?, decks=?, dconf=?, tags=?",
            mod, conf.serialized(), Collection.encode(models), Collection.encode(decks),
            Collection.encode(dconf), JSON.object(tagObj).serialized())
    }

    func setModified() throws {
        mod = max(Time.nowMillis, mod + 1)
        try db.execute("update col set mod=?", mod)
    }

    func setSchemaModified() throws {
        scm = Time.nowMillis
        try db.execute("update col set scm=?", scm)
    }

    func setSyncState(usn: Int, mod: Int64, ls: Int64) throws {
        self.usn = usn
        self.mod = mod
        self.ls = ls
        try db.execute("update col set usn=?, mod=?, ls=?", usn, mod, ls)
    }

    func setCreationStamp(_ value: Int64) throws {
        crt = value
        try db.execute("update col set crt=?", value)
    }

    func setUSN(_ value: Int) throws {
        usn = value
        try db.execute("update col set usn=?", value)
    }

    func setLastSync(_ value: Int64) throws {
        ls = value
        try db.execute("update col set ls=?", value)
    }

    func close() { db.close() }

    var needsFullSync: Bool { scm > ls }
    var hasUnsyncedChanges: Bool { mod > ls }

    // MARK: ID allocation

    private var lastAllocated: Int64 = 0

    /// Millisecond timestamp ids, unique within `table`.
    func newID(table: String) throws -> Int64 {
        var id = max(Time.nowMillis, lastAllocated + 1)
        while try db.int("select count() from \(table) where id = ?", id) > 0 { id += 1 }
        lastAllocated = id
        return id
    }

    // MARK: Config

    func config(_ key: String) -> JSON { conf[key] }

    func setConfig(_ key: String, _ value: JSON) throws {
        conf[key] = value
        try save()
    }

    var currentDeckID: Int64 {
        get { conf["curDeck"].int(or: 1) }
        set { conf["curDeck"] = .int(newValue) }
    }

    var learnAheadSecs: Int64 { conf["collapseTime"].int(or: 1200) }

    var rolloverHour: Int {
        get { Int(conf["rollover"].int(or: 4)) }
        set { conf["rollover"] = JSON(newValue) }
    }

    // MARK: Notetypes

    var notetypes: [Notetype] {
        models.values.map { Notetype(json: $0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func notetype(_ id: Int64) -> Notetype? { models[id].map(Notetype.init) }

    func notetype(named name: String) -> Notetype? { notetypes.first { $0.name == name } }

    /// Saves changes to an existing notetype that do not alter its fields or
    /// templates count (those changes need a full sync).
    func updateNotetype(_ nt: Notetype) throws {
        var json = nt.json
        json["mod"] = .int(Time.nowSecs)
        json["usn"] = -1
        models[nt.id] = json
        try save()
    }

    func addNotetype(_ json: JSON) throws -> Int64 {
        var json = json
        var id = json["id"].int(or: 0)
        if id == 0 || models[id] != nil { id = Time.nowMillis }
        while models[id] != nil { id += 1 }
        json["id"] = .int(id)
        json["mod"] = .int(Time.nowSecs)
        json["usn"] = -1
        var name = json["name"].string(or: "Notetype")
        let names = Set(models.values.map { $0["name"].string(or: "") })
        if names.contains(name) {
            var n = 2
            while names.contains("\(name)-\(n)") { n += 1 }
            name = "\(name)-\(n)"
            json["name"] = .string(name)
        }
        models[id] = json
        try save()
        return id
    }

    // MARK: Decks

    var allDecks: [Deck] {
        decks.values.map(Deck.init).sorted { Collection.deckNameLess($0.name, $1.name) }
    }

    static func deckNameLess(_ a: String, _ b: String) -> Bool {
        let ac = a.components(separatedBy: "::"), bc = b.components(separatedBy: "::")
        for (x, y) in zip(ac, bc) {
            let r = x.localizedCaseInsensitiveCompare(y)
            if r != .orderedSame { return r == .orderedAscending }
        }
        return ac.count < bc.count
    }

    func deck(_ id: Int64) -> Deck? { decks[id].map(Deck.init) }

    func deck(named name: String) -> Deck? {
        decks.values.first { $0["name"].string(or: "").caseInsensitiveCompare(name) == .orderedSame }.map(Deck.init)
    }

    func childDecks(of id: Int64) -> [Deck] {
        guard let parent = deck(id) else { return [] }
        let prefix = parent.name + "::"
        return allDecks.filter { $0.name.hasPrefix(prefix) }
    }

    /// The deck plus all its descendants.
    func deckTreeIDs(_ id: Int64) -> [Int64] {
        [id] + childDecks(of: id).map(\.id)
    }

    func parents(of deck: Deck) -> [Deck] {
        var out: [Deck] = []
        var comps = deck.components
        while comps.count > 1 {
            comps.removeLast()
            if let d = self.deck(named: comps.joined(separator: "::")) { out.append(d) }
        }
        return out
    }

    /// Returns the id of the deck with `name`, creating it and any missing
    /// parents.
    @discardableResult
    func addDeck(named rawName: String) throws -> Int64 {
        let name = Collection.normalizeDeckName(rawName)
        if let existing = deck(named: name) { return existing.id }
        let comps = name.components(separatedBy: "::")
        if comps.count > 1 {
            try addDeck(named: comps.dropLast().joined(separator: "::"))
        }
        var id = Time.nowMillis
        while decks[id] != nil { id += 1 }
        decks[id] = Defaults.deck(id: id, name: name)
        try save()
        return id
    }

    static func normalizeDeckName(_ name: String) -> String {
        name.components(separatedBy: "::")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "::")
    }

    func updateDeck(_ deck: Deck) throws {
        var json = deck.json
        json["mod"] = .int(Time.nowSecs)
        json["usn"] = -1
        decks[deck.id] = json
        try save()
    }

    func renameDeck(_ id: Int64, to newName: String) throws {
        guard let d = deck(id) else { return }
        let name = Collection.normalizeDeckName(newName)
        guard !name.isEmpty, deck(named: name) == nil else {
            throw CollectionError.invalid("A deck named “\(name)” already exists.")
        }
        let oldPrefix = d.name + "::"
        let children = childDecks(of: id)
        var renamed = d
        renamed.name = name
        try updateDeck(renamed)
        for var child in children {
            child.name = name + "::" + child.name.dropFirst(oldPrefix.count)
            try updateDeck(child)
        }
        if let parent = Deck(json: decks[id]!).parentName { try addDeck(named: parent) }
    }

    /// Deletes a deck, its children, and all cards in them.
    func removeDeck(_ id: Int64) throws {
        guard id != 1 else { throw CollectionError.invalid("The default deck can't be deleted.") }
        let ids = deckTreeIDs(id)
        try db.transaction {
            let list = ids.map(String.init).joined(separator: ",")
            let cids = try db.query("select id from cards where did in (\(list)) or odid in (\(list))").map { $0[0].int }
            try removeCards(cids)
            for did in ids {
                decks.removeValue(forKey: did)
                try addGrave(did, type: GraveType.deck)
            }
            if ids.contains(currentDeckID) { currentDeckID = 1 }
            try save()
        }
    }

    // MARK: Deck options

    func deckConfig(_ id: Int64) -> DeckConfig {
        DeckConfig(json: dconf[id] ?? dconf[1] ?? Defaults.deckConfig(id: 1, name: "Default"))
    }

    func config(forDeck did: Int64) -> DeckConfig {
        guard let d = deck(did) else { return deckConfig(1) }
        if d.isFiltered {
            return deckConfig(1)
        }
        return deckConfig(d.configID)
    }

    var allDeckConfigs: [DeckConfig] {
        dconf.values.map(DeckConfig.init).sorted { $0.id < $1.id }
    }

    func updateDeckConfig(_ json: JSON) throws {
        var json = json
        json["mod"] = .int(Time.nowSecs)
        json["usn"] = -1
        dconf[json["id"].int(or: 1)] = json
        try save()
    }

    func addDeckConfig(named name: String, cloning source: JSON? = nil) throws -> Int64 {
        var id = Time.nowMillis
        while dconf[id] != nil { id += 1 }
        var json = source ?? Defaults.deckConfig(id: id, name: name)
        json["id"] = .int(id)
        json["name"] = .string(name)
        try updateDeckConfig(json)
        return id
    }

    // MARK: Tags

    func registerTags(_ list: [String]) {
        for tag in list where !tag.isEmpty {
            if !tags.keys.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags[tag] = -1
            }
        }
    }

    var allTags: [String] { tags.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }

    // MARK: Graves

    func addGrave(_ oid: Int64, type: Int, usn: Int = -1) throws {
        try db.execute("insert into graves (usn, oid, type) values (?, ?, ?)", usn, oid, type)
    }

    // MARK: Notes

    func note(_ id: Int64) throws -> Note? {
        try db.first("select \(Note.columns) from notes where id = ?", id).map(Note.init(row:))
    }

    func note(guid: String) throws -> Note? {
        try db.first("select \(Note.columns) from notes where guid = ?", guid).map(Note.init(row:))
    }

    /// Writes a note, updating its sort field and checksum.
    func writeNote(_ note: Note) throws {
        let nt = notetype(note.mid)
        let sortIdx = min(nt?.sortIndex ?? 0, max(0, note.fields.count - 1))
        let first = HTML.stripPreservingMediaFilenames(note.fields.first ?? "")
        let sortField = sortIdx == 0 ? first : HTML.stripPreservingMediaFilenames(note.fields[sortIdx])
        let csum = Collection.fieldChecksum(first)
        let sfld: SQLBindable = Int64(sortField).map { $0 as SQLBindable } ?? sortField
        try db.execute(
            "insert or replace into notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) values (?,?,?,?,?,?,?,?,?,?,?)",
            note.id, note.guid, note.mid, note.mod, note.usn, note.joinedTags, note.joinedFields,
            sfld, csum, note.flags, note.data)
    }

    static func fieldChecksum(_ text: String) -> Int64 {
        let digest = SHA1.hash(Data(text.utf8))
        return Int64(UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3]))
    }

    /// Adds a new note and generates its cards. Returns the number of cards.
    @discardableResult
    func addNote(_ note: inout Note, deckID: Int64) throws -> Int {
        guard let nt = notetype(note.mid) else { throw CollectionError.notFound("notetype") }
        let ords = CardGenerator.ordinalsToGenerate(note: note, notetype: nt)
        guard !ords.isEmpty else {
            throw CollectionError.invalid(nt.isCloze
                ? "No cloze deletions found. Use {{c1::text}} to make one."
                : "The front of this card would be empty.")
        }
        return try db.transaction {
            note.id = try newID(table: "notes")
            note.mod = Time.nowSecs
            note.usn = -1
            registerTags(note.tags)
            try writeNote(note)
            for ord in ords {
                let did = templateDeck(nt, ord: ord) ?? deckID
                try addCard(nid: note.id, did: did, ord: ord)
            }
            conf["curModel"] = .int(nt.id)
            try save()
            return ords.count
        }
    }

    private func templateDeck(_ nt: Notetype, ord: Int) -> Int64? {
        guard !nt.isCloze, ord < nt.templates.count else { return nil }
        let did = nt.templates[ord]["did"].int(or: 0)
        if did > 0, let d = deck(did), !d.isFiltered { return did }
        return nil
    }

    private func addCard(nid: Int64, did: Int64, ord: Int) throws {
        let pos = conf["nextPos"].int(or: 1)
        let id = try newID(table: "cards")
        let card = Card(id: id, nid: nid, did: did, ord: ord, due: pos)
        try writeCard(card)
        conf["nextPos"] = .int(pos + 1)
    }

    /// Saves edits to an existing note and adds any newly required cards.
    func updateNote(_ note: Note) throws {
        guard let nt = notetype(note.mid) else { throw CollectionError.notFound("notetype") }
        try db.transaction {
            var note = note
            note.mod = Time.nowSecs
            note.usn = -1
            registerTags(note.tags)
            try writeNote(note)
            let existing = Set(try db.query("select ord from cards where nid = ?", note.id).map { Int($0[0].int) })
            let wanted = CardGenerator.ordinalsToGenerate(note: note, notetype: nt)
            let did = try db.first("select did, odid from cards where nid = ? limit 1", note.id)
                .map { $0[1].int != 0 ? $0[1].int : $0[0].int } ?? currentDeckID
            for ord in wanted where !existing.contains(ord) {
                try addCard(nid: note.id, did: templateDeck(nt, ord: ord) ?? did, ord: ord)
            }
            try save()
        }
    }

    func removeNotes(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for nid in ids {
                let cids = try db.query("select id from cards where nid = ?", nid).map { $0[0].int }
                for cid in cids {
                    try db.execute("delete from cards where id = ?", cid)
                    try addGrave(cid, type: GraveType.card)
                }
                try db.execute("delete from notes where id = ?", nid)
                try addGrave(nid, type: GraveType.note)
            }
            try setModified()
        }
    }

    // MARK: Cards

    func card(_ id: Int64) throws -> Card? {
        try db.first("select \(Card.columns) from cards where id = ?", id).map(Card.init(row:))
    }

    func cards(ofNote nid: Int64) throws -> [Card] {
        try db.query("select \(Card.columns) from cards where nid = ? order by ord", nid).map(Card.init(row:))
    }

    func writeCard(_ card: Card) throws {
        try db.execute(
            "insert or replace into cards (\(Card.columns)) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            params: card.params)
    }

    /// Marks a card as locally modified and saves it.
    func updateCard(_ card: Card) throws {
        var card = card
        card.mod = Time.nowSecs
        card.usn = -1
        try writeCard(card)
        try setModified()
    }

    /// Removes cards, and notes left without cards.
    func removeCards(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            var nids = Set<Int64>()
            for cid in ids {
                if let nid = try db.first("select nid from cards where id = ?", cid)?[0].int { nids.insert(nid) }
                try db.execute("delete from cards where id = ?", cid)
                try addGrave(cid, type: GraveType.card)
            }
            for nid in nids {
                guard try db.int("select count() from cards where nid = ?", nid) == 0 else { continue }
                try db.execute("delete from notes where id = ?", nid)
                try addGrave(nid, type: GraveType.note)
            }
            try setModified()
        }
    }

    func setDeck(cardIDs: [Int64], deckID: Int64) throws {
        try db.transaction {
            for cid in cardIDs {
                guard var c = try card(cid) else { continue }
                if c.odid != 0 { c.odid = deckID } else { c.did = deckID }
                try updateCard(c)
            }
        }
    }

    func suspend(cardIDs: [Int64], _ suspend: Bool) throws {
        try db.transaction {
            for cid in cardIDs {
                guard var c = try card(cid) else { continue }
                if suspend {
                    c.queue = CardQueue.suspended
                } else if c.queue == CardQueue.suspended {
                    c.queue = Collection.restoredQueue(for: c)
                }
                try updateCard(c)
            }
        }
    }

    func bury(cardIDs: [Int64]) throws {
        try db.transaction {
            for cid in cardIDs {
                guard var c = try card(cid) else { continue }
                c.queue = CardQueue.userBuried
                try updateCard(c)
            }
        }
    }

    func setFlag(cardIDs: [Int64], flag: Int) throws {
        try db.transaction {
            for cid in cardIDs {
                guard var c = try card(cid) else { continue }
                c.flags = (c.flags & ~0b111) | (flag & 0b111)
                try updateCard(c)
            }
        }
    }

    /// Forgets cards, returning them to the end of the new queue.
    func forget(cardIDs: [Int64]) throws {
        try db.transaction {
            for cid in cardIDs {
                guard var c = try card(cid) else { continue }
                let pos = conf["nextPos"].int(or: 1)
                conf["nextPos"] = .int(pos + 1)
                c.type = CardType.new
                c.queue = CardQueue.new
                c.due = pos
                c.ivl = 0
                c.factor = 0
                c.left = 0
                c.reps = 0
                c.lapses = 0
                c.odue = 0
                c.odid = 0
                var data = c.dataJSON
                for key in ["s", "d", "dr", "decay", "lrt", "pos"] { data[key] = .null }
                if var obj = data.object {
                    obj = obj.filter { !$0.value.isNull }
                    c.dataJSON = .object(obj)
                }
                try updateCard(c)
            }
            try save()
        }
    }

    static func restoredQueue(for c: Card) -> Int {
        switch c.type {
        case CardType.learn, CardType.relearn:
            return c.due > 1_000_000_000 ? CardQueue.learn : CardQueue.dayLearn
        default:
            return c.type
        }
    }

    func addTags(noteIDs: [Int64], tags newTags: [String]) throws {
        try db.transaction {
            for nid in noteIDs {
                guard var n = try note(nid) else { continue }
                for t in newTags where !n.hasTag(t) { n.tags.append(t) }
                n.mod = Time.nowSecs
                n.usn = -1
                try writeNote(n)
            }
            registerTags(newTags)
            try save()
        }
    }

    // MARK: Revlog

    func addRevlog(_ entry: RevlogEntry) throws {
        var entry = entry
        while try db.int("select count() from revlog where id = ?", entry.id) > 0 { entry.id += 1 }
        try db.execute("insert into revlog (\(RevlogEntry.columns)) values (?,?,?,?,?,?,?,?,?)", params: entry.params)
    }

    // MARK: Counts

    var cardCount: Int { (try? Int(db.int("select count() from cards"))) ?? 0 }
    var noteCount: Int { (try? Int(db.int("select count() from notes"))) ?? 0 }
    var isEmpty: Bool { ((try? db.int("select exists(select 1 from cards)")) ?? 0) == 0 }
}

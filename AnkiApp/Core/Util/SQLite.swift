import Foundation
import SQLite3

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    var int: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    var double: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s) ?? 0
        default: return 0
        }
    }

    var text: String {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .blob(let d): return String(decoding: d, as: UTF8.self)
        case .null: return ""
        }
    }

    var blob: Data {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return Data()
        }
    }

    var isNull: Bool { self == .null }
}

protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Int32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }

struct SQLiteError: Error, LocalizedError {
    let code: Int32
    let message: String
    var errorDescription: String? { "Database error \(code): \(message)" }
}

typealias SQLRow = [SQLValue]

/// Minimal wrapper around the system SQLite library.
final class Database {
    private(set) var handle: OpaquePointer?
    let path: String
    private var statementCache: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try registerFunctions()
    }

    deinit { close() }

    func close() {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        statementCache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    /// Runs one or more statements without parameters.
    func executeBatch(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errmsg)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        statementCache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLBindable?]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p?.sqlValue ?? .null {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, Database.transient)
            case .blob(let d):
                rc = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(d.count), Database.transient)
                }
            }
            if rc != SQLITE_OK { throw error(rc) }
        }
    }

    private func column(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, i) else { return .text("") }
            let len = Int(sqlite3_column_bytes(stmt, i))
            return .text(String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self))
        case SQLITE_BLOB:
            let len = Int(sqlite3_column_bytes(stmt, i))
            guard len > 0, let ptr = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: ptr, count: len))
        default: return .null
        }
    }

    @discardableResult
    func execute(_ sql: String, _ params: SQLBindable?...) throws -> Int {
        try execute(sql, params: params)
    }

    @discardableResult
    func execute(_ sql: String, params: [SQLBindable?]) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: SQLBindable?...) throws -> [SQLRow] {
        try query(sql, params: params)
    }

    func query(_ sql: String, params: [SQLBindable?]) throws -> [SQLRow] {
        var rows: [SQLRow] = []
        try forEach(sql, params: params) { rows.append($0) }
        return rows
    }

    func forEach(_ sql: String, params: [SQLBindable?] = [], _ body: (SQLRow) throws -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params)
        let count = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var row: SQLRow = []
            row.reserveCapacity(Int(count))
            for i in 0..<count { row.append(column(stmt, i)) }
            try body(row)
        }
    }

    func first(_ sql: String, _ params: SQLBindable?...) throws -> SQLRow? {
        try first(sql, params: params)
    }

    func first(_ sql: String, params: [SQLBindable?]) throws -> SQLRow? {
        var result: SQLRow?
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            result = (0..<count).map { column(stmt, $0) }
        } else if rc != SQLITE_DONE {
            throw error(rc)
        }
        return result
    }

    func scalar(_ sql: String, _ params: SQLBindable?...) throws -> SQLValue {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return column(stmt, 0) }
        if rc != SQLITE_DONE { throw error(rc) }
        return .null
    }

    func int(_ sql: String, params: [SQLBindable?]) throws -> Int64 {
        try first(sql, params: params)?.first?.int ?? 0
    }

    func int(_ sql: String, _ params: SQLBindable?...) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return column(stmt, 0).int }
        if rc != SQLITE_DONE { throw error(rc) }
        return 0
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: Transactions

    var inTransaction: Bool { transactionDepth > 0 }

    func begin() throws {
        if transactionDepth == 0 { try executeBatch("begin immediate") }
        transactionDepth += 1
    }

    func commit() throws {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        if transactionDepth == 0 { try executeBatch("commit") }
    }

    func rollback() {
        guard transactionDepth > 0 else { return }
        transactionDepth = 0
        try? executeBatch("rollback")
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try begin()
        do {
            let result = try body()
            try commit()
            return result
        } catch {
            rollback()
            throw error
        }
    }

    // MARK: Custom functions

    private func registerFunctions() throws {
        // Anki's search and sort code uses these helpers; they are cheap to provide.
        let rc = sqlite3_create_function_v2(
            handle, "field_at_index", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { ctx, argc, argv in
                guard let argv, argc == 2, let ctx else { return }
                guard let textPtr = sqlite3_value_text(argv[0]) else {
                    sqlite3_result_null(ctx)
                    return
                }
                let flds = String(cString: textPtr)
                let idx = Int(sqlite3_value_int64(argv[1]))
                let parts = flds.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                if idx >= 0, idx < parts.count {
                    let s = String(parts[idx])
                    sqlite3_result_text(ctx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else {
                    sqlite3_result_text(ctx, "", -1, nil)
                }
            }, nil, nil, nil)
        if rc != SQLITE_OK { throw error(rc) }

        // schema 18 collections declare columns with Anki's `unicase` collation
        let rc2 = sqlite3_create_collation_v2(
            handle, "unicase", SQLITE_UTF8, nil,
            { _, len1, p1, len2, p2 in
                let a = p1.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len1)), as: UTF8.self) } ?? ""
                let b = p2.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len2)), as: UTF8.self) } ?? ""
                switch a.lowercased().compare(b.lowercased()) {
                case .orderedAscending: return -1
                case .orderedDescending: return 1
                case .orderedSame: return 0
                }
            }, nil)
        if rc2 != SQLITE_OK { throw error(rc2) }
    }
}

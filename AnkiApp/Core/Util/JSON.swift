import Foundation

/// A loosely typed JSON value. Anki's legacy (schema 11) objects such as
/// notetypes, decks and deck options are stored and synced as JSON, and
/// unknown keys must survive a round trip, so they are kept as `JSON`
/// rather than decoded into fixed structs.
enum JSON: Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Accessors

    subscript(key: String) -> JSON {
        get {
            if case .object(let dict) = self { return dict[key] ?? .null }
            return .null
        }
        set {
            if case .object(var dict) = self {
                dict[key] = newValue
                self = .object(dict)
            } else {
                self = .object([key: newValue])
            }
        }
    }

    subscript(index: Int) -> JSON {
        if case .array(let arr) = self, index >= 0, index < arr.count { return arr[index] }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var int: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return v.isFinite ? Int64(v) : nil
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int64(s) ?? Double(s).map { Int64($0) }
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let v): return v != 0
        case .double(let v): return v != 0
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return nil
        }
    }

    var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    func int(or fallback: Int64) -> Int64 { int ?? fallback }
    func double(or fallback: Double) -> Double { double ?? fallback }
    func bool(or fallback: Bool) -> Bool { bool ?? fallback }
    func string(or fallback: String) -> String { string ?? fallback }

    var intValue: Int { Int(int ?? 0) }
    var doubleArray: [Double] { array?.compactMap { $0.double } ?? [] }

    // MARK: Literals

    init(_ value: Int) { self = .int(Int64(value)) }
    init(_ value: Int64) { self = .int(value) }
    init(_ value: Double) { self = .double(value) }
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ value: [Double]) { self = .array(value.map { JSON.double($0) }) }
    init(_ value: [Int]) { self = .array(value.map { JSON.int(Int64($0)) }) }

    // MARK: Serialization

    static func parse(_ data: Data) throws -> JSON {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    static func parse(_ string: String) throws -> JSON {
        try parse(Data(string.utf8))
    }

    /// Parses, returning `fallback` when the input is not valid JSON.
    static func parseOr(_ string: String, _ fallback: JSON) -> JSON {
        (try? parse(string)) ?? fallback
    }

    func serialized() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    func data() -> Data { Data(serialized().utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let v): out += String(v)
        case .double(let v):
            if !v.isFinite {
                out += "null"
            } else if v == v.rounded(), abs(v) < 1e15 {
                // keep a fractional marker so floats stay floats
                out += String(format: "%.1f", v)
            } else {
                out += "\(v)"
            }
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let arr):
            out += "["
            for (i, v) in arr.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            var first = true
            for key in dict.keys.sorted() {
                if !first { out += "," }
                first = false
                JSON.writeString(key, to: &out)
                out += ":"
                dict[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByNilLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        var dict: [String: JSON] = [:]
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
    init(nilLiteral: ()) { self = .null }
}

enum JSONError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let msg) = self { return "Invalid JSON: \(msg)" }
        return nil
    }
}

/// A small, strict JSON parser that keeps integers and floats apart,
/// which `JSONSerialization` does not reliably do.
private struct JSONParser {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSON {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if pos != bytes.count { throw JSONError.invalid("trailing data at \(pos)") }
        return value
    }

    mutating func skipWhitespace() {
        while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 {
            pos += 1
        }
    }

    mutating func parseValue(depth: Int) throws -> JSON {
        guard depth < 512 else { throw JSONError.invalid("nesting too deep") }
        guard pos < bytes.count else { throw JSONError.invalid("unexpected end") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        for b in word.utf8 {
            guard pos < bytes.count, bytes[pos] == b else { throw JSONError.invalid("expected \(word)") }
            pos += 1
        }
    }

    mutating func parseObject(depth: Int) throws -> JSON {
        pos += 1
        var dict: [String: JSON] = [:]
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(dict) }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw JSONError.invalid("expected key") }
            let key = try parseString()
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw JSONError.invalid("expected :") }
            pos += 1
            skipWhitespace()
            dict[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard pos < bytes.count else { throw JSONError.invalid("unterminated object") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(dict) }
            throw JSONError.invalid("expected , or }")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSON {
        pos += 1
        var arr: [JSON] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(arr) }
        while true {
            skipWhitespace()
            arr.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard pos < bytes.count else { throw JSONError.invalid("unterminated array") }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(arr) }
            throw JSONError.invalid("expected , or ]")
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw JSONError.invalid("bad escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[pos]
            pos += 1
            v <<= 4
            switch c {
            case 0x30...0x39: v |= UInt32(c - 0x30)
            case 0x41...0x46: v |= UInt32(c - 0x41 + 10)
            case 0x61...0x66: v |= UInt32(c - 0x61 + 10)
            default: throw JSONError.invalid("bad hex")
            }
        }
        return v
    }

    mutating func parseString() throws -> String {
        pos += 1
        var buf: [UInt8] = []
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: "\"") {
                return String(decoding: buf, as: UTF8.self)
            }
            if c == UInt8(ascii: "\\") {
                guard pos < bytes.count else { break }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): buf.append(0x22)
                case UInt8(ascii: "\\"): buf.append(0x5C)
                case UInt8(ascii: "/"): buf.append(0x2F)
                case UInt8(ascii: "b"): buf.append(0x08)
                case UInt8(ascii: "f"): buf.append(0x0C)
                case UInt8(ascii: "n"): buf.append(0x0A)
                case UInt8(ascii: "r"): buf.append(0x0D)
                case UInt8(ascii: "t"): buf.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    if (0xD800...0xDBFF).contains(code), pos + 6 <= bytes.count,
                       bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u")
                    {
                        pos += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw JSONError.invalid("bad escape")
                }
            } else {
                buf.append(c)
            }
        }
        throw JSONError.invalid("unterminated string")
    }

    mutating func parseNumber() throws -> JSON {
        let start = pos
        var isFloat = false
        while pos < bytes.count {
            let c = bytes[pos]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
                pos += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                isFloat = true
                pos += 1
            } else {
                break
            }
        }
        guard pos > start else { throw JSONError.invalid("unexpected character at \(pos)") }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        if !isFloat, let v = Int64(text) { return .int(v) }
        guard let d = Double(text) else { throw JSONError.invalid("bad number \(text)") }
        return .double(d)
    }
}

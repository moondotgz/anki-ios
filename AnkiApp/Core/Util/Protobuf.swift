import Foundation

/// A minimal protobuf decoder. Schema 18 collections (as sent by AnkiWeb
/// on a full download, and inside `.anki21b` packages) store notetype,
/// deck and deck option settings as protobuf blobs.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    private(set) var fields: [(number: Int, value: Value)] = []

    init() {}

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var pos = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while pos < bytes.count {
                let b = bytes[pos]
                pos += 1
                if shift < 64 { result |= UInt64(b & 0x7F) << shift }
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while pos < bytes.count {
            guard let key = readVarint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return }
                fields.append((number, .varint(v)))
            case 1:
                guard pos + 8 <= bytes.count else { return }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
                pos += 8
                fields.append((number, .fixed64(v)))
            case 2:
                guard let len = readVarint(), pos + Int(len) <= bytes.count else { return }
                fields.append((number, .bytes(Data(bytes[pos..<(pos + Int(len))]))))
                pos += Int(len)
            case 5:
                guard pos + 4 <= bytes.count else { return }
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
                pos += 4
                fields.append((number, .fixed32(v)))
            default:
                return
            }
        }
    }

    private func last(_ n: Int) -> Value? { fields.last { $0.number == n }?.value }
    func has(_ n: Int) -> Bool { fields.contains { $0.number == n } }

    func uint(_ n: Int) -> UInt64 {
        if case .varint(let v) = last(n) { return v }
        return 0
    }

    func int64(_ n: Int) -> Int64 { Int64(bitPattern: uint(n)) }
    func int32(_ n: Int) -> Int32 { Int32(truncatingIfNeeded: int64(n)) }
    func bool(_ n: Int) -> Bool { uint(n) != 0 }

    func sint32(_ n: Int) -> Int32 {
        let v = UInt32(truncatingIfNeeded: uint(n))
        return Int32(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    func optionalInt64(_ n: Int) -> Int64? { has(n) ? int64(n) : nil }
    func optionalUInt32(_ n: Int) -> UInt32? { has(n) ? UInt32(truncatingIfNeeded: uint(n)) : nil }

    func float(_ n: Int) -> Float {
        if case .fixed32(let v) = last(n) { return Float(bitPattern: v) }
        return 0
    }

    func optionalFloat(_ n: Int) -> Float? { has(n) ? float(n) : nil }

    func bytes(_ n: Int) -> Data {
        if case .bytes(let d) = last(n) { return d }
        return Data()
    }

    func string(_ n: Int) -> String { String(decoding: bytes(n), as: UTF8.self) }

    func message(_ n: Int) -> ProtoMessage? {
        if case .bytes(let d) = last(n) { return ProtoMessage(d) }
        return nil
    }

    func messages(_ n: Int) -> [ProtoMessage] {
        fields.compactMap { f in
            guard f.number == n, case .bytes(let d) = f.value else { return nil }
            return ProtoMessage(d)
        }
    }

    /// Repeated float, accepting both packed and unpacked encodings.
    func floats(_ n: Int) -> [Float] {
        var out: [Float] = []
        for f in fields where f.number == n {
            switch f.value {
            case .fixed32(let v): out.append(Float(bitPattern: v))
            case .bytes(let d):
                let b = [UInt8](d)
                var i = 0
                while i + 4 <= b.count {
                    let v = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                    out.append(Float(bitPattern: v))
                    i += 4
                }
            default: break
            }
        }
        return out
    }

    /// Repeated varint, accepting both packed and unpacked encodings.
    func uints(_ n: Int) -> [UInt64] {
        var out: [UInt64] = []
        for f in fields where f.number == n {
            switch f.value {
            case .varint(let v): out.append(v)
            case .bytes(let d):
                let b = [UInt8](d)
                var pos = 0
                while pos < b.count {
                    var result: UInt64 = 0
                    var shift: UInt64 = 0
                    while pos < b.count {
                        let byte = b[pos]
                        pos += 1
                        if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
                        if byte & 0x80 == 0 { break }
                        shift += 7
                    }
                    out.append(result)
                }
            default: break
            }
        }
        return out
    }
}

/// Minimal protobuf encoder, used for package metadata.
struct ProtoWriter {
    private(set) var data = Data()

    private mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func uint(_ n: Int, _ v: UInt64) {
        guard v != 0 else { return }
        varint(UInt64(n << 3))
        varint(v)
    }

    mutating func bytes(_ n: Int, _ d: Data) {
        varint(UInt64(n << 3 | 2))
        varint(UInt64(d.count))
        data.append(d)
    }

    mutating func string(_ n: Int, _ s: String) { bytes(n, Data(s.utf8)) }
}

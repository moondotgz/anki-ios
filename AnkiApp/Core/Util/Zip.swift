import Foundation

enum ZipError: Error, LocalizedError {
    case invalid(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let m): return "Invalid zip file: \(m)"
        case .unsupported(let m): return "Unsupported zip file: \(m)"
        }
    }
}

/// Reads zip archives (stored and deflated entries, including zip64),
/// as used by `.apkg`, `.colpkg` and media sync downloads.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    let data: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init(data: Data) throws {
        self.data = data
        try readDirectory()
    }

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func u16(_ at: Int) -> UInt16 {
        UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8
    }

    private func u32(_ at: Int) -> UInt32 {
        UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
    }

    private func u64(_ at: Int) -> UInt64 {
        UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
    }

    private mutating func readDirectory() throws {
        let count = data.count
        guard count >= 22 else { throw ZipError.invalid("too small") }
        var eocd = -1
        var i = count - 22
        let minPos = max(0, count - 22 - 65_535)
        while i >= minPos {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid("no end of central directory") }
        var total = UInt64(u16(eocd + 10))
        var cdOffset = UInt64(u32(eocd + 16))

        // zip64 end of central directory locator
        if eocd >= 20, u32(eocd - 20) == 0x0706_4B50 {
            let z64 = Int(u64(eocd - 20 + 8))
            if z64 + 56 <= count, u32(z64) == 0x0606_4B50 {
                total = u64(z64 + 32)
                cdOffset = u64(z64 + 48)
            }
        }

        var p = Int(cdOffset)
        for _ in 0..<total {
            guard p + 46 <= count, u32(p) == 0x0201_4B50 else { throw ZipError.invalid("bad central directory") }
            let method = u16(p + 10)
            var csize = UInt64(u32(p + 20))
            var usize = UInt64(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            var offset = UInt64(u32(p + 42))
            guard p + 46 + nameLen + extraLen <= count else { throw ZipError.invalid("truncated") }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)

            // zip64 extended information
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let tag = u16(e)
                let size = Int(u16(e + 2))
                if tag == 0x0001 {
                    var f = e + 4
                    if usize == 0xFFFF_FFFF, f + 8 <= e + 4 + size { usize = u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= e + 4 + size { csize = u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= e + 4 + size { offset = u64(f); f += 8 }
                }
                e += 4 + size
            }

            let entry = Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset)
            entries[name] = entry
            names.append(name)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ZipError.invalid("missing \(name)") }
        return try read(entry)
    }

    func read(_ entry: Entry) throws -> Data {
        let h = Int(entry.localHeaderOffset)
        guard h + 30 <= data.count, u32(h) == 0x0403_4B50 else { throw ZipError.invalid("bad local header") }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        let end = start + Int(entry.compressedSize)
        guard end <= data.count else { throw ZipError.invalid("truncated entry") }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
        switch entry.method {
        case 0: return raw
        case 8: return try Inflater.inflate(raw, expectedSize: Int(entry.uncompressedSize))
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
    }
}

/// Writes zip archives with stored (uncompressed) entries. Anki's own
/// media and package code does the same for already-compressed content.
struct ZipWriter {
    private var output = Data()
    private var central = Data()
    private var count = 0

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    mutating func add(name: String, data: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(output.count)
        let size = UInt32(data.count)
        // DOS date 1980-01-01
        let time: UInt16 = 0
        let date: UInt16 = 0x21

        var local = Data()
        local += Self.le32(0x0403_4B50)
        local += Self.le16(20)
        local += Self.le16(0x0800) // UTF-8 names
        local += Self.le16(0)
        local += Self.le16(time)
        local += Self.le16(date)
        local += Self.le32(crc)
        local += Self.le32(size)
        local += Self.le32(size)
        local += Self.le16(UInt16(nameData.count))
        local += Self.le16(0)
        local += nameData
        output += local
        output += data

        var cd = Data()
        cd += Self.le32(0x0201_4B50)
        cd += Self.le16(20)
        cd += Self.le16(20)
        cd += Self.le16(0x0800)
        cd += Self.le16(0)
        cd += Self.le16(time)
        cd += Self.le16(date)
        cd += Self.le32(crc)
        cd += Self.le32(size)
        cd += Self.le32(size)
        cd += Self.le16(UInt16(nameData.count))
        cd += Self.le16(0)
        cd += Self.le16(0)
        cd += Self.le16(0)
        cd += Self.le16(0)
        cd += Self.le32(0)
        cd += Self.le32(offset)
        cd += nameData
        central += cd
        count += 1
    }

    func finish() -> Data {
        var out = output
        let cdOffset = UInt32(out.count)
        out += central
        out += Self.le32(0x0605_4B50)
        out += Self.le16(0)
        out += Self.le16(0)
        out += Self.le16(UInt16(count))
        out += Self.le16(UInt16(count))
        out += Self.le32(UInt32(central.count))
        out += Self.le32(cdOffset)
        out += Self.le16(0)
        return out
    }
}

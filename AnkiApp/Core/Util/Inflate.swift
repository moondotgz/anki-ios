import Foundation

/// Raw DEFLATE (RFC 1951) decoder, used for zip entries in older Anki
/// packages. Portable, so packages import the same way everywhere.
struct Inflater {
    private let input: [UInt8]
    private var pos = 0
    private var bitBuf: UInt32 = 0
    private var bitCount = 0
    private var out: [UInt8] = []

    enum InflateError: Error { case corrupt(String) }

    static func inflate(_ data: Data, expectedSize: Int = 0) throws -> Data {
        var inf = Inflater(input: [UInt8](data))
        inf.out.reserveCapacity(max(expectedSize, data.count * 3))
        try inf.run()
        return Data(inf.out)
    }

    private init(input: [UInt8]) { self.input = input }

    private mutating func bits(_ n: Int) throws -> Int {
        while bitCount < n {
            guard pos < input.count else { throw InflateError.corrupt("unexpected end") }
            bitBuf |= UInt32(input[pos]) << UInt32(bitCount)
            pos += 1
            bitCount += 8
        }
        let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
        bitBuf >>= UInt32(n)
        bitCount -= n
        return v
    }

    /// Canonical Huffman table: counts per length and symbols by code order.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbols[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    private mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = h.counts[len]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw InflateError.corrupt("bad code")
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let fixedLit: Huffman = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return Huffman(lengths: l)
    }()
    private static let fixedDist = Huffman(lengths: [Int](repeating: 5, count: 30))

    private mutating func run() throws {
        var last = 0
        repeat {
            last = try bits(1)
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Inflater.fixedLit, Inflater.fixedDist)
            case 2:
                let (lit, dist) = try dynamicTables()
                try codes(lit, dist)
            default: throw InflateError.corrupt("bad block type")
            }
        } while last == 0
    }

    private mutating func stored() throws {
        bitBuf = 0
        bitCount = 0
        guard pos + 4 <= input.count else { throw InflateError.corrupt("short stored block") }
        let len = Int(input[pos]) | Int(input[pos + 1]) << 8
        pos += 4
        guard pos + len <= input.count else { throw InflateError.corrupt("short stored data") }
        out.append(contentsOf: input[pos..<(pos + len)])
        pos += len
    }

    private mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode { lengths[order[i]] = try bits(3) }
        let lencode = Huffman(lengths: lengths)
        var all: [Int] = []
        while all.count < nlen + ndist {
            let sym = try decode(lencode)
            if sym < 16 {
                all.append(sym)
            } else {
                var len = 0
                var rep: Int
                if sym == 16 {
                    guard let prev = all.last else { throw InflateError.corrupt("repeat without length") }
                    len = prev
                    rep = 3 + (try bits(2))
                } else if sym == 17 {
                    rep = 3 + (try bits(3))
                } else {
                    rep = 11 + (try bits(7))
                }
                all += [Int](repeating: len, count: rep)
            }
        }
        guard all.count == nlen + ndist else { throw InflateError.corrupt("too many lengths") }
        return (Huffman(lengths: Array(all[0..<nlen])), Huffman(lengths: Array(all[nlen...])))
    }

    private mutating func codes(_ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try decode(lit)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw InflateError.corrupt("bad length") }
                let len = Inflater.lengthBase[li] + (try bits(Inflater.lengthExtra[li]))
                let di = try decode(dist)
                guard di < 30 else { throw InflateError.corrupt("bad distance") }
                let d = Inflater.distBase[di] + (try bits(Inflater.distExtra[di]))
                guard d <= out.count else { throw InflateError.corrupt("distance too far") }
                let start = out.count - d
                for i in 0..<len { out.append(out[start + i]) }
            }
        }
    }
}

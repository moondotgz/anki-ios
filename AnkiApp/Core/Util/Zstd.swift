import Foundation
import libzstd

enum ZstdError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let msg) = self { return "zstd: \(msg)" }
        return nil
    }
}

/// zstd is used by the v11 sync protocol for every request and response
/// body, by `.anki21b` collections and by modern `.apkg`/`.colpkg` files.
enum Zstd {
    private static let one: [UInt8] = [0]

    static func compress(_ data: Data, level: Int32 = 3) throws -> Data {
        let bound = ZSTD_compressBound(data.count)
        var out = [UInt8](repeating: 0, count: bound)
        // an empty Data may have no base address, so give zstd a valid pointer
        let source = data.isEmpty ? Data(one) : data
        let written: Int = source.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                ZSTD_compress(dst.baseAddress, bound, src.baseAddress, data.count, level)
            }
        }
        if ZSTD_isError(written) != 0 {
            throw ZstdError.failed(String(cString: ZSTD_getErrorName(written)))
        }
        return Data(out[0..<written])
    }

    /// Streaming decompression; works whether or not the frame header
    /// records the content size, and handles concatenated frames.
    static func decompress(_ data: Data) throws -> Data {
        guard let dctx = ZSTD_createDCtx() else { throw ZstdError.failed("no context") }
        defer { ZSTD_freeDCtx(dctx) }
        let chunkSize = ZSTD_DStreamOutSize()
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var result = Data()
        result.reserveCapacity(data.count * 4)

        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.baseAddress, src.count > 0 else { return }
            var input = ZSTD_inBuffer(src: base, size: src.count, pos: 0)
            var lastRet: Int = 0
            while true {
                let produced: Int = try chunk.withUnsafeMutableBytes { dst in
                    var output = ZSTD_outBuffer(dst: dst.baseAddress, size: chunkSize, pos: 0)
                    let ret = ZSTD_decompressStream(dctx, &output, &input)
                    if ZSTD_isError(ret) != 0 {
                        throw ZstdError.failed(String(cString: ZSTD_getErrorName(ret)))
                    }
                    lastRet = ret
                    return output.pos
                }
                if produced > 0 { result.append(contentsOf: chunk[0..<produced]) }
                let inputDone = input.pos >= input.size
                if inputDone && produced < chunkSize { break }
                if inputDone && produced == 0 { break }
            }
            if lastRet != 0 && input.pos >= input.size {
                // frame incomplete; tolerate truncated trailing data the same way
                // as a short read would fail elsewhere
                throw ZstdError.failed("truncated input")
            }
        }
        return result
    }

    static func isZstd(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data([0x28, 0xB5, 0x2F, 0xFD])
    }
}

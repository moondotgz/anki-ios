import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SyncError: Error, LocalizedError {
    case authFailed
    case server(status: Int, message: String)
    case serverMessage(String)
    case clockIncorrect
    case sanityCheckFailed
    case resyncRequired
    case invalidResponse(String)
    case uploadTooLarge(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authFailed: return "AnkiWeb ID or password was incorrect; please try again."
        case .server(let status, let message):
            return message.isEmpty ? "The sync server returned an error (\(status))." : "Sync error (\(status)): \(message)"
        case .serverMessage(let m): return m
        case .clockIncorrect:
            return "Syncing failed because your device's clock is not set to the correct time. Please fix the clock and try again."
        case .sanityCheckFailed:
            return "After syncing, the collection was in an inconsistent state. The next sync will need to be a one-way sync."
        case .resyncRequired:
            return "A one-way sync is required. Please sync again and choose upload or download."
        case .invalidResponse(let m): return "Unexpected response from the sync server: \(m)"
        case .uploadTooLarge(let m): return "The collection is too large to upload to AnkiWeb: \(m)"
        case .cancelled: return "Sync was cancelled."
        }
    }
}

/// HTTP transport for Anki's sync protocol version 11: JSON bodies,
/// zstd-compressed in both directions, with a JSON `anki-sync` header.
final class SyncClient: NSObject, URLSessionTaskDelegate {
    static let defaultEndpoint = URL(string: "https://sync.ankiweb.net/")!
    static let syncVersion = 11
    /// Sent as the client version; AnkiWeb uses it to identify clients.
    static let clientVersion = "anki,26.09.3 (ios-swift),ios"

    var endpoint: URL
    var hostKey: String
    let sessionKey: String
    private var session: URLSession!

    init(hostKey: String = "", endpoint: URL? = nil) {
        self.hostKey = hostKey
        self.endpoint = endpoint ?? SyncClient.defaultEndpoint
        sessionKey = SyncClient.randomSessionKey()
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": "AnkiSwift/1.0"]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    static func randomSessionKey() -> String {
        let table = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var n = UInt64(UInt32.random(in: 0...UInt32.max))
        var out: [Character] = []
        repeat {
            out.append(table[Int(n % UInt64(table.count))])
            n /= UInt64(table.count)
        } while n > 0
        return String(out.reversed())
    }

    // Redirects are reported to the caller rather than followed, because a
    // 308 from AnkiWeb means the account moved to another sync host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }

    struct PermanentRedirect: Error { let location: URL }

    /// Posts `body` to `path` (e.g. "sync/meta") and returns the
    /// decompressed response body.
    func request(_ path: String, body: Data) async throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint) else { throw SyncError.invalidResponse("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let header: JSON = [
            "v": JSON(SyncClient.syncVersion),
            "k": .string(hostKey),
            "c": .string(SyncClient.clientVersion),
            "s": .string(sessionKey),
        ]
        req.setValue(header.serialized(), forHTTPHeaderField: "anki-sync")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Zstd.compress(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse("no response") }
        if http.statusCode == 308 || http.statusCode == 301 || http.statusCode == 307 {
            if let loc = http.value(forHTTPHeaderField: "Location"), let newURL = URL(string: loc, relativeTo: endpoint) {
                throw PermanentRedirect(location: newURL.absoluteURL)
            }
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 { throw SyncError.authFailed }
            var message = String(decoding: data.prefix(500), as: UTF8.self)
            if http.value(forHTTPHeaderField: "anki-original-size") != nil, let d = try? Zstd.decompress(data) {
                message = String(decoding: d.prefix(500), as: UTF8.self)
            }
            throw SyncError.server(status: http.statusCode, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if http.value(forHTTPHeaderField: "anki-original-size") != nil || Zstd.isZstd(data) {
            return try Zstd.decompress(data)
        }
        return data
    }

    func json(_ path: String, _ body: JSON) async throws -> JSON {
        let data = try await request(path, body: body.data())
        do {
            return try JSON.parse(data)
        } catch {
            throw SyncError.invalidResponse("\(path): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    // MARK: Login

    /// Exchanges AnkiWeb credentials for a host key.
    func login(username: String, password: String) async throws -> String {
        let resp = try await json("sync/hostKey", ["u": .string(username), "p": .string(password)])
        guard let key = resp["key"].string, !key.isEmpty else { throw SyncError.authFailed }
        hostKey = key
        return key
    }

    // MARK: Media endpoints wrap results as {"data": …, "err": ""}

    func media(_ method: String, _ body: JSON) async throws -> JSON {
        let resp = try await json("msync/\(method)", body)
        if let err = resp["err"].string, !err.isEmpty { throw SyncError.serverMessage(err) }
        return resp["data"]
    }

    func mediaRaw(_ method: String, body: Data) async throws -> Data {
        try await request("msync/\(method)", body: body)
    }
}

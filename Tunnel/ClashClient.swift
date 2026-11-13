import Foundation

struct ProbeOutcome {
    var url: String
    var ok: Bool
    var ms: Int
    var error: String?
}

struct ConnectionsSnapshot {
    var uploadTotal: Int64
    var downloadTotal: Int64
    var conns: [ConnSample]
}

/// Talks to sing-box's built-in Clash API on 127.0.0.1 (random port + random bearer secret per start).
/// Endpoints used: GET /version, GET /connections, PUT /proxies/{group}, GET /proxies/{tag}/delay, DELETE /connections.
final class ClashClient {
    private let base: String
    private let secret: String
    private let session: URLSession

    init(port: Int, secret: String) {
        base = "http://127.0.0.1:\(port)"
        self.secret = secret
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 10
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)
    }

    enum ClashError: LocalizedError {
        case http(Int, String)
        case badURL
        var errorDescription: String? {
            switch self {
            case .http(let c, let m): return "Clash API HTTP \(c) \(m)"
            case .badURL: return "Clash API: bad URL"
            }
        }
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         timeout: TimeInterval = 10) async throws -> Data {
        guard var comps = URLComponents(string: base + path) else { throw ClashError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw ClashError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClashError.http(code, String(data: data.prefix(160), encoding: .utf8) ?? "")
        }
        return data
    }

    func waitReady(attempts: Int = 20) async -> Bool {
        for _ in 0..<attempts {
            if (try? await request("GET", "/version", timeout: 2)) != nil { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func select(group: String, tag: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": tag])
        _ = try await request("PUT", "/proxies/" + enc(group), body: body)
    }

    func current(group: String) async -> String? {
        guard let d = try? await request("GET", "/proxies/" + enc(group)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["now"] as? String
    }

    func closeAll() async {
        _ = try? await request("DELETE", "/connections")
    }

    /// Real L7 probe: the core itself performs DNS + TCP + TLS + HTTP GET through the named outbound
    /// (works for outbounds that are NOT currently selected). Reported value covers time to response headers.
    func delay(tag: String, url: String, timeoutMs: Int) async -> ProbeOutcome {
        let started = Date()
        do {
            let d = try await request("GET", "/proxies/" + enc(tag) + "/delay",
                                      query: [URLQueryItem(name: "url", value: url),
                                              URLQueryItem(name: "timeout", value: String(timeoutMs))],
                                      timeout: Double(timeoutMs) / 1000 + 3)
            if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = o["delay"] as? Int {
                return ProbeOutcome(url: url, ok: true, ms: ms, error: nil)
            }
            return ProbeOutcome(url: url, ok: true, ms: Int(Date().timeIntervalSince(started) * 1000), error: nil)
        } catch ClashError.http(let code, let msg) {
            let kind = code == 504 ? "timeout" : (msg.isEmpty ? "http \(code)" : "failed")
            return ProbeOutcome(url: url, ok: false, ms: timeoutMs, error: kind)
        } catch {
            return ProbeOutcome(url: url, ok: false, ms: timeoutMs, error: "api")
        }
    }

    func connections() async throws -> ConnectionsSnapshot {
        let data = try await request("GET", "/connections")
        let dto = try JSONDecoder().decode(ConnectionsDTO.self, from: data)
        let conns = (dto.connections ?? []).map {
            ConnSample(id: $0.id, host: $0.metadata?.host ?? "", up: $0.upload ?? 0, down: $0.download ?? 0,
                       chain: $0.chains ?? [])
        }
        return ConnectionsSnapshot(uploadTotal: dto.uploadTotal ?? 0, downloadTotal: dto.downloadTotal ?? 0, conns: conns)
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

private struct ConnectionsDTO: Decodable {
    struct Meta: Decodable { var host: String? }
    struct Conn: Decodable {
        var id: String
        var upload: Int64?
        var download: Int64?
        var chains: [String]?
        var metadata: Meta?
    }
    var uploadTotal: Int64?
    var downloadTotal: Int64?
    var connections: [Conn]?
}

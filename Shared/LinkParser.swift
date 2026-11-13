import Foundation

/// Parses vless:// vmess:// trojan:// ss:// hysteria2:// (hy2://) links and subscription bodies.
/// Deliberately hand-written (no URLComponents): names with Cyrillic/emoji and odd query values must not break parsing.
enum LinkParser {

    // MARK: Public

    static func parseMany(_ text: String) -> (servers: [Server], skipped: [String]) {
        var servers: [Server] = []
        var skipped: [String] = []
        var seen = Set<String>()
        let body = decodeSubscription(text)
        for raw in body.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.contains("://") else { continue }
            if let s = parse(line) {
                if seen.insert(s.id).inserted { servers.append(s) }
            } else {
                skipped.append(String(line.prefix(48)))
            }
        }
        return (servers, skipped)
    }

    /// Subscriptions are usually base64 of a newline-separated list; plain lists pass through.
    static func decodeSubscription(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://") { return t }
        if let d = base64Decode(t), let s = String(data: d, encoding: .utf8), s.contains("://") { return s }
        return t
    }

    static func parse(_ link: String) -> Server? {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = l.range(of: "://") else { return nil }
        switch l[l.startIndex..<r.lowerBound].lowercased() {
        case "vless": return parseVless(l)
        case "vmess": return parseVmess(l)
        case "trojan": return parseTrojan(l)
        case "ss": return parseSS(l)
        case "hysteria2", "hy2": return parseHy2(l)
        default: return nil
        }
    }

    // MARK: Raw link splitting

    struct Raw {
        var scheme = ""
        var user = ""
        var host = ""
        var port: Int?
        var portExtra: String?      // e.g. hysteria2 "443,20000-30000"
        var path = ""
        var query: [String: String] = [:]
        var fragment = ""
    }

    static func split(_ link: String) -> Raw? {
        guard let sep = link.range(of: "://") else { return nil }
        var raw = Raw()
        raw.scheme = String(link[link.startIndex..<sep.lowerBound]).lowercased()
        var rest = String(link[sep.upperBound...])

        if let h = rest.firstIndex(of: "#") {
            raw.fragment = pdec(String(rest[rest.index(after: h)...]))
            rest = String(rest[rest.startIndex..<h])
        }
        var queryStr = ""
        if let q = rest.firstIndex(of: "?") {
            queryStr = String(rest[rest.index(after: q)...])
            rest = String(rest[rest.startIndex..<q])
        }
        var authority = rest
        if let s = rest.firstIndex(of: "/") {
            raw.path = String(rest[s...])
            authority = String(rest[rest.startIndex..<s])
        }
        var hostport = authority
        if let at = authority.lastIndex(of: "@") {
            raw.user = pdec(String(authority[authority.startIndex..<at]))
            hostport = String(authority[authority.index(after: at)...])
        }
        var portStr: String?
        if hostport.hasPrefix("["), let close = hostport.firstIndex(of: "]") {
            raw.host = String(hostport[hostport.index(after: hostport.startIndex)..<close])
            let after = hostport[hostport.index(after: close)...]
            if after.hasPrefix(":") { portStr = String(after.dropFirst()) }
        } else if let colon = hostport.lastIndex(of: ":") {
            raw.host = String(hostport[hostport.startIndex..<colon])
            portStr = String(hostport[hostport.index(after: colon)...])
        } else {
            raw.host = hostport
        }
        if let p = portStr, !p.isEmpty {
            let digits = p.prefix { $0.isNumber }
            raw.port = Int(digits)
            let extra = p.dropFirst(digits.count)
            if !extra.isEmpty { raw.portExtra = String(extra).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
        }
        for pair in queryStr.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first, !k.isEmpty else { continue }
            raw.query[pdec(String(k))] = kv.count > 1 ? pdec(String(kv[1])) : ""
        }
        guard !raw.host.isEmpty else { return nil }
        return raw
    }

    // MARK: Protocols

    private static func parseVless(_ link: String) -> Server? {
        guard let r = split(link), let port = r.port, !r.user.isEmpty else { return nil }
        var p = r.query
        if r.path.count > 1, p["path"] == nil { p["path"] = pdec(r.path) }
        let enc = (p["encryption"] ?? "none").lowercased()
        var bad = unsupportedTransport(p)
        if bad == nil, enc != "none", !enc.isEmpty { bad = "VLESS encryption=\(enc) не поддерживается ядром" }
        return make(.vless, name: r.fragment, host: r.host, port: port, secret: r.user, params: p, unsupported: bad)
    }

    private static func parseTrojan(_ link: String) -> Server? {
        guard let r = split(link), let port = r.port, !r.user.isEmpty else { return nil }
        var p = r.query
        if p["security"] == nil { p["security"] = "tls" }
        return make(.trojan, name: r.fragment, host: r.host, port: port, secret: r.user, params: p,
                    unsupported: unsupportedTransport(p))
    }

    private static func parseHy2(_ link: String) -> Server? {
        guard let r = split(link), let port = r.port else { return nil }
        var p = r.query
        if let extra = r.portExtra, !extra.isEmpty {
            p["mport"] = extra.replacingOccurrences(of: "-", with: ":")
        }
        var secret = r.user
        if secret.isEmpty { secret = p["auth"] ?? p["password"] ?? "" }
        guard !secret.isEmpty else { return nil }
        return make(.hysteria2, name: r.fragment, host: r.host, port: port, secret: secret, params: p, unsupported: nil)
    }

    private static func parseVmess(_ link: String) -> Server? {
        guard let sep = link.range(of: "://") else { return nil }
        var payload = String(link[sep.upperBound...])
        var frag = ""
        if let h = payload.firstIndex(of: "#") {
            frag = pdec(String(payload[payload.index(after: h)...]))
            payload = String(payload[payload.startIndex..<h])
        }
        guard let data = base64Decode(payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func s(_ k: String) -> String {
            guard let v = obj[k] else { return "" }
            if let str = v as? String { return str }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        let host = s("add"), id = s("id")
        guard !host.isEmpty, !id.isEmpty, let port = Int(s("port")) else { return nil }
        var p: [String: String] = [:]
        let net = s("net").isEmpty ? "tcp" : s("net")
        p["type"] = net
        if !s("host").isEmpty { p["host"] = s("host") }
        if !s("path").isEmpty { p["path"] = s("path") }
        if !s("sni").isEmpty { p["sni"] = s("sni") }
        if !s("alpn").isEmpty { p["alpn"] = s("alpn") }
        if !s("fp").isEmpty { p["fp"] = s("fp") }
        p["security"] = s("tls") == "tls" ? "tls" : "none"
        p["aid"] = s("aid").isEmpty ? "0" : s("aid")
        p["scy"] = s("scy").isEmpty ? "auto" : s("scy")
        if net == "grpc", !s("path").isEmpty { p["serviceName"] = s("path") }
        let name = s("ps").isEmpty ? frag : s("ps")
        return make(.vmess, name: name, host: host, port: port, secret: id, params: p,
                    unsupported: unsupportedTransport(p))
    }

    private static func parseSS(_ link: String) -> Server? {
        guard let sep = link.range(of: "://") else { return nil }
        var rest = String(link[sep.upperBound...])
        var frag = ""
        if let h = rest.firstIndex(of: "#") {
            frag = pdec(String(rest[rest.index(after: h)...]))
            rest = String(rest[rest.startIndex..<h])
        }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[rest.startIndex..<q])
        }
        if rest.hasSuffix("/") { rest.removeLast() }

        var method = "", password = "", host = "", port = 0
        if let at = rest.lastIndex(of: "@") {
            // SIP002: userinfo@host:port
            let userinfo = String(rest[rest.startIndex..<at])
            let hostport = String(rest[rest.index(after: at)...])
            let dec = pdec(userinfo)
            var cred = dec
            if !dec.contains(":") {
                guard let d = base64Decode(dec), let str = String(data: d, encoding: .utf8) else { return nil }
                cred = str
            }
            guard let c = cred.firstIndex(of: ":") else { return nil }
            method = String(cred[cred.startIndex..<c])
            password = String(cred[cred.index(after: c)...])
            guard let (h, p) = hostPort(hostport) else { return nil }
            host = h; port = p
        } else {
            // legacy: base64(method:password@host:port)
            guard let d = base64Decode(rest), let str = String(data: d, encoding: .utf8),
                  let at = str.lastIndex(of: "@") else { return nil }
            let cred = String(str[str.startIndex..<at])
            guard let c = cred.firstIndex(of: ":") else { return nil }
            method = String(cred[cred.startIndex..<c])
            password = String(cred[cred.index(after: c)...])
            guard let (h, p) = hostPort(String(str[str.index(after: at)...])) else { return nil }
            host = h; port = p
        }
        guard !method.isEmpty, !password.isEmpty, !host.isEmpty, port > 0 else { return nil }
        var params: [String: String] = ["method": method]
        var bad: String? = nil
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.first == "plugin" { bad = "SS plugin не поддерживается на iOS"; params["plugin"] = "1" }
        }
        return make(.shadowsocks, name: frag, host: host, port: port, secret: password, params: params, unsupported: bad)
    }

    // MARK: Helpers

    private static func make(_ kind: ProxyKind, name: String, host: String, port: Int, secret: String,
                             params: [String: String], unsupported: String?) -> Server {
        let id = Server.makeID(kind: kind, host: host, port: port, secret: secret)
        let title = name.trimmingCharacters(in: .whitespaces)
        return Server(id: id, name: title.isEmpty ? "\(host):\(port)" : title, kind: kind, host: host, port: port,
                      secret: secret, params: params, enabled: unsupported == nil, source: nil, unsupported: unsupported)
    }

    private static func unsupportedTransport(_ p: [String: String]) -> String? {
        let t = (p["type"] ?? p["net"] ?? "tcp").lowercased()
        switch t {
        case "xhttp", "splithttp": return "Транспорт \(t) не поддерживается ядром sing-box"
        case "kcp", "mkcp": return "Транспорт mKCP не поддерживается ядром sing-box"
        default: return nil
        }
    }

    private static func hostPort(_ s: String) -> (String, Int)? {
        var h = s
        if h.hasSuffix("/") { h.removeLast() }
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            let host = String(h[h.index(after: h.startIndex)..<close])
            let after = h[h.index(after: close)...]
            guard after.hasPrefix(":"), let p = Int(after.dropFirst()) else { return nil }
            return (host, p)
        }
        guard let colon = h.lastIndex(of: ":"), let p = Int(h[h.index(after: colon)...]) else { return nil }
        return (String(h[h.startIndex..<colon]), p)
    }

    static func pdec(_ s: String) -> String { s.removingPercentEncoding ?? s }

    static func base64Decode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        t += String(repeating: "=", count: pad)
        return Data(base64Encoded: t)
    }
}

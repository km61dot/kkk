import Foundation

struct RuntimeParams {
    var clashPort: Int
    var clashSecret: String
    var activeID: String?
}

enum ConfigError: LocalizedError {
    case emptyPool
    case encoding

    var errorDescription: String? {
        switch self {
        case .emptyPool: return "Нет ни одного включённого поддерживаемого сервера"
        case .encoding: return "Не удалось сформировать конфиг"
        }
    }
}

/// Generates sing-box 1.11-style JSON. The selector group is always called "proxy".
enum ConfigBuilder {
    static let selector = "proxy"

    static func build(profile: Profile, runtime: RuntimeParams, redact: Bool = false) throws -> String {
        let pool = profile.pool
        guard !pool.isEmpty else { throw ConfigError.emptyPool }
        let st = profile.settings

        var outbounds: [[String: Any]] = pool.map { outbound($0, redact: redact) }
        let defaultTag = pool.first(where: { $0.id == runtime.activeID })?.tag ?? pool[0].tag
        outbounds.insert([
            "type": "selector",
            "tag": selector,
            "outbounds": pool.map { $0.tag },
            "default": defaultTag,
            "interrupt_exist_connections": true,
        ], at: 0)
        outbounds.append(["type": "direct", "tag": "direct"])

        // DNS
        var dnsServers: [[String: Any]] = [
            ["tag": "remote", "address": st.remoteDNS, "address_resolver": "direct-dns", "detour": selector],
            ["tag": "direct-dns", "address": st.bootstrapDNS],
        ]
        var dnsRules: [[String: Any]] = [
            ["outbound": ["any"], "server": "direct-dns"],
        ]
        let direct = st.directDomains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !direct.isEmpty { dnsRules.append(["domain_suffix": direct, "server": "direct-dns"]) }
        var dns: [String: Any] = ["final": "remote"]
        if st.fakeIP {
            dnsServers.append(["tag": "fakeip", "address": "fakeip"])
            dnsRules.append(["query_type": ["A", "AAAA"], "server": "fakeip"])
            dns["fakeip"] = ["enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"]
        }
        if st.preferIPv4 { dns["strategy"] = "prefer_ipv4" }
        dns["servers"] = dnsServers
        dns["rules"] = dnsRules

        // Route
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["port": [53], "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"],
        ]
        if !direct.isEmpty { rules.append(["domain_suffix": direct, "outbound": "direct"]) }
        if st.blockQUIC { rules.append(["protocol": "quic", "action": "reject"]) }

        let config: [String: Any] = [
            "log": ["level": st.logLevel, "timestamp": false],
            "dns": dns,
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": st.mtu,
                "auto_route": true,
                "strict_route": false,
            ] as [String: Any]],
            "outbounds": outbounds,
            "route": [
                "rules": rules,
                "final": selector,
                "auto_detect_interface": true,
            ] as [String: Any],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(runtime.clashPort)",
                    "secret": redact ? "•••" : runtime.clashSecret,
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { throw ConfigError.encoding }
        return text
    }

    // MARK: Outbounds

    static func outbound(_ s: Server, redact: Bool) -> [String: Any] {
        let p = s.params
        let secret = redact ? "•••" : s.secret
        var o: [String: Any] = ["tag": s.tag, "server": s.host, "server_port": s.port]
        switch s.kind {
        case .vless:
            o["type"] = "vless"
            o["uuid"] = secret
            o["packet_encoding"] = "xudp"
            if let f = p["flow"], !f.isEmpty { o["flow"] = f }
            if let t = tls(s, redact: redact) { o["tls"] = t }
            if let tr = transport(s) { o["transport"] = tr }
        case .vmess:
            o["type"] = "vmess"
            o["uuid"] = secret
            o["security"] = p["scy"] ?? "auto"
            o["alter_id"] = Int(p["aid"] ?? "0") ?? 0
            o["packet_encoding"] = "xudp"
            if let t = tls(s, redact: redact) { o["tls"] = t }
            if let tr = transport(s) { o["transport"] = tr }
        case .trojan:
            o["type"] = "trojan"
            o["password"] = secret
            if let t = tls(s, redact: redact) { o["tls"] = t }
            if let tr = transport(s) { o["transport"] = tr }
        case .shadowsocks:
            o["type"] = "shadowsocks"
            o["method"] = p["method"] ?? "aes-128-gcm"
            o["password"] = secret
        case .hysteria2:
            o["type"] = "hysteria2"
            o["password"] = secret
            if let m = p["mport"], !m.isEmpty {
                o["server_ports"] = m.split(separator: ",").map { String($0) }
            }
            if let ob = p["obfs"], !ob.isEmpty {
                o["obfs"] = ["type": ob, "password": redact ? "•••" : (p["obfs-password"] ?? "")]
            }
            var t: [String: Any] = ["enabled": true]
            if let sni = p["sni"], !sni.isEmpty { t["server_name"] = sni }
            if truthy(p["insecure"]) || truthy(p["allowInsecure"]) { t["insecure"] = true }
            t["alpn"] = ["h3"]
            o["tls"] = t
        }
        return o
    }

    private static func tls(_ s: Server, redact: Bool) -> [String: Any]? {
        let p = s.params
        let sec = (p["security"] ?? (s.kind == .trojan ? "tls" : "none")).lowercased()
        guard sec == "tls" || sec == "reality" else { return nil }
        var t: [String: Any] = ["enabled": true]
        if let sni = p["sni"] ?? p["peer"] ?? p["host"], !sni.isEmpty { t["server_name"] = sni }
        if truthy(p["allowInsecure"]) || truthy(p["insecure"]) { t["insecure"] = true }
        if let a = p["alpn"], !a.isEmpty { t["alpn"] = a.split(separator: ",").map { String($0) } }
        var fp = p["fp"] ?? ""
        if sec == "reality", fp.isEmpty { fp = "chrome" }
        if !fp.isEmpty { t["utls"] = ["enabled": true, "fingerprint": fp] }
        if sec == "reality" {
            t["reality"] = ["enabled": true,
                            "public_key": redact ? "•••" : (p["pbk"] ?? ""),
                            "short_id": p["sid"] ?? ""]
        }
        return t
    }

    private static func transport(_ s: Server) -> [String: Any]? {
        let p = s.params
        let type = (p["type"] ?? p["net"] ?? "tcp").lowercased()
        let host = p["host"] ?? ""
        let path = p["path"] ?? "/"
        switch type {
        case "ws":
            var t: [String: Any] = ["type": "ws", "path": path]
            if !host.isEmpty { t["headers"] = ["Host": host] }
            return t
        case "grpc":
            return ["type": "grpc", "service_name": p["serviceName"] ?? p["path"] ?? ""]
        case "http", "h2":
            var t: [String: Any] = ["type": "http", "path": path]
            if !host.isEmpty { t["host"] = host.split(separator: ",").map { String($0) } }
            return t
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade", "path": path]
            if !host.isEmpty { t["host"] = host }
            return t
        default:
            return nil
        }
    }

    private static func truthy(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }
}

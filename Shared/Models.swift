import Foundation

// MARK: - Servers

enum ProxyKind: String, Codable, CaseIterable {
    case vless, vmess, trojan, shadowsocks, hysteria2

    var title: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        case .hysteria2: return "Hysteria2"
        }
    }
}

struct Server: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: ProxyKind
    var host: String
    var port: Int
    var secret: String                 // uuid / password
    var params: [String: String]       // flat link parameters (security, sni, type, path, ...)
    var enabled: Bool
    var source: String?                // subscription id, nil = manual
    var unsupported: String?           // reason the core cannot run it

    var tag: String { "s-" + id }
    var subtitle: String { "\(kind.title) · \(host):\(port)" }

    var securityLabel: String {
        let sec = params["security"] ?? (kind == .trojan || kind == .hysteria2 ? "tls" : "none")
        let net = (params["type"] ?? "tcp").lowercased()
        return [sec == "none" ? nil : sec.uppercased(), net == "tcp" ? nil : net.uppercased()]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func makeID(kind: ProxyKind, host: String, port: Int, secret: String) -> String {
        // FNV-1a 64: stable across launches, good enough for de-duplication
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(kind.rawValue)|\(host.lowercased())|\(port)|\(secret)".utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%010llx", h & 0xFFFFFFFFFF)
    }
}

// MARK: - Services

struct ServiceTarget: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String              // SF Symbol
    var suffixes: [String]        // passive matching (sniffed host suffixes)
    var probes: [String]          // active probe URLs (>= 2 independent endpoints)
    var enabled: Bool
    var critical: Bool
    var weight: Double
    var builtin: Bool

    static let baselineID = "base"

    static let defaults: [ServiceTarget] = [
        ServiceTarget(id: baselineID, name: "Базовая связность", icon: "network",
                      suffixes: [],
                      probes: ["https://www.gstatic.com/generate_204",
                               "https://cp.cloudflare.com/generate_204",
                               "https://www.google.com/generate_204"],
                      enabled: true, critical: true, weight: 1.0, builtin: true),
        ServiceTarget(id: "instagram", name: "Instagram", icon: "camera.fill",
                      suffixes: ["instagram.com", "cdninstagram.com", "fbcdn.net"],
                      probes: ["https://www.instagram.com/",
                               "https://i.instagram.com/",
                               "https://scontent.cdninstagram.com/",
                               "https://static.xx.fbcdn.net/"],
                      enabled: true, critical: true, weight: 1.0, builtin: true),
        ServiceTarget(id: "whatsapp", name: "WhatsApp", icon: "message.fill",
                      suffixes: ["whatsapp.net", "whatsapp.com"],
                      probes: ["https://web.whatsapp.com/",
                               "https://www.whatsapp.com/",
                               "https://static.whatsapp.net/",
                               "https://mmg.whatsapp.net/"],
                      enabled: true, critical: true, weight: 1.0, builtin: true),
        ServiceTarget(id: "youtube", name: "YouTube", icon: "play.rectangle.fill",
                      suffixes: ["youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com"],
                      probes: ["https://www.youtube.com/generate_204",
                               "https://www.youtube.com/",
                               "https://i.ytimg.com/"],
                      enabled: false, critical: false, weight: 0.7, builtin: true),
        ServiceTarget(id: "telegram", name: "Telegram", icon: "paperplane.fill",
                      suffixes: ["telegram.org", "t.me", "telegram.me", "cdn-telegram.org"],
                      probes: ["https://telegram.org/",
                               "https://web.telegram.org/"],
                      enabled: false, critical: false, weight: 0.7, builtin: true),
    ]
}

// MARK: - Tuning

enum Preset: String, Codable, CaseIterable {
    case gentle, standard, fast

    var title: String {
        switch self {
        case .gentle: return "Мягкий"
        case .standard: return "Стандарт"
        case .fast: return "Быстрый"
        }
    }
    var hint: String {
        switch self {
        case .gentle: return "Реже переключается, меньше трафика проб"
        case .standard: return "Баланс скорости реакции и стабильности"
        case .fast: return "Реагирует быстрее, чаще проверяет"
        }
    }
    var tuning: Tuning {
        switch self {
        case .gentle:
            return Tuning(tickActive: 3, tickIdle: 15, stallTicks: 4, hungAge: 10, probeTimeoutMs: 7000,
                          routineInterval: 420, observeSeconds: 150, cooldown: 120, switchMargin: 20,
                          returnStreak: 3, returnInterval: 420, maxSwitchesPer30m: 3)
        case .standard:
            return Tuning(tickActive: 2, tickIdle: 10, stallTicks: 3, hungAge: 8, probeTimeoutMs: 6000,
                          routineInterval: 300, observeSeconds: 120, cooldown: 90, switchMargin: 15,
                          returnStreak: 3, returnInterval: 300, maxSwitchesPer30m: 4)
        case .fast:
            return Tuning(tickActive: 2, tickIdle: 8, stallTicks: 2, hungAge: 6, probeTimeoutMs: 5000,
                          routineInterval: 180, observeSeconds: 90, cooldown: 45, switchMargin: 10,
                          returnStreak: 2, returnInterval: 240, maxSwitchesPer30m: 5)
        }
    }
}

/// Starting hypotheses. They are NOT measured optima: calibrate on real traffic.
struct Tuning: Codable, Equatable {
    var tickActive: Double
    var tickIdle: Double
    var stallTicks: Int
    var hungAge: Double
    var probeTimeoutMs: Int
    var routineInterval: Double
    var observeSeconds: Double
    var cooldown: Double
    var switchMargin: Double
    var returnStreak: Int
    var returnInterval: Double
    var maxSwitchesPer30m: Int
}

// MARK: - Settings / Profile

struct Settings: Codable, Equatable {
    var autoFailover: Bool = true
    var preset: Preset = .standard
    var mtu: Int = 1400
    var fakeIP: Bool = false
    var preferIPv4: Bool = true
    var blockQUIC: Bool = true
    var bootstrapDNS: String = "1.1.1.1"
    var remoteDNS: String = "https://1.1.1.1/dns-query"
    var directDomains: [String] = []
    var services: [ServiceTarget] = ServiceTarget.defaults
    var maxBackups: Int = 3
    var logLevel: String = "warn"

    var tuning: Tuning { preset.tuning }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        autoFailover = try c.decodeIfPresent(Bool.self, forKey: .autoFailover) ?? d.autoFailover
        preset = try c.decodeIfPresent(Preset.self, forKey: .preset) ?? d.preset
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? d.mtu
        fakeIP = try c.decodeIfPresent(Bool.self, forKey: .fakeIP) ?? d.fakeIP
        preferIPv4 = try c.decodeIfPresent(Bool.self, forKey: .preferIPv4) ?? d.preferIPv4
        blockQUIC = try c.decodeIfPresent(Bool.self, forKey: .blockQUIC) ?? d.blockQUIC
        bootstrapDNS = try c.decodeIfPresent(String.self, forKey: .bootstrapDNS) ?? d.bootstrapDNS
        remoteDNS = try c.decodeIfPresent(String.self, forKey: .remoteDNS) ?? d.remoteDNS
        directDomains = try c.decodeIfPresent([String].self, forKey: .directDomains) ?? d.directDomains
        services = try c.decodeIfPresent([ServiceTarget].self, forKey: .services) ?? d.services
        maxBackups = try c.decodeIfPresent(Int.self, forKey: .maxBackups) ?? d.maxBackups
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
    }
}

struct Subscription: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var updated: Date?
}

struct Profile: Codable, Equatable {
    var servers: [Server] = []
    var subscriptions: [Subscription] = []
    var settings = Settings()
    var primaryID: String? = nil

    /// Servers that enter the selector: primary first, then enabled supported servers in list order.
    var pool: [Server] {
        let ok = servers.filter { $0.enabled && $0.unsupported == nil }
        guard !ok.isEmpty else { return [] }
        var ordered = ok
        if let p = primaryID, let i = ordered.firstIndex(where: { $0.id == p }) {
            let s = ordered.remove(at: i)
            ordered.insert(s, at: 0)
        }
        return Array(ordered.prefix(1 + max(0, settings.maxBackups)))
    }
    var primary: Server? { pool.first }
}

// MARK: - Runtime state (extension -> app)

struct ServiceScore: Codable, Hashable {
    var score: Double
    var availability: Double
    var latencyMs: Int?
    var samples: Int
}

struct ServerHealth: Codable, Hashable {
    var serverID: String
    var overall: Double?
    var services: [String: ServiceScore]
    var quarantineLeft: Int          // seconds, 0 = none
    var baselineMs: Int?
}

struct ProbeDot: Codable, Hashable {
    var t: Double
    var ok: Bool
    var ms: Int
}

struct EventLine: Codable, Hashable, Identifiable {
    var t: Double
    var level: String                // info, ok, warn, err
    var text: String
    var id: String { "\(t)-\(text.hashValue)" }
}

struct TunnelState: Codable {
    var phase: String = "stopped"    // starting, running, stopping, error
    var activeID: String?
    var primaryID: String?
    var auto: Bool = true
    var health: [String: ServerHealth] = [:]
    var history: [String: [ProbeDot]] = [:]   // service id -> recent probes on the active server
    var events: [EventLine] = []
    var net: String = "unknown"
    var availMemMB: Int?
    var upBps: Int64 = 0
    var downBps: Int64 = 0
    var totalUp: Int64 = 0
    var totalDown: Int64 = 0
    var conns: Int = 0
    var lastSwitch: Double?
    var observing: Bool = false
    var busy: String?
    var updated: Double = 0
}

struct Command: Codable {
    var cmd: String                  // state, select, auto, probe, reset, logs
    var arg: String? = nil
    var flag: Bool? = nil
}

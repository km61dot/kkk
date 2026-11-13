import Foundation

// MARK: - Score book

struct ProbeSample {
    var t: Double
    var ok: Bool
    var ms: Int
    var inconclusive: Bool // failure on an endpoint that never succeeded anywhere: inconclusive, ignored by scoring
}

/// Decayed per-(server, service) health memory. Not thread-safe: owned by the engine actor.
final class HealthBook {
    struct Key: Hashable { let server: String; let service: String }

    private var samples: [Key: [ProbeSample]] = [:]
    private var stalls: [Key: [Double]] = [:]
    private var strikes: [String: Int] = [:]
    private var quarantineUntil: [String: Double] = [:]
    /// url -> last time it succeeded through ANY server (proves the endpoint itself is sane)
    private(set) var knownGood: [String: Double] = [:]

    let halfLife: Double = 600       // seconds; weight(t) = 0.5^(age/halfLife)
    let maxSamples = 24

    // MARK: Recording

    func record(server: String, service: String, url: String, ok: Bool, ms: Int, now: Double) {
        if ok { knownGood[url] = now }
        let inconclusive = !ok && knownGood[url] == nil
        let key = Key(server: server, service: service)
        var arr = samples[key] ?? []
        arr.append(ProbeSample(t: now, ok: ok, ms: ms, inconclusive: inconclusive))
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
        samples[key] = arr
    }

    func addStall(server: String, service: String, now: Double) {
        let key = Key(server: server, service: service)
        var arr = stalls[key] ?? []
        arr.append(now)
        if arr.count > 8 { arr.removeFirst(arr.count - 8) }
        stalls[key] = arr
    }

    /// Network changed (Wi-Fi <-> LTE): old measurements describe another path.
    func resetMeasurements() {
        samples.removeAll()
        stalls.removeAll()
    }

    // MARK: Scores

    func serviceScore(server: String, service: String, now: Double) -> ServiceScore? {
        let key = Key(server: server, service: service)
        var wSum = 0.0, wOK = 0.0
        var lat: [(Double, Double)] = []
        var n = 0
        for s in samples[key] ?? [] where !s.inconclusive {
            let w = pow(0.5, max(0, now - s.t) / halfLife)
            wSum += w; n += 1
            if s.ok { wOK += w; lat.append((Double(s.ms), w)) }
        }
        guard wSum >= 0.05 else { return nil }
        let availability = wOK / wSum
        let med = weightedMedian(lat)
        let latScore = med == nil ? 0 : 1 - min(1, max(0, (med! - 500) / 4000))
        var penalty = 0.0
        for t in stalls[key] ?? [] { penalty += 15 * pow(0.5, max(0, now - t) / halfLife) }
        penalty = min(40, penalty)
        let raw = max(0, min(100, 100 * (0.7 * availability + 0.3 * latScore) - penalty))
        let conf = min(1, wSum / 2.0)       // ~2 fresh samples = full confidence
        let score = conf * raw + (1 - conf) * 50
        return ServiceScore(score: score, availability: availability, latencyMs: med.map { Int($0) }, samples: n)
    }

    /// Overall = 0.35 * weighted mean + 0.65 * worst critical service; a dead baseline caps everything.
    func health(server: String, services: [ServiceTarget], now: Double) -> ServerHealth {
        var per: [String: ServiceScore] = [:]
        var wSum = 0.0, wTot = 0.0
        var worstCritical: Double?
        for svc in services where svc.enabled {
            guard let sc = serviceScore(server: server, service: svc.id, now: now) else { continue }
            per[svc.id] = sc
            wSum += sc.score * svc.weight
            wTot += svc.weight
            if svc.critical { worstCritical = min(worstCritical ?? 100, sc.score) }
        }
        var overall: Double?
        if wTot > 0 {
            let mean = wSum / wTot
            overall = 0.35 * mean + 0.65 * (worstCritical ?? mean)
            if let b = per[ServiceTarget.baselineID], b.score < 30 { overall = min(overall!, b.score) }
        }
        return ServerHealth(serverID: server, overall: overall, services: per,
                            quarantineLeft: max(0, Int((quarantineUntil[server] ?? 0) - now)),
                            baselineMs: per[ServiceTarget.baselineID]?.latencyMs)
    }

    func recentDots(server: String, service: String, limit: Int = 16) -> [ProbeDot] {
        (samples[Key(server: server, service: service)] ?? []).filter { !$0.inconclusive }.suffix(limit)
            .map { ProbeDot(t: $0.t, ok: $0.ok, ms: $0.ms) }
    }

    // MARK: Quarantine (exponential backoff, anti-flapping)

    func quarantine(_ server: String, now: Double) {
        let n = (strikes[server] ?? 0) + 1
        strikes[server] = n
        quarantineUntil[server] = now + min(900, 60 * pow(2, Double(n - 1)))
    }

    func clearQuarantine(_ server: String) {
        strikes[server] = 0
        quarantineUntil[server] = nil
    }

    func isQuarantined(_ server: String, now: Double) -> Bool { (quarantineUntil[server] ?? 0) > now }

    private func weightedMedian(_ v: [(Double, Double)]) -> Double? {
        guard !v.isEmpty else { return nil }
        let sorted = v.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        var acc = 0.0
        for (x, w) in sorted {
            acc += w
            if acc >= total / 2 { return x }
        }
        return sorted.last!.0
    }
}

// MARK: - Passive analyzer

struct ConnSample {
    var id: String
    var host: String
    var up: Int64
    var down: Int64
    var chain: [String]
}

struct PassiveSignal {
    var service: String
    var reason: String
}

/// Looks at per-connection byte counters (from the core's connection table) and raises a SUSPICION
/// for a service when traffic goes out but nothing comes back. It never switches servers by itself:
/// a suspicion only triggers active probes.
final class PassiveAnalyzer {
    private struct Prev { var up: Int64; var down: Int64; var firstSeen: Double }
    private struct Acc { var dUp: Int64 = 0; var dDown: Int64 = 0; var n = 0; var hung = 0 }

    private var prev: [String: Prev] = [:]
    private var streak: [String: Int] = [:]
    private var lastSignal: [String: Double] = [:]
    private var primed = false
    private var suffixMap: [String: String] = [:]
    var tuning: Tuning
    private let maxConns = 600

    init(tuning: Tuning, services: [ServiceTarget]) {
        self.tuning = tuning
        configure(services: services)
    }

    func configure(services: [ServiceTarget]) {
        suffixMap.removeAll()
        for s in services where s.enabled {
            for suf in s.suffixes { suffixMap[suf.lowercased()] = s.id }
        }
    }

    func reset() {
        prev.removeAll()
        streak.removeAll()
        primed = false
    }

    func match(host: String) -> String? {
        guard !host.isEmpty else { return nil }
        var h = Substring(host.lowercased())
        while true {
            if let id = suffixMap[String(h)] { return id }
            guard let dot = h.firstIndex(of: ".") else { return nil }
            h = h[h.index(after: dot)...]
        }
    }

    /// dt = seconds since previous ingest.
    func ingest(_ conns: [ConnSample], activeTag: String, now: Double, dt: Double) -> [PassiveSignal] {
        var acc: [String: Acc] = [:]
        var seen = Set<String>()
        for c in conns.prefix(maxConns) {
            seen.insert(c.id)
            let p = prev[c.id]
            let first = p?.firstSeen ?? now
            let dUp = p.map { max(0, c.up - $0.up) } ?? c.up
            let dDown = p.map { max(0, c.down - $0.down) } ?? c.down
            prev[c.id] = Prev(up: c.up, down: c.down, firstSeen: first)
            guard c.chain.contains(activeTag), let svc = match(host: c.host) else { continue }
            var a = acc[svc] ?? Acc()
            a.n += 1
            a.dUp += dUp
            a.dDown += dDown
            if c.down == 0, c.up >= 300, now - first >= tuning.hungAge { a.hung += 1 }
            acc[svc] = a
        }
        if prev.count > seen.count { prev = prev.filter { seen.contains($0.key) } }

        // First snapshot only primes the counters (connections may be older than the observer).
        guard primed else { primed = true; return [] }

        var out: [PassiveSignal] = []
        let svcIDs = Set(suffixMap.values)
        for svc in svcIDs {
            guard let a = acc[svc], a.n > 0 else { streak[svc] = 0; continue }
            let upRate = Double(a.dUp) / max(0.5, dt)
            // Big sustained upload (posting a video) also has little downlink: not a stall.
            let stalled = a.dUp >= 1500 && a.dDown < 300 && upRate < 64 * 1024
            streak[svc] = stalled ? (streak[svc] ?? 0) + 1 : 0
            var reason: String?
            if (streak[svc] ?? 0) >= tuning.stallTicks {
                reason = "исходящий трафик без ответа ≈\(Int(Double(streak[svc] ?? 0) * dt)) с"
            } else if a.hung >= 2 {
                reason = "\(a.hung) зависших соединений без единого байта ответа"
            }
            if let reason, now - (lastSignal[svc] ?? 0) >= 60 {
                lastSignal[svc] = now
                streak[svc] = 0
                out.append(PassiveSignal(service: svc, reason: reason))
            }
        }
        return out
    }
}

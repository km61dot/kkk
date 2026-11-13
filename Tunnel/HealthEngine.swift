import Foundation
import os

/// Limits concurrent probes (RAM / battery / server load).
actor Gate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

enum Verdict { case healthy, serviceDegraded, serverDown, inconclusive }

/// The brain: ONE scheduler loop (no timers per component), event-driven where the OS allows.
///   passive tick  -> suspicion  -> active probes confirm -> candidates probed -> selector switch -> observe -> return-to-primary
actor HealthEngine {
    private let clash: ClashClient
    private let profile: Profile
    private let pool: [Server]
    private let tuning: Tuning
    private let book = HealthBook()
    private let passive: PassiveAnalyzer
    private let gate = Gate(limit: 2)
    private let log = Logger(subsystem: "com.custom.proxyclient", category: "engine")

    private var activeID: String
    private let primaryID: String
    private var auto: Bool
    private var events: [EventLine] = []
    private var phase = "running"
    private var loop: Task<Void, Never>?
    private var busy: String?
    private var paused = false
    private var netUp = true
    private var netKind = "unknown"
    private var constrained = false
    private var expensive = false

    private var cooldownUntil = 0.0
    private var frozenUntil = 0.0
    private var switchTimes: [Double] = []
    private var lastSwitch: Double?
    private var observing: (id: String, until: Double, nextCheck: Double, service: String?)?
    private var primaryStreak = 0
    private var nextPrimaryCheck = 0.0
    private var nextRoutine = 0.0
    private var lastTraffic = 0.0
    private var wakeProbe = true
    private var rotate = 0
    private var apiFailures = 0

    private var lastTotals: (up: Int64, down: Int64)?
    private var lastTickAt = 0.0
    private var upBps: Int64 = 0
    private var downBps: Int64 = 0
    private var totals: (up: Int64, down: Int64) = (0, 0)
    private var connCount = 0
    private var idleTicks = 0
    private var availMemMB: Int?
    private var lowMemory = false
    private var lastPersist = 0.0
    private var dirty = true

    init(clash: ClashClient, profile: Profile, activeID: String) {
        self.clash = clash
        self.profile = profile
        self.pool = profile.pool
        self.tuning = profile.settings.tuning
        self.primaryID = profile.pool.first?.id ?? activeID
        self.activeID = activeID
        self.auto = profile.settings.autoFailover
        self.passive = PassiveAnalyzer(tuning: profile.settings.tuning, services: profile.settings.services)
    }

    // MARK: Lifecycle

    func start() {
        let now = Date().timeIntervalSince1970
        nextRoutine = now + 4
        nextPrimaryCheck = now + tuning.returnInterval
        lastTraffic = now
        say("ok", "Движок запущен. Активный: \(name(activeID)), основной: \(name(primaryID))")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next = await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(next * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        phase = "stopping"
        persist(force: true)
    }

    func pause() {
        paused = true
        say("info", "Устройство засыпает: проверки на паузе")
    }

    func resume() {
        paused = false
        wakeProbe = true
        nextRoutine = Date().timeIntervalSince1970 + 3
        passive.reset()
        say("info", "Пробуждение: плановая проверка через пару секунд")
    }

    func networkChanged(_ info: PathInfo) {
        let was = netKind
        netKind = info.kind
        constrained = info.constrained
        expensive = info.expensive
        let wasUp = netUp
        netUp = info.satisfied
        guard was != info.kind || wasUp != info.satisfied else { return }
        passive.reset()
        if !info.satisfied {
            say("warn", "Сеть пропала: проверки и переключения приостановлены")
        } else {
            book.resetMeasurements()
            wakeProbe = true
            nextRoutine = Date().timeIntervalSince1970 + 4
            cooldownUntil = max(cooldownUntil, Date().timeIntervalSince1970 + 10)
            say("info", "Сеть: \(was) → \(info.kind). Старые замеры сброшены, перепроверка через 4 с")
        }
        dirty = true
    }

    func memoryPressure(critical: Bool) {
        lowMemory = true
        say("warn", critical ? "Критическое давление памяти: проверки замедлены" : "Давление памяти: проверки замедлены")
        dirty = true
    }

    // MARK: Commands from the app

    func handle(_ c: Command) async -> Data {
        switch c.cmd {
        case "select":
            if let id = c.arg, let s = pool.first(where: { $0.id == id }) {
                do {
                    try await switchTo(s, reason: "ручной выбор", quarantineOld: false, manual: true)
                } catch {
                    say("err", "Не удалось переключить: \(error.localizedDescription)")
                }
            }
        case "auto":
            auto = c.flag ?? auto
            say("info", auto ? "Автопереключение включено" : "Автопереключение выключено")
        case "probe":
            nextRoutine = 0
            wakeProbe = true
            Task { await self.runRoutine(force: true) }
        case "reset":
            await clash.closeAll()
            passive.reset()
            say("info", "Все соединения сброшены")
        default:
            break
        }
        return encodeState()
    }

    func encodeState() -> Data {
        (try? JSONEncoder().encode(snapshot())) ?? Data()
    }

    // MARK: Main tick

    private func tick() async -> Double {
        if paused { return 5 }
        let now = Date().timeIntervalSince1970
        sampleMemory()

        // 1) passive snapshot
        var snap: ConnectionsSnapshot?
        do {
            snap = try await clash.connections()
            apiFailures = 0
        } catch {
            apiFailures += 1
            if apiFailures == 5 { say("err", "Clash API не отвечает: \(error.localizedDescription)") }
        }
        if let snap {
            let dt = lastTickAt > 0 ? max(0.5, now - lastTickAt) : tuning.tickActive
            lastTickAt = now
            if let last = lastTotals {
                let dUp = max(0, snap.uploadTotal - last.up)
                let dDown = max(0, snap.downloadTotal - last.down)
                upBps = Int64(Double(dUp) / dt)
                downBps = Int64(Double(dDown) / dt)
                if dUp + dDown > 2048 { lastTraffic = now; idleTicks = 0 } else { idleTicks += 1 }
            }
            lastTotals = (snap.uploadTotal, snap.downloadTotal)
            totals = lastTotals!
            connCount = snap.conns.count
            if netUp && observing == nil {
                let signals = passive.ingest(snap.conns, activeTag: tag(activeID), now: now, dt: dt)
                for sig in signals where busy == nil {
                    await onSuspicion(sig)
                }
            }
        }

        // 2) observation of a fresh switch
        if netUp, busy == nil { await observeIfNeeded(now: now) }
        // 3) routine probe of the active server (only when the user actually uses the network)
        if netUp, busy == nil, !lowMemory, now >= nextRoutine, now - lastTraffic < 900 || wakeProbe {
            await runRoutine(force: false)
        }
        // 4) coming back to the primary
        if netUp, busy == nil, auto, activeID != primaryID, observing == nil, !lowMemory, now >= nextPrimaryCheck {
            await checkPrimaryReturn(now: now)
        }

        persist(force: false)

        // adaptive polling: fast while traffic flows, slow when idle
        var next = tuning.tickActive
        if idleTicks >= 3 { next = tuning.tickIdle }
        if now - lastTraffic > 300 { next = max(next, 30) }
        if lowMemory { next = max(next, 10) }
        return next
    }

    // MARK: Suspicion -> confirmation -> failover

    private func onSuspicion(_ sig: PassiveSignal) async {
        guard let svc = service(sig.service) else { return }
        busy = "проверка \(svc.name)"
        defer { busy = nil; dirty = true }
        say("warn", "Подозрение: \(svc.name) — \(sig.reason)")
        let verdict = await confirm(serverID: activeID, svc: svc)
        switch verdict {
        case .healthy:
            say("ok", "Активные пробы \(svc.name) в норме: ложная тревога")
        case .inconclusive:
            say("info", "Пробы \(svc.name) неубедительны, ждём")
        case .serviceDegraded:
            book.addStall(server: activeID, service: svc.id, now: Date().timeIntervalSince1970)
            say("warn", "Подтверждено: \(svc.name) деградирует на \(name(activeID))")
            await failover(degraded: svc, reason: "\(svc.name) деградирует")
        case .serverDown:
            book.addStall(server: activeID, service: svc.id, now: Date().timeIntervalSince1970)
            say("err", "Сервер \(name(activeID)) не пропускает даже базовые проверки")
            await failover(degraded: svc, reason: "сервер недоступен")
        }
    }

    /// Up to two rounds of independent endpoints; baseline decides "server dead" vs "service-specific problem".
    private func confirm(serverID: String, svc: ServiceTarget) async -> Verdict {
        guard let server = pool.first(where: { $0.id == serverID }) else { return .inconclusive }
        var fails = 0, oks = 0
        var baseOK = false
        var baseFails = 0
        for round in 0..<2 {
            var jobs: [(ServiceTarget, String)] = svc.probes.map { (svc, $0) }
            if let b = service(ServiceTarget.baselineID), b.id != svc.id {
                for u in b.probes.prefix(2) { jobs.append((b, u)) }
            }
            let results = await runProbes(server: server, jobs: jobs)
            for (s, r) in results {
                if s.id == ServiceTarget.baselineID {
                    if r.ok { baseOK = true } else if r.error != "api" { baseFails += 1 }
                } else if r.ok {
                    oks += 1
                } else if book.knownGood[r.url] != nil, r.error != "api" {
                    fails += 1        // failures on never-proven endpoints do not count
                }
            }
            // Two independent baseline endpoints dead and none alive: the server itself is down
            // (works even on a cold start when no endpoint has ever been proven).
            if !baseOK && baseFails >= 2 { return .serverDown }
            if fails == 0 { break }
            if fails >= 2 && oks == 0 { break }
            if round == 0 { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        }
        if fails == 0 { return oks > 0 ? .healthy : .inconclusive }
        let total = fails + oks
        if !baseOK && oks == 0 { return .serverDown }
        if fails >= 2 && Double(fails) / Double(max(1, total)) >= 0.66 { return baseOK ? .serviceDegraded : .serverDown }
        return .inconclusive
    }

    private func failover(degraded svc: ServiceTarget, reason: String) async {
        let now = Date().timeIntervalSince1970
        guard auto else { say("info", "Автопереключение выключено — остаёмся"); return }
        guard now >= frozenUntil else { say("warn", "Переключения заморожены (защита от флаппинга)"); return }
        guard now >= cooldownUntil else {
            say("info", "Кулдаун после предыдущего переключения: \(Int(cooldownUntil - now)) с"); return
        }
        switchTimes = switchTimes.filter { now - $0 < 1800 }
        if switchTimes.count >= tuning.maxSwitchesPer30m {
            frozenUntil = now + 600
            say("err", "Слишком много переключений за 30 мин: автопереключение заморожено на 10 мин")
            return
        }
        // Candidates: not active, not quarantined (if everything is quarantined, take the least bad ones)
        var cands = pool.filter { $0.id != activeID && !book.isQuarantined($0.id, now: now) }
        if cands.isEmpty { cands = pool.filter { $0.id != activeID } }
        guard !cands.isEmpty else { say("warn", "Нет резервных серверов"); return }

        busy = "поиск замены"
        say("info", "Проверяю кандидатов: \(cands.map { $0.name }.joined(separator: ", "))")
        for c in cands { await fullRound(server: c) }

        let t = Date().timeIntervalSince1970
        let cur = book.health(server: activeID, services: profile.settings.services, now: t)
        var best: (Server, Double, Double)?
        for c in cands {
            let h = book.health(server: c.id, services: profile.settings.services, now: t)
            guard let overall = h.overall else { continue }
            let baseOK = (h.services[ServiceTarget.baselineID]?.score ?? 0) >= 50
            let svcScore = h.services[svc.id]?.score ?? 50
            guard baseOK, svcScore >= 55 else { continue }
            if best == nil || overall > best!.1 { best = (c, overall, svcScore) }
        }
        guard let (winner, overall, svcScore) = best else {
            say("warn", "Ни один резервный сервер не лучше текущего по \(svc.name)")
            return
        }
        let curOverall = cur.overall ?? 0
        guard overall >= curOverall + tuning.switchMargin else {
            say("info", "Лучший кандидат \(winner.name) (\(Int(overall))) не превосходит текущий (\(Int(curOverall))) на запас \(Int(tuning.switchMargin))")
            return
        }
        do {
            try await switchTo(winner, reason: "\(reason); \(svc.name) \(Int(svcScore)), общий \(Int(overall)) против \(Int(curOverall))",
                               quarantineOld: true, manual: false, service: svc.id)
        } catch {
            say("err", "Переключение не удалось: \(error.localizedDescription)")
        }
    }

    /// Switching = selector change. The selector has interrupt_exist_connections=true, so connections that were
    /// bound to the old outbound are closed by the core and apps reconnect through the new one. The tunnel stays up.
    private func switchTo(_ s: Server, reason: String, quarantineOld: Bool, manual: Bool, service: String? = nil) async throws {
        guard s.id != activeID else { return }
        let now = Date().timeIntervalSince1970
        let old = activeID
        let t0 = ProcessInfo.processInfo.systemUptime
        try await clash.select(group: ConfigBuilder.selector, tag: s.tag)
        let took = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        activeID = s.id
        Store.saveActive(s.id)
        passive.reset()
        lastSwitch = now
        switchTimes.append(now)
        cooldownUntil = now + (manual ? 300 : tuning.cooldown)
        if quarantineOld { book.quarantine(old, now: now) }
        if s.id == primaryID { book.clearQuarantine(s.id) }
        primaryStreak = 0
        if manual {
            observing = nil
        } else {
            observing = (id: s.id, until: now + tuning.observeSeconds, nextCheck: now + 10, service: service)
        }
        nextRoutine = now + 8
        say("ok", "Переключено: \(name(old)) → \(s.name) за \(took) мс (\(reason))")
        dirty = true
        persist(force: true)
    }

    // MARK: Observation after a switch

    private func observeIfNeeded(now: Double) async {
        guard let obs = observing else { return }
        if now >= obs.until {
            observing = nil
            say("ok", "Наблюдение за \(name(obs.id)) завершено: сервер стабилен")
            return
        }
        guard now >= obs.nextCheck, let server = pool.first(where: { $0.id == obs.id }) else { return }
        busy = "наблюдение"
        defer { busy = nil }
        var jobs: [(ServiceTarget, String)] = []
        if let b = service(ServiceTarget.baselineID), let u = b.probes.first { jobs.append((b, u)) }
        if let sid = obs.service, let s = service(sid), let u = s.probes.first { jobs.append((s, u)) }
        let res = await runProbes(server: server, jobs: jobs)
        let failed = res.filter { !$0.1.ok && book.knownGood[$0.1.url] != nil }
        observing?.nextCheck = Date().timeIntervalSince1970 + 15
        if failed.count >= 1 && failed.count == res.count {
            say("err", "Кандидат \(server.name) не прошёл наблюдение — ищу другой")
            observing = nil
            cooldownUntil = 0
            if let sid = obs.service, let svc = service(sid) {
                book.addStall(server: obs.id, service: svc.id, now: now)
                await failover(degraded: svc, reason: "кандидат не прошёл наблюдение")
            }
        }
    }

    // MARK: Routine probes

    private func runRoutine(force: Bool) async {
        guard busy == nil, netUp else { return }
        busy = "плановая проверка"
        defer { busy = nil; dirty = true }
        guard let server = pool.first(where: { $0.id == activeID }) else { return }
        let services = profile.settings.services.filter { $0.enabled }
        var jobs: [(ServiceTarget, String)] = []
        rotate += 1
        for s in services where !s.probes.isEmpty {
            // rotate across the independent endpoints of a service so one dead URL never defines the service
            jobs.append((s, s.probes[(rotate + jobs.count) % s.probes.count]))
        }
        let res = await runProbes(server: server, jobs: jobs)
        wakeProbe = false
        // A failed routine probe is only a hint: escalate to the confirmed path.
        for (s, r) in res where !r.ok && book.knownGood[r.url] != nil && s.id != ServiceTarget.baselineID && auto && observing == nil {
            await onSuspicion(PassiveSignal(service: s.id, reason: "плановая проба не прошла (\(r.error ?? "ошибка"))"))
            break
        }
        var interval = tuning.routineInterval
        if constrained { interval *= 3 } else if expensive { interval *= 1.5 }
        if observing != nil { interval = 20 }
        let now = Date().timeIntervalSince1970
        nextRoutine = now + interval * Double.random(in: 0.85...1.15)
    }

    // MARK: Return to the primary server

    private func checkPrimaryReturn(now: Double) async {
        guard let primary = pool.first(where: { $0.id == primaryID }),
              !book.isQuarantined(primaryID, now: now), now >= cooldownUntil else {
            nextPrimaryCheck = now + 60
            return
        }
        busy = "проверка основного"
        defer { busy = nil; dirty = true }
        await fullRound(server: primary)
        let t = Date().timeIntervalSince1970
        let hp = book.health(server: primaryID, services: profile.settings.services, now: t)
        let ha = book.health(server: activeID, services: profile.settings.services, now: t)
        let good = (hp.overall ?? 0) >= 70 && (hp.services[ServiceTarget.baselineID]?.score ?? 0) >= 60
        if good && (hp.overall ?? 0) >= (ha.overall ?? 0) - 5 { primaryStreak += 1 } else { primaryStreak = 0 }
        say("info", "Основной \(primary.name): \(Int(hp.overall ?? 0)) (серия \(primaryStreak)/\(tuning.returnStreak))")
        nextPrimaryCheck = t + tuning.returnInterval
        if primaryStreak >= tuning.returnStreak {
            await waitForQuiet(maxWait: 90)
            do {
                try await switchTo(primary, reason: "основной стабилен", quarantineOld: false, manual: false)
            } catch {
                say("err", "Возврат не удался: \(error.localizedDescription)")
            }
        }
    }

    /// Prefer to move at a quiet moment: switching interrupts connections.
    private func waitForQuiet(maxWait: Double) async {
        let deadline = Date().timeIntervalSince1970 + maxWait
        while Date().timeIntervalSince1970 < deadline, !Task.isCancelled {
            if let s = try? await clash.connections() {
                let before = s.downloadTotal + s.uploadTotal
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let s2 = try? await clash.connections(), (s2.downloadTotal + s2.uploadTotal - before) < 40_000 { return }
            } else { return }
        }
    }

    // MARK: Probing

    /// Baseline (1 endpoint) + two endpoints for each enabled service.
    private func fullRound(server: Server) async {
        var jobs: [(ServiceTarget, String)] = []
        for s in profile.settings.services where s.enabled {
            let n = s.id == ServiceTarget.baselineID ? 1 : 2
            for u in s.probes.prefix(n) { jobs.append((s, u)) }
        }
        _ = await runProbes(server: server, jobs: jobs)
    }

    @discardableResult
    private func runProbes(server: Server, jobs: [(ServiceTarget, String)]) async -> [(ServiceTarget, ProbeOutcome)] {
        let tag = server.tag
        let timeout = tuning.probeTimeoutMs
        let gate = self.gate
        let clash = self.clash
        let results = await withTaskGroup(of: (Int, ProbeOutcome).self) { group -> [(Int, ProbeOutcome)] in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    await gate.acquire()
                    let r = await clash.delay(tag: tag, url: job.1, timeoutMs: timeout)
                    await gate.release()
                    return (i, r)
                }
            }
            var out: [(Int, ProbeOutcome)] = []
            for await r in group { out.append(r) }
            return out
        }
        let now = Date().timeIntervalSince1970
        var paired: [(ServiceTarget, ProbeOutcome)] = []
        for (i, r) in results.sorted(by: { $0.0 < $1.0 }) {
            let svc = jobs[i].0
            // "api" errors mean our own control channel failed, not the server: never score them
            if r.error != "api" {
                book.record(server: server.id, service: svc.id, url: r.url, ok: r.ok, ms: r.ms, now: now)
            }
            paired.append((svc, r))
        }
        dirty = true
        return paired
    }

    // MARK: Helpers

    private func service(_ id: String) -> ServiceTarget? { profile.settings.services.first { $0.id == id } }
    private func tag(_ id: String) -> String { "s-" + id }
    private func name(_ id: String) -> String { pool.first { $0.id == id }?.name ?? id }

    private func say(_ level: String, _ text: String) {
        events.append(EventLine(t: Date().timeIntervalSince1970, level: level, text: text))
        if events.count > 120 { events.removeFirst(events.count - 120) }
        log.info("\(text, privacy: .public)")
        dirty = true
    }

    private func sampleMemory() {
        let avail = Int(os_proc_available_memory() / 1_048_576)
        availMemMB = avail
        if avail < 8 && !lowMemory {
            lowMemory = true
            say("warn", "Мало памяти (\(avail) МБ): проверки замедлены")
        } else if avail > 14 && lowMemory {
            lowMemory = false
            say("info", "Память в норме: проверки возобновлены")
        }
    }

    private func snapshot() -> TunnelState {
        let now = Date().timeIntervalSince1970
        var st = TunnelState()
        st.phase = phase
        st.activeID = activeID
        st.primaryID = primaryID
        st.auto = auto
        for s in pool { st.health[s.id] = book.health(server: s.id, services: profile.settings.services, now: now) }
        for s in profile.settings.services where s.enabled {
            st.history[s.id] = book.recentDots(server: activeID, service: s.id)
        }
        st.events = Array(events.suffix(60))
        st.net = netUp ? netKind : "none"
        st.availMemMB = availMemMB
        st.upBps = upBps
        st.downBps = downBps
        st.totalUp = totals.up
        st.totalDown = totals.down
        st.conns = connCount
        st.lastSwitch = lastSwitch
        st.observing = observing != nil
        st.busy = busy
        st.updated = now
        return st
    }

    private func persist(force: Bool) {
        let now = Date().timeIntervalSince1970
        guard force || (dirty && now - lastPersist >= 5) else { return }
        lastPersist = now
        dirty = false
        Store.saveState(snapshot())
    }
}

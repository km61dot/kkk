import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.custom.proxyclient", category: "tunnel")
    private var bridge: LibboxBridge?
    private var engine: HealthEngine?
    private var memorySource: DispatchSourceMemoryPressure?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                try await self.boot()
                Store.saveError(nil)
                completionHandler(nil)
            } catch {
                let text = "Запуск туннеля не удался: \(error.localizedDescription)"
                self.log.error("\(text, privacy: .public)")
                Store.saveError(text + "\n\n" + (self.bridge?.logText() ?? ""))
                var st = TunnelState()
                st.phase = "error"
                st.updated = Date().timeIntervalSince1970
                Store.saveState(st)
                self.bridge?.stop()
                self.bridge = nil
                completionHandler(error)
            }
        }
    }

    private func boot() async throws {
        let profile = Store.loadProfile()
        let pool = profile.pool
        guard !pool.isEmpty else { throw ConfigError.emptyPool }

        var starting = TunnelState()
        starting.phase = "starting"
        starting.updated = Date().timeIntervalSince1970
        Store.saveState(starting)

        // Resume on the last active server if it is still in the pool.
        let saved = Store.loadActive()
        let activeID = pool.first(where: { $0.id == saved })?.id ?? pool[0].id

        let port = Int.random(in: 20000...59999)
        let secret = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let runtime = RuntimeParams(clashPort: port, clashSecret: secret, activeID: activeID)

        let config = try ConfigBuilder.build(profile: profile, runtime: runtime)
        Store.saveConfigPreview(try ConfigBuilder.build(profile: profile, runtime: runtime, redact: true))

        let bridge = LibboxBridge(provider: self)
        self.bridge = bridge
        try await bridge.start(config: config, baseDir: try Store.dir("singbox"), mtu: profile.settings.mtu)

        let clash = ClashClient(port: port, secret: secret)
        guard await clash.waitReady() else {
            throw BridgeError.msg("Clash API не поднялся (нет with_clash_api в сборке libbox?)")
        }

        let engine = HealthEngine(clash: clash, profile: profile, activeID: activeID)
        self.engine = engine
        bridge.onPath = { info in Task { await engine.networkChanged(info) } }
        await engine.start()
        installMemoryPressure(engine)
        log.info("tunnel up, available memory \(os_proc_available_memory() / 1_048_576) MB")
    }

    private func installMemoryPressure(_ engine: HealthEngine) {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        src.setEventHandler { [weak src] in
            let critical = src?.data.contains(.critical) ?? false
            Task { await engine.memoryPressure(critical: critical) }
        }
        src.resume()
        memorySource = src
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        memorySource?.cancel()
        memorySource = nil
        Task {
            await engine?.stop()
            engine = nil
            bridge?.stop()
            bridge = nil
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let cmd = try? JSONDecoder().decode(Command.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        if cmd.cmd == "logs" {
            completionHandler?(Data((bridge?.logText() ?? "").utf8))
            return
        }
        guard let engine else {
            completionHandler?(nil)
            return
        }
        Task { completionHandler?(await engine.handle(cmd)) }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        bridge?.pause()
        Task { await engine?.pause(); completionHandler() }
    }

    override func wake() {
        bridge?.wake()
        Task { await engine?.resume() }
    }
}

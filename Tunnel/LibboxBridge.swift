import Foundation
import Libbox
import Network
import NetworkExtension
import os

// =====================================================================================
//  THE ONLY FILE THAT TOUCHES THE Libbox API.
//  Written against sing-box 1.11.x libbox (gomobile ObjC bindings) from the sing-box-for-apple
//  reference client. It has NOT been compiled by the author (no Mac / no Xcode available).
//  If CI reports "does not conform to LibboxPlatformInterfaceProtocol" or a missing symbol,
//  compare with the header dump in the "libbox-headers" CI artifact and fix ONLY this file.
// =====================================================================================

struct PathInfo {
    var kind: String          // wifi, cellular, wired, other, none
    var satisfied: Bool
    var expensive: Bool
    var constrained: Bool
}

enum BridgeError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self { case .msg(let m): return m }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// Libbox calls openTun synchronously from a Go thread; we must hop to async NetworkExtension APIs and wait.
private func runBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    guard let r = box.value else { throw BridgeError.msg("runBlocking: no result") }
    return try r.get()
}

final class LibboxBridge: NSObject, LibboxPlatformInterfaceProtocol {
    private let provider: NEPacketTunnelProvider
    private var service: LibboxBoxService?
    private var monitor: NWPathMonitor?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private let queue = DispatchQueue(label: "pc.bridge.path")
    private let logger = Logger(subsystem: "com.custom.proxyclient", category: "core")
    private var mtu = 1400

    private let linesLock = NSLock()
    private var lines: [String] = []

    var onPath: ((PathInfo) -> Void)?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    // MARK: Lifecycle

    func start(config: String, baseDir: URL, mtu: Int) async throws {
        self.mtu = mtu
        let fm = FileManager.default
        let work = baseDir.appendingPathComponent("work", isDirectory: true)
        let temp = baseDir.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)

        var err: NSError?
        _ = LibboxSetup(baseDir.path, work.path, temp.path, false, &err)
        if let err { throw err }
        // Go side: GC tuning + soft memory limit (see libbox SetMemoryLimit); keeps us under the Jetsam ceiling.
        LibboxSetMemoryLimit(true)

        let svc = LibboxNewService(config, self, &err)
        if let err { throw err }
        guard let svc else { throw BridgeError.msg("LibboxNewService returned nil") }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try svc.start(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
        service = svc
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if let svc = service { try? svc.close() }
        service = nil
    }

    func pause() { service?.pause() }
    func wake() { service?.wake() }

    func logText() -> String {
        linesLock.lock(); defer { linesLock.unlock() }
        return lines.joined(separator: "\n")
    }

    // MARK: LibboxPlatformInterfaceProtocol

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let ret0_ else { throw BridgeError.msg("openTun: missing return pointer") }
        let settings = makeSettings()
        let p = provider
        try runBlocking { try await p.setTunnelNetworkSettings(settings) }
        networkSettings = settings
        if let fd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        if fd != -1 {
            ret0_.pointee = fd
            return
        }
        throw BridgeError.msg("missing TUN file descriptor")
    }

    private func makeSettings() -> NEPacketTunnelNetworkSettings {
        // Addresses must match the "tun" inbound in ConfigBuilder.
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        v4.includedRoutes = [NEIPv4Route.default()]
        s.ipv4Settings = v4
        let v6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        v6.includedRoutes = [NEIPv6Route.default()]
        s.ipv6Settings = v6
        let dns = NEDNSSettings(servers: ["172.19.0.2"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        s.dnsSettings = dns
        s.mtu = NSNumber(value: mtu)
        return s
    }

    // Both naming generations of the auto-detect hooks are provided; whichever the header wants is satisfied.
    func usePlatformAutoDetectControl() -> Bool { true }
    func autoDetectControl(_ fd: Int32) throws {}
    func usePlatformAutoDetectInterfaceControl() -> Bool { true }
    func autoDetectInterfaceControl(_ fd: Int32) throws {}

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        let m = String(message.prefix(400))
        linesLock.lock()
        lines.append(m)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        linesLock.unlock()
        logger.info("\(m, privacy: .public)")
    }

    func useProcFS() -> Bool { false }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32,
                             ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw BridgeError.msg("not implemented")
    }

    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { "" }

    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw BridgeError.msg("not implemented")
    }

    func usePlatformDefaultInterfaceMonitor() -> Bool { true }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { [weak self] path in
            self?.report(path, to: listener)
        }
        m.start(queue: queue)
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        monitor?.cancel()
        monitor = nil
    }

    private func report(_ path: NWPath, to listener: LibboxInterfaceUpdateListenerProtocol) {
        var kind = "none"
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi) { kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { kind = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { kind = "wired" }
            else { kind = "other" }
            if let iface = path.availableInterfaces.first {
                listener.updateDefaultInterface(iface.name, interfaceIndex: Int32(iface.index),
                                                isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            }
        } else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
        }
        onPath?(PathInfo(kind: kind, satisfied: path.status == .satisfied,
                         expensive: path.isExpensive, constrained: path.isConstrained))
    }

    // Go's own net.Interfaces works inside the extension, so the platform getter is not used.
    func usePlatformInterfaceGetter() -> Bool { false }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw BridgeError.msg("not implemented")
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }

    func clearDNSCache() {
        guard let settings = networkSettings else { return }
        provider.reasserting = true
        provider.setTunnelNetworkSettings(nil) { _ in }
        provider.setTunnelNetworkSettings(settings) { _ in }
        provider.reasserting = false
    }

    func readWIFIState() -> LibboxWIFIState? { nil }
}

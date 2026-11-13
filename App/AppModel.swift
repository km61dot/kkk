import SwiftUI
import NetworkExtension
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var profile: Profile
    @Published var status: NEVPNStatus = .invalid
    @Published var state: TunnelState?
    @Published var startError: String?
    @Published var storeError: String?
    @Published var toast: String?
    @Published var coreLog: String = ""
    @Published var working = false
    private var runningProfile: Profile?
    private var manager: NETunnelProviderManager?
    private var timer: Timer?
    private var statusObserver: NSObjectProtocol?

    init() {
        profile = Store.loadProfile()
        do { _ = try Store.container() } catch { storeError = error.localizedDescription }
        Task { await prepare() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Derived

    var isOn: Bool { status == .connected || status == .connecting || status == .reasserting }
    var isConnected: Bool { status == .connected }

    var statusTitle: String {
        switch status {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .reasserting: return "Переподключение…"
        case .disconnecting: return "Отключение…"
        case .disconnected: return "Отключено"
        default: return "Не настроено"
        }
    }

    var needsRestart: Bool {
        guard isOn, let running = runningProfile else { return false }
        return running.pool != profile.pool || running.settings != profile.settings
    }

    func server(_ id: String?) -> Server? {
        guard let id else { return nil }
        return profile.servers.first { $0.id == id }
    }

    // MARK: Persistence

    func persist() {
        do { try Store.saveProfile(profile) } catch { storeError = error.localizedDescription }
    }

    func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == text { toast = nil }
        }
    }

    // MARK: VPN manager

    private func prepare() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            if let m = all.first { attach(m) }
        } catch {
            storeError = "Не удалось загрузить VPN-конфигурацию: \(error.localizedDescription)"
        }
        refresh()
    }

    private func attach(_ m: NETunnelProviderManager) {
        manager = m
        status = m.connection.status
        if let o = statusObserver { NotificationCenter.default.removeObserver(o) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = self.manager?.connection.status ?? .invalid
                if self.status == .connected, self.runningProfile == nil { self.runningProfile = self.profile }
                if self.status == .disconnected { self.runningProfile = nil }
                self.refresh()
            }
        }
        if status == .connected { runningProfile = profile }
    }

    static func extensionBundleID() -> String {
        if let url = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
           let appex = items.first(where: { $0.pathExtension == "appex" }),
           let id = Bundle(url: appex)?.bundleIdentifier {
            return id
        }
        return (Bundle.main.bundleIdentifier ?? "com.custom.proxyclient") + ".PacketTunnel"
    }

    func connect() async {
        guard !profile.pool.isEmpty else {
            flash("Добавь хотя бы один поддерживаемый сервер")
            return
        }
        working = true
        defer { working = false }
        persist()
        Store.saveError(nil)
        startError = nil
        do {
            let mgr = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionBundleID()
            proto.serverAddress = "Smart Proxy"
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "Smart Proxy"
            mgr.isEnabled = true
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
            attach(mgr)
            try mgr.connection.startVPNTunnel()
            runningProfile = profile
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            startError = "Не удалось запустить: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func toggle() {
        if isOn { disconnect() } else { Task { await connect() } }
    }

    func restart() async {
        disconnect()
        for _ in 0..<40 {
            if status == .disconnected || status == .invalid { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await connect()
    }

    // MARK: State polling and commands

    func refresh() {
        status = manager?.connection.status ?? status
        if isOn, let session = manager?.connection as? NETunnelProviderSession {
            send(Command(cmd: "state"), session: session) { [weak self] data in
                guard let data, let st = try? JSONDecoder().decode(TunnelState.self, from: data) else { return }
                Task { @MainActor in self?.state = st }
            }
        } else {
            state = Store.loadState()
            if status == .disconnected { startError = startError ?? Store.loadError() }
        }
    }

    private func send(_ c: Command, session: NETunnelProviderSession, reply: @escaping (Data?) -> Void) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        do { try session.sendProviderMessage(data) { reply($0) } } catch { reply(nil) }
    }

    func command(_ c: Command) {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        send(c, session: session) { [weak self] data in
            guard let data, let st = try? JSONDecoder().decode(TunnelState.self, from: data) else { return }
            Task { @MainActor in self?.state = st }
        }
    }

    func fetchCoreLog() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            coreLog = Store.loadError() ?? "Туннель не запущен"
            return
        }
        send(Command(cmd: "logs"), session: session) { [weak self] data in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in self?.coreLog = text.isEmpty ? "Лог пуст" : text }
        }
    }

    func select(_ id: String) {
        command(Command(cmd: "select", arg: id))
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    func setAuto(_ on: Bool) {
        profile.settings.autoFailover = on
        persist()
        command(Command(cmd: "auto", flag: on))
    }

    func probeNow() { command(Command(cmd: "probe")); flash("Проверка запущена") }
    func resetConnections() { command(Command(cmd: "reset")); flash("Соединения сброшены") }

    // MARK: Servers

    @discardableResult
    func importText(_ text: String, source: String? = nil) -> Int {
        let (found, skipped) = LinkParser.parseMany(text)
        var added = 0
        for var s in found {
            s.source = source
            if let i = profile.servers.firstIndex(where: { $0.id == s.id }) {
                profile.servers[i].name = s.name
                profile.servers[i].params = s.params
                profile.servers[i].unsupported = s.unsupported
            } else {
                profile.servers.append(s)
                added += 1
            }
        }
        persist()
        if found.isEmpty { flash("Ссылки не найдены") }
        else { flash("Добавлено: \(added)" + (skipped.isEmpty ? "" : ", пропущено: \(skipped.count)")) }
        return added
    }

    func pasteFromClipboard() {
        guard let t = UIPasteboard.general.string, !t.isEmpty else { flash("Буфер пуст"); return }
        importText(t)
    }

    func addSubscription(name: String, url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), u.scheme?.hasPrefix("http") == true else { flash("Некорректная ссылка"); return }
        let sub = Subscription(id: Server.makeID(kind: .vless, host: trimmed, port: 0, secret: "sub"),
                               name: name.isEmpty ? (u.host ?? "Подписка") : name, url: trimmed, updated: nil)
        if !profile.subscriptions.contains(where: { $0.id == sub.id }) { profile.subscriptions.append(sub) }
        persist()
        await refreshSubscription(sub.id)
    }

    func refreshSubscription(_ id: String) async {
        guard let i = profile.subscriptions.firstIndex(where: { $0.id == id }),
              let url = URL(string: profile.subscriptions[i].url) else { return }
        working = true
        defer { working = false }
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("SmartProxy/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let body = String(decoding: data, as: UTF8.self)
            let (found, _) = LinkParser.parseMany(body)
            guard !found.isEmpty else { flash("В подписке нет поддерживаемых ссылок"); return }
            let old = Dictionary(profile.servers.filter { $0.source == id }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            profile.servers.removeAll { $0.source == id }
            for var s in found {
                s.source = id
                if let prev = old[s.id] { s.enabled = prev.enabled && s.unsupported == nil }
                if !profile.servers.contains(where: { $0.id == s.id }) { profile.servers.append(s) }
            }
            if let j = profile.subscriptions.firstIndex(where: { $0.id == id }) { profile.subscriptions[j].updated = Date() }
            persist()
            flash("Подписка обновлена: \(found.count)")
        } catch {
            flash("Ошибка загрузки: \(error.localizedDescription)")
        }
    }

    func removeSubscription(_ id: String) {
        profile.subscriptions.removeAll { $0.id == id }
        profile.servers.removeAll { $0.source == id }
        persist()
    }

    func delete(_ ids: [String]) {
        profile.servers.removeAll { ids.contains($0.id) }
        if let p = profile.primaryID, ids.contains(p) { profile.primaryID = nil }
        persist()
    }

    func setPrimary(_ id: String) {
        profile.primaryID = id
        if let i = profile.servers.firstIndex(where: { $0.id == id }) {
            profile.servers[i].enabled = profile.servers[i].unsupported == nil
        }
        persist()
        flash("Основной сервер изменён" + (isOn ? " — примени перезапуском" : ""))
    }

    func role(of id: String) -> String? {
        let pool = profile.pool
        guard let i = pool.firstIndex(where: { $0.id == id }) else { return nil }
        return i == 0 ? "Основной" : "Резерв \(i)"
    }
}

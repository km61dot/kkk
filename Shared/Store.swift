import Foundation

/// Resolves the real App Group id at runtime. Re-signing tools (Sideloadly etc.) may rewrite
/// group identifiers, so we read it from the embedded provisioning profile first.
enum AppGroup {
    static let fallback = "group.com.custom.proxyclient"

    static let id: String = {
        if let g = AppGroup.fromProvision() { return g }
        if let g = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String, !g.isEmpty { return g }
        return fallback
    }()

    private static func fromProvision() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let obj = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let ent = obj["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String] else { return nil }
        return groups.first
    }
}

enum StoreError: LocalizedError {
    case noContainer(String)
    var errorDescription: String? {
        switch self {
        case .noContainer(let id): return "App Group недоступна: \(id). Проверь подпись и entitlements."
        }
    }
}

enum Store {
    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) else {
            throw StoreError.noContainer(AppGroup.id)
        }
        return url
    }

    private static func file(_ name: String) throws -> URL { try container().appendingPathComponent(name) }

    static func dir(_ name: String) throws -> URL {
        let u = try container().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // Profile (app writes, extension reads)
    static func saveProfile(_ p: Profile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(p).write(to: file("profile.json"), options: .atomic)
    }

    static func loadProfile() -> Profile {
        guard let url = try? file("profile.json"), let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Profile.self, from: d) else { return Profile() }
        return p
    }

    // State (extension writes, app reads when the tunnel is not answering)
    static func saveState(_ s: TunnelState) {
        guard let url = try? file("state.json"), let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
    }

    static func loadState() -> TunnelState? {
        guard let url = try? file("state.json"), let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TunnelState.self, from: d)
    }

    // Last active server id (restored on the next start)
    static func saveActive(_ id: String) {
        guard let url = try? file("active.txt") else { return }
        try? Data(id.utf8).write(to: url, options: .atomic)
    }

    static func loadActive() -> String? {
        guard let url = try? file("active.txt"), let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.isEmpty ? nil : s
    }

    // Startup error: iOS shows nothing useful when a tunnel fails to start, so we keep our own.
    static func saveError(_ text: String?) {
        guard let url = try? file("lasterror.txt") else { return }
        if let text { try? Data(text.utf8).write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
    }

    static func loadError() -> String? {
        guard let url = try? file("lasterror.txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Generated config with secrets masked (for the diagnostics screen)
    static func saveConfigPreview(_ text: String) {
        guard let url = try? file("last-config.json") else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    static func loadConfigPreview() -> String? {
        guard let url = try? file("last-config.json") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

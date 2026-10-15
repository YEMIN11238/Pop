import Foundation
import Security
import Combine

enum SecretStore {
    private static let keychainService = "com.local.pop.credentials"
    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PopError.message("钥匙串删除失败（\(status)）。")
            }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PopError.message("钥匙串保存失败（\(status)）。") }
    }
    static func serviceKey(_ id: UUID) -> String { "service.\(id.uuidString)" }
    static func pluginKey(_ id: UUID, option: String) -> String { "plugin.\(id.uuidString).\(option)" }
}

struct ShortcutConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

enum AppStorage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pop", isDirectory: true)
    }()
    static func load<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, file: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(file), options: .atomic)
    }
}

struct ConfigurationExport: Codable {
    var format = "PopConfiguration"
    var version = 1
    var preferences: AppPreferences
    var shortcuts: [String: ShortcutConfig]
    /// Preferences export includes installed plugin files, but not history or Keychain values.
    var plugins: [PortableBackup.File]?
}

@MainActor
final class HistoryRepository: ObservableObject {
    static let shared = HistoryRepository()
    @Published private(set) var items = AppStorage.load([HistoryItem].self, file: "history.json") ?? []

    func replace(_ values: [HistoryItem], limit: Int = 10000) throws {
        try DataImportCoordinator.requireAvailable()
        let latest = Array(values.prefix(max(100, min(100000, limit))))
        try AppStorage.save(latest, file: "history.json")
        publishPersisted(latest)
    }

    /// Import callers must persist every file successfully before publishing.
    func publishPersisted(_ values: [HistoryItem]) { items = values }
}

@MainActor
final class ConfigurationRepository: ObservableObject {
    static let shared = ConfigurationRepository()
    @Published private(set) var preferences = AppStorage.load(AppPreferences.self, file: "preferences.json") ?? AppPreferences()
    @Published private(set) var shortcuts = AppStorage.load([String: ShortcutConfig].self, file: "shortcuts.json") ?? [:]
    private var saving = false

    func save(preferences next: AppPreferences, shortcuts keys: [String: ShortcutConfig]) throws {
        try DataImportCoordinator.requireAvailable()
        guard !saving else { return }
        saving = true
        defer { saving = false }
        try AppStorage.save(next, file: "preferences.json")
        try AppStorage.save(keys, file: "shortcuts.json")
        publishPersisted(preferences: next, shortcuts: keys)
    }

    /// No disk writes: used after a complete import transaction has committed.
    func publishPersisted(preferences next: AppPreferences, shortcuts keys: [String: ShortcutConfig]) {
        if preferences != next { preferences = next }
        if shortcuts != keys { shortcuts = keys }
    }
}

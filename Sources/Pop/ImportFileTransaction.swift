import Foundation

/// Imports are synchronous on the main actor. The gate also prevents a nested
/// run-loop callback from starting another import or plugin worker during cancel.
@MainActor
enum DataImportCoordinator {
    private(set) static var isImporting = false

    enum Failure: LocalizedError {
        case alreadyImporting
        var errorDescription: String? { "正在导入数据，请等待当前操作完成。" }
    }

    static func requireAvailable() throws {
        if isImporting { throw Failure.alreadyImporting }
    }

    static func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
        try requireAvailable()
        isImporting = true
        defer { isImporting = false }
        return try operation()
    }
}

/// A raw, presence-preserving recovery snapshot. Restoration can only touch the
/// four fixed app-data entries; a missing original is restored by removing the
/// newly imported entry. Plugins includes all hidden .sandboxes contents.
struct ImportFileTransaction {
    enum Item: String, CaseIterable, Codable {
        case preferences = "preferences.json"
        case shortcuts = "shortcuts.json"
        case history = "history.json"
        case plugins = "Plugins"
    }

    struct RecoveryFailure: Equatable {
        let item: Item
        let message: String
    }

    struct Failure: LocalizedError {
        let reason: String
        let recoveryURL: URL
        let portableRecoveryURL: URL?
        let recoveryFailures: [RecoveryFailure]
        let importStarted: Bool

        var errorDescription: String? {
            var message = "导入失败：" + reason
            if importStarted {
                if recoveryFailures.isEmpty { message += "\n已恢复导入前的文件，内存中的设置与历史未替换。" }
                else {
                    message += "\n自动恢复未完成：" + recoveryFailures.map { $0.item.rawValue + "：" + $0.message }.joined(separator: "；")
                }
            } else { message += "\n尚未开始替换应用数据。" }
            if let portableRecoveryURL { message += "\n导入前完整备份：" + portableRecoveryURL.path }
            message += "\n原始文件快照：" + recoveryURL.path
            return message
        }
    }

    private struct Entry: Codable {
        let item: Item
        let present: Bool
    }
    private struct Manifest: Codable {
        var format = "PopImportFileSnapshot"
        var version = 1
        let originalRoot: String
        let entries: [Entry]
    }

    let rootURL: URL
    let recoveryURL: URL
    let portableRecoveryURL: URL?
    private let entries: [Entry]
    private let manager = FileManager.default

    init(rootURL: URL, portableRecoveryURL: URL? = nil) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.portableRecoveryURL = portableRecoveryURL
        recoveryURL = self.rootURL.appendingPathComponent("Backups/before-import-files-" + UUID().uuidString, isDirectory: true)
        let files = recoveryURL.appendingPathComponent("files", isDirectory: true)
        var saved: [Entry] = []
        do {
            try manager.createDirectory(at: files, withIntermediateDirectories: true)
            for item in Item.allCases {
                let source = self.rootURL.appendingPathComponent(item.rawValue)
                let present = try Self.exists(source)
                if present { try manager.copyItem(at: source, to: files.appendingPathComponent(item.rawValue)) }
                saved.append(Entry(item: item, present: present))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Manifest(originalRoot: self.rootURL.path, entries: saved))
                .write(to: recoveryURL.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            throw Failure(reason: "无法创建完整恢复快照：" + error.localizedDescription,
                          recoveryURL: recoveryURL, portableRecoveryURL: portableRecoveryURL,
                          recoveryFailures: [], importStarted: false)
        }
        entries = saved
    }

    /// The caller publishes repository state only after this returns successfully.
    /// beforeRestore is an isolated-fixture fault hook, unused by app imports.
    func perform<T>(beforeRestore: ((Item) throws -> Void)? = nil,
                    _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            let original = error.localizedDescription
            let failures = restore(beforeItem: beforeRestore)
            throw Failure(reason: original, recoveryURL: recoveryURL,
                          portableRecoveryURL: portableRecoveryURL,
                          recoveryFailures: failures, importStarted: true)
        }
    }

    private func restore(beforeItem: ((Item) throws -> Void)?) -> [RecoveryFailure] {
        var failures: [RecoveryFailure] = []
        for entry in entries {
            do {
                try beforeItem?(entry.item)
                let target = rootURL.appendingPathComponent(entry.item.rawValue)
                if entry.present {
                    // Prepare the complete old entry before removing its imported
                    // replacement. If copy fails, that replacement stays intact.
                    let source = recoveryURL.appendingPathComponent("files").appendingPathComponent(entry.item.rawValue)
                    let staged = recoveryURL.appendingPathComponent("restore-" + UUID().uuidString)
                    try manager.copyItem(at: source, to: staged)
                    if try Self.exists(target) { try manager.removeItem(at: target) }
                    try manager.moveItem(at: staged, to: target)
                } else if try Self.exists(target) {
                    try manager.removeItem(at: target)
                }
            } catch {
                failures.append(RecoveryFailure(item: entry.item, message: error.localizedDescription))
            }
        }
        return failures
    }

    private static func exists(_ url: URL) throws -> Bool {
        do {
            // attributesOfItem also sees a dangling symbolic link; fileExists
            // would incorrectly treat that original entry as absent.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return false }
            throw error
        }
    }
}

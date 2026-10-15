import Foundation

@MainActor
enum ImportFileTransactionSelfCheck {
    static func run() throws -> [String] {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("Pop-import-check-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try manager.removeItem(at: directory) }
            catch { fputs("Import fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "PopImportCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func injected(_ message: String) -> NSError {
            NSError(domain: "PopImportInjected", code: 9, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func root(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("unrelated-user-file".utf8).write(to: url.appendingPathComponent("untouched.txt"))
            return url
        }
        func plugins(_ root: URL, value: String) throws {
            let folder = root.appendingPathComponent("Plugins")
            if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
            let cache = folder.appendingPathComponent(".sandboxes/com.example.fixture/nested")
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data((value + "-package").utf8).write(to: folder.appendingPathComponent("main.js"))
            try Data([0, 1, 255] + Array((value + "-cache").utf8)).write(to: cache.appendingPathComponent(".persistent.bin"))
        }
        func original(_ root: URL) throws {
            for name in ["preferences.json", "shortcuts.json", "history.json"] {
                try Data(("old-" + name + "\r\n").utf8).write(to: root.appendingPathComponent(name))
            }
            try plugins(root, value: "old")
        }
        func files(_ root: URL) throws -> [String: Data] {
            var values: [String: Data] = [:]
            for item in ImportFileTransaction.Item.allCases {
                let url = root.appendingPathComponent(item.rawValue)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    values[item.rawValue + "/"] = Data()
                    guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { throw injected("fixture enumeration") }
                    while let child = enumerator.nextObject() as? URL {
                        if try child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                            values[String(child.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: child)
                        }
                    }
                } else { values[item.rawValue] = try Data(contentsOf: url) }
            }
            return values
        }
        func mutate(_ root: URL, step: Int) throws {
            switch step {
            case 0: try plugins(root, value: "new")
            case 1: try Data("new preferences".utf8).write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
            case 2: try Data("new shortcuts".utf8).write(to: root.appendingPathComponent("shortcuts.json"), options: .atomic)
            default: try Data("new history".utf8).write(to: root.appendingPathComponent("history.json"), options: .atomic)
            }
        }

        for stop in 0...3 {
            let location = try root("after-step-\(stop)")
            try original(location)
            let before = try files(location)
            let transaction = try ImportFileTransaction(rootURL: location)
            var failure: ImportFileTransaction.Failure?
            do {
                try transaction.perform {
                    for step in 0...3 {
                        try mutate(location, step: step)
                        if step == stop { throw injected("commit stage \(stop)") }
                    }
                }
            } catch let error as ImportFileTransaction.Failure { failure = error }
            try check(failure?.recoveryFailures.isEmpty == true && (try files(location)) == before, "failure stage \(stop) did not restore complete original data/cache")
            try check(try String(contentsOf: location.appendingPathComponent("untouched.txt"), encoding: .utf8) == "unrelated-user-file", "rollback changed a path outside the four entries")
        }

        let actualFailureRoot = try root("actual-filesystem-error")
        try original(actualFailureRoot)
        let actualBefore = try files(actualFailureRoot)
        let actualTransaction = try ImportFileTransaction(rootURL: actualFailureRoot)
        var actualFailure: ImportFileTransaction.Failure?
        do {
            try actualTransaction.perform {
                try mutate(actualFailureRoot, step: 0); try mutate(actualFailureRoot, step: 1)
                let blocked = actualFailureRoot.appendingPathComponent("shortcuts.json")
                try manager.removeItem(at: blocked)
                try manager.createDirectory(at: blocked, withIntermediateDirectories: false)
                try Data("cannot replace a directory".utf8).write(to: blocked, options: .atomic)
            }
        } catch let error as ImportFileTransaction.Failure { actualFailure = error }
        try check(actualFailure?.recoveryFailures.isEmpty == true && (try files(actualFailureRoot)) == actualBefore, "actual Foundation write failure did not roll back earlier imports")

        for keepPreferences in [false, true] {
            let location = try root("missing-\(keepPreferences)")
            if keepPreferences { try Data("existing preferences".utf8).write(to: location.appendingPathComponent("preferences.json")) }
            let before = try files(location)
            let transaction = try ImportFileTransaction(rootURL: location)
            var rejected = false
            do {
                try transaction.perform {
                    for step in 0...3 { try mutate(location, step: step) }
                    throw injected("after creating missing entries")
                }
            } catch let error as ImportFileTransaction.Failure { rejected = error.recoveryFailures.isEmpty }
            try check(rejected && (try files(location)) == before, "rollback did not preserve original absent entries")
        }

        let partialRoot = try root("partial-recovery")
        try original(partialRoot)
        let portable = partialRoot.appendingPathComponent("Backups/original.popbackup")
        let partialTransaction = try ImportFileTransaction(rootURL: partialRoot, portableRecoveryURL: portable)
        var partialFailure: ImportFileTransaction.Failure?
        do {
            try partialTransaction.perform(beforeRestore: { item in
                if item == .preferences || item == .plugins { throw injected("restore blocked: " + item.rawValue) }
            }) {
                for step in 0...3 { try mutate(partialRoot, step: step) }
                throw injected("commit failed")
            }
        } catch let error as ImportFileTransaction.Failure { partialFailure = error }
        try check(Set(partialFailure?.recoveryFailures.map { $0.item.rawValue } ?? []) == Set(["preferences.json", "Plugins"]), "recovery did not independently collect every failed entry")
        let remaining = try files(partialRoot)
        try check(remaining["shortcuts.json"] == Data("old-shortcuts.json\r\n".utf8) && remaining["history.json"] == Data("old-history.json\r\n".utf8), "one failed recovery prevented the other entries from restoring")
        try check(partialFailure?.localizedDescription.contains(portable.path) == true && partialFailure?.localizedDescription.contains(partialTransaction.recoveryURL.path) == true, "failed recovery omitted recovery paths")
        try check(manager.fileExists(atPath: partialTransaction.recoveryURL.appendingPathComponent("files/Plugins/.sandboxes/com.example.fixture/nested/.persistent.bin").path), "raw recovery snapshot did not retain hidden plugin cache")

        let successRoot = try root("successful-settings-import")
        try original(successRoot)
        let success = try ImportFileTransaction(rootURL: successRoot)
        try success.perform { for step in 0...2 { try mutate(successRoot, step: step) } }
        let committed = try files(successRoot)
        try check(committed["preferences.json"] == Data("new preferences".utf8) && committed["history.json"] == Data("old-history.json\r\n".utf8), "successful settings import changed history or failed to commit")

        var nestedEntered = false, nestedRejected = false, outerFailed = false
        do {
            try DataImportCoordinator.withExclusiveAccess {
                try check(DataImportCoordinator.isImporting, "import gate was not set")
                do { try DataImportCoordinator.withExclusiveAccess { nestedEntered = true } }
                catch DataImportCoordinator.Failure.alreadyImporting { nestedRejected = true }
                try check(DataImportCoordinator.isImporting, "rejected nested import reset the first import's gate")
                throw injected("outer import failure")
            }
        } catch { outerFailed = true }
        try check(outerFailed && nestedRejected && !nestedEntered && !DataImportCoordinator.isImporting, "exclusive import gate did not reset correctly")

        return [
            "导入文件事务：插件/设置/快捷键/历史四个写入阶段故障及实际Foundation写入失败均恢复原字节，含隐藏.sandboxes缓存，未触及四路径外文件。",
            "导入缺失与失败恢复：原缺失文件/插件保持缺失；多项恢复失败逐项收集且继续恢复其他项，保留完整备份和原始快照路径；成功设置导入保留历史。",
            "导入重入保护：嵌套导入被拒绝且不重置外层状态，异常退出后解除门禁；全部fixture仅使用临时目录，未读写用户现有配置或启动插件。"
        ]
    }
}

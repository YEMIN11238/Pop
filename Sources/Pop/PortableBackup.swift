import Foundation

struct PortableBackup: Codable {
    struct File: Codable { var path: String; var contents: Data }
    var format = "PopBackup"
    var version = 1
    var created = Date()
    var configuration: ConfigurationExport
    var history: [HistoryItem]
    var plugins: [File]

    static func validate(_ backup: PortableBackup) throws {
        guard backup.format == "PopBackup", backup.version == 1,
              backup.configuration.format == "PopConfiguration", backup.configuration.version == 1,
              backup.history.count <= 100000, backup.plugins.count <= 10000 else { throw PopError.message("不支持的备份格式或备份内容过多。") }
        var paths = Set<String>(); var bytes = 0
        for file in backup.plugins {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.isEmpty, !file.path.hasPrefix("/"), !file.path.contains("\\"), !file.path.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw PopError.message("备份包含不安全或重复的插件路径。") }
            bytes += file.contents.count
            guard bytes <= 128 * 1024 * 1024 else { throw PopError.message("插件备份超过 128 MB。") }
        }
    }

    static func collectPlugins(at root: URL) throws -> [File] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [File] = []; var total = 0
        while let url = enumerator.nextObject() as? URL {
            let value = try url.resourceValues(forKeys: Set(keys))
            if value.isSymbolicLink == true { throw PopError.message("插件目录包含符号链接，无法生成便携备份。") }
            guard value.isRegularFile == true else { continue }
            total += value.fileSize ?? 0
            guard total <= 128 * 1024 * 1024, files.count < 10000 else { throw PopError.message("插件备份超过容量限制。") }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files.append(File(path: relative, contents: try Data(contentsOf: url)))
        }
        return files.sorted { $0.path < $1.path }
    }
    func restorePlugins(at root: URL) throws {
        try Self.validate(self)
        let manager = FileManager.default
        let parent = root.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".plugins-restore-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for file in plugins {
            let path = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: path, options: .atomic)
        }
        let previous = parent.appendingPathComponent(".plugins-previous-\(UUID().uuidString)")
        let exists = manager.fileExists(atPath: root.path)
        if exists { try manager.moveItem(at: root, to: previous) }
        do { try manager.moveItem(at: staging, to: root) }
        catch { if exists { try? manager.moveItem(at: previous, to: root) }; throw error }
        if exists { try? manager.removeItem(at: previous) }
    }
}

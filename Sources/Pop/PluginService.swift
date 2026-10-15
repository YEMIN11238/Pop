import Foundation
import JavaScriptCore
import NaturalLanguage
import ImageIO
import Security
import CryptoKit

struct PluginMenuValue: Identifiable, Equatable {
    var id: String { value }
    let title: String
    let value: String
}

struct PluginOption: Identifiable, Equatable {
    var id: String { identifier }
    let identifier: String
    let type: String
    let title: String
    let defaultValue: String
    let description: String
    let isSecure: Bool
    let menuValues: [PluginMenuValue]
}

struct PluginDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let path: URL
    let summary: String
    let author: String
    let homepage: String
    let category: String
    var categories: [String] { [category] }
    let options: [PluginOption]
}

/// Independent implementation of the public Bob translation-plugin interfaces.
/// JavaScript and every host callback run on the worker main actor. Import never executes code.
/// Workers can be forcibly terminated, but do not add OS sandbox entitlements: install trusted plugins.
@MainActor
final class PluginService {
    static let shared = PluginService()
    static let compatibilityNotes = "支持公开文本翻译、OCR、TTS 协议、CommonJS、crypto-js 4.2.0、选项、日志、HTTP 回调/Promise、流式 HTTP、multipart、隔离 $file、二进制 $data、定时器、WebSocket、pluginValidate、appcast 检查与用户显式更新；支持公开词典、plain/lines/markdown 格式和思考过程。OCR 区域/段落转换为行列表，旋转四边形转换为包围矩形。JavaScript 默认在独立进程执行，超时与取消会终止进程；这是运行隔离，未提供额外 OS sandbox 权限限制，插件只应来自可信来源。"
    let rootURL: URL
    private let timeout: TimeInterval
    private let executionMode: PluginExecutionMode
    private let sessions: NetworkProxySessionProvider
    private var session: URLSession { sessions.session }
    private let logHandler: (String, String) -> Void
    private var active: [UUID: PluginRuntime] = [:]
    private let manager = FileManager.default

    init(rootURL: URL? = nil, timeout: TimeInterval = 60, session: URLSession? = nil,
         executionMode: PluginExecutionMode = .isolated, logHandler: @escaping (String, String) -> Void = { _, _ in }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rootURL = (rootURL ?? support.appendingPathComponent("Pop/Plugins", isDirectory: true)).standardizedFileURL
        self.timeout = max(0.02, min(timeout, 300))
        self.executionMode = executionMode
        self.logHandler = logHandler
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = self.timeout
        sessions = NetworkProxySessionProvider(session: session, configuration: config)
    }

    func listPlugins() -> [PluginDescriptor] {
        guard let urls = try? manager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let descriptor = try? readDescriptor(at: url), descriptor.id == url.lastPathComponent else { return nil }
            return descriptor
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importPlugin(from url: URL, expectedIdentity: (id: String, version: String)? = nil) throws -> PluginDescriptor {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PopError.message("插件来源不能是符号链接。") }
        if values.isDirectory == true {
            let origin = url.resolvingSymlinksInPath().standardizedFileURL.path
            let storage = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard storage != origin, !storage.hasPrefix(origin.hasSuffix("/") ? origin : origin + "/") else {
                throw PopError.message("不能将插件存储目录或它的上级目录作为导入来源。")
            }
        } else {
            guard values.isRegularFile == true else { throw PopError.message("插件来源必须是普通 ZIP 文件或插件目录。") }
        }
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let staging = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let incoming = staging.appendingPathComponent("contents", isDirectory: true)
        if values.isDirectory == true {
            try validateTree(url)
            try manager.copyItem(at: url, to: incoming)
        } else {
            try validateZIP(url)
            try manager.createDirectory(at: incoming, withIntermediateDirectories: false)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qq", url.path, "-d", incoming.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw PopError.message("插件 ZIP 解压失败。") }
            try validateTree(incoming)
        }
        // Bob packages put info.json/main.js at the archive root. Also accept one enclosing folder.
        var packageRoot = incoming
        if !manager.fileExists(atPath: incoming.appendingPathComponent("info.json").path) {
            let entries = try manager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { $0.lastPathComponent != "__MACOSX" }
            if entries.count == 1, (try entries[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { packageRoot = entries[0] }
        }
        let descriptor = try readDescriptor(at: packageRoot)
        if let expectedIdentity {
            guard descriptor.id == expectedIdentity.id, descriptor.version == expectedIdentity.version else { throw PopError.message("更新包的插件标识符或版本与 appcast 不一致。") }
        }
        let destination = rootURL.appendingPathComponent(descriptor.id, isDirectory: true)
        let backup = rootURL.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        let replacing = manager.fileExists(atPath: destination.path)
        if replacing {
            cancelExecutions(pluginID: descriptor.id)
            try manager.moveItem(at: destination, to: backup)
        }
        do { try manager.moveItem(at: packageRoot, to: destination) }
        catch {
            if replacing { try? manager.moveItem(at: backup, to: destination) }
            throw error
        }
        if replacing { try? manager.removeItem(at: backup) }
        return try readDescriptor(at: destination)
    }

    func removePlugin(id: String) throws {
        try validateIdentifier(id)
        cancelExecutions(pluginID: id)
        let sandboxes = rootURL.appendingPathComponent(".sandboxes", isDirectory: true)
        if manager.fileExists(atPath: sandboxes.path) {
            guard (try sandboxes.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw PopError.message("插件缓存目录不能使用符号链接。") }
            let cache = sandboxes.appendingPathComponent(id, isDirectory: true)
            if manager.fileExists(atPath: cache.path) { try manager.removeItem(at: cache) }
        }
        let url = rootURL.appendingPathComponent(id, isDirectory: true)
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }

    func cancelAllExecutions() {
        let identifiers = Set(listPlugins().map(\.id) + active.values.map(\.pluginIdentifier))
        for id in identifiers { cancelExecutions(pluginID: id) }
    }

    func cancelExecutions(pluginID: String) {
        PluginProcessIsolation.cancel(pluginID: pluginID, rootURL: rootURL)
        let runtimes = active.values.filter { $0.pluginIdentifier == pluginID }
        runtimes.forEach { $0.cancel() }
    }

    func translate(_ req: TranslationRequest, service: ServiceConfig, onStream: ((TranslationOutput) -> Void)? = nil) async throws -> TranslationOutput {
        guard case .translation(let result) = try await execute(.translation(req), service: service, onStream: onStream) else { throw PopError.message("插件结果类型错误。") }
        return result
    }

    func validate(service: ServiceConfig) async throws -> PluginValidationResult {
        guard case .validation(let result) = try await execute(.validation, service: service) else { throw PopError.message("插件验证结果类型错误。") }
        return result
    }

    /// Read-only update discovery for an explicitly selected, already installed plugin.
    func checkForUpdate(id: String) async throws -> PluginUpdate? {
        try validateIdentifier(id)
        let installed = try readDescriptor(at: rootURL.appendingPathComponent(id))
        guard installed.id == id else { throw PopError.message("插件标识符与安装目录不一致。") }
        let info = try readJSON(at: installed.path.appendingPathComponent("info.json"))
        guard let string = info["appcast"] as? String, !string.isEmpty else { return nil }
        let appcastURL = try updateURL(string)
        let data = try await downloadUpdateResource(appcastURL, limit: 2 * 1024 * 1024)
        guard let cast = try JSONSerialization.jsonObject(with: data) as? [String: Any], cast["identifier"] as? String == id,
              let versions = cast["versions"] as? [[String: Any]] else { throw PopError.message("appcast 缺少版本列表或插件标识符不匹配。") }
        let candidates = try versions.compactMap { row -> PluginUpdate? in
            guard let version = row["version"] as? String, !version.isEmpty,
                  PluginVersions.compare(version, installed.version) == .orderedDescending else { return nil }
            guard let checksum = row["sha256"] as? String, checksum.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                  let url = row["url"] as? String else { throw PopError.message("appcast 更新项缺少有效 SHA256 或下载地址。") }
            var date: Date?
            if let timestamp = row["timestamp"] as? Double, timestamp.isFinite {
                date = Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
            }
            return PluginUpdate(pluginID: id, name: installed.name, currentVersion: installed.version, version: version,
                                notes: row["desc"] as? String ?? "", downloadURL: try updateURL(url), sha256: checksum.lowercased(),
                                minBobVersion: row["minBobVersion"] as? String, publishedAt: date, appcastURL: appcastURL)
        }
        return candidates.max { PluginVersions.compare($0.version, $1.version) == .orderedAscending }
    }

    /// Call only for the update the user chose to install. Discovery never calls this.
    func installUpdate(_ update: PluginUpdate) async throws -> PluginDescriptor {
        try validateIdentifier(update.pluginID)
        let installed = try readDescriptor(at: rootURL.appendingPathComponent(update.pluginID))
        guard installed.id == update.pluginID, installed.version == update.currentVersion else { throw PopError.message("插件版本已改变，请重新检查更新。") }
        let info = try readJSON(at: installed.path.appendingPathComponent("info.json"))
        guard let appcast = info["appcast"] as? String, try updateURL(appcast) == update.appcastURL,
              PluginVersions.compare(update.version, installed.version) == .orderedDescending else { throw PopError.message("更新来源与当前插件不一致。") }
        let data = try await downloadUpdateResource(update.downloadURL, limit: 50 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == update.sha256.lowercased() else { throw PopError.message("插件更新包 SHA256 校验失败，原插件未改变。") }
        let refreshed = try readDescriptor(at: installed.path)
        guard refreshed.version == update.currentVersion else { throw PopError.message("下载期间插件版本已改变，请重新检查更新。") }
        let temporary = manager.temporaryDirectory.appendingPathComponent("pop-plugin-update-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("update.bobplugin")
        try data.write(to: archive, options: .atomic)
        return try importPlugin(from: archive, expectedIdentity: (update.pluginID, update.version))
    }

    private func updateURL(_ string: String) throws -> URL {
        guard let parts = URLComponents(string: string), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil, let url = parts.url else { throw PopError.message("插件更新地址必须是有效的 http/https URL。") }
        return url
    }

    private func downloadUpdateResource(_ url: URL, limit: Int) async throws -> Data {
        let session = self.session, seconds = timeout
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.setValue("application/json, application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), !data.isEmpty, data.count <= limit else { throw PopError.message("插件更新下载失败、内容为空或超过大小限制。") }
                return data
            }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw PopError.message("插件更新请求超时。") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func recognize(imageData: Data, service: ServiceConfig) async throws -> OCRDocument {
        guard !imageData.isEmpty, imageData.count <= 20 * 1024 * 1024 else { throw PopError.message("OCR 图片为空或超过 20 MB。") }
        guard case .recognition(let result) = try await execute(.recognition(imageData, service.options["language"] ?? "auto"), service: service) else { throw PopError.message("插件 OCR 结果类型错误。") }
        return result
    }

    func synthesize(text: String, language: String, service: ServiceConfig) async throws -> Data {
        let language = language == "auto" ? PluginRuntime.detect(text, source: "auto") : language
        guard case .speech(let audio) = try await execute(.speech(text, language), service: service) else { throw PopError.message("插件语音结果类型错误。") }
        switch audio {
        case .data(let data): return data
        case .url(let url):
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let session = self.session, seconds = timeout
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    let (data, response) = try await session.data(for: request)
                    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw PopError.message("插件音频下载失败、内容为空或超过 20 MB。") }
                    return data
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw PopError.message("插件音频下载超时。")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
    }

    private func execute(_ operation: PluginOperation, service: ServiceConfig, onStream: ((TranslationOutput) -> Void)? = nil) async throws -> PluginExecutionResult {
        try DataImportCoordinator.requireAvailable()
        try validateIdentifier(service.pluginID)
        let path = rootURL.appendingPathComponent(service.pluginID, isDirectory: true)
        let descriptor = try readDescriptor(at: path)
        guard descriptor.id == service.pluginID else { throw PopError.message("插件标识符与安装目录不一致。") }
        if case .validation = operation { /* Validation is optional for every plugin category. */ }
        else { guard descriptor.category == operation.category else { throw PopError.message("插件类型不是 \(operation.category)。") } }
        if executionMode == .isolated {
            return try await PluginProcessIsolation.execute(operation, service: service, rootURL: rootURL, timeout: timeout, logHandler: logHandler, onStream: onStream)
        }
        let metadata = try readJSON(at: path.appendingPathComponent("info.json"))
        var options = Dictionary(uniqueKeysWithValues: descriptor.options.map { ($0.identifier, $0.defaultValue) })
        options.merge(service.options) { _, new in new }
        let sandbox = try sandboxDirectory(for: descriptor.id)
        let identifier = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let runtime = PluginRuntime(root: path, sandbox: sandbox, metadata: metadata, options: options, operation: operation, timeout: timeout, session: session, logHandler: logHandler, onStream: onStream) { [weak self] result in
                    self?.active.removeValue(forKey: identifier)
                    continuation.resume(with: result)
                }
                active[identifier] = runtime
                if Task.isCancelled { runtime.cancel() } else { runtime.start() }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.active[identifier]?.cancel() }
        })
    }

    private func validateIdentifier(_ id: String) throws {
        guard id.count <= 180, id.range(of: "^[a-z0-9]+(?:\\.[a-z0-9]+)*$", options: .regularExpression) != nil else { throw PopError.message("插件 identifier 必须由小写字母、数字和分隔点组成。") }
    }

    private func sandboxDirectory(for id: String) throws -> URL {
        var current = rootURL
        for component in [".sandboxes", id] {
            current.appendPathComponent(component, isDirectory: true)
            if manager.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw PopError.message("插件缓存路径无效或包含符号链接。") }
            } else { try manager.createDirectory(at: current, withIntermediateDirectories: false) }
        }
        return current
    }

    private func readJSON(at url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) <= 1024 * 1024 else { throw PopError.message("插件元信息不能使用符号链接或超过 1 MB。") }
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw PopError.message("info.json 必须是 JSON 对象。") }
        return result
    }

    private func readDescriptor(at root: URL) throws -> PluginDescriptor {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw PopError.message("插件目录无效。") }
        let info = try readJSON(at: root.appendingPathComponent("info.json"))
        guard let id = info["identifier"] as? String, let name = info["name"] as? String, !name.isEmpty,
              let version = info["version"] as? String, !version.isEmpty, let category = info["category"] as? String, ["translate", "ocr", "tts"].contains(category) else { throw PopError.message("需要含 identifier、name、version 和有效 category 的插件。") }
        try validateIdentifier(id)
        let main = root.appendingPathComponent("main.js")
        let mainValues = try main.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard mainValues.isRegularFile == true, mainValues.isSymbolicLink != true else { throw PopError.message("插件缺少 main.js，或 main.js 使用了符号链接。") }
        var seen = Set<String>()
        let options = try (info["options"] as? [[String: Any]] ?? []).map { row -> PluginOption in
            guard let key = row["identifier"] as? String, !key.isEmpty, seen.insert(key).inserted else { throw PopError.message("插件选项标识符缺失或重复。") }
            let menu = (row["menuValues"] as? [[String: Any]] ?? []).compactMap { entry -> PluginMenuValue? in
                guard let value = entry["value"] as? String else { return nil }
                return PluginMenuValue(title: entry["title"] as? String ?? value, value: value)
            }
            return PluginOption(identifier: key, type: row["type"] as? String ?? "text", title: row["title"] as? String ?? key, defaultValue: row["defaultValue"] as? String ?? "", description: row["desc"] as? String ?? "", isSecure: (row["textConfig"] as? [String: Any])?["type"] as? String != "visible", menuValues: menu)
        }
        return PluginDescriptor(id: id, name: name, version: version, path: root, summary: info["summary"] as? String ?? "", author: info["author"] as? String ?? "", homepage: info["homepage"] as? String ?? "", category: category, options: options)
    }

    private func validateTree(_ root: URL) throws {
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { throw PopError.message("无法读取插件目录。") }
        var total = 0, count = 0
        for case let file as URL in enumerator {
            let value = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard value.isSymbolicLink != true else { throw PopError.message("插件包不能包含符号链接。") }
            guard value.isRegularFile == true || value.isDirectory == true else { throw PopError.message("插件包不能包含管道、设备或其他特殊文件。") }
            count += 1
            if value.isRegularFile == true { total += value.fileSize ?? 0 }
            guard total <= 50 * 1024 * 1024, count <= 2000 else { throw PopError.message("插件包超过 50 MB 或 2000 个文件/目录。") }
        }
    }

    /// Validate the ZIP central directory before invoking Apple's unzip. ZIP64/encrypted archives
    /// and links are intentionally unsupported; traversal is rejected rather than normalized.
    private func validateZIP(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 22, size <= 50 * 1024 * 1024 else { throw PopError.message("插件 ZIP 大小无效。") }
        let bytes = [UInt8](try Data(contentsOf: url))
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= bytes.count else { throw PopError.message("ZIP 元数据损坏。") }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            let low = try u16(at), high = try u16(at + 2)
            return UInt32(low) | UInt32(high) << 16
        }
        func validateExtra(at start: Int, length: Int) throws {
            var cursor = start
            guard start >= 0, start + length <= bytes.count else { throw PopError.message("ZIP 扩展字段损坏。") }
            while cursor < start + length {
                let tag = try u16(cursor), count = try u16(cursor + 2)
                // Timestamps and Unix UID/GID do not change names or create links. Other
                // extensions can override filenames, encode links, or enable ZIP64.
                guard [0x5455, 0x7875, 0x000a].contains(tag), cursor + 4 + count <= start + length else { throw PopError.message("ZIP 包含不支持的路径、链接或扩展字段。") }
                cursor += 4 + count
            }
        }
        guard let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first(where: { at in
            bytes[at] == 0x50 && bytes[at + 1] == 0x4b && bytes[at + 2] == 0x05 && bytes[at + 3] == 0x06
        }), try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw PopError.message("不支持此 ZIP 格式。") }
        let entries = try u16(end + 10)
        guard entries > 0, entries <= 2000, try u16(end + 8) == entries,
              end + 22 + (try u16(end + 20)) == bytes.count else { throw PopError.message("ZIP 文件数量或目录无效。") }
        let centralSize = Int(try u32(end + 12)), centralStart = Int(try u32(end + 16))
        guard centralStart + centralSize == end else { throw PopError.message("不支持 ZIP64 或损坏的 ZIP 目录。") }
        var at = centralStart, total: UInt64 = 0
        var names = Set<String>()
        for _ in 0..<entries {
            guard try u32(at) == 0x02014b50 else { throw PopError.message("ZIP 目录损坏。") }
            let flag = try u16(at + 8), method = try u16(at + 10)
            guard flag & 1 == 0, method == 0 || method == 8 else { throw PopError.message("不支持加密插件或此压缩方式。") }
            let length = try u16(at + 28), extra = try u16(at + 30), comment = try u16(at + 32)
            guard at + 46 + length + extra + comment <= end,
                  let name = String(bytes: bytes[(at + 46)..<(at + 46 + length)], encoding: .utf8) else { throw PopError.message("ZIP 文件名无效。") }
            try validateExtra(at: at + 46 + length, length: extra)
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !components.contains(".."), !components.contains("."),
                  !components.dropLast().contains(""), names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw PopError.message("ZIP 包含不安全路径或重复文件。") }
            let mode = (try u32(at + 38)) >> 16
            guard mode & 0xf000 != 0xa000, mode & 0xf000 == 0 || mode & 0xf000 == 0x8000 || mode & 0xf000 == 0x4000 else { throw PopError.message("ZIP 包含符号链接或特殊文件。") }
            total += UInt64(try u32(at + 24))
            guard total <= 50 * 1024 * 1024 else { throw PopError.message("插件解压后超过 50 MB。") }
            let local = Int(try u32(at + 42))
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flag,
                  try u16(local + 8) == method, try u16(local + 26) == length,
                  local + 30 + length <= centralStart,
                  Array(bytes[(local + 30)..<(local + 30 + length)]) == Array(bytes[(at + 46)..<(at + 46 + length)]) else { throw PopError.message("ZIP 本地路径与目录不一致。") }
            try validateExtra(at: local + 30 + length, length: u16(local + 28))
            at += 46 + length + extra + comment
        }
        guard at == end else { throw PopError.message("ZIP 目录长度不一致。") }
    }
}

/// The delegate has a serial queue. Only Foundation data crosses to the main actor.
private final class PluginHTTPStreamTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var ownedSession: URLSession!
    private var task: URLSessionDataTask!
    private var response: HTTPURLResponse?
    private var count = 0
    private var bytes = 0
    private var failure: Error?
    private let onChunk: @Sendable (Int, Data) -> Void
    private let onFinish: @Sendable (Int, HTTPURLResponse?, Error?) -> Void
    init(configuration: URLSessionConfiguration, request: URLRequest,
         onChunk: @escaping @Sendable (Int, Data) -> Void,
         onFinish: @escaping @Sendable (Int, HTTPURLResponse?, Error?) -> Void) {
        self.onChunk = onChunk; self.onFinish = onFinish
        super.init()
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        ownedSession = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = ownedSession.dataTask(with: request)
    }
    func start() { task.resume() }
    func cancel() { task.cancel(); ownedSession.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > 20 * 1024 * 1024 {
            failure = PopError.message("流式 HTTP 响应超过 20 MB。")
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        bytes += data.count
        guard bytes <= 20 * 1024 * 1024 else { failure = PopError.message("流式 HTTP 响应超过 20 MB。"); dataTask.cancel(); return }
        onChunk(count, data); count += 1
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onFinish(count, response, failure ?? error)
        session.finishTasksAndInvalidate()
    }
}

private final class PluginFileSystem {
    private let package: URL
    private let sandbox: URL
    private let manager = FileManager.default
    init(package: URL, sandbox: URL) {
        self.package = package.resolvingSymlinksInPath().standardizedFileURL
        self.sandbox = sandbox.resolvingSymlinksInPath().standardizedFileURL
    }

    private func resolve(_ path: String, writing: Bool = false, allowRoot: Bool = true) throws -> URL {
        guard !path.contains("\\"), !path.contains("\0") else { throw PopError.message("插件文件路径无效。") }
        let root: URL, relative: String
        if path == "$sandbox" || path.hasPrefix("$sandbox/") {
            root = sandbox
            relative = path == "$sandbox" ? "" : String(path.dropFirst("$sandbox/".count))
        } else if path.hasPrefix("/"), !writing {
            root = package; relative = String(path.dropFirst())
        } else { throw PopError.message("插件文件写入只能使用 $sandbox/ 虚拟路径，读取需使用绝对虚拟路径。") }
        var pieces: [String] = []
        for part in relative.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !pieces.isEmpty else { throw PopError.message("插件文件路径越界。") }
                pieces.removeLast()
            } else { pieces.append(String(part)) }
        }
        guard allowRoot || !pieces.isEmpty else { throw PopError.message("不能修改插件沙盒根目录。") }
        var current = root
        for piece in pieces {
            current.appendPathComponent(piece)
            if manager.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw PopError.message("插件文件路径包含符号链接或特殊文件。") }
            }
        }
        let resolved = current.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { throw PopError.message("插件文件路径越界。") }
        return current
    }

    private func footprint(_ url: URL) throws -> (bytes: Int, entries: Int) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw PopError.message("插件缓存不能包含符号链接。") }
        if values.isRegularFile == true { return (values.fileSize ?? 0, 1) }
        guard values.isDirectory == true, let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw PopError.message("插件缓存类型无效。") }
        var bytes = 0, entries = 0
        for case let child as URL in enumerator {
            let info = try child.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true || info.isDirectory == true else { throw PopError.message("插件缓存不能包含符号链接或特殊文件。") }
            entries += 1
            if info.isRegularFile == true { bytes += info.fileSize ?? 0 }
            guard bytes <= 50 * 1024 * 1024, entries <= 2000 else { throw PopError.message("插件缓存超过容量限制。") }
        }
        return (bytes, entries)
    }

    func read(_ path: String) throws -> PluginBinaryData {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 20 * 1024 * 1024 else { throw PopError.message("插件读取需要普通文件且不能超过 20 MB。") }
        return PluginBinaryData(try Data(contentsOf: url))
    }
    func list(_ path: String) throws -> [String] {
        let url = try resolve(path)
        guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw PopError.message("插件 list 需要目录。") }
        return try manager.contentsOfDirectory(atPath: url.path).sorted()
    }
    func write(_ path: String, data: PluginBinaryData) throws {
        let url = try resolve(path, writing: true, allowRoot: false)
        let total = try footprint(sandbox)
        let previous = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard data.length <= 20 * 1024 * 1024, total.bytes - previous + data.length <= 50 * 1024 * 1024,
              total.entries + (manager.fileExists(atPath: url.path) ? 0 : 1) <= 2000 else { throw PopError.message("插件缓存写入超过容量限制。") }
        try data.bytes.write(to: url, options: .atomic)
    }
    func action(_ action: String, path: String) throws -> Bool {
        switch action {
        case "exists": return manager.fileExists(atPath: try resolve(path).path)
        case "isDirectory": return (try? resolve(path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        case "delete": try manager.removeItem(at: resolve(path, writing: true, allowRoot: false)); return true
        case "mkdir":
            let url = try resolve(path, writing: true)
            let total = try footprint(sandbox)
            guard total.entries + path.split(separator: "/").count <= 2000 else { throw PopError.message("插件缓存目录数量超过限制。") }
            try manager.createDirectory(at: url, withIntermediateDirectories: true); return true
        default: return false
        }
    }
    func transfer(_ source: String, destination: String, moving: Bool) throws {
        let sourceURL = try resolve(source, writing: moving, allowRoot: false)
        let destinationURL = try resolve(destination, writing: true, allowRoot: false)
        guard sourceURL != destinationURL, !destinationURL.path.hasPrefix(sourceURL.path + "/") else { throw PopError.message("插件文件不能递归复制或移动。") }
        let sourceSize = try footprint(sourceURL), total = try footprint(sandbox)
        let copyingDirectory = (try sourceURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        guard moving || total.bytes + sourceSize.bytes <= 50 * 1024 * 1024,
              moving || total.entries + sourceSize.entries + (copyingDirectory ? 1 : 0) <= 2000 else { throw PopError.message("插件缓存复制超过容量限制。") }
        if moving { try manager.moveItem(at: sourceURL, to: destinationURL) }
        else { try manager.copyItem(at: sourceURL, to: destinationURL) }
    }
}

enum PluginOperation {
    case translation(TranslationRequest)
    case recognition(Data, String)
    case speech(String, String)
    case validation
    var category: String {
        switch self { case .translation: return "translate"; case .recognition: return "ocr"; case .speech: return "tts"; case .validation: return "pluginValidate" }
    }
}

enum PluginSpeechResult { case data(Data), url(URL) }
enum PluginExecutionResult {
    case translation(TranslationOutput), recognition(OCRDocument), speech(PluginSpeechResult), validation(PluginValidationResult)
}

@objc private protocol PluginBinaryDataExports: JSExport {
    var length: Int { get }
    func toUTF8() -> String?
    func toBase64() -> String
    func toHex(_ useUpper: Bool) -> String
    func toByteArray() -> [NSNumber]
    func readUInt8(_ index: Int) -> Int
    func writeUInt8(_ value: Int, _ index: Int)
    func subData(_ start: Int, _ end: Int) -> PluginBinaryData?
    func appendData(_ data: PluginBinaryData)
}

final class PluginBinaryData: NSObject, PluginBinaryDataExports {
    private(set) var bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    var length: Int { bytes.count }
    func toUTF8() -> String? { String(data: bytes, encoding: .utf8) }
    func toBase64() -> String { bytes.base64EncodedString() }
    func toHex(_ useUpper: Bool) -> String {
        let format = useUpper ? "%02X" : "%02x"
        return bytes.map { String(format: format, $0) }.joined()
    }
    func toByteArray() -> [NSNumber] { bytes.map { NSNumber(value: $0) } }
    func readUInt8(_ index: Int) -> Int { bytes.indices.contains(index) ? Int(bytes[index]) : 0 }
    func writeUInt8(_ value: Int, _ index: Int) { if bytes.indices.contains(index), (0...255).contains(value) { bytes[index] = UInt8(value) } }
    func subData(_ start: Int, _ end: Int) -> PluginBinaryData? {
        guard start >= 0, end > start, end <= bytes.count else { return nil }
        return PluginBinaryData(bytes.subdata(in: start..<end))
    }
    func appendData(_ data: PluginBinaryData) {
        guard bytes.count + data.bytes.count <= 20 * 1024 * 1024 else {
            if let context = JSContext.current() { context.exception = JSValue(newErrorFromMessage: "$data exceeds 20 MB", in: context) }
            return
        }
        bytes.append(data.bytes)
    }
}

@MainActor
private final class PluginRuntime {
    var pluginIdentifier: String { metadata["identifier"] as? String ?? "" }
    private let root: URL
    private let files: PluginFileSystem
    private let metadata: [String: Any]
    private let options: [String: String]
    private let operation: PluginOperation
    private let timeout: TimeInterval
    private let session: URLSession
    private let logHandler: (String, String) -> Void
    private let onStream: ((TranslationOutput) -> Void)?
    private var completion: ((Result<PluginExecutionResult, Error>) -> Void)?
    private let context = JSContext()!
    private var deadline: Task<Void, Never>?
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private var httpCallbacks: [UUID: JSValue] = [:]
    private struct StreamState {
        var next = 0
        var chunks: [Int: Data] = [:]
        var pendingUTF8 = Data()
        var end: (Int, HTTPURLResponse?, Error?)?
        let callback: JSValue
        let finalCallback: JSValue
        let transport: PluginHTTPStreamTransport
    }
    private var streams: [UUID: StreamState] = [:]
    private var cancelSignal: JSValue?
    private var sockets: [PluginWebSocket] = []
    private var resultDecoder = PluginResultDecoder()
    private var timers: [Int: Timer] = [:]
    private var timerCallbacks: [Int: JSValue] = [:]
    private var nextTimerID = 1

    init(root: URL, sandbox: URL, metadata: [String: Any], options: [String: String], operation: PluginOperation, timeout: TimeInterval, session: URLSession, logHandler: @escaping (String, String) -> Void, onStream: ((TranslationOutput) -> Void)?, completion: @escaping (Result<PluginExecutionResult, Error>) -> Void) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        files = PluginFileSystem(package: root, sandbox: sandbox)
        self.metadata = metadata; self.options = options; self.operation = operation
        self.timeout = timeout; self.session = session; self.logHandler = logHandler
        self.onStream = onStream
        self.completion = completion
    }

    func start() {
        context.exceptionHandler = { [weak self] _, error in self?.finish(.failure(PopError.message("插件 JavaScript 错误：\(error?.toString() ?? "未知错误")"))) }
        installHost()
        _ = context.evaluateScript(Self.bootstrap)
        guard completion != nil, let plugin = context.objectForKeyedSubscript("__popPlugin") else { return }
        guard let entrypoint = plugin.objectForKeyedSubscript(operation.category), !entrypoint.isUndefined else {
            if case .validation = operation { finish(.success(.validation(PluginValidationResult(supported: false, isValid: false, message: "插件未提供验证接口。", troubleshootingLink: nil)))) }
            else { finish(.failure(PopError.message("插件没有实现 \(operation.category)。"))) }
            return
        }
        var supported: [String] = []
        if case .validation = operation { }
        else {
            guard let languages = plugin.objectForKeyedSubscript("supportLanguages"), !languages.isUndefined,
                  let languagesArray = languages.call(withArguments: [])?.toArray() as? [String] else { finish(.failure(PopError.message("插件必须实现 supportLanguages 并返回语言数组。"))); return }
            supported = languagesArray
        }
        guard completion != nil else { return }
        switch operation {
        case .translation(let request):
            guard supported.contains(request.target), request.source == "auto" || supported.contains(request.source) else { finish(.failure(PopError.message("插件不支持所选语言。"))); return }
        case .speech(_, let language):
            guard supported.contains(language) else { finish(.failure(PopError.message("插件不支持所选语音语言。"))); return }
        case .recognition(_, let source):
            guard source == "auto" || supported.contains(source) else { finish(.failure(PopError.message("插件不支持所选 OCR 语言。"))); return }
        case .validation: break
        }
        var seconds = timeout
        if let timeoutFunction = plugin.objectForKeyedSubscript("pluginTimeoutInterval"), !timeoutFunction.isUndefined,
           let value = timeoutFunction.call(withArguments: [])?.toDouble(), value.isFinite, value >= 30, value <= 300 { seconds = min(seconds, value) }
        guard completion != nil else { return }
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(PopError.message("插件 \(self?.operation.category ?? "调用") 超时（\(seconds) 秒）。")))
        }
        let callback: @convention(block) (JSValue) -> Void = { [weak self] value in self?.receive(value) }
        let callbackValue = JSValue(object: callback, in: context)!
        if case .validation = operation { observeReturned(entrypoint.call(withArguments: [callbackValue])); return }
        let query: JSValue
        switch operation {
        case .translation(let request):
            let detected = Self.detect(request.text, source: request.source)
            let detectedTo = request.target == "auto" ? (detected.hasPrefix("zh") ? "en" : "zh-Hans") : request.target
            query = JSValue(object: ["text": request.text, "originalText": request.originalText, "from": request.source, "to": request.target, "detectFrom": detected, "detectTo": detectedTo], in: context)!
        case .recognition(let data, let source):
            var width = 0, height = 0
            if let image = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            }
            query = JSValue(object: ["from": source, "detectFrom": source == "auto" ? "en" : source, "pixelWidth": width, "pixelHeight": height, "image": PluginBinaryData(data)], in: context)!
        case .speech(let text, let language):
            query = JSValue(object: ["text": text, "lang": language], in: context)!
        case .validation: return
        }
        query.setObject(callbackValue, forKeyedSubscript: "onCompletion" as NSString)
        cancelSignal = context.evaluateScript("$signal.new()")
        if let cancelSignal { query.setObject(cancelSignal, forKeyedSubscript: "cancelSignal" as NSString) }
        let stream: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, self.completion != nil, case .translation(let request) = self.operation, let result = value.toDictionary() as? [String: Any] else { return }
            do {
                let output = try self.resultDecoder.decode(result, originalText: request.originalText, streaming: true)
                if !output.text.isEmpty || output.reasoning != nil { self.onStream?(output) }
            } catch { self.finish(.failure(error)) }
        }
        query.setObject(stream, forKeyedSubscript: "onStream" as NSString)
        let returned = entrypoint.call(withArguments: [query, callbackValue])
        observeReturned(returned)
    }

    private func observeReturned(_ returned: JSValue?) {
        if completion != nil, let returned, !returned.isUndefined, !returned.isNull {
            context.setObject(returned, forKeyedSubscript: "__popReturned" as NSString)
            _ = context.evaluateScript("if (__popReturned && typeof __popReturned.then === 'function') __popReturned.catch(function(error) { __popFail(error && (error.message || (error.error && error.error.message)) || String(error)); });")
        }
    }

    func cancel() {
        let signal = cancelSignal
        finish(.failure(CancellationError()))
        _ = signal?.invokeMethod("send", withArguments: [])
    }

    private func finish(_ result: Result<PluginExecutionResult, Error>) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel(); deadline = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        httpCallbacks.removeAll()
        streams.values.forEach { $0.transport.cancel() }; streams.removeAll()
        sockets.forEach { $0.shutdown() }; sockets.removeAll()
        timers.values.forEach { $0.invalidate() }; timers.removeAll()
        timerCallbacks.removeAll()
        context.exceptionHandler = nil
        completion(result)
    }

    private func receive(_ value: JSValue) {
        guard completion != nil, let payload = value.toDictionary() as? [String: Any] else { finish(.failure(PopError.message("插件返回了无效结果。"))); return }
        if case .validation = operation {
            let error = payload["error"] as? [String: Any]
            let troubleshooting = (error?["troubleshootingLink"] as? String).flatMap(URL.init(string:))
            let valid = payload["result"] as? Bool ?? false
            finish(.success(.validation(PluginValidationResult(supported: true, isValid: valid, message: error?["message"] as? String ?? (valid ? nil : "插件验证未通过。"), troubleshootingLink: troubleshooting))))
            return
        }
        if let error = payload["error"] as? [String: Any] { finish(.failure(PopError.message(error["message"] as? String ?? "插件翻译失败。"))); return }
        guard let result = payload["result"] as? [String: Any] else { finish(.failure(PopError.message("插件结果缺少 result。"))); return }
        if case .recognition = operation { receiveOCR(result); return }
        if case .speech = operation { receiveSpeech(result); return }
        guard case .translation(let request) = operation else { return }
        do { finish(.success(.translation(try resultDecoder.decode(result, originalText: request.originalText, streaming: false)))) }
        catch { finish(.failure(error)) }
    }

    private func receiveOCR(_ result: [String: Any]) {
        var entries: [[String: Any]] = []
        if let flat = result["texts"] as? [[String: Any]] { entries = flat }
        else if let regions = result["regionInfos"] as? [[String: Any]] {
            for region in regions {
                for paragraph in region["paragraphInfos"] as? [[String: Any]] ?? [] {
                    entries += paragraph["texts"] as? [[String: Any]] ?? []
                }
            }
        } else { finish(.failure(PopError.message("插件 OCR 结果缺少 texts 或 regionInfos。"))); return }
        var lines: [OCRLine] = []
        for entry in entries {
            guard let text = entry["text"] as? String, !text.isEmpty else { continue }
            var x = 0.0, y = 0.0, width = 0.0, height = 0.0
            if let box = entry["boundingBox"] as? [String: Any], let points = box["points"] as? [[String: Any]], points.count == 4 {
                let pairs = points.compactMap { row -> (Double, Double)? in
                    guard let x = row["x"] as? Double, let y = row["y"] as? Double,
                          x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
                    return (x, y)
                }
                guard pairs.count == 4 else { finish(.failure(PopError.message("插件 OCR boundingBox 坐标无效。"))); return }
                let xs = pairs.map(\.0), ys = pairs.map(\.1)
                x = xs.min()!; y = 1 - ys.max()!; width = xs.max()! - x; height = ys.max()! - ys.min()!
            }
            // The public protocol has no confidence field. Zero records an unknown confidence.
            lines.append(OCRLine(text: text, x: x, y: y, width: width, height: height, confidence: 0))
        }
        finish(.success(.recognition(OCRDocument(text: lines.map(\.text).joined(separator: "\n"), lines: lines, qrCodes: []))))
    }

    private func receiveSpeech(_ result: [String: Any]) {
        guard let type = result["type"] as? String, let value = result["value"] as? String else { finish(.failure(PopError.message("插件 TTS 结果缺少 type/value。"))); return }
        if type == "base64", value.utf8.count <= 28 * 1024 * 1024, let data = Data(base64Encoded: value), !data.isEmpty, data.count <= 20 * 1024 * 1024 {
            finish(.success(.speech(.data(data)))); return
        }
        if type == "url", let components = URLComponents(string: value),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil,
           components.user == nil, components.password == nil, let url = components.url {
            finish(.success(.speech(.url(url)))); return
        }
        finish(.failure(PopError.message("插件 TTS 仅接受有效的 base64 音频或 http/https 音频 URL。")))
    }

    private func installHost() {
        context.setObject(options, forKeyedSubscript: "$option" as NSString)
        context.setObject(metadata, forKeyedSubscript: "$info" as NSString)
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pop"
        context.setObject(["appName": appName, "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0", "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1", "macOSVersion": ProcessInfo.processInfo.operatingSystemVersionString, "macModel": "", "compatibility": "Bob public plugin API subset"], forKeyedSubscript: "$env" as NSString)
        let read: @convention(block) (String, String) -> String? = { [weak self] name, parent in
            guard let self, self.completion != nil else { return nil }
            do { return try self.readModule(name, parent: parent) }
            catch { self.context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context); return nil }
        }
        context.setObject(read, forKeyedSubscript: "__popReadModule" as NSString)
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in self?.logHandler(level, message) }
        context.setObject(log, forKeyedSubscript: "__popLog" as NSString)
        let fail: @convention(block) (String) -> Void = { [weak self] message in self?.finish(.failure(PopError.message("插件 JavaScript 错误：\(message)"))) }
        context.setObject(fail, forKeyedSubscript: "__popFail" as NSString)
        let http: @convention(block) (JSValue, JSValue) -> String = { [weak self] params, callback in self?.sendHTTP(params, callback: callback) ?? "" }
        context.setObject(http, forKeyedSubscript: "__popHTTP" as NSString)
        let streamHTTP: @convention(block) (JSValue, JSValue, JSValue) -> String = { [weak self] params, stream, callback in self?.sendStreamingHTTP(params, stream: stream, callback: callback) ?? "" }
        let cancelHTTP: @convention(block) (String) -> Void = { [weak self] string in
            guard let id = UUID(uuidString: string), let self else { return }
            self.tasks[id]?.cancel(); self.streams[id]?.transport.cancel()
        }
        context.setObject(streamHTTP, forKeyedSubscript: "__popStreamHTTP" as NSString)
        context.setObject(cancelHTTP, forKeyedSubscript: "__popCancelHTTP" as NSString)
        let schedule: @convention(block) (JSValue, Double, Bool) -> Int = { [weak self] callback, delay, repeats in self?.schedule(callback: callback, delay: delay, repeats: repeats) ?? 0 }
        context.setObject(schedule, forKeyedSubscript: "__popSchedule" as NSString)
        let invalidate: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.invalidate()
            self?.timerCallbacks.removeValue(forKey: id)
        }
        context.setObject(invalidate, forKeyedSubscript: "__popInvalidate" as NSString)
        let utf8: @convention(block) (String) -> PluginBinaryData? = { text in
            let data = Data(text.utf8); return data.count <= 20 * 1024 * 1024 ? PluginBinaryData(data) : nil
        }
        let base64: @convention(block) (String) -> PluginBinaryData? = { text in
            guard text.utf8.count <= 28 * 1024 * 1024, let data = Data(base64Encoded: text), data.count <= 20 * 1024 * 1024 else { return nil }
            return PluginBinaryData(data)
        }
        let hex: @convention(block) (String) -> PluginBinaryData? = { text in
            let bytes = Array(text.utf8)
            guard bytes.count % 2 == 0, bytes.count <= 40 * 1024 * 1024 else { return nil }
            var data = Data(); data.reserveCapacity(bytes.count / 2)
            func nibble(_ byte: UInt8) -> UInt8? {
                switch byte { case 48...57: return byte - 48; case 65...70: return byte - 55; case 97...102: return byte - 87; default: return nil }
            }
            for index in stride(from: 0, to: bytes.count, by: 2) {
                guard let first = nibble(bytes[index]), let second = nibble(bytes[index + 1]) else { return nil }
                data.append(first << 4 | second)
            }
            return PluginBinaryData(data)
        }
        let array: @convention(block) (JSValue) -> PluginBinaryData? = { value in
            guard let elements = value.toArray() as? [NSNumber], elements.count <= 20 * 1024 * 1024 else { return nil }
            var data = Data(); data.reserveCapacity(elements.count)
            for item in elements {
                let number = item.doubleValue
                guard number.isFinite, number.rounded() == number, (0...255).contains(number) else { return nil }
                data.append(UInt8(number))
            }
            return PluginBinaryData(data)
        }
        let copy: @convention(block) (JSValue) -> PluginBinaryData? = { value in
            guard let data = value.toObject() as? PluginBinaryData else { return nil }; return PluginBinaryData(data.bytes)
        }
        let isData: @convention(block) (JSValue) -> Bool = { $0.toObject() is PluginBinaryData }
        let random: @convention(block) (Int) -> [NSNumber]? = { count in
            guard (0...65_536).contains(count) else { return nil }
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
            return bytes.map { NSNumber(value: $0) }
        }
        context.setObject(utf8, forKeyedSubscript: "__popDataUTF8" as NSString)
        context.setObject(base64, forKeyedSubscript: "__popDataBase64" as NSString)
        context.setObject(hex, forKeyedSubscript: "__popDataHex" as NSString)
        context.setObject(array, forKeyedSubscript: "__popDataArray" as NSString)
        context.setObject(copy, forKeyedSubscript: "__popDataCopy" as NSString)
        context.setObject(isData, forKeyedSubscript: "__popIsData" as NSString)
        context.setObject(random, forKeyedSubscript: "__popRandom" as NSString)
        let fileRead: @convention(block) (String) -> PluginBinaryData? = { [weak self] path in
            guard let self else { return nil }; return try? self.files.read(path)
        }
        let fileList: @convention(block) (String) -> [String]? = { [weak self] path in
            guard let self else { return nil }; return try? self.files.list(path)
        }
        let fileWrite: @convention(block) (String, JSValue) -> Bool = { [weak self] path, value in
            guard let self, let data = value.toObject() as? PluginBinaryData else { return false }
            do { try self.files.write(path, data: data); return true } catch { return false }
        }
        let fileAction: @convention(block) (String, String) -> Bool = { [weak self] action, path in
            guard let self else { return false }; return (try? self.files.action(action, path: path)) ?? false
        }
        let fileTransfer: @convention(block) (String, String, Bool) -> Bool = { [weak self] source, destination, moving in
            guard let self else { return false }
            do { try self.files.transfer(source, destination: destination, moving: moving); return true } catch { return false }
        }
        context.setObject(fileRead, forKeyedSubscript: "__popFileRead" as NSString)
        context.setObject(fileList, forKeyedSubscript: "__popFileList" as NSString)
        context.setObject(fileWrite, forKeyedSubscript: "__popFileWrite" as NSString)
        context.setObject(fileAction, forKeyedSubscript: "__popFileAction" as NSString)
        context.setObject(fileTransfer, forKeyedSubscript: "__popFileTransfer" as NSString)
        let websocket: @convention(block) (JSValue) -> PluginWebSocket? = { [weak self] value in
            guard let self, self.completion != nil else { return nil }
            do {
                let socket = try PluginWebSocket(options: value.toDictionary() as? [String: Any] ?? [:])
                self.sockets.append(socket); return socket
            } catch { self.context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context); return nil }
        }
        context.setObject(websocket, forKeyedSubscript: "__popWebSocket" as NSString)
    }

    private func readModule(_ name: String, parent: String) throws -> String {
        if name == "crypto-js" {
            let record = ["path": "/@builtin/crypto-js.js", "type": "js", "source": CompiledCryptoJS.source]
            return String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)!
        }
        guard !name.isEmpty, !name.contains("\\"), !name.contains("\0") else { throw PopError.message("插件模块路径无效。") }
        let parentDirectory = (parent as NSString).deletingLastPathComponent
        let raw = name.hasPrefix("/") ? name : (name.hasPrefix(".") ? parentDirectory + "/" + name : "/" + name)
        var components: [String] = []
        for part in raw.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { throw PopError.message("插件模块路径越出插件目录。") }
                components.removeLast()
            } else { components.append(String(part)) }
        }
        let relative = components.joined(separator: "/")
        let candidates = [relative, relative + ".js", relative + ".json", relative + "/index.js"]
        for candidate in candidates {
            let url = root.appendingPathComponent(candidate).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { throw PopError.message("插件模块路径越出插件目录。") }
            guard ["js", "json"].contains(url.pathExtension), FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 4 * 1024 * 1024 else { throw PopError.message("插件模块无效或超过 4 MB。") }
            let source = try String(contentsOf: url, encoding: .utf8)
            let record = ["path": "/" + candidate, "type": url.pathExtension, "source": source]
            return String(data: try JSONSerialization.data(withJSONObject: record), encoding: .utf8)!
        }
        throw PopError.message("插件模块不存在：\(name)。内置模块暂未实现，可将依赖放入插件包。")
    }

    private func schedule(callback: JSValue, delay: Double, repeats: Bool) -> Int {
        guard completion != nil, delay.isFinite, timers.count < 100 else { return 0 }
        let id = nextTimerID; nextTimerID += 1
        timerCallbacks[id] = callback
        let timer = Timer(timeInterval: max(0.001, min(delay, 300)), repeats: repeats) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.completion != nil, let callback = self.timerCallbacks[id] else { return }
                if !repeats { self.timers.removeValue(forKey: id); self.timerCallbacks.removeValue(forKey: id) }
                _ = callback.call(withArguments: [])
            }
        }
        timers[id] = timer
        RunLoop.main.add(timer, forMode: .common)
        return id
    }

    private func makeHTTPRequest(_ params: [String: Any], streaming: Bool = false) throws -> URLRequest {
            guard let string = params["url"] as? String,
                  var components = URLComponents(string: string), ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.host != nil,
                  components.user == nil, components.password == nil else { throw PopError.message("插件 HTTP 仅支持无内嵌凭据的 http/https 地址。") }
            let files = params["files"] as? [[String: Any]] ?? []
            if let rawFiles = params["files"], !(rawFiles is NSNull), !(rawFiles is [[String: Any]]) { throw PopError.message("HTTP files 必须是文件对象数组。") }
            guard !streaming || files.isEmpty else { throw PopError.message("流式 HTTP 不支持 files。") }
            let method = (params["method"] as? String ?? "GET").uppercased()
            guard method.range(of: "^[A-Z]+$", options: .regularExpression) != nil else { throw PopError.message("HTTP method 无效。") }
            let body = params["body"]
            if ["GET", "HEAD", "DELETE"].contains(method), let fields = body as? [String: Any] {
                var items = components.queryItems ?? []
                items += fields.keys.sorted().map { URLQueryItem(name: $0, value: Self.stringValue(fields[$0]!)) }
                components.queryItems = items
            }
            guard let url = components.url else { throw PopError.message("HTTP 地址无效。") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            let seconds = params["timeout"] as? Double ?? timeout
            request.timeoutInterval = seconds.isFinite ? max(0.1, min(seconds, 300)) : timeout
            let headers = params["header"] as? [String: Any] ?? params["headers"] as? [String: Any] ?? [:]
            for (key, value) in headers {
                let text = Self.stringValue(value)
                guard key.range(of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$"#, options: .regularExpression) != nil,
                      !text.contains("\r"), !text.contains("\n"), !text.contains("\0") else { throw PopError.message("HTTP header 含无效名称或换行。") }
                request.setValue(text, forHTTPHeaderField: key)
            }
            if !files.isEmpty {
                guard !["GET", "HEAD", "DELETE"].contains(method) else { throw PopError.message("文件上传需使用 POST/PUT 等带 body 的方法。") }
                let boundary = "pop-" + UUID().uuidString
                var data = Data()
                func quoted(_ text: String) throws -> String {
                    guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw PopError.message("multipart 名称含无效字符。") }
                    return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                }
                func append(_ text: String) { data.append(Data(text.utf8)) }
                if let fields = body as? [String: Any] {
                    for key in fields.keys.sorted() {
                        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(try quoted(key))\"\r\n\r\n\(Self.stringValue(fields[key]!))\r\n")
                    }
                } else if let body, !(body is NSNull) { throw PopError.message("multipart body 必须是表单字段对象。") }
                for file in files {
                    guard let bytes = file["data"] as? PluginBinaryData, let name = file["name"] as? String,
                          let filename = file["filename"] as? String else { throw PopError.message("multipart 文件需包含 $data、name 和 filename。") }
                    let type = file["content-type"] as? String ?? "application/octet-stream"
                    guard !type.contains("\r"), !type.contains("\n"), !type.contains("\0") else { throw PopError.message("multipart content-type 无效。") }
                    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(try quoted(name))\"; filename=\"\(try quoted(filename))\"\r\nContent-Type: \(type)\r\n\r\n")
                    data.append(bytes.bytes); append("\r\n")
                    guard data.count <= 20 * 1024 * 1024 else { throw PopError.message("multipart body 超过 20 MB。") }
                }
                append("--\(boundary)--\r\n")
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = data
            } else if let body, !(body is NSNull), !["GET", "HEAD", "DELETE"].contains(method) {
                if let data = body as? PluginBinaryData { request.httpBody = data.bytes }
                else if let text = body as? String { request.httpBody = Data(text.utf8) }
                else if let fields = body as? [String: Any] {
                    let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "application/x-www-form-urlencoded"
                    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                    if contentType.lowercased().contains("application/json") { request.httpBody = try JSONSerialization.data(withJSONObject: fields) }
                    else if contentType.lowercased().contains("application/x-www-form-urlencoded") {
                        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                        let text = fields.keys.sorted().map { key in
                            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (Self.stringValue(fields[key]!).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
                        }.joined(separator: "&")
                        request.httpBody = Data(text.utf8)
                    } else { throw PopError.message("插件 HTTP body 暂只支持 JSON、表单或文本。") }
                } else { throw PopError.message("插件 HTTP body 类型不受支持。") }
            }
            guard (request.httpBody?.count ?? 0) <= 20 * 1024 * 1024 else { throw PopError.message("HTTP body 超过 20 MB。") }
            return request
    }

    private func sendHTTP(_ value: JSValue, callback: JSValue) -> String {
        guard completion != nil else { return "" }
        do {
            guard let params = value.toDictionary() as? [String: Any] else { throw PopError.message("HTTP 参数必须是对象。") }
            let request = try makeHTTPRequest(params)
            let identifier = UUID()
            httpCallbacks[identifier] = callback
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                Task { @MainActor in
                    guard let self, self.completion != nil, let callback = self.httpCallbacks.removeValue(forKey: identifier) else { return }
                    self.tasks.removeValue(forKey: identifier)
                    var payload: [String: Any] = [:]
                    if let data, data.count <= 20 * 1024 * 1024 {
                        payload["rawData"] = PluginBinaryData(data)
                        payload["data"] = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? String(data: data, encoding: .utf8) ?? PluginBinaryData(data)
                    }
                    if let data, data.count > 20 * 1024 * 1024 { payload["error"] = ["message": "HTTP 响应超过 20 MB。", "debugMessage": "response size limit"] }
                    if let response = response as? HTTPURLResponse {
                        payload["response"] = ["url": response.url?.absoluteString ?? "", "statusCode": response.statusCode, "headers": response.allHeaderFields, "MIMEType": response.mimeType ?? "", "expectedContentLength": response.expectedContentLength, "textEncodingName": response.textEncodingName ?? "", "suggestedFilename": response.suggestedFilename ?? ""]
                    }
                    if let error { payload["error"] = ["message": error.localizedDescription, "debugMessage": String(describing: error)] }
                    _ = callback.call(withArguments: [payload])
                }
            }
            tasks[identifier] = task
            task.resume()
            return identifier.uuidString
        } catch {
            _ = callback.call(withArguments: [["error": ["message": error.localizedDescription, "debugMessage": error.localizedDescription]]])
            return ""
        }
    }

    private func sendStreamingHTTP(_ value: JSValue, stream: JSValue, callback: JSValue) -> String {
        guard completion != nil else { return "" }
        do {
            guard let params = value.toDictionary() as? [String: Any] else { throw PopError.message("HTTP 参数必须是对象。") }
            let request = try makeHTTPRequest(params, streaming: true)
            let id = UUID()
            let configuration = session.configuration.copy() as! URLSessionConfiguration
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForResource = timeout
            let transport = PluginHTTPStreamTransport(configuration: configuration, request: request, onChunk: { [weak self] index, data in
                Task { @MainActor in
                    guard let self, var state = self.streams[id], self.completion != nil else { return }
                    state.chunks[index] = data; self.streams[id] = state
                    self.drainStream(id)
                }
            }, onFinish: { [weak self] count, response, error in
                Task { @MainActor in
                    guard let self, var state = self.streams[id], self.completion != nil else { return }
                    state.end = (count, response, error); self.streams[id] = state
                    self.drainStream(id)
                }
            })
            streams[id] = StreamState(callback: stream, finalCallback: callback, transport: transport)
            transport.start()
            return id.uuidString
        } catch {
            _ = callback.call(withArguments: [["error": ["message": error.localizedDescription, "debugMessage": error.localizedDescription]]])
            return ""
        }
    }

    private func drainStream(_ id: UUID) {
        while var state = streams[id], let data = state.chunks.removeValue(forKey: state.next) {
            state.next += 1
            state.pendingUTF8.append(data)
            let text = Self.decodeStreamUTF8(&state.pendingUTF8)
            streams[id] = state
            _ = state.callback.call(withArguments: [["text": text, "rawData": PluginBinaryData(data)]])
            guard completion != nil else { return }
        }
        guard let state = streams[id], let end = state.end, end.0 == state.next else { return }
        streams.removeValue(forKey: id)
        var payload: [String: Any] = [:]
        if let response = end.1 { payload["response"] = Self.responseInfo(response) }
        if let error = end.2 { payload["error"] = ["message": error.localizedDescription, "debugMessage": String(describing: error)] }
        // Bob's streaming final callback intentionally has no data or rawData.
        _ = state.finalCallback.call(withArguments: [payload])
    }

    private static func decodeStreamUTF8(_ pending: inout Data) -> String {
        let bytes = [UInt8](pending)
        guard !bytes.isEmpty else { return "" }
        var lastLead = bytes.count - 1
        while lastLead > 0, bytes[lastLead] & 0xc0 == 0x80, bytes.count - lastLead <= 3 { lastLead -= 1 }
        let lead = bytes[lastLead]
        let expected = (0xc2...0xdf).contains(lead) ? 2 : ((0xe0...0xef).contains(lead) ? 3 : ((0xf0...0xf4).contains(lead) ? 4 : 1))
        let cut = expected > bytes.count - lastLead ? lastLead : bytes.count
        let text = String(decoding: bytes[..<cut], as: UTF8.self)
        pending = Data(bytes[cut...])
        return text
    }

    private static func responseInfo(_ response: HTTPURLResponse) -> [String: Any] {
        ["url": response.url?.absoluteString ?? "", "statusCode": response.statusCode, "headers": response.allHeaderFields, "MIMEType": response.mimeType ?? "", "expectedContentLength": response.expectedContentLength, "textEncodingName": response.textEncodingName ?? "", "suggestedFilename": response.suggestedFilename ?? ""]
    }

    private static func stringValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if value is NSNull { return "" }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }

    static func detect(_ text: String, source: String) -> String {
        guard source == "auto" else { return source }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        let language = recognizer.dominantLanguage?.rawValue ?? "en"
        return language == "zh-Hans" || language == "zh-Hant" ? language : language.components(separatedBy: "-").first ?? "en"
    }

    private static let bootstrap = #"""
    (function () {
      const cache = Object.create(null);
      function load(name, parent) {
        const raw = __popReadModule(name, parent);
        if (!raw) throw new Error('Cannot load module ' + name);
        const record = JSON.parse(raw);
        if (cache[record.path]) return cache[record.path].exports;
        const module = {exports: {}};
        cache[record.path] = module;
        if (record.type === 'json') { module.exports = JSON.parse(record.source); return module.exports; }
        const dirname = record.path.slice(0, record.path.lastIndexOf('/')) || '/';
        const localRequire = function (path) { return load(path, record.path); };
        let suffix = '';
        if (record.path === '/main.js') suffix = '\n; if (typeof translate === "function" && !module.exports.translate) module.exports.translate = translate; if (typeof ocr === "function" && !module.exports.ocr) module.exports.ocr = ocr; if (typeof tts === "function" && !module.exports.tts) module.exports.tts = tts; if (typeof pluginValidate === "function" && !module.exports.pluginValidate) module.exports.pluginValidate = pluginValidate; if (typeof supportLanguages === "function" && !module.exports.supportLanguages) module.exports.supportLanguages = supportLanguages; if (typeof supportBoundingBox === "function" && !module.exports.supportBoundingBox) module.exports.supportBoundingBox = supportBoundingBox; if (typeof pluginTimeoutInterval === "function" && !module.exports.pluginTimeoutInterval) module.exports.pluginTimeoutInterval = pluginTimeoutInterval;';
        new Function('require', 'module', 'exports', '__filename', '__dirname', record.source + suffix)(localRequire, module, module.exports, record.path, dirname);
        return module.exports;
      }
      globalThis.$log = {};
      ['debug', 'info', 'warn', 'warning', 'error'].forEach(function (level) {
        $log[level] = function (value) { __popLog(level, typeof value === 'string' ? value : JSON.stringify(value)); };
      });
      function request(params, streaming) {
        if (!params || typeof params !== 'object') throw new Error('$http requires an object');
        function send(handler) {
          let disposable;
          const wrapped = function(response) { if(disposable)disposable.dispose(); handler(response); };
          const id = streaming ? __popStreamHTTP(params, typeof params.streamHandler === 'function' ? params.streamHandler : function(){}, wrapped) : __popHTTP(params, wrapped);
          if(id && params.cancelSignal && typeof params.cancelSignal.subscribe === 'function') disposable = params.cancelSignal.subscribe(function(){__popCancelHTTP(id);});
        }
        if (typeof params.handler === 'function') { send(params.handler); return; }
        return new Promise(function (resolve, reject) {
          send(function (response) { if (response.error) reject(response); else resolve(response); });
        });
      }
      globalThis.$http = {
        request: request,
        streamRequest: function(params) { return request(params, true); },
        get: function (params) { return request(Object.assign({}, params, {method: 'GET'})); },
        post: function (params) { return request(Object.assign({}, params, {method: 'POST'})); }
      };
      globalThis.$timer = {
        schedule: function (params) { if (!params || typeof params.handler !== 'function') throw new Error('timer.handler is required'); return __popSchedule(params.handler, Number(params.interval), !!params.repeats); },
        invalidate: function (id) { __popInvalidate(Number(id)); }
      };
      globalThis.$signal = {
        new: function() {
          const callbacks = new Map(); let next = 0;
          return {
            send: function(value) { Array.from(callbacks.values()).forEach(function(callback){callback(value);}); },
            subscribe: function(callback) { if(typeof callback !== 'function')throw new Error('signal subscriber must be a function'); const id=++next; callbacks.set(id,callback); return {dispose:function(){callbacks.delete(id);}}; },
            removeAllSubscriber: function() { callbacks.clear(); }
          };
        }
      };
      globalThis.$data = {
        fromUTF8: function (text) { return __popDataUTF8(String(text)); },
        fromHex: function (text) { return __popDataHex(String(text)); },
        fromBase64: function (text) { return __popDataBase64(String(text)); },
        fromByteArray: function (array) { return __popDataArray(array); },
        fromData: function (data) { return __popDataCopy(data); },
        isData: function (data) { return __popIsData(data); }
      };
      globalThis.$file = {
        read: function(path) { return __popFileRead(String(path)); },
        list: function(path) { return __popFileList(String(path)); },
        write: function(params) { return __popFileWrite(String(params.path), params.data); },
        copy: function(params) { return __popFileTransfer(String(params.src), String(params.dst), false); },
        move: function(params) { return __popFileTransfer(String(params.src), String(params.dst), true); },
        delete: function(path) { return __popFileAction('delete', String(path)); },
        mkdir: function(path) { return __popFileAction('mkdir', String(path)); },
        exists: function(path) { return __popFileAction('exists', String(path)); },
        isDirectory: function(path) { return __popFileAction('isDirectory', String(path)); }
      };
      globalThis.$websocket = {new: function(options) { return __popWebSocket(options || {}); }};
      globalThis.crypto = {
        getRandomValues: function (array) {
          if (!ArrayBuffer.isView(array) || array.byteLength > 65536) throw new Error('Invalid random buffer');
          const values = __popRandom(array.byteLength);
          if (!values) throw new Error('Secure randomness unavailable');
          new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(values);
          return array;
        }
      };
      globalThis.setTimeout = function (fn, milliseconds) { return __popSchedule(fn, Number(milliseconds || 0) / 1000, false); };
      globalThis.clearTimeout = function (id) { __popInvalidate(Number(id)); };
      globalThis.require = function (name) { return load(name, '/main.js'); };
      globalThis.__popPlugin = load('/main.js', '/main.js');
    })();
    """#
}

import Foundation
import Darwin

/// A killable worker boundary for untrusted JavaScript. This does not add OS sandbox entitlements.
/// Each invocation gets one child process; credentials and content travel only through anonymous pipes.
enum PluginExecutionMode { case isolated, inProcess }

@MainActor
enum PluginProcessIsolation {
    private static var active: [UUID: (root: String, plugin: String, call: PluginProcessCall)] = [:]

    static func cancel(pluginID: String, rootURL: URL) {
        let path = rootURL.standardizedFileURL.path
        let calls = active.values.filter { $0.root == path && $0.plugin == pluginID }.map(\.call)
        calls.forEach { $0.cancelImmediately() }
    }

    static func execute(_ operation: PluginOperation, service: ServiceConfig, rootURL: URL,
                        timeout: TimeInterval, logHandler: @escaping (String, String) -> Void,
                        onStream: ((TranslationOutput) -> Void)?) async throws -> PluginExecutionResult {
        guard let executable = Bundle.main.executableURL else { throw PopError.message("找不到插件工作进程程序。") }
        let request = PluginWorkerRequest(rootPath: rootURL.path, timeout: timeout, service: service, operation: operation)
        let call = PluginProcessCall(executable: executable, timeout: timeout, logHandler: logHandler, onStream: onStream)
        let identifier = UUID()
        active[identifier] = (rootURL.standardizedFileURL.path, service.pluginID, call)
        defer { active.removeValue(forKey: identifier) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                call.start(request, continuation: continuation)
            }
        }, onCancel: { Task { @MainActor in call.cancel() } })
    }

    /// AppMain handles --plugin-worker before creating a normal UI and pumps the main run loop.
    /// This entry point always returns; AppMain must then exit so one invocation cannot retain JS state.
    static func runWorker() async {
        func emit(_ response: PluginWorkerResponse) {
            guard let data = try? JSONEncoder().encode(response), data.count <= PluginProcessCall.maximumMessageSize else { return }
            do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) } catch { }
        }
        do {
            let input = try FileHandle.standardInput.readToEnd() ?? Data()
            guard !input.isEmpty, input.count <= PluginProcessCall.maximumMessageSize else { throw PopError.message("插件工作进程输入为空或过大。") }
            let request = try JSONDecoder().decode(PluginWorkerRequest.self, from: input)
            guard request.timeout.isFinite, request.timeout >= 0.02, request.timeout <= 300,
                  request.rootPath.hasPrefix("/"), request.image?.count ?? 0 <= 20 * 1024 * 1024 else { throw PopError.message("插件工作进程请求无效。") }
            NetworkProxy.install(request.proxy ?? NetworkProxySnapshot())
            let host = PluginService(rootURL: URL(fileURLWithPath: request.rootPath, isDirectory: true), timeout: request.timeout,
                                     executionMode: .inProcess, logHandler: { level, message in emit(PluginWorkerResponse(kind: "log", level: level, message: message)) })
            let result: PluginExecutionResult
            switch request.kind {
            case "translate":
                let value = try await host.translate(TranslationRequest(text: request.text ?? "", source: request.source ?? "auto", target: request.target ?? "en", originalText: request.originalText), service: request.service,
                                                     onStream: { emit(PluginWorkerResponse(kind: "stream", translation: PluginWorkerTranslation($0))) })
                result = .translation(value)
            case "ocr":
                guard let image = request.image else { throw PopError.message("插件工作进程缺少图片。") }
                result = .recognition(try await host.recognize(imageData: image, service: request.service))
            case "tts": result = .speech(.data(try await host.synthesize(text: request.text ?? "", language: request.source ?? "auto", service: request.service)))
            case "validate": result = .validation(try await host.validate(service: request.service))
            default: throw PopError.message("插件工作进程调用类型无效。")
            }
            emit(try PluginWorkerResponse(result))
        } catch { emit(PluginWorkerResponse(kind: "error", message: error.localizedDescription)) }
    }
}

private struct PluginWorkerRequest: Codable {
    var rootPath: String
    var timeout: TimeInterval
    var service: ServiceConfig
    var kind: String
    var text: String?
    var originalText: String?
    var source: String?
    var target: String?
    var image: Data?
    var proxy: NetworkProxySnapshot?
    init(rootPath: String, timeout: TimeInterval, service: ServiceConfig, operation: PluginOperation) {
        self.rootPath = rootPath; self.timeout = timeout; self.service = service
        proxy = NetworkProxy.current
        switch operation {
        case .translation(let request): kind = "translate"; text = request.text; originalText = request.originalText; source = request.source; target = request.target
        case .recognition(let data, let language): kind = "ocr"; image = data; source = language
        case .speech(let text, let language): kind = "tts"; self.text = text; source = language
        case .validation: kind = "validate"
        }
    }
}

private struct PluginWorkerTranslation: Codable {
    var text: String
    var detectedSource: String?
    var pronunciation: String?
    var details: [String]
    var reasoning: String?
    var format: String?
    var dictionary: DictionaryResult?
    init(_ value: TranslationOutput) {
        text = value.text; detectedSource = value.detectedSource; pronunciation = value.pronunciation; details = value.details
        reasoning = value.reasoning; format = value.format; dictionary = value.dictionary
    }
    var output: TranslationOutput { TranslationOutput(text: text, detectedSource: detectedSource, pronunciation: pronunciation, details: details, reasoning: reasoning, format: format, dictionary: dictionary) }
}

private struct PluginWorkerOCR: Codable {
    struct Line: Codable {
        var text: String; var x: Double; var y: Double; var width: Double; var height: Double; var confidence: Float
        init(_ line: OCRLine) { text = line.text; x = line.x; y = line.y; width = line.width; height = line.height; confidence = line.confidence }
        var output: OCRLine { OCRLine(text: text, x: x, y: y, width: width, height: height, confidence: confidence) }
    }
    var text: String; var lines: [Line]; var qrCodes: [String]
    init(_ value: OCRDocument) { text = value.text; lines = value.lines.map(Line.init); qrCodes = value.qrCodes }
    var output: OCRDocument { OCRDocument(text: text, lines: lines.map(\.output), qrCodes: qrCodes) }
}

private struct PluginWorkerValidation: Codable {
    var supported: Bool; var isValid: Bool; var message: String?; var troubleshootingLink: URL?
    init(_ value: PluginValidationResult) { supported = value.supported; isValid = value.isValid; message = value.message; troubleshootingLink = value.troubleshootingLink }
    var output: PluginValidationResult { PluginValidationResult(supported: supported, isValid: isValid, message: message, troubleshootingLink: troubleshootingLink) }
}

private struct PluginWorkerResponse: Codable {
    var kind: String
    var level: String?
    var message: String?
    var translation: PluginWorkerTranslation?
    var ocr: PluginWorkerOCR?
    var validation: PluginWorkerValidation?
    var audio: Data?
    init(kind: String, level: String? = nil, message: String? = nil, translation: PluginWorkerTranslation? = nil) {
        self.kind = kind; self.level = level; self.message = message; self.translation = translation
    }
    init(_ result: PluginExecutionResult) throws {
        kind = "result"
        switch result {
        case .translation(let value): translation = PluginWorkerTranslation(value)
        case .recognition(let value): ocr = PluginWorkerOCR(value)
        case .validation(let value): validation = PluginWorkerValidation(value)
        case .speech(.data(let value)): audio = value
        case .speech(.url): throw PopError.message("工作进程必须先下载插件音频。")
        }
    }
    func result() throws -> PluginExecutionResult {
        if let translation { return .translation(translation.output) }
        if let ocr { return .recognition(ocr.output) }
        if let validation { return .validation(validation.output) }
        if let audio { return .speech(.data(audio)) }
        throw PopError.message("插件工作进程结果为空。")
    }
}

@MainActor
private final class PluginProcessCall {
    nonisolated static let maximumMessageSize = 64 * 1024 * 1024
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: TimeInterval
    private let logHandler: (String, String) -> Void
    private let onStream: ((TranslationOutput) -> Void)?
    private var continuation: CheckedContinuation<PluginExecutionResult, Error>?
    private var deadline: DispatchWorkItem?

    init(executable: URL, timeout: TimeInterval, logHandler: @escaping (String, String) -> Void, onStream: ((TranslationOutput) -> Void)?) {
        process.executableURL = executable
        process.arguments = ["--plugin-worker"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        self.timeout = timeout; self.logHandler = logHandler; self.onStream = onStream
    }

    func start(_ request: PluginWorkerRequest, continuation: CheckedContinuation<PluginExecutionResult, Error>) {
        self.continuation = continuation
        do {
            let data = try JSONEncoder().encode(request)
            guard data.count <= Self.maximumMessageSize else { throw PopError.message("插件工作进程输入超过大小限制。") }
            try process.run()
            let writer = input.fileHandleForWriting, reader = output.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async {
                do { try writer.write(contentsOf: data) } catch { }
                try? writer.close()
            }
            // One serial reader preserves onStream order. No JSValue crosses a thread boundary.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var buffer = Data(), received = 0, messageCount = 0
                do {
                    var bytes = [UInt8](repeating: 0, count: 32 * 1024)
                    while true {
                        // FileHandle.read(upToCount:) can wait for the requested byte count
                        // on a pipe. POSIX read returns currently available stream bytes.
                        let count = bytes.withUnsafeMutableBytes { Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count) }
                        if count < 0 && errno == EINTR { continue }
                        guard count >= 0 else { throw PopError.message("无法读取插件工作进程管道。") }
                        if count == 0 { break }
                        let chunk = Data(bytes.prefix(count))
                        buffer.append(chunk); received += chunk.count
                        guard received <= PluginProcessCall.maximumMessageSize, buffer.count <= PluginProcessCall.maximumMessageSize else { throw PopError.message("插件工作进程响应超过大小限制。") }
                        while let newline = buffer.firstIndex(of: 10) {
                            messageCount += 1
                            guard messageCount <= 10000 else { throw PopError.message("插件工作进程事件数量超过限制。") }
                            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                            let packet = try JSONDecoder().decode(PluginWorkerResponse.self, from: line)
                            DispatchQueue.main.async { [weak self] in self?.receive(packet) }
                        }
                    }
                    guard buffer.isEmpty else { throw PopError.message("插件工作进程响应不完整。") }
                    DispatchQueue.main.async { [weak self] in self?.ended() }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { [weak self] in self?.finish(.failure(PopError.message("插件工作进程通信失败：" + message))) }
                }
                try? reader.close()
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finish(.failure(PopError.message("插件进程超时（\(self.timeout) 秒），已终止。")))
            }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        } catch { finish(.failure(error)) }
    }

    func cancel() { finish(.failure(CancellationError())) }
    /// Replacement/removal waits for process death before changing package/cache paths.
    func cancelImmediately() {
        // waitUntilExit may pump the main run loop. Retire the continuation first so
        // a reentrant pipe EOF cannot win the race and report a crash instead.
        let pending = continuation
        continuation = nil; deadline?.cancel(); deadline = nil
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        pending?.resume(throwing: CancellationError())
    }
    private func receive(_ packet: PluginWorkerResponse) {
        guard continuation != nil else { return }
        switch packet.kind {
        case "stream": if let output = packet.translation { onStream?(output.output) }
        case "log": logHandler(packet.level ?? "info", packet.message ?? "")
        case "error": finish(.failure(PopError.message(packet.message ?? "插件工作进程失败。")))
        case "result": do { finish(.success(try packet.result())) } catch { finish(.failure(error)) }
        default: finish(.failure(PopError.message("插件工作进程响应类型无效。")))
        }
    }
    private func ended() {
        guard continuation != nil else { return }
        finish(.failure(PopError.message("插件工作进程提前退出或未返回结果。")))
    }
    private func finish(_ result: Result<PluginExecutionResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.cancel(); deadline = nil
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        continuation.resume(with: result)
    }
}

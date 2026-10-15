import Foundation

enum HTTPTranslationError: LocalizedError, Equatable {
    case configuration(String)
    case missingAPIKey(String)
    case unsupportedService
    case invalidResponse(String)
    case http(Int, String)
    case provider(String, String)
    case timedOut
    case network(Int)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .invalidResponse(let message): return message
        case .missingAPIKey(let provider): return "请先为 \(provider) 填写 API Key。"
        case .unsupportedService: return "这个服务不使用 HTTP 翻译接口。"
        case .http(let status, let message): return "服务返回 HTTP \(status)。\(message)"
        case .provider(let code, let message): return "服务错误（\(code)）：\(message)"
        case .timedOut: return "翻译请求超时，请检查网络或本地模型。"
        case .network(let code): return "无法连接翻译服务（网络错误 \(code)），请检查服务地址。"
        }
    }
}

/// Official provider APIs only. Requests, source text and credentials remain in
/// memory and are never logged or persisted by this transport.
struct HTTPTranslationService {
    private let sessions: NetworkProxySessionProvider
    private var session: URLSession { sessions.session }
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 60) {
        self.timeout = timeout.isFinite ? max(1, min(timeout, 600)) : 60
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = self.timeout; config.timeoutIntervalForResource = self.timeout
        sessions = NetworkProxySessionProvider(session: session, configuration: config, delegate: TranslationSessionDelegate())
    }

    func translate(_ request: TranslationRequest, service: ServiceConfig, apiKey: String,
                   onStream: (@Sendable (TranslationOutput) -> Void)? = nil) async throws -> TranslationOutput {
        let credentials = try CloudServiceCredentials(apiKey)
        do {
            try Task.checkCancellation()
            let streaming = CloudServiceRequests.useStream(service, callbackPresent: onStream != nil)
            let outgoing = try CloudServiceRequests.build(request, service: service, credentials: credentials,
                                                         timeout: timeout, streaming: streaming, now: Date(), nonce: UUID().uuidString)
            if streaming {
                return try await receiveStream(outgoing, service: service, credentials: credentials, onStream: onStream)
            }
            let (data, response) = try await session.data(for: outgoing)
            try Task.checkCancellation()
            try validate(response, data: data, credentials: credentials)
            return try CloudServiceResponses.decode(data, service: service)
        } catch let error as HTTPTranslationError {
            switch error {
            case .http(let status, let message): throw HTTPTranslationError.http(status, credentials.redact(message))
            case .provider(let code, let message): throw HTTPTranslationError.provider(credentials.redact(code), credentials.redact(message))
            case .invalidResponse(let message): throw HTTPTranslationError.invalidResponse(credentials.redact(message))
            default: throw error
            }
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            if error.code == .timedOut { throw HTTPTranslationError.timedOut }
            throw HTTPTranslationError.network(error.code.rawValue)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw HTTPTranslationError.invalidResponse("翻译请求未完成，请检查网络与服务配置。")
        }
    }

    // Public within the app module for deterministic protocol/signature tests and
    // future OCR/TTS adapters. Supplying now/nonce never changes global state.
    func buildRequest(_ input: TranslationRequest, service: ServiceConfig, apiKey: String,
                      streaming: Bool? = nil, now: Date = Date(), nonce: String = UUID().uuidString) throws -> URLRequest {
        try CloudServiceRequests.build(input, service: service, credentials: CloudServiceCredentials(apiKey),
                                       timeout: timeout, streaming: streaming ?? CloudServiceRequests.useStream(service),
                                       now: now, nonce: nonce)
    }

    func endpointURL(_ service: ServiceConfig) throws -> URL {
        try CloudServiceRequests.endpoint(service, streaming: CloudServiceRequests.useStream(service))
    }

    private func receiveStream(_ request: URLRequest, service: ServiceConfig, credentials: CloudServiceCredentials,
                               onStream: (@Sendable (TranslationOutput) -> Void)?) async throws -> TranslationOutput {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw HTTPTranslationError.invalidResponse("服务返回非 HTTP 响应。") }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if OllamaProtocol.isNative(service), (200..<300).contains(http.statusCode),
           type.contains("application/x-ndjson") || type.contains("application/ndjson") {
            var framing = OllamaNDJSONDecoder()
            var state = CloudServiceAIAccumulator(kind: "ollama", format: service.options["format"] == "markdown" ? "markdown" : "plain")
            for try await byte in bytes {
                if byte == 10 { try Task.checkCancellation() }
                if let line = try framing.append(byte), try state.event(name: "", data: line) { onStream?(state.output()) }
                if state.terminal { break }
            }
            try Task.checkCancellation()
            if let line = try framing.finish(), try state.event(name: "", data: line) { onStream?(state.output()) }
            return try state.final()
        }
        if !(200..<300).contains(http.statusCode) || !type.contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 16 * 1024 * 1024 else { throw HTTPTranslationError.invalidResponse("服务响应超过本地允许的大小。") }
                data.append(byte)
            }
            try validate(response, data: data, credentials: credentials)
            // Compatible servers may ignore stream=true and return valid JSON.
            let result = try CloudServiceResponses.decode(data, service: service)
            onStream?(result); return result
        }
        var framing = CloudServiceSSEDecoder()
        var state = CloudServiceAIAccumulator(kind: ProviderTranslationModels.accumulatorKind(service), format: service.options["format"] == "markdown" ? "markdown" : "plain")
        for try await byte in bytes {
            if byte == 10 { try Task.checkCancellation() }
            if let event = try framing.append(byte), try state.event(name: event.0, data: event.1) { onStream?(state.output()) }
            if state.terminal { break }
        }
        try Task.checkCancellation()
        if let event = try framing.finish(), try state.event(name: event.0, data: event.1) { onStream?(state.output()) }
        return try state.final()
    }

    private func validate(_ response: URLResponse, data: Data, credentials: CloudServiceCredentials) throws {
        guard let http = response as? HTTPURLResponse else { throw HTTPTranslationError.invalidResponse("服务返回非 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let message = errorMessage(data: data, status: http.statusCode)
            throw HTTPTranslationError.http(http.statusCode, credentials.redact(message))
        }
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
    static func deepLLanguage(_ code: String, isTarget: Bool) -> String {
        let value = code.replacingOccurrences(of: "_", with: "-").uppercased()
        let base = String(value.split(separator: "-").first ?? Substring(value))
        guard isTarget else { return base }
        switch value {
        case "ZH-HANS", "ZH-CN", "ZH-SG": return "ZH-HANS"
        case "ZH-HANT", "ZH-TW", "ZH-HK": return "ZH-HANT"
        case "EN", "EN-US": return "EN-US"
        case "EN-GB": return "EN-GB"
        case "PT", "PT-BR": return "PT-BR"
        case "PT-PT": return "PT-PT"
        default: return base
        }
    }
    static func googleLanguage(_ code: String) -> String {
        switch code.lowercased() {
        case "zh-hans", "zh-cn", "zh-sg": return "zh-CN"
        case "zh-hant", "zh-tw", "zh-hk": return "zh-TW"
        default: return String(code.lowercased().split(separator: "-").first ?? Substring(code))
        }
    }

    private func errorMessage(data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = json["error"] as? [String: Any]
            let responseError = (json["Response"] as? [String: Any])?["Error"] as? [String: Any]
            let message = error?["message"] as? String ?? json["message"] as? String ?? json["Message"] as? String ?? json["error_msg"] as? String ?? responseError?["Message"] as? String ?? json["error"] as? String
            if let message, !message.isEmpty { return String(message.prefix(1000)) }
        }
        switch status {
        case 401, 403: return "认证失败或没有权限，请检查密钥和服务配置。"
        case 404: return "接口或模型不存在，请检查完整服务地址和模型 ID。"
        case 413: return "原文超过服务允许的大小。"
        case 429: return "请求过于频繁或额度不足。"
        case 456: return "DeepL 翻译额度已用尽。"
        case 500...599: return "服务暂时不可用，请稍后重试。"
        case 300..<400: return "服务地址发生重定向。请填写最终接口地址。"
        default: return "请检查服务配置与输入内容。"
        }
    }
}

/// Prevent credential forwarding to redirect targets.
private final class TranslationSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

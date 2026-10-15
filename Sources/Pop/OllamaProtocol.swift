import Foundation

/// Native Ollama wire contract recovered from Bob 1.21.2 ARM64:
/// 0x10042fd24 (endpoint), 0x10042d5c4 (body), 0x10042dd60 (options),
/// 0x1004c1fe4 (response content/thinking). This is an independent adapter.
enum OllamaProtocol {
    static func isNative(_ service: ServiceConfig) -> Bool {
        service.kind == .openAI && ProviderProtocol.providerID(for: service) == "ollama"
    }

    static func endpoint(_ service: ServiceConfig) throws -> URL {
        let supplied = CloudServiceRequests.nonempty(service.endpoint) ?? "http://localhost:11434"
        guard !supplied.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var components = URLComponents(string: supplied), let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || HTTPTranslationService.isLoopback(host) else {
            throw HTTPTranslationError.configuration("Ollama 地址无效。请输入完整 HTTPS 地址；本机 localhost、127.0.0.1 或 ::1 可使用 HTTP。")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        // Pop's earlier Ollama preset stored /v1. Normalize only this explicitly
        // selected provider, leaving generic OpenAI-compatible services intact.
        for suffix in ["/v1/chat/completions", "/chat/completions", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count); break
        }
        if !path.hasSuffix("/api/chat") { path += path.hasSuffix("/api") ? "/chat" : "/api/chat" }
        components.path = path
        guard let url = components.url else { throw HTTPTranslationError.configuration("无法构造 Ollama 请求地址。") }
        return url
    }

    static func payload(_ input: TranslationRequest, service: ServiceConfig, streaming: Bool) throws -> [String: Any] {
        let content = AIMessageBuilder.resolve(input, service: service)
        var messages: [[String: String]] = []
        if let system = content.system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": content.user])
        var payload: [String: Any] = ["model": try CloudServiceRequests.modelName(service), "messages": messages, "stream": streaming]
        var options: [String: Any] = [:]
        if let temperature = try CloudServiceRequests.temperature(service.options["temperature"]) { options["temperature"] = temperature }
        if let maximum = try CloudServiceRequests.positiveInt(service.options["maxTokens"], name: "最大输出 Tokens") { options["num_predict"] = maximum }
        payload["options"] = options
        switch CloudServiceRequests.nonempty(service.options["thinking"]) ?? "default" {
        case "default", "auto": break // Bob leaves the Optional<Bool> absent for both.
        case "disabled": payload["think"] = false
        case "enabled": payload["think"] = true
        default: throw HTTPTranslationError.configuration("Ollama 思考模式无效，请选择默认、禁用或启用。")
        }
        return payload
    }
}

/// Ollama sends one JSON object per line, not SSE data: fields. Buffer bytes
/// until a complete line so a UTF-8 scalar may cross any network chunk.
struct OllamaNDJSONDecoder {
    private var line = Data()
    private var size = 0
    mutating func append(_ byte: UInt8) throws -> String? {
        size += 1
        guard size <= 16 * 1024 * 1024, line.count <= 2 * 1024 * 1024 else { throw HTTPTranslationError.invalidResponse("Ollama 流式响应超过本地允许的大小。") }
        if byte == 10 { return try finishLine() }
        line.append(byte); return nil
    }
    mutating func finish() throws -> String? { try finishLine() }
    private mutating func finishLine() throws -> String? {
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        guard var text = String(data: line, encoding: .utf8) else { throw HTTPTranslationError.invalidResponse("Ollama 流式响应含无效 UTF-8。") }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

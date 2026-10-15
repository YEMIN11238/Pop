import Foundation

enum OllamaProtocolSelfCheck {
    static func run(session: URLSession) async throws -> [String] {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw PopError.message("Ollama 协议验收：" + message) } }
        let client = HTTPTranslationService(session: session, timeout: 10)
        let input = TranslationRequest(text: "Hello\n\nWorld 😀", source: "en", target: "zh-Hans")
        var service = ServiceConfig(name: "Ollama fixture", kind: .openAI, endpoint: "http://localhost:11434", model: "fixture-model", options: ["provider": "ollama", "stream": "true", "maxTokens": "2048", "temperature": "0.2", "thinking": "enabled", "mode": "custom", "systemPrompt": "Translate to $query.detectToLang", "userPrompt": "$query.text"])
        for (address, expected) in [
            ("", "http://localhost:11434/api/chat"),
            ("http://localhost:11434/", "http://localhost:11434/api/chat"),
            ("http://127.0.0.1:11434/api", "http://127.0.0.1:11434/api/chat"),
            ("http://localhost:11434/api/chat/", "http://localhost:11434/api/chat"),
            ("http://localhost:11434/v1", "http://localhost:11434/api/chat"),
            ("http://localhost:11434/v1/chat/completions", "http://localhost:11434/api/chat"),
            ("https://fixture.invalid/ollama/v1", "https://fixture.invalid/ollama/api/chat")
        ] {
            var candidate = service; candidate.endpoint = address
            try check(try client.endpointURL(candidate).absoluteString == expected, "原生地址或旧预设迁移错误：" + address)
        }
        var generic = service; generic.options = [:]
        try check(try client.endpointURL(generic).path == "/v1/chat/completions", "误改通用 OpenAI 接口")
        var localMT = service; localMT.model = "qwen-mt-plus"
        try check(ProviderTranslationModels.mode(localMT) == .ordinary && ProviderTranslationModels.accumulatorKind(localMT) == "ollama", "本地模型误走云提供商的翻译专用协议")
        let fields = CloudServiceCatalog.optionFields(for: .openAI, options: service.options)
        try check(fields.contains(where: { $0.key == "thinking" }) && !fields.contains(where: { ["reasoningEffort", "maxTokensParameter"].contains($0.key) }), "编辑器仍显示不适用的 OpenAI 字段")
        let request = try client.buildRequest(input, service: service, apiKey: "")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let options = body["options"] as? [String: Any]
        let messages = body["messages"] as? [[String: String]]
        try check(body["model"] as? String == service.model && body["think"] as? Bool == true && body["stream"] as? Bool == true, "原生 model/think/stream 错误")
        try check(options?["num_predict"] as? Int == 2048 && options?["temperature"] as? Double == 0.2 && body["max_tokens"] == nil && body["max_completion_tokens"] == nil, "生成参数未映射至 options")
        try check(messages?.first?["content"] == "Translate to 简体中文" && messages?.last?["content"] == input.text && request.value(forHTTPHeaderField: "Authorization") == nil, "角色/原文/空密钥错误")
        for (value, expected) in [("default", nil), ("auto", nil), ("disabled", false), ("enabled", true)] as [(String, Bool?)] {
            var candidate = service; candidate.options["thinking"] = value
            let payload = try OllamaProtocol.payload(input, service: candidate, streaming: false)
            try check(payload["think"] as? Bool == expected, "thinking→think 映射错误")
        }
        var defaultConfig = service; defaultConfig.options = ["provider": "ollama"]
        let defaultBody = try OllamaProtocol.payload(input, service: defaultConfig, streaming: true)
        try check((defaultBody["options"] as? [String: Any])?.isEmpty == true && defaultBody["think"] == nil && defaultBody["format"] == nil && defaultBody["keep_alive"] == nil, "不应补写未设置的原生选项")

        let updates = OllamaCheckCollector()
        let streamed = "\u{feff}{\"message\":{\"thinking\":\"核对\",\"content\":\"\"},\"done\":false}\r\n\r\n{\"message\":{\"content\":\"你好\"},\"done\":false}\n{\"message\":{\"content\":\" 😀\"},\"done\":true,\"done_reason\":\"stop\"}"
        SelfCheckTranslationProtocol.setHandler(contentType: "application/x-ndjson", chunkWidth: 1) { outgoing in
            try check(outgoing.url?.path == "/api/chat", "传输层仍发送到兼容接口")
            try check(outgoing.value(forHTTPHeaderField: "Accept")?.contains("application/x-ndjson") == true, "流式 Accept 错误")
            return (200, Data(streamed.utf8))
        }
        let result = try await client.translate(input, service: service, apiKey: "", onStream: { updates.add($0) })
        try check(result.text == "你好 😀" && result.reasoning == "核对" && updates.items.contains(where: { $0.text == "你好" }) && updates.items.count >= 3, "UTF-8/CRLF/末行/渐进内容/思考分离失败")

        service.options["stream"] = "false"
        SelfCheckTranslationProtocol.setHandler { _ in (200, Data(#"{"message":{"role":"assistant","content":"你好","thinking":"核对"},"done":true,"done_reason":"stop"}"#.utf8)) }
        let complete = try await client.translate(input, service: service, apiKey: "")
        try check(complete.text == "你好" && complete.reasoning == "核对", "非流式原生响应失败")

        service.options["stream"] = "true"
        SelfCheckTranslationProtocol.setHandler { _ in (200, Data(#"{"message":{"content":"你好"},"done":true}"#.utf8)) }
        let ignoredStream = try await client.translate(input, service: service, apiKey: "")
        try check(ignoredStream.text == "你好", "服务忽略 stream 返回 JSON 时未回退")
        for broken in [
            #"{"error":"model not found fixture-token"}"#,
            #"{"message":{"content":"未完成"},"done":false}"#,
            #"{"message":{"content":"半句"},"done":true,"done_reason":"length"}"#,
            #"{"message":{"thinking":"仅思考"},"done":true}"#,
            "{invalid-json}"
        ] {
            SelfCheckTranslationProtocol.setHandler(contentType: "application/x-ndjson", chunkWidth: 2) { _ in (200, Data((broken + "\n").utf8)) }
            do { _ = try await client.translate(input, service: service, apiKey: "fixture-token"); throw PopError.message("Ollama错误流被当作成功") }
            catch let error as HTTPTranslationError { try check(!error.localizedDescription.contains("fixture-token"), "错误暴露密钥") }
        }
        service.options["stream"] = "false"
        SelfCheckTranslationProtocol.setHandler { _ in (200, Data(#"{"message":{"content":"未完成"},"done":false}"#.utf8)) }
        do { _ = try await client.translate(input, service: service, apiKey: ""); throw PopError.message("Ollama非流式缺少完成标记仍成功") }
        catch let error as HTTPTranslationError { guard case .invalidResponse = error else { throw error } }

        service.options["stream"] = "true"
        let cancelUpdates = OllamaCheckCollector()
        SelfCheckTranslationProtocol.setHandler(contentType: "application/x-ndjson", chunkWidth: 80, delay: 0.01) { _ in
            let frame = "{\"message\":{\"content\":\"片段\"},\"done\":false}\n"
            return (200, Data(String(repeating: frame, count: 200).utf8))
        }
        let task = Task { try await client.translate(input, service: service, apiKey: "", onStream: { cancelUpdates.add($0) }) }
        for _ in 0..<200 {
            if !cancelUpdates.items.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard !cancelUpdates.items.isEmpty else {
            task.cancel(); _ = try? await task.value
            throw PopError.message("Ollama 取消测试未收到首段")
        }
        task.cancel()
        do { _ = try await task.value; throw PopError.message("Ollama 取消后返回假成功") }
        catch is CancellationError {}

        return ["Ollama 原生请求：/api/chat、旧 /v1 预设迁移、system/user、temperature/num_predict/think及字段适用范围通过",
                "Ollama 流式传输：真实 URLSession + 本地 URLProtocol，逐字节 UTF-8、CRLF、BOM、末行无换行、逐步译文与thinking分离通过",
                "Ollama 完整响应与错误：非流式、服务忽略stream回退、错误/提前断流/截断/仅思考/无效JSON/缺done明确失败，密钥错误脱敏通过；没有调用真实模型",
                "Ollama 取消：实际本地 URLSession 在首段之后取消，返回 CancellationError，不产生最终假成功"]
    }
}

private final class OllamaCheckCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranslationOutput] = []
    var items: [TranslationOutput] { lock.lock(); defer { lock.unlock() }; return values }
    func add(_ output: TranslationOutput) { lock.lock(); defer { lock.unlock() }; values.append(output) }
}

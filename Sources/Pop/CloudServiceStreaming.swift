import Foundation

/// Byte-oriented SSE framing preserves blank lines, CRLF and UTF-8 scalars
/// split across arbitrary transport chunks. Unknown fields and comments are ignored.
struct CloudServiceSSEDecoder {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventName = ""
    private var size = 0
    mutating func append(_ byte: UInt8) throws -> (String, String)? {
        size += 1
        guard size <= 16 * 1024 * 1024, line.count <= 2 * 1024 * 1024 else { throw HTTPTranslationError.invalidResponse("流式响应超过本地允许的大小。") }
        if byte == 10 { return try endLine() }
        line.append(byte); return nil
    }
    mutating func finish() throws -> (String, String)? {
        if !line.isEmpty { _ = try endLine() }
        return dispatch()
    }
    private mutating func endLine() throws -> (String, String)? {
        if line.last == 13 { line.removeLast() }
        guard var text = String(data: line, encoding: .utf8) else { throw HTTPTranslationError.invalidResponse("流式响应含无效 UTF-8。") }
        line.removeAll(keepingCapacity: true)
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0]); var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "data" { dataLines.append(value) }
        else if field == "event" { eventName = value }
        return nil
    }
    private mutating func dispatch() -> (String, String)? {
        defer { dataLines.removeAll(keepingCapacity: true); eventName = "" }
        guard !dataLines.isEmpty else { return nil }
        return (eventName, dataLines.joined(separator: "\n"))
    }
}

/// Accumulates only content actually returned by the provider. OpenAI's official
/// Chat Completions does not expose hidden reasoning; reasoning_content and
/// <think> are supported only when an explicitly configured compatible server sends them.
struct CloudServiceAIAccumulator {
    let kind: String
    let format: String
    var rawText = ""
    var reasoning = ""
    var terminal = false
    private var finishReason: String?
    private var refusal = ""
    private var responses = ProviderResponsesAccumulator()

    init(kind: String, format: String) {
        self.kind = kind
        self.format = format
    }

    mutating func event(name: String, data: String) throws -> Bool {
        if data == "[DONE]" {
            if kind == "openAIResponses", !responses.terminal { throw HTTPTranslationError.invalidResponse("Responses 流在 completed 事件之前结束。") }
            terminal = true; return false
        }
        guard let bytes = data.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw HTTPTranslationError.invalidResponse("模型流式事件不是有效 JSON。")
        }
        if let error = json["error"] as? [String: Any] { throw HTTPTranslationError.provider(String(describing: error["type"] ?? error["code"] ?? "error"), error["message"] as? String ?? "模型返回错误。") }
        if kind == "ollama", let error = json["error"] as? String, !error.isEmpty { throw HTTPTranslationError.provider("ollama", error) }
        let oldText = rawText; let oldReasoning = reasoning
        if kind == "openAIResponses" {
            _ = try responses.event(name: name, json: json)
            rawText = responses.text; reasoning = responses.reasoning; terminal = responses.terminal
            return rawText != oldText || reasoning != oldReasoning
        }
        switch kind {
        case "ollama":
            if let message = json["message"] as? [String: Any] {
                rawText += Self.text(message["content"])
                reasoning += Self.text(message["thinking"])
            }
            if json["done"] as? Bool == true {
                finishReason = json["done_reason"] as? String
                terminal = true
            }
        case "openAI", "qwenMTCumulative":
            if let choice = (json["choices"] as? [[String: Any]])?.first {
                let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
                let content = Self.text(delta["content"])
                if kind == "qwenMTCumulative" {
                    if !content.isEmpty { rawText = content }
                } else { rawText += content }
                reasoning += Self.text(delta["reasoning_content"] ?? delta["reasoning"])
                refusal += delta["refusal"] as? String ?? ""
                if let value = choice["finish_reason"] as? String { finishReason = value; terminal = true }
            }
        case "claude":
            let type = json["type"] as? String ?? name
            if type == "content_block_start", let block = json["content_block"] as? [String: Any] { addClaude(block) }
            else if type == "content_block_delta", let delta = json["delta"] as? [String: Any] { addClaude(delta) }
            else if type == "message_delta" { finishReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String }
            else if type == "message_stop" { terminal = true }
        case "gemini":
            if let blocked = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String { refusal = blocked; terminal = true }
            if let candidate = (json["candidates"] as? [[String: Any]])?.first {
                for part in (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
                    if part["thought"] as? Bool == true { reasoning += part["text"] as? String ?? "" }
                    else { rawText += part["text"] as? String ?? "" }
                }
                if let value = candidate["finishReason"] as? String { finishReason = value; terminal = true }
            }
        default: throw HTTPTranslationError.unsupportedService
        }
        guard rawText.utf8.count + reasoning.utf8.count <= 8 * 1024 * 1024 else { throw HTTPTranslationError.invalidResponse("模型文字超过本地允许的大小。") }
        try validateFinish()
        return rawText != oldText || reasoning != oldReasoning
    }
    mutating func complete(_ json: [String: Any]) throws -> TranslationOutput {
        if kind == "openAIResponses" {
            try responses.complete(json)
            rawText = responses.text; reasoning = responses.reasoning; terminal = responses.terminal
        } else if kind == "claude" {
            for block in json["content"] as? [[String: Any]] ?? [] { addClaude(block) }
            finishReason = json["stop_reason"] as? String; terminal = true
        } else {
            let data = try JSONSerialization.data(withJSONObject: json)
            _ = try event(name: "", data: String(decoding: data, as: UTF8.self))
            if kind != "ollama" { terminal = true }
        }
        return try final()
    }
    private mutating func addClaude(_ block: [String: Any]) {
        switch block["type"] as? String {
        case "text", "text_delta": rawText += block["text"] as? String ?? ""
        case "thinking", "thinking_delta": reasoning += block["thinking"] as? String ?? ""
        case "refusal_delta": refusal += block["refusal"] as? String ?? "服务拒绝该请求。"
        default: break // signatures and redacted thinking remain opaque
        }
    }
    func output() -> TranslationOutput {
        let parsed = Self.splitThinking(rawText)
        let thought = [reasoning, parsed.1].filter { !$0.isEmpty }.joined(separator: "\n")
        return TranslationOutput(text: parsed.0, reasoning: thought.isEmpty ? nil : thought, format: format)
    }
    func final() throws -> TranslationOutput {
        try validateFinish()
        guard terminal else { throw HTTPTranslationError.invalidResponse("流式连接提前结束，模型没有返回完成标记。请重试。") }
        var result = output(); result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.text.isEmpty else {
            if result.reasoning?.isEmpty == false { throw HTTPTranslationError.invalidResponse("模型只返回了思考过程，没有译文。请增加输出额度或关闭思考后重试。") }
            throw HTTPTranslationError.invalidResponse("模型没有返回可显示的翻译文字。")
        }
        return result
    }
    private func validateFinish() throws {
        if !refusal.isEmpty { throw HTTPTranslationError.provider("refusal", "服务拒绝生成译文：" + String(refusal.prefix(300))) }
        if ["length", "max_tokens", "MAX_TOKENS", "model_context_window_exceeded"].contains(finishReason ?? "") { throw HTTPTranslationError.provider("truncated", "译文因输出或上下文限制被截断，请缩短原文或增加最大输出 Tokens。") }
        if ["content_filter", "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "refusal"].contains(finishReason ?? "") { throw HTTPTranslationError.provider("blocked", "服务安全策略阻止生成完整译文（\(finishReason!)）。") }
    }
    private static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func splitThinking(_ text: String) -> (String, String) {
        var remaining = text[...]; var body = "", thought = ""
        while let opening = remaining.range(of: "<think>") {
            body += remaining[..<opening.lowerBound]; remaining = remaining[opening.upperBound...]
            if let closing = remaining.range(of: "</think>") { thought += remaining[..<closing.lowerBound]; remaining = remaining[closing.upperBound...] }
            else { thought += remaining; remaining = ""; break }
        }
        var tail = String(remaining)
        // Do not briefly show partial opening tags during a stream.
        for length in stride(from: min(6, tail.count), through: 1, by: -1) {
            if tail.hasSuffix(String("<think>".prefix(length))) { tail.removeLast(length); break }
        }
        body += tail
        return (body, thought)
    }
}

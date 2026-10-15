import Foundation

/// Protocol branches recovered from the installed adapters, independently
/// implemented here. These helpers do not maintain or invent model catalogs.
enum ProviderTranslationModels {
    enum Mode: Equatable { case ordinary, qwenMT, doubaoTranslation }
    static func effectiveModel(_ service: ServiceConfig) -> String {
        if ProviderProtocol.providerID(for: service) == "doubao",
           let endpointID = CloudServiceRequests.nonempty(service.options["accessPointName"]) { return endpointID }
        return service.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func mode(_ service: ServiceConfig, model: String? = nil) -> Mode {
        guard service.kind == .openAI else { return .ordinary }
        if OllamaProtocol.isNative(service) { return .ordinary }
        let model = model ?? effectiveModel(service)
        if model.hasPrefix("qwen-mt-") { return .qwenMT }
        switch ProviderProtocol.providerID(for: service) {
        case "doubao" where model.hasPrefix("doubao-seed-translation-"): return .doubaoTranslation
        default: return .ordinary
        }
    }
    static func accumulatorKind(_ service: ServiceConfig) -> String {
        if OllamaProtocol.isNative(service) { return "ollama" }
        switch mode(service) {
        case .doubaoTranslation: return "openAIResponses"
        case .qwenMT where effectiveModel(service).hasPrefix("qwen-mt-plus"): return "qwenMTCumulative"
        default: return service.kind.rawValue
        }
    }

    /// Provider-specific fields applied only to ordinary Chat Completions.
    /// Translation-only bodies deliberately bypass these generation options.
    static func adjustOrdinaryPayload(_ payload: inout [String: Any], service: ServiceConfig, model: String) throws {
        let provider = ProviderProtocol.providerID(for: service)
        if provider == "doubao" {
            let value = service.options["thinking"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch value {
            case "", "default": payload.removeValue(forKey: "thinking")
            case "disabled", "enabled", "auto": payload["thinking"] = ["type": value]
            default: throw HTTPTranslationError.configuration("豆包思考模式无效，请选择默认、禁用、启用或自动。")
            }
        }
        // The installed Gitee adapter changes an existing optional temperature;
        // it does not turn an absent parameter into a supplied one.
        if provider == "gitee", model == "kimi-k3", payload["temperature"] != nil { payload["temperature"] = 1.0 }
    }

    // Exact non-nil code values recovered from 0x100468488. Unknown target
    // languages fail explicitly instead of silently translating to another one.
    private static let qwenCodes = Set("af ar as ast az be bg bn bs ca ceb cs cy da de el en es et eu fa fi fr gl gu he hi hr hu hy id is it ja jv ka kk km kn ko lb lo lt lv mai mk mr ms mt my nb ne nl oc or pag pl pt ro ru sd si sk sl sq sr sv sw ta te th tl tr uk ur uz vi war yue zh zh_tw".split(separator: " ").map(String.init))
    // Non-nil values from 0x1003ead78's two 54-entry Swift String tables.
    private static let doubaoCodes = Set("zh zh-Hant en ja ko fr es th ar ru pt de it nl pl da fi cs ro sv hu vi id hr ms nb tr uk".split(separator: " ").map(String.init))

    static func language(_ code: String, mode: Mode) throws -> String {
        let lower = code.replacingOccurrences(of: "_", with: "-").lowercased()
        let canonical: String
        switch lower {
        case "zh", "zh-cn", "zh-sg", "zh-hans": canonical = "zh"
        case "zh-tw", "zh-hk", "zh-mo", "zh-hant": canonical = mode == .qwenMT ? "zh_tw" : "zh-Hant"
        case "no": canonical = "nb"
        case "fil": canonical = "tl"
        case "pt-br", "pt-pt": canonical = "pt"
        case "en-us", "en-gb": canonical = "en"
        default: canonical = lower
        }
        let supported = mode == .qwenMT ? qwenCodes : doubaoCodes
        guard supported.contains(canonical) else {
            throw HTTPTranslationError.configuration("\(mode == .qwenMT ? "千问 MT" : "豆包翻译")模型未确认支持目标语言 \(code)。请选择该模型支持的语言。")
        }
        return canonical
    }
    static func payload(_ input: TranslationRequest, service: ServiceConfig, model: String, streaming: Bool) throws -> [String: Any]? {
        let model = effectiveModel(service).isEmpty ? model : effectiveModel(service)
        let mode = mode(service, model: model)
        guard mode != .ordinary else { return nil }
        let target = try language(input.target, mode: mode)
        switch mode {
        case .qwenMT:
            // The recovered constructor uses source_lang=auto even for an
            // explicitly selected source, and sends one raw user message.
            return ["model": model, "stream": streaming,
                    "messages": [["role": "user", "content": input.text]],
                    "translation_options": ["source_lang": "auto", "target_lang": target]]
        case .doubaoTranslation:
            // Source language is nil in the recovered path and thus omitted.
            return ["model": model, "stream": streaming,
                    "input": [["role": "user", "content": [["type": "input_text", "text": input.text,
                        "translation_options": ["target_language": target]]]]]]
        case .ordinary: return nil
        }
    }
    static func endpoint(_ service: ServiceConfig) throws -> URL? {
        guard mode(service) == .doubaoTranslation else { return nil }
        let supplied = CloudServiceRequests.nonempty(service.endpoint) ?? "https://ark.cn-beijing.volces.com/api/v3/responses"
        guard !supplied.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              var components = URLComponents(string: supplied), let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              scheme == "https" || HTTPTranslationService.isLoopback(host) else {
            throw HTTPTranslationError.configuration("豆包服务地址无效；请使用无账号、查询或片段的 HTTPS 地址，本机测试可使用 loopback HTTP。")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") { path = String(path.dropLast("/chat/completions".count)) + "/responses" }
        else if !path.hasSuffix("/responses") { path = (path.isEmpty ? "/api/v3" : path) + "/responses" }
        components.path = path
        guard let url = components.url else { throw HTTPTranslationError.configuration("豆包 Responses 地址无效。") }
        return url
    }
}

extension ProviderProtocol {
    static func translationModelEndpoint(for service: ServiceConfig) throws -> URL? { try ProviderTranslationModels.endpoint(service) }
    static func translationModelPayload(_ input: TranslationRequest, service: ServiceConfig, model: String,
                                        streaming: Bool, prompt: String) throws -> [String: Any]? {
        try ProviderTranslationModels.payload(input, service: service, model: model, streaming: streaming)
    }
}

/// Responses events are deltas; terminal response snapshots replace the same
/// output parts rather than being appended to already streamed text.
struct ProviderResponsesAccumulator {
    private struct Position: Hashable, Comparable {
        let output: Int
        let content: Int
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.output == rhs.output ? lhs.content < rhs.content : lhs.output < rhs.output }
    }
    private var parts: [Position: String] = [:]
    private var thoughts: [Position: String] = [:]
    var reasoning: String { thoughts.keys.sorted().map { thoughts[$0] ?? "" }.joined() }
    private(set) var terminal = false
    private var refused = ""

    var text: String { parts.keys.sorted().map { parts[$0] ?? "" }.joined() }
    mutating func event(name: String, json: [String: Any]) throws -> Bool {
        let old = text, oldReasoning = reasoning
        let type = json["type"] as? String ?? name
        try rejectError(json)
        switch type {
        case "response.output_text.delta": append(json["delta"] as? String ?? "", at: partKey(json))
        case "response.output_text.done": if let text = json["text"] as? String { replace(text, at: partKey(json)) }
        case "response.content_part.added", "response.content_part.done":
            if let part = json["part"] as? [String: Any] { try content(part, key: partKey(json)) }
        case "response.output_item.added", "response.output_item.done":
            if let item = json["item"] as? [String: Any] { try outputItem(item, output: json["output_index"] as? Int ?? 0) }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let key = thoughtKey(json); thoughts[key, default: ""] += json["delta"] as? String ?? ""
        case "response.reasoning_summary_text.done", "response.reasoning_text.done":
            if let value = json["text"] as? String { thoughts[thoughtKey(json)] = value }
        case "response.reasoning_summary_part.added", "response.reasoning_summary_part.done":
            if let part = json["part"] as? [String: Any], let value = part["text"] as? String { thoughts[thoughtKey(json)] = value }
        case "response.refusal.delta": refused += json["delta"] as? String ?? "服务拒绝生成译文。"
        case "response.refusal.done": refused = json["refusal"] as? String ?? "服务拒绝生成译文。"
        case "response.completed":
            guard let response = json["response"] as? [String: Any] else { throw HTTPTranslationError.invalidResponse("Responses 完成事件缺少 response。") }
            try snapshot(response); terminal = true
        case "response.failed", "response.incomplete", "error":
            let response = json["response"] as? [String: Any] ?? json
            try rejectError(response)
            throw HTTPTranslationError.provider(type, (response["incomplete_details"] as? [String: Any])?["reason"] as? String ?? json["message"] as? String ?? "Responses 请求未完成。")
        default: break // created/in_progress/usage/unknown metadata is not output.
        }
        guard refused.isEmpty else { throw HTTPTranslationError.provider("refusal", refused) }
        try checkSize()
        return text != old || reasoning != oldReasoning
    }
    mutating func complete(_ json: [String: Any]) throws {
        try snapshot(json); terminal = true
    }
    private mutating func snapshot(_ json: [String: Any]) throws {
        try rejectError(json)
        guard let status = json["status"] as? String, status == "completed" else {
            throw HTTPTranslationError.provider(json["status"] as? String ?? "missing_status", (json["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "Responses 没有返回 completed 状态。")
        }
        guard let output = json["output"] as? [[String: Any]] else { throw HTTPTranslationError.invalidResponse("Responses 响应缺少 output。") }
        // A full snapshot is authoritative. It avoids duplicating delta text
        // and catches an empty final result instead of reusing a stale preview.
        parts.removeAll(); thoughts.removeAll(); refused = ""
        for (index, item) in output.enumerated() { try outputItem(item, output: index) }
        guard refused.isEmpty else { throw HTTPTranslationError.provider("refusal", refused) }
        try checkSize()
    }
    private mutating func outputItem(_ item: [String: Any], output index: Int) throws {
        if item["type"] as? String == "reasoning" {
            let summary = item["summary"] as? [[String: Any]] ?? []
            for (summaryIndex, part) in summary.enumerated() {
                if let value = part["text"] as? String { thoughts[Position(output: index, content: summaryIndex)] = value }
            }
            return
        }
        guard item["type"] as? String == "message" else { return }
        if let role = item["role"] as? String, role != "assistant" { return }
        for (contentIndex, part) in (item["content"] as? [[String: Any]] ?? []).enumerated() {
            try content(part, key: Position(output: index, content: contentIndex))
        }
    }
    private mutating func content(_ part: [String: Any], key: Position) throws {
        if part["type"] as? String == "refusal" { refused += part["refusal"] as? String ?? "服务拒绝生成译文。" }
        else if part["type"] as? String == "output_text", let value = part["text"] as? String { replace(value, at: key) }
    }
    private func partKey(_ json: [String: Any]) -> Position { Position(output: json["output_index"] as? Int ?? 0, content: json["content_index"] as? Int ?? 0) }
    private func thoughtKey(_ json: [String: Any]) -> Position { Position(output: json["output_index"] as? Int ?? 0, content: json["summary_index"] as? Int ?? 0) }
    private mutating func replace(_ value: String, at key: Position) { parts[key] = value }
    private mutating func append(_ value: String, at key: Position) { replace((parts[key] ?? "") + value, at: key) }
    private func rejectError(_ json: [String: Any]) throws {
        if let error = json["error"] as? [String: Any] { throw HTTPTranslationError.provider(String(describing: error["code"] ?? error["type"] ?? "error"), error["message"] as? String ?? "Responses 返回错误。") }
    }
    private func checkSize() throws { guard text.utf8.count + reasoning.utf8.count <= 8 * 1024 * 1024 else { throw HTTPTranslationError.invalidResponse("模型文字超过本地允许的大小。") } }
}

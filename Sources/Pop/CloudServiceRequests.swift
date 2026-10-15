import Foundation

enum CloudServiceRequests {
    static func isAI(_ kind: ServiceKind) -> Bool { ["openAI", "claude", "gemini"].contains(kind.rawValue) }
    static func useStream(_ service: ServiceConfig, callbackPresent: Bool = false) -> Bool {
        isAI(service.kind) && (service.options["stream"].map { $0.lowercased() == "true" } ?? (OllamaProtocol.isNative(service) || callbackPresent))
    }
    static func endpoint(_ service: ServiceConfig, streaming: Bool = false) throws -> URL {
        if OllamaProtocol.isNative(service) { return try OllamaProtocol.endpoint(service) }
        if ProviderProtocol.isAzure(service) { return try ProviderProtocol.azureEndpoint(service) }
        if let specialized = try ProviderProtocol.translationModelEndpoint(for: service) { return specialized }
        let raw = service.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = CloudServiceCatalog.defaultEndpoint(for: service.kind, options: service.options)
        guard !fallback.isEmpty else { throw HTTPTranslationError.unsupportedService }
        let supplied = raw.isEmpty ? fallback : raw
        guard !supplied.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              var components = URLComponents(string: supplied), let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw HTTPTranslationError.configuration("服务地址无效。请输入完整 http(s) 地址，不要含账号、查询参数或片段。")
        }
        guard scheme == "https" || HTTPTranslationService.isLoopback(host) else {
            throw HTTPTranslationError.configuration("远程和局域网服务需要 HTTPS。目前仅 localhost、127.0.0.1 与 ::1 支持 HTTP。")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let type = service.kind.rawValue
        if type == "openAI" {
            if path.hasSuffix("/chat/completions") {} else if path.isEmpty { path = "/v1/chat/completions" }
            else if path.hasSuffix("/chat") { path += "/completions" } else { path += "/chat/completions" }
        } else if type == "claude" {
            if path.hasSuffix("/messages") {} else if path.isEmpty { path = "/v1/messages" } else { path += "/messages" }
        } else if type == "gemini" {
            let model = try modelName(service)
            if path.contains(":generateContent") || path.contains(":streamGenerateContent") {
                path = path.replacingOccurrences(of: ":streamGenerateContent", with: ":generateContent")
                if streaming { path = path.replacingOccurrences(of: ":generateContent", with: ":streamGenerateContent") }
            } else {
                if path.isEmpty { path = "/v1beta" }
                path += "/models/\(model):" + (streaming ? "streamGenerateContent" : "generateContent")
            }
            if streaming { components.queryItems = [URLQueryItem(name: "alt", value: "sse")] }
        } else {
            guard scheme == "https", components.port == nil || components.port == 443 else { throw HTTPTranslationError.configuration("官方云翻译接口必须使用 HTTPS 的标准端口。") }
            let lower = host.lowercased()
            let allowed: Bool
            switch type {
            case "deepL": allowed = ["api-free.deepl.com", "api.deepl.com"].contains(lower); if path.isEmpty { path = "/v2/translate" }; if path == "/v2" { path += "/translate" }
            case "google": allowed = lower == "translation.googleapis.com"; if path.isEmpty { path = "/language/translate/v2" }
            case "baidu": allowed = ["fanyi-api.baidu.com", "api.fanyi.baidu.com"].contains(lower); if path.isEmpty { path = "/api/trans/vip/translate" }
            case "youdao": allowed = lower == "openapi.youdao.com"; if path.isEmpty { path = "/api" }
            case "tencent": allowed = lower == "tmt.tencentcloudapi.com"
            case "microsoft": allowed = lower == "api.cognitive.microsofttranslator.com" || lower.hasSuffix(".cognitiveservices.azure.com"); if path.isEmpty { path = lower.hasSuffix(".cognitiveservices.azure.com") ? "/translator/text/v3.0/translate" : "/translate" }
            case "aliyun": allowed = lower == "mt.aliyuncs.com" || (lower.hasPrefix("mt.") && lower.hasSuffix(".aliyuncs.com"))
            case "caiyun": allowed = lower == "api.interpreter.caiyunai.com"; if path.isEmpty { path = "/v1/translator" }
            case "niutrans": allowed = lower == "api.niutrans.com"; if path.isEmpty { path = "/NiuTransServer/translation" }
            case "volcano": allowed = lower == "translate.volcengineapi.com"
            case "amazon": allowed = lower.hasPrefix("translate.") && (lower.hasSuffix(".amazonaws.com") || lower.hasSuffix(".amazonaws.com.cn"))
            default: throw HTTPTranslationError.unsupportedService
            }
            guard allowed else { throw HTTPTranslationError.configuration("\(service.kind.title) 的地址不是支持的官方 API 域名。") }
            let expected = ["deepL": "/v2/translate", "google": "/language/translate/v2", "baidu": "/api/trans/vip/translate", "youdao": "/api", "caiyun": "/v1/translator", "niutrans": "/NiuTransServer/translation"]
            if let exact = expected[type], path != exact { throw HTTPTranslationError.configuration("\(service.kind.title) 接口路径应为 \(exact)。") }
            if ["tencent", "aliyun", "volcano", "amazon"].contains(type), !path.isEmpty { throw HTTPTranslationError.configuration("该云服务的 API 地址应指向域名根路径。") }
        }
        components.path = path.isEmpty ? "/" : path
        guard let url = components.url else { throw HTTPTranslationError.configuration("服务地址无法构造。") }
        return url
    }

    static func build(_ input: TranslationRequest, service: ServiceConfig, credentials: CloudServiceCredentials,
                      timeout: TimeInterval, streaming: Bool, now: Date, nonce: String) throws -> URLRequest {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HTTPTranslationError.configuration("请输入需要翻译的文字。") }
        for (value, allowAuto) in [(input.source, true), (input.target, false)] {
            let listed = LanguageCatalog.choices.contains { $0.0 == value }
            let standard = value.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
            guard (allowAuto && value == "auto") || (value != "auto" && (listed || standard)) else { throw HTTPTranslationError.configuration("请选择有效语言，目标语言不能是自动识别。") }
        }
        let kind = service.kind.rawValue; let options = service.options
        var outgoing = URLRequest(url: try endpoint(service, streaming: streaming), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        outgoing.httpMethod = "POST"
        outgoing.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        outgoing.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        var body: Any = [:]
        func key() throws -> String { try credentials.require("apiKey", provider: service.kind.title) }
        func form(_ values: [String: String]) { outgoing.httpBody = CloudServiceSigning.form(values); outgoing.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        func addQuery(_ values: [String: String]) {
            var c = URLComponents(url: outgoing.url!, resolvingAgainstBaseURL: false)!
            c.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }; outgoing.url = c.url!
        }
        switch kind {
        case "openAI":
            if OllamaProtocol.isNative(service) {
                if !credentials.apiKey.isEmpty { outgoing.setValue("Bearer " + credentials.apiKey, forHTTPHeaderField: "Authorization") }
                outgoing.setValue(streaming ? "application/x-ndjson, application/json" : "application/json", forHTTPHeaderField: "Accept")
                body = try OllamaProtocol.payload(input, service: service, streaming: streaming)
                break
            }
            let azure = ProviderProtocol.isAzure(service)
            let model: String
            if azure {
                outgoing.setValue(try credentials.require("apiKey", provider: "Azure OpenAI"), forHTTPHeaderField: "api-key")
                model = nonempty(service.model) == nil ? "" : try modelName(service)
            } else {
                var resolvedService = service
                resolvedService.model = ProviderTranslationModels.effectiveModel(service)
                model = try modelName(resolvedService)
                if !credentials.apiKey.isEmpty { outgoing.setValue("Bearer " + credentials.apiKey, forHTTPHeaderField: "Authorization") }
            }
            if !model.isEmpty, let specialized = try ProviderProtocol.translationModelPayload(input, service: service, model: model, streaming: streaming, prompt: prompt(input, service: service)) {
                body = specialized
                break
            }
            var payload: [String: Any] = ["stream": streaming, "messages": AIMessageBuilder.messages(input, service: service, model: model)]
            if !model.isEmpty { payload["model"] = model }
            if let effort = nonempty(options["reasoningEffort"]) { payload["reasoning_effort"] = effort }
            if let tokens = try positiveInt(options["maxTokens"], name: "最大输出 Tokens") {
                let parameter = nonempty(options["maxTokensParameter"]) ?? (HTTPTranslationService.isLoopback(outgoing.url?.host) ? "max_tokens" : "max_completion_tokens")
                guard ["max_tokens", "max_completion_tokens"].contains(parameter) else { throw HTTPTranslationError.configuration("输出额度参数只能为 max_tokens 或 max_completion_tokens。") }
                payload[parameter] = tokens
            }
            if let temperature = try temperature(options["temperature"]) { payload["temperature"] = temperature }
            try ProviderTranslationModels.adjustOrdinaryPayload(&payload, service: service, model: model)
            body = payload
        case "claude":
            outgoing.setValue(try key(), forHTTPHeaderField: "x-api-key"); outgoing.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let tokens = try positiveInt(options["maxTokens"], name: "最大输出 Tokens") ?? 4096
            let message = AIMessageBuilder.resolve(input, service: service)
            var payload: [String: Any] = ["model": try modelName(service), "max_tokens": tokens, "stream": streaming, "messages": [["role": "user", "content": message.user]]]
            if let system = message.system { payload["system"] = system }
            if let budget = try positiveInt(options["thinkingBudget"], name: "思考预算") {
                guard budget >= 1024, budget < tokens else { throw HTTPTranslationError.configuration("Claude 思考预算至少1024，且应小于最大输出 Tokens。") }
                payload["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
            if let temperature = try temperature(options["temperature"]) {
                guard payload["thinking"] == nil else { throw HTTPTranslationError.configuration("Claude 启用思考时请留空 Temperature。") }
                guard temperature <= 1 else { throw HTTPTranslationError.configuration("Claude Temperature 应为0到1。") }; payload["temperature"] = temperature
            }
            body = payload
        case "gemini":
            outgoing.setValue(try key(), forHTTPHeaderField: "x-goog-api-key")
            let message = AIMessageBuilder.resolve(input, service: service)
            var payload: [String: Any] = ["contents": [["role": "user", "parts": [["text": message.user]]]]]
            if let system = message.system { payload["systemInstruction"] = ["parts": [["text": system]]] }
            var generation: [String: Any] = [:]
            if let tokens = try positiveInt(options["maxTokens"], name: "最大输出 Tokens") { generation["maxOutputTokens"] = tokens }
            if let temperature = try temperature(options["temperature"]) { generation["temperature"] = temperature }
            var thinking: [String: Any] = [:]
            if let value = nonempty(options["thinkingBudget"]) {
                guard let budget = Int(value), budget >= -1 else { throw HTTPTranslationError.configuration("Gemini 思考预算应为-1、0或正整数。") }; thinking["thinkingBudget"] = budget
            }
            if let level = nonempty(options["thinkingLevel"]) {
                guard thinking.isEmpty else { throw HTTPTranslationError.configuration("Gemini 思考预算与等级请选择其一。") }; thinking["thinkingLevel"] = level
            }
            if !thinking.isEmpty { thinking["includeThoughts"] = true; generation["thinkingConfig"] = thinking }
            if !generation.isEmpty { payload["generationConfig"] = generation }; body = payload
        case "deepL":
            outgoing.setValue("DeepL-Auth-Key " + (try key()), forHTTPHeaderField: "Authorization")
            var payload: [String: Any] = ["text": [input.text], "target_lang": HTTPTranslationService.deepLLanguage(input.target, isTarget: true), "preserve_formatting": true]
            if input.source != "auto" { payload["source_lang"] = HTTPTranslationService.deepLLanguage(input.source, isTarget: false) }
            if let value = nonempty(options["modelType"]) { payload["model_type"] = value }; if let value = nonempty(options["formality"]) { payload["formality"] = value }; body = payload
        case "google":
            outgoing.setValue(try key(), forHTTPHeaderField: "X-Goog-API-Key")
            var payload: [String: Any] = ["q": [input.text], "target": HTTPTranslationService.googleLanguage(input.target), "format": "text"]
            if input.source != "auto" { payload["source"] = HTTPTranslationService.googleLanguage(input.source) }; body = payload
        case "baidu":
            let appId = try credentials.require("appId", provider: "百度"); let secret = try credentials.require("secretKey", provider: "百度")
            form(["q": input.text, "from": language(input.source, provider: kind), "to": language(input.target, provider: kind), "appid": appId, "salt": nonce, "sign": CloudServiceSigning.md5(appId + input.text + nonce + secret)])
        case "youdao":
            let appKey = try credentials.require("appKey", provider: "有道"); let secret = try credentials.require("appSecret", provider: "有道")
            let scalars = Array(input.text.unicodeScalars); let signInput = scalars.count > 20 ? String(String.UnicodeScalarView(scalars.prefix(10))) + String(scalars.count) + String(String.UnicodeScalarView(scalars.suffix(10))) : input.text
            let time = String(Int(now.timeIntervalSince1970))
            form(["q": input.text, "from": language(input.source, provider: kind), "to": language(input.target, provider: kind), "appKey": appKey, "salt": nonce, "curtime": time, "signType": "v3", "strict": "true", "sign": CloudServiceSigning.sha256(appKey + signInput + nonce + time + secret)])
        case "tencent":
            guard let project = Int(options["projectId"] ?? "0"), project >= 0 else { throw HTTPTranslationError.configuration("腾讯 Project ID 应为非负整数。") }
            body = ["SourceText": input.text, "Source": language(input.source, provider: kind), "Target": language(input.target, provider: kind), "ProjectId": project]
        case "microsoft":
            outgoing.setValue(try key(), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            if let region = nonempty(options["region"]) { outgoing.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
            var values = ["api-version": "3.0", "to": language(input.target, provider: kind), "textType": "plain"]
            if input.source != "auto" { values["from"] = language(input.source, provider: kind) }; if let category = nonempty(options["category"]) { values["category"] = category }
            addQuery(values); body = [["Text": input.text]]
        case "aliyun":
            form(["FormatType": "text", "SourceText": input.text, "SourceLanguage": language(input.source, provider: kind), "TargetLanguage": language(input.target, provider: kind), "Scene": nonempty(options["scene"]) ?? "general"])
        case "caiyun":
            outgoing.setValue("token " + (try key()), forHTTPHeaderField: "X-Authorization")
            let from = language(input.source, provider: kind), to = language(input.target, provider: kind)
            body = ["source": [input.text], "trans_type": from + "2" + to, "detect": input.source == "auto", "media": "text", "request_id": nonce]
        case "niutrans":
            form(["from": language(input.source, provider: kind), "to": language(input.target, provider: kind), "apikey": try key(), "src_text": input.text])
        case "volcano":
            addQuery(["Action": "TranslateText", "Version": "2020-06-01"])
            var payload: [String: Any] = ["TargetLanguage": language(input.target, provider: kind), "TextList": [input.text]]
            if input.source != "auto" { payload["SourceLanguage"] = language(input.source, provider: kind) }; body = payload
        case "amazon":
            outgoing.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
            outgoing.setValue("AWSShineFrontendService_20170701.TranslateText", forHTTPHeaderField: "X-Amz-Target")
            body = ["SourceLanguageCode": language(input.source, provider: kind), "TargetLanguageCode": language(input.target, provider: kind), "Text": input.text]
        default: throw HTTPTranslationError.unsupportedService
        }
        if outgoing.httpBody == nil { outgoing.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]) }
        switch kind {
        case "tencent": CloudServiceSigning.signTencent(&outgoing, secretId: try credentials.require("secretId", provider: "腾讯"), secretKey: try credentials.require("secretKey", provider: "腾讯"), service: "tmt", action: "TextTranslate", version: "2018-03-21", region: try region(service, fallback: "ap-guangzhou"), now: now)
        case "aliyun": CloudServiceSigning.signAliyun(&outgoing, accessKeyId: try credentials.require("accessKeyId", provider: "阿里云"), accessKeySecret: try credentials.require("accessKeySecret", provider: "阿里云"), action: "TranslateGeneral", version: "2018-10-12", now: now, nonce: nonce)
        case "volcano": CloudServiceSigning.signVolcano(&outgoing, accessKeyId: try credentials.require("accessKeyId", provider: "火山"), secretAccessKey: try credentials.require("secretAccessKey", provider: "火山"), sessionToken: credentials.values["sessionToken"], region: try region(service, fallback: "cn-north-1"), service: "translate", now: now)
        case "amazon": CloudServiceSigning.signAWS(&outgoing, accessKeyId: try credentials.require("accessKeyId", provider: "Amazon"), secretAccessKey: try credentials.require("secretAccessKey", provider: "Amazon"), sessionToken: credentials.values["sessionToken"], region: try region(service, fallback: "us-east-1"), service: "translate", now: now)
        default: break
        }
        return outgoing
    }

    static func nonempty(_ text: String?) -> String? { guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }; return value }
    static func positiveInt(_ text: String?, name: String) throws -> Int? {
        guard let value = nonempty(text) else { return nil }; guard let result = Int(value), result > 0, result <= 1_000_000 else { throw HTTPTranslationError.configuration("\(name) 应为1到1000000的整数。") }; return result
    }
    static func temperature(_ text: String?) throws -> Double? {
        guard let value = nonempty(text) else { return nil }; guard let number = Double(value), number.isFinite, (0...2).contains(number) else { throw HTTPTranslationError.configuration("Temperature 应为0到2的数字。") }; return number
    }
    static func region(_ service: ServiceConfig, fallback: String) throws -> String {
        let value = nonempty(service.options["region"]) ?? fallback
        guard value.range(of: "^[a-z0-9-]{2,40}$", options: .regularExpression) != nil else { throw HTTPTranslationError.configuration("地区 Region 格式无效。") }; return value
    }
    static func modelName(_ service: ServiceConfig) throws -> String {
        var value = nonempty(service.model) ?? ""
        if service.kind.rawValue == "openAI", value.isEmpty {
            let host = URLComponents(string: service.endpoint)?.host
            if HTTPTranslationService.isLoopback(host) { throw HTTPTranslationError.configuration("请填写本地服务器已安装的模型名称，可通过 ollama list 查看。") }
            throw HTTPTranslationError.configuration("请填写此接口实际可用的模型名称。")
        }
        if service.kind == .gemini, value.hasPrefix("models/") { value.removeFirst(7) }
        guard !value.isEmpty else { throw HTTPTranslationError.configuration("请填写账户实际可用的模型 ID。") }
        guard !value.contains("\r"), !value.contains("\n"), value.count <= 200 else { throw HTTPTranslationError.configuration("模型名称格式无效。") }
        if service.kind.rawValue == "gemini", value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil { throw HTTPTranslationError.configuration("Gemini 模型 ID 只能包含字母、数字、点、下划线与连字符。") }
        return value
    }
    static func prompt(_ input: TranslationRequest, service: ServiceConfig) -> String {
        AIMessageBuilder.resolve(input, service: service).system ?? ""
    }
    static func language(_ code: String, provider: String) -> String {
        if code == "auto" { return "auto" }
        let lower = code.lowercased(); let base = String(lower.split(separator: "-").first ?? "")
        let traditional = ["zh-hant", "zh-tw", "zh-hk", "cht"].contains(lower)
        if ["zh-hans", "zh-cn", "zh-sg", "zh-hant", "zh-tw", "zh-hk", "zh", "cht"].contains(lower) {
            switch provider {
            case "baidu", "niutrans": return traditional ? "cht" : "zh"
            case "youdao": return traditional ? "zh-CHT" : "zh-CHS"
            case "microsoft": return traditional ? "zh-Hant" : "zh-Hans"
            case "volcano": return traditional ? "zh-Hant" : "zh"
            case "amazon", "tencent": return traditional ? "zh-TW" : "zh"
            case "aliyun": return traditional ? "zh-tw" : "zh"
            default: return "zh"
            }
        }
        if provider == "baidu" { return ["ja": "jp", "ko": "kor", "fr": "fra", "es": "spa", "ar": "ara", "vi": "vie", "pt": "pt", "yue": "yue"][base] ?? base }
        if ["amazon", "microsoft"].contains(provider), ["pt-pt", "pt-br"].contains(lower) { return lower == "pt-pt" ? "pt-PT" : "pt" }
        return base
    }
}

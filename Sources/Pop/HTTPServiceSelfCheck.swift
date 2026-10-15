import Foundation

/// Executable offline acceptance checks for hosts that have Command Line Tools
/// but no XCTest framework. All URLSession traffic is intercepted by the private
/// protocol below; these checks never contact a translation provider.
public enum HTTPServiceSelfCheck {
    public static func run() async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelfCheckTranslationProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SelfCheckTranslationProtocol.setHandler(nil)
        }
        let client = HTTPTranslationService(session: session, timeout: 17)
        let input = TranslationRequest(text: "Hello\n\nWorld", source: "auto", target: "zh-Hans")
        var passed: [String] = []

        for (endpoint, expected) in [
            ("https://private.example", "https://private.example/v1/chat/completions"),
            ("https://private.example/v1/", "https://private.example/v1/chat/completions"),
            ("https://private.example/prefix/v1", "https://private.example/prefix/v1/chat/completions"),
            ("https://private.example/prefix/chat/completions", "https://private.example/prefix/chat/completions"),
            ("http://localhost:11434", "http://localhost:11434/v1/chat/completions"),
            ("http://[::1]:11434/v1", "http://[::1]:11434/v1/chat/completions")
        ] {
            let url = try client.endpointURL(ServiceConfig(name: "Offline", kind: .openAI, endpoint: endpoint))
            try require(url.absoluteString == expected, "OpenAI/Ollama 地址拼接错误")
        }
        for endpoint in ["file:///tmp/api", "https:///no-host", "https://user:password@private.example/v1", "https://private.example/v1?key=value", "https://private.example/v1#section", "http://192.168.1.10:11434", "https://private.example:99999"] {
            try expectConfigurationError {
                _ = try client.endpointURL(ServiceConfig(name: "Offline", kind: .openAI, endpoint: endpoint))
            }
        }
        passed.append("HTTP：基础地址、完整接口和 IPv4/IPv6 本地地址拼接通过；非法地址和局域网 HTTP 明确拒绝。")

        for endpoint in ["https://gateway.example/custom/v1", "https://gateway.example/custom/v1/chat/completions"] {
            for model in ["models/custom-name", "org/Any-Model:latest", "deepseek-flash"] {
                for stream in [false, true] {
                    let service = ServiceConfig(name: "Compatible fixture", kind: .openAI, endpoint: endpoint, model: model)
                    let request = try client.buildRequest(input, service: service, apiKey: "", streaming: stream)
                    let body = try requestBody(request)
                    try require(request.url?.absoluteString == "https://gateway.example/custom/v1/chat/completions", "兼容接口基础/完整地址拼接错误")
                    try require(body["model"] as? String == model, "任意兼容模型名被改写")
                    try require(body["stream"] as? Bool == stream, "兼容接口流式开关未传入")
                }
            }
        }
        try expectConfigurationError {
            _ = try client.buildRequest(input, service: ServiceConfig(name: "Missing model", kind: .openAI, endpoint: "https://gateway.example/v1", model: ""), apiKey: "")
        }
        passed.append("HTTP：通用兼容基础/完整地址、任意模型名（含models/前缀）、流式开关与空模型拒绝通过。")

        SelfCheckTranslationProtocol.setHandler { request in
            try require(request.httpMethod == "POST", "OpenAI 没有使用 POST")
            try require(request.url?.path == "/v1/chat/completions", "OpenAI 最终路径错误")
            try require(request.value(forHTTPHeaderField: "Authorization") == nil, "空密钥不应生成 Authorization")
            try require(request.timeoutInterval == 17, "请求超时配置未生效")
            let body = try requestBody(request)
            try require(body["model"] as? String == "configured-model", "用户模型名没有传入请求")
            try require(body["stream"] as? Bool == false, "请求必须使用非流式响应")
            let messages = body["messages"] as? [[String: String]]
            try require(messages?.count == 2, "OpenAI messages 数量错误")
            try require(messages?.first?["role"] == "system", "缺少独立翻译 system prompt")
            try require(messages?.first?["content"]?.contains("简体中文") == true, "目标语言没有传入翻译指令")
            try require(messages?.last?["content"] == "The passage between the ~~~ markers needs a 简体中文 translation. Return the translated passage without the markers.\n~~~\n" + input.text + "\n~~~", "翻译指令中的原文或段落被修改")
            return (200, Data(#"{"choices":[{"message":{"content":"  你好\n\n世界  "}}]}"#.utf8))
        }
        let remote = ServiceConfig(name: "Offline", kind: .openAI, endpoint: "https://private.example/v1", model: "configured-model")
        let openAIOutput = try await client.translate(input, service: remote, apiKey: "")
        try require(openAIOutput.text == "你好\n\n世界", "OpenAI 响应没有正确保留段落")
        passed.append("HTTP：通过注入 URLSession 验证 OpenAI POST、模型、非流式 schema、翻译 prompt、空密钥和成功响应。")

        let local = ServiceConfig(name: "Local", kind: .openAI, endpoint: "http://localhost:11434", model: "installed-local-model")
        let localRequest = try client.buildRequest(input, service: local, apiKey: "")
        try require(localRequest.value(forHTTPHeaderField: "Authorization") == nil, "本地服务空密钥应保持无认证头")
        try require(try requestBody(localRequest)["model"] as? String == "installed-local-model", "本地模型名不正确")
        try expectConfigurationError {
            _ = try client.buildRequest(input, service: ServiceConfig(name: "Local", kind: .openAI, endpoint: "http://localhost:11434"), apiKey: "")
        }
        passed.append("HTTP：本地模型可无密钥使用；没有填写已安装模型名时给出配置错误。")

        SelfCheckTranslationProtocol.setHandler { request in
            try require(request.url?.absoluteString == "https://api.deepl.com/v2/translate", "DeepL 官方路径错误")
            try require(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key self-check-placeholder", "DeepL 认证头错误")
            let body = try requestBody(request)
            try require(body["source_lang"] as? String == "PT", "DeepL 源语言地区码应归一化为 PT")
            try require(body["target_lang"] as? String == "ZH-HANT", "DeepL 繁体目标码不正确")
            try require(body["text"] as? [String] == ["Olá"], "DeepL text 数组不正确")
            return (200, Data(#"{"translations":[{"text":"你好","detected_source_language":"PT"}]}"#.utf8))
        }
        let deepL = ServiceConfig(name: "DeepL", kind: .deepL, endpoint: "https://api.deepl.com/v2")
        let deepLOutput = try await client.translate(TranslationRequest(text: "Olá", source: "pt-PT", target: "zh-Hant"), service: deepL, apiKey: "self-check-placeholder")
        try require(deepLOutput.text == "你好" && deepLOutput.detectedSource == "pt", "DeepL 响应解码错误")
        let automatic = try client.buildRequest(input, service: deepL, apiKey: "self-check-placeholder")
        try require(try requestBody(automatic)["source_lang"] == nil, "自动识别不应发送 DeepL source_lang")
        passed.append("HTTP：通过模拟 DeepL 响应验证官方端点、认证头、语言码和自动识别字段。")

        SelfCheckTranslationProtocol.setHandler { request in
            try require(request.url?.absoluteString == "https://translation.googleapis.com/language/translate/v2", "Google 不是官方 v2 地址")
            try require(request.value(forHTTPHeaderField: "X-Goog-API-Key") == "self-check-placeholder", "Google key header 错误")
            try require(request.url?.query == nil, "Google 密钥不得进入 URL 查询参数")
            let body = try requestBody(request)
            try require(body["q"] as? [String] == ["Hello"], "Google q 数组错误")
            try require(body["source"] as? String == "en", "Google 源语言归一化错误")
            try require(body["target"] as? String == "zh-TW", "Google 繁体目标码错误")
            try require(body["format"] as? String == "text", "Google 请求必须明确使用 plain text")
            return (200, Data(#"{"data":{"translations":[{"translatedText":"Tom &#39;n&#39; Jerry &amp; friends &#x4E2D;","detectedSourceLanguage":"en"}]}}"#.utf8))
        }
        let google = ServiceConfig(name: "Google", kind: .google)
        let googleOutput = try await client.translate(TranslationRequest(text: "Hello", source: "en-US", target: "zh-Hant"), service: google, apiKey: "self-check-placeholder")
        try require(googleOutput.text == "Tom 'n' Jerry & friends 中" && googleOutput.detectedSource == "en", "Google HTML 实体或检测语言解码错误")
        passed.append("HTTP：通过模拟 Google v2 验证请求字段、密钥 header、语言码和 HTML 实体还原。")

        SelfCheckTranslationProtocol.setHandler { _ in (401, Data(#"{"error":{"message":"Invalid token self-check-placeholder"}}"#.utf8)) }
        do {
            _ = try await client.translate(input, service: remote, apiKey: "self-check-placeholder")
            throw PopError.message("离线验收未通过：HTTP 401 未产生错误。")
        } catch let error as HTTPTranslationError {
            guard case .http(401, let message) = error else { throw PopError.message("离线验收未通过：401 错误类型不正确。") }
            try require(!message.contains("self-check-placeholder") && message.contains("[已隐藏]"), "服务错误中的密钥未隐藏")
        }
        passed.append("HTTP：401 错误保留状态码，并隐藏服务器回显的模拟密钥。")

        SelfCheckTranslationProtocol.setHandler { _ in (200, Data(#"{"choices":[]}"#.utf8)) }
        do {
            _ = try await client.translate(input, service: remote, apiKey: "")
            throw PopError.message("离线验收未通过：错误响应结构被当成翻译结果。")
        } catch let error as HTTPTranslationError {
            guard case .invalidResponse = error else { throw PopError.message("离线验收未通过：响应结构错误类型不正确。") }
        }
        SelfCheckTranslationProtocol.setHandler { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.translate(input, service: remote, apiKey: "")
            throw PopError.message("离线验收未通过：超时未产生错误。")
        } catch let error as HTTPTranslationError {
            try require(error == .timedOut, "超时错误类型不正确")
        }
        passed.append("HTTP：空结果 schema 和超时均给出明确错误；不把失败当成成功。")

        passed += try await CloudServiceProtocolSelfCheck.run(session: session)

        for (identifier, expected) in [("getUserID", "get User ID"), ("parseHTTPResponse", "parse HTTP Response"), ("user_name", "user name"), ("__HTTP_RESPONSE__", "HTTP RESPONSE"), ("version2Value", "version2 Value")] {
            try require(TextUtilities.normalizedInput(identifier, splitIdentifiers: true) == expected, "标识符拆分失败")
        }
        let paragraph = "Use camelCase in this sentence.\n\nOpenAI and HTTP remain proper names."
        try require(TextUtilities.normalizedInput(paragraph, splitIdentifiers: true) == paragraph, "普通句段不应被标识符规则改变")
        for link in ["https://example.com/my_value?q=getUserID", "www.example.com/my_value", "user_name@example.com"] {
            try require(TextUtilities.normalizedInput(link, splitIdentifiers: true) == link, "网址或邮件被错误拆分")
        }
        try require(TextUtilities.normalizedInput("getUserID", splitIdentifiers: false) == "getUserID", "关闭标识符处理没有生效")
        passed.append("文本：camelCase、snake_case 和缩写边界拆分通过；普通句段、URL 和邮件保持完整。")

        try require(TextUtilities.decodeHTMLEntities("&amp;lt; &#x4E2D;&#25991; &unknown;") == "&lt; 中文 &unknown;", "实体解码必须只执行一次并保留未知实体")
        try require(TextUtilities.detectLanguage("123 !?") == "auto", "没有文字时语言识别应返回未知")
        try require(TextUtilities.detectLanguage("The application translates a selected paragraph into another language and preserves its meaning.") == "en", "英文段落的本地语言识别不正确")
        try require(TextUtilities.readingLanguageCode("zh-Hant") == "zh-TW" && TextUtilities.readingLanguageCode("en-GB") == "en-GB", "朗读语言码映射不正确")
        passed.append("文本：HTML 数字实体、单次解码、本地语言识别和朗读地区码检查通过。")
        return passed
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw PopError.message("离线验收未通过：\(message)。") }
    }

    private static func expectConfigurationError(_ action: () throws -> Void) throws {
        do {
            try action()
            throw PopError.message("离线验收未通过：非法配置没有被拒绝。")
        } catch let error as HTTPTranslationError {
            guard case .configuration = error else { throw PopError.message("离线验收未通过：非法配置错误类型不正确。") }
        }
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count < 0 { throw PopError.message("离线验收未通过：请求 body stream 无法读取。") }
                if count == 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            data = result
        } else {
            throw PopError.message("离线验收未通过：请求缺少 JSON body。")
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PopError.message("离线验收未通过：请求不是 JSON object。") }
        return body
    }
}

final class SelfCheckTranslationProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var contentType = "application/json"
    private static var chunkWidth = 0
    private static var delay: TimeInterval = 0
    private let stopLock = NSLock()
    private var stopped = false

    static func setHandler(contentType: String = "application/json", chunkWidth: Int = 0, delay: TimeInterval = 0, _ value: Handler?) {
        lock.lock()
        handler = value
        self.contentType = contentType
        self.chunkWidth = chunkWidth
        self.delay = delay
        lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        let contentType = Self.contentType
        let chunkWidth = Self.chunkWidth
        let delay = Self.delay
        Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType]) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let width = max(1, chunkWidth > 0 ? chunkWidth : data.count)
                var start = 0
                while start < data.count {
                    stopLock.lock(); let stop = stopped; stopLock.unlock()
                    if stop { return }
                    let end = min(data.count, start + width)
                    client?.urlProtocol(self, didLoad: data.subdata(in: start..<end)); start = end
                    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                }
                stopLock.lock(); let stop = stopped; stopLock.unlock()
                if !stop { client?.urlProtocolDidFinishLoading(self) }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { stopLock.lock(); stopped = true; stopLock.unlock() }
}

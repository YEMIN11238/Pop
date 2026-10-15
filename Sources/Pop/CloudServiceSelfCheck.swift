import Foundation

/// All requests use SelfCheckTranslationProtocol. No real credentials, provider
/// connections, disk configuration or account state participate in these checks.
enum CloudServiceProtocolSelfCheck {
    static func run(session: URLSession) async throws -> [String] {
        let client = HTTPTranslationService(session: session, timeout: 10)
        let input = TranslationRequest(text: "Hello\n\nWorld", source: "auto", target: "zh-Hans")
        var passed: [String] = []
        passed += try await OllamaProtocolSelfCheck.run(session: session)
        passed += try await runAzure(session: session)
        passed += try await runTranslationModels(session: session)
        passed += try await runResponsesCancellation(session: session)
        let openAI = ServiceConfig(name: "Fixture", kind: .openAI, endpoint: "https://fixture.example/v1", model: "fixture-model", options: ["stream": "true", "prompt": "Translate {{source}} to {{target}}", "reasoningEffort": "low", "maxTokens": "1000", "temperature": "0.2", "format": "markdown"])
        _ = try client.buildRequest(TranslationRequest(text: "中文", source: "zh-Hans", target: "pysx"), service: openAI, apiKey: "")
        do { _ = try client.buildRequest(TranslationRequest(text: "Hello", source: "auto", target: "xxxx"), service: openAI, apiKey: ""); throw PopError.message("云协议验收失败：未知四字码未被拒绝") }
        catch let error as HTTPTranslationError { guard case .configuration = error else { throw error } }
        passed.append("云语言：公开语言表中的pysx特殊码可构造请求，未知四字码仍拒绝；供应商能力由实际响应判断")
        let updates = CloudServiceCheckCollector()
        let openAIEvents = ": heartbeat\r\n\r\ndata: {\"choices\":[{\"delta\":{\"reasoning_content\":\"检查语义\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream; charset=utf-8", chunkWidth: 2) { request in
            let json = try object(request)
            try require(json["stream"] as? Bool == true && json["max_completion_tokens"] as? Int == 1000, "OpenAI 流式/输出参数错误")
            try require(json["reasoning_effort"] as? String == "low" && json["temperature"] as? Double == 0.2, "OpenAI 推理/温度参数错误")
            let messages = json["messages"] as? [[String: String]]
            try require(messages?.first?["content"] == "Translate auto-detect to zh-Hans" && messages?.last?["content"] == input.text, "自定义 prompt 模板或原文隔离错误")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "JSON 单密钥读取错误")
            return (200, Data(openAIEvents.utf8))
        }
        let openAIResult = try await client.translate(input, service: openAI, apiKey: #"{"apiKey":"fixture-token"}"#, onStream: { updates.add($0) })
        try require(openAIResult.text == "你好" && openAIResult.reasoning == "检查语义" && openAIResult.format == "markdown", "OpenAI SSE 累计输出/思考分离失败")
        try require(updates.items.count >= 3 && updates.items.contains(where: { $0.text == "你" }), "流式请求只在结束后生成了单个结果")
        passed.append("云AI：OpenAI 实际 URLSession SSE、跨块UTF8、CRLF/heartbeat、累计预览、自定义prompt、参数和JSON密钥通过")

        var claude = ServiceConfig(name: "Claude fixture", kind: .claude, model: "fixture-claude", options: ["stream": "true", "maxTokens": "2048", "thinkingBudget": "1024"])
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 3) { request in
            let json = try object(request)
            try require(request.url?.path == "/v1/messages" && request.value(forHTTPHeaderField: "x-api-key") == "fixture-token" && request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Claude endpoint/auth/version 错误")
            try require(json["system"] is String && (json["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 1024, "Claude system/thinking schema 错误")
            return (200, Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"核对\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        }
        let claudeResult = try await client.translate(input, service: claude, apiKey: "fixture-token")
        try require(claudeResult.text == "你好" && claudeResult.reasoning == "核对", "Claude 流式思考或正文错误")
        claude.options["stream"] = "false"
        SelfCheckTranslationProtocol.setHandler { _ in (200, Data(#"{"content":[{"type":"thinking","thinking":"核对"},{"type":"text","text":"你好"}],"stop_reason":"end_turn"}"#.utf8)) }
        let claudePlain = try await client.translate(input, service: claude, apiKey: "fixture-token")
        try require(claudePlain.text == "你好", "Claude 非流式输出错误")
        passed.append("云AI：Claude Messages 的认证、system、思考预算及流式/非流式正文与thinking分离通过")

        let gemini = ServiceConfig(name: "Gemini fixture", kind: .gemini, model: "fixture-gemini", options: ["stream": "true", "thinkingBudget": "0"])
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 1) { request in
            let json = try object(request)
            try require(request.url?.path == "/v1beta/models/fixture-gemini:streamGenerateContent" && request.url?.query == "alt=sse", "Gemini 流式地址错误")
            try require(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-token" && json["systemInstruction"] != nil, "Gemini key header/systemInstruction错误")
            let config = json["generationConfig"] as? [String: Any]; let thinking = config?["thinkingConfig"] as? [String: Any]
            try require(thinking?["thinkingBudget"] as? Int == 0 && thinking?["includeThoughts"] as? Bool == true, "Gemini thinkingConfig错误")
            return (200, Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"核对\",\"thought\":true},{\"text\":\"你好\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8))
        }
        let geminiResult = try await client.translate(input, service: gemini, apiKey: "fixture-token")
        try require(geminiResult.text == "你好" && geminiResult.reasoning == "核对", "Gemini 思考和正文错误")
        passed.append("云AI：Gemini streamGenerateContent、key header、generation/thinking配置及thought正文分离通过")

        for event in [
            "data: {\"choices\":[{\"delta\":{\"content\":\"半句\"},\"finish_reason\":\"length\"}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"refusal\":\"refused fixture-token\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"只有思考\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"未结束\"}}]}\n\n"
        ] {
            SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 7) { _ in (200, Data(event.utf8)) }
            do { _ = try await client.translate(input, service: openAI, apiKey: "fixture-token"); throw PopError.message("云协议验收失败：错误流被当作成功") }
            catch let error as HTTPTranslationError { try require(!error.localizedDescription.contains("fixture-token"), "流式错误暴露密钥") }
        }
        passed.append("云AI：截断、服务拒绝、只有思考和提前断流均明确失败，错误中的密钥被隐藏")

        let fixtures: [(ServiceKind, String, String)] = [
            (.baidu, #"{"appId":"fixture-app","secretKey":"fixture-secret"}"#, #"{"from":"en","trans_result":[{"dst":"你好"}]}"#),
            (.youdao, #"{"appKey":"fixture-app","appSecret":"fixture-secret"}"#, #"{"errorCode":"0","translation":["你好"],"l":"en2zh-CHS"}"#),
            (.tencent, #"{"secretId":"fixture-id","secretKey":"fixture-secret"}"#, #"{"Response":{"TargetText":"你好","Source":"en"}}"#),
            (.microsoft, "fixture-token", #"[{"detectedLanguage":{"language":"en"},"translations":[{"text":"你好","to":"zh-Hans"}]}]"#),
            (.aliyun, #"{"accessKeyId":"fixture-id","accessKeySecret":"fixture-secret"}"#, #"{"Code":"200","Data":{"Translated":"你好","DetectedLanguage":"en"}}"#),
            (.caiyun, "fixture-token", #"{"target":["你好"]}"#),
            (.niutrans, "fixture-token", #"{"tgt_text":"你好","from":"en"}"#),
            (.volcano, #"{"accessKeyId":"fixture-id","secretAccessKey":"fixture-secret"}"#, #"{"TranslationList":[{"Translation":"你好","DetectedSourceLanguage":"en"}],"ResponseMetadata":{"Error":null}}"#),
            (.amazon, #"{"accessKeyId":"fixture-id","secretAccessKey":"fixture-secret","sessionToken":"fixture-session"}"#, #"{"TranslatedText":"你好","SourceLanguageCode":"en"}"#)
        ]
        for (kind, credentials, response) in fixtures {
            let service = ServiceConfig(name: "Fixture", kind: kind, options: CloudServiceCatalog.defaultOptions(for: kind))
            SelfCheckTranslationProtocol.setHandler { request in
                try require(request.httpMethod == "POST" && request.url?.scheme == "https", "云服务未用 HTTPS POST")
                try require(!request.url!.absoluteString.contains("fixture-token") && !request.url!.absoluteString.contains("fixture-secret"), "云服务密钥进入 URL")
                switch kind {
                case .baidu: let form = try formValues(request); try require(form["appid"] == "fixture-app" && form["q"] == input.text && form["sign"]?.count == 32, "百度表单/签名错误")
                case .youdao: let form = try formValues(request); try require(form["signType"] == "v3" && form["to"] == "zh-CHS" && form["sign"]?.count == 64, "有道v3表单错误")
                case .tencent: try require(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("TC3-HMAC-SHA256") == true && (try object(request))["ProjectId"] as? Int == 0, "腾讯TC3/ProjectId错误")
                case .microsoft: try require(request.url?.query?.contains("api-version=3.0") == true && request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "fixture-token", "Microsoft v3认证错误")
                case .aliyun: try require(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("ACS3-HMAC-SHA256") == true && (try formValues(request))["SourceText"] == input.text, "阿里ACS3/表单错误")
                case .caiyun: try require(request.value(forHTTPHeaderField: "X-Authorization") == "token fixture-token" && (try object(request))["trans_type"] as? String == "auto2zh", "彩云认证/方向错误")
                case .niutrans: try require((try formValues(request))["src_text"] == input.text, "小牛原文表单错误")
                case .volcano: try require(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("HMAC-SHA256") == true && request.url?.query?.contains("Action=TranslateText") == true && (try object(request))["SourceLanguage"] == nil, "火山签名/自动语种错误")
                case .amazon: try require(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true && request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "fixture-session" && request.value(forHTTPHeaderField: "X-Amz-Target")?.hasSuffix("TranslateText") == true, "Amazon SigV4/临时Token错误")
                default: break
                }
                return (200, Data(response.utf8))
            }
            let result = try await client.translate(input, service: service, apiKey: credentials)
            try require(result.text == "你好", "\(kind.title)响应解码错误")
        }
        passed.append("官方云翻译：百度/有道/腾讯/Microsoft/阿里/彩云/小牛/火山/Amazon九家POST、鉴权、schema与模拟译文通过")

        try require(CloudServiceSigning.md5("abc") == "900150983cd24fb0d6963f7d28e17f72", "MD5向量错误")
        try require(CloudServiceSigning.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256向量错误")
        try require(CloudServiceSigning.hex(CloudServiceSigning.hmac(Data(repeating: 0x0b, count: 20), "Hi There")) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "RFC4231 HMAC向量错误")
        var official = URLRequest(url: URL(string: "https://ecs.cn-shanghai.aliyuncs.com/?ImageId=win2019_1809_x64_dtc_zh-cn_40G_alibase_20230811.vhd&RegionId=cn-shanghai")!)
        official.httpMethod = "POST"
        CloudServiceSigning.signAliyun(&official, accessKeyId: "YourAccessKeyId", accessKeySecret: "YourAccessKeySecret", action: "RunInstances", version: "2014-05-26", now: ISO8601DateFormatter().date(from: "2023-10-26T10:22:32Z")!, nonce: "3156853299f313e23d1673dc12e1703d")
        try require(official.value(forHTTPHeaderField: "Authorization")?.hasSuffix("06563a9e1b43f5dfe96b81484da74bceab24a1d853912eee15083a6f0f3283c0") == true, "阿里官方ACS3签名向量错误")
        let tencent = try client.buildRequest(input, service: ServiceConfig(name: "fixture", kind: .tencent), apiKey: #"{"secretId":"fixture-id","secretKey":"fixture-secret"}"#, now: Date(timeIntervalSince1970: 1700000000), nonce: "fixed")
        try require(tencent.value(forHTTPHeaderField: "Authorization")?.hasSuffix("fa6d87f84699f5bf7f701c7220ce6061ba63db668972af984b1d10a75fe27856") == true, "腾讯TC3独立计算向量错误")
        passed.append("签名：MD5/SHA256/RFC4231 HMAC向量、阿里官方ACS3向量与腾讯TC3独立计算向量通过")

        SelfCheckTranslationProtocol.setHandler { _ in (200, Data(#"{"Response":{"Error":{"Code":"AuthFailure","Message":"bad fixture-secret"}}}"#.utf8)) }
        do { _ = try await client.translate(input, service: ServiceConfig(name: "Fixture", kind: .tencent), apiKey: #"{"secretId":"fixture-id","secretKey":"fixture-secret"}"#); throw PopError.message("云协议验收失败：200中的业务错误被忽略") }
        catch let error as HTTPTranslationError { try require(!error.localizedDescription.contains("fixture-secret") && error.localizedDescription.contains("AuthFailure"), "业务错误密钥脱敏或错误码错误") }
        passed.append("官方云翻译：HTTP200中的提供商业务错误被识别，多密钥包逐字段脱敏通过")

        let cancellingUpdates = CloudServiceCheckCollector()
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 100, delay: 0.01) { _ in
            (200, Data(String(repeating: "data: {\"choices\":[{\"delta\":{\"content\":\"片段\"}}]}\n\n", count: 200).utf8))
        }
        let task = Task { try await client.translate(input, service: openAI, apiKey: "", onStream: { cancellingUpdates.add($0) }) }
        for _ in 0..<100 { if !cancellingUpdates.items.isEmpty { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!cancellingUpdates.items.isEmpty, "取消测试未收到流式首帧")
        task.cancel()
        do { _ = try await task.value; throw PopError.message("云协议验收失败：流式取消被当作成功") }
        catch is CancellationError {}
        passed.append("云AI：实际URLSession流式请求在首帧后取消，返回CancellationError且停止传输通过")
        return passed
    }

    static func runResponsesCancellation(session: URLSession) async throws -> [String] {
        let client = HTTPTranslationService(session: session, timeout: 10)
        let input = TranslationRequest(text: "Hello", source: "en", target: "zh-Hans")
        let service = ServiceConfig(name: "Responses cancellation fixture", kind: .openAI, endpoint: "https://fixture.example/api/v3/responses", model: "doubao-seed-translation-fixture", options: ["provider": "doubao", "stream": "true"])
        let updates = CloudServiceCheckCollector()
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 160, delay: 0.01) { request in
            try require(request.url?.path == "/api/v3/responses" && (try object(request))["stream"] as? Bool == true, "Responses 取消测试未进入专用流式入口")
            let event = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"片段\"}\n\n"
            return (200, Data(String(repeating: event, count: 200).utf8))
        }
        let task = Task { try await client.translate(input, service: service, apiKey: "fixture-model-key", onStream: { updates.add($0) }) }
        for _ in 0..<200 {
            if !updates.items.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard !updates.items.isEmpty else {
            task.cancel(); _ = try? await task.value
            throw PopError.message("云协议验收失败：Responses 取消测试未收到流式首帧")
        }
        task.cancel()
        do {
            _ = try await task.value
            throw PopError.message("云协议验收失败：Responses 流式取消被当作成功")
        } catch is CancellationError {}
        return ["豆包Responses：实际本地URLSession在收到流式首帧后取消，返回CancellationError，未返回最终假成功通过"]
    }

    static func runTranslationModels(session: URLSession) async throws -> [String] {
        let client = HTTPTranslationService(session: session, timeout: 10)
        let input = TranslationRequest(text: "Hello\n\nWorld 😀", source: "en", target: "zh-Hant")
        var qwen = ServiceConfig(name: "Qwen fixture", kind: .openAI, endpoint: "https://fixture.example/compatible-mode/v1", model: "qwen-mt-plus", options: ["provider": "qwen", "stream": "false", "mode": "custom", "systemPrompt": "must not enter an MT request", "userPrompt": "must not replace the original", "temperature": "0.2", "maxTokens": "100"])
        SelfCheckTranslationProtocol.setHandler { request in
            let json = try object(request)
            try require(request.url?.path == "/compatible-mode/v1/chat/completions" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-model-key", "千问 MT 地址/鉴权错误")
            let messages = json["messages"] as? [[String: String]]
            let options = json["translation_options"] as? [String: String]
            try require(messages == [["role": "user", "content": input.text]] && options == ["source_lang": "auto", "target_lang": "zh_tw"], "千问 MT 必须只发送原文及已恢复的翻译参数")
            try require(json["temperature"] == nil && json["max_completion_tokens"] == nil && json["max_tokens"] == nil, "专用翻译路径泄漏通用采样参数")
            return (200, Data(#"{"choices":[{"message":{"content":"你好"},"finish_reason":"stop"}]}"#.utf8))
        }
        let plain = try await client.translate(input, service: qwen, apiKey: "fixture-model-key")
        try require(plain.text == "你好", "千问 MT 非流式响应错误")

        var azureMT = qwen
        azureMT.endpoint = "https://resource.example"
        azureMT.options["provider"] = "azure"
        azureMT.options["deploymentName"] = "translation"
        let azureRequest = try client.buildRequest(input, service: azureMT, apiKey: "fixture-model-key")
        try require(azureRequest.url?.path == "/openai/deployments/translation/chat/completions" && azureRequest.value(forHTTPHeaderField: "api-key") == "fixture-model-key" && azureRequest.value(forHTTPHeaderField: "Authorization") == nil, "Azure 的 MT 模型改变了部署地址或认证")
        try require((try object(azureRequest)["translation_options"] as? [String: String])?["target_lang"] == "zh_tw", "Azure 未进入共享 qwen-mt 模型分支")
        try expectConfigurationError {
            _ = try client.buildRequest(.init(text: "Hello", source: "en", target: "xx"), service: qwen, apiKey: "fixture-model-key")
        }
        var passed = ["翻译专用模型：千问MT本地URLSession原文/auto源语言/繁体映射与响应，Azure共享MT分支保留api-key和部署URL，未知语言明确拒绝通过"]

        qwen.options["stream"] = "true"
        let qwenUpdates = CloudServiceCheckCollector()
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 2) { request in
            try require(try object(request)["stream"] as? Bool == true, "千问 MT stream 未传入")
            return (200, Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":\"stop\"}]}\n\n".utf8))
        }
        let qwenStream = try await client.translate(input, service: qwen, apiKey: "fixture-model-key", onStream: { qwenUpdates.add($0) })
        try require(qwenStream.text == "你好" && qwenUpdates.items.contains(where: { $0.text == "你" }), "千问 MT Plus 累计内容被重复拼接或没有增量预览")
        passed.append("翻译专用模型：千问MT Plus本地URLSession累计SSE不会重复拼接，并产生逐段结果通过")

        var doubao = ServiceConfig(name: "Doubao fixture", kind: .openAI, endpoint: "https://fixture.example/api/v3/chat/completions", model: "ignored-model", options: ["provider": "doubao", "accessPointName": "doubao-seed-translation-fixture", "stream": "false"])
        let response = #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"你好"}]}]}"#
        SelfCheckTranslationProtocol.setHandler { request in
            let json = try object(request)
            try require(request.url?.path == "/api/v3/responses" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-model-key", "豆包翻译模型未切换 Responses 地址或鉴权错误")
            try require(json["model"] as? String == "doubao-seed-translation-fixture" && json["messages"] == nil, "豆包接入点优先级或Responses schema错误")
            let content = ((json["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first
            let options = content?["translation_options"] as? [String: String]
            try require(content?["type"] as? String == "input_text" && content?["text"] as? String == input.text && options == ["target_language": "zh-Hant"], "豆包翻译参数必须嵌套input/content并省略source_language")
            return (200, Data(response.utf8))
        }
        let doubaoPlain = try await client.translate(input, service: doubao, apiKey: "fixture-model-key")
        try require(doubaoPlain.text == "你好", "豆包Responses完整JSON解码错误")
        doubao.options["stream"] = "true"
        let doubaoUpdates = CloudServiceCheckCollector()
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 3) { request in
            try require(try object(request)["stream"] as? Bool == true && request.url?.path == "/api/v3/responses", "豆包Responses流式请求未进入专用地址")
            let events = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"你\"}\n\nevent: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"好\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":" + response + "}\n\n"
            return (200, Data(events.utf8))
        }
        let doubaoStream = try await client.translate(input, service: doubao, apiKey: "fixture-model-key", onStream: { doubaoUpdates.add($0) })
        try require(doubaoStream.text == "你好" && doubaoUpdates.items.contains(where: { $0.text == "你" }), "豆包Responses delta与最终快照重复或没有预览")
        passed.append("翻译专用模型：豆包接入点优先、Responses地址/嵌套翻译参数、完整JSON与delta加最终快照SSE本地URLSession通过")

        var ordinary = doubao
        ordinary.model = "ignored-model"
        ordinary.options = ["provider": "doubao", "accessPointName": "ep-fixture", "stream": "false", "mode": "custom", "systemPrompt": "system fixture", "userPrompt": "{{text}}", "thinking": "enabled", "temperature": "0.3"]
        let ordinaryRequest = try client.buildRequest(input, service: ordinary, apiKey: "fixture-model-key")
        let ordinaryJSON = try object(ordinaryRequest)
        try require(ordinaryRequest.url?.path == "/api/v3/chat/completions" && ordinaryJSON["model"] as? String == "ep-fixture" && ordinaryJSON["input"] == nil, "豆包普通接入点错误进入Responses或未优先")
        try require((ordinaryJSON["thinking"] as? [String: String])?["type"] == "enabled" && ordinaryJSON["temperature"] as? Double == 0.3 && (ordinaryJSON["messages"] as? [[String: String]]) == [["role": "system", "content": "system fixture"], ["role": "user", "content": input.text]], "豆包普通模型思考/采样或双prompt未保留")
        ordinary.model = ""
        _ = try client.buildRequest(input, service: ordinary, apiKey: "fixture-model-key")
        var gitee = ServiceConfig(name: "Gitee fixture", kind: .openAI, endpoint: "https://fixture.example/v1", model: "kimi-k3", options: ["provider": "gitee", "temperature": "0.3"])
        try require(try object(client.buildRequest(input, service: gitee, apiKey: ""))["temperature"] as? Double == 1.0, "模力方舟kimi-k3已有温度未覆盖1.0")
        gitee.options.removeValue(forKey: "temperature")
        try require(try object(client.buildRequest(input, service: gitee, apiKey: ""))["temperature"] == nil, "模力方舟kimi-k3不应强加缺省温度")
        passed.append("普通模型回归：豆包接入点优先且可替代空model、Chat/双prompt/thinking.type、模力方舟kimi-k3仅覆盖已有temperature通过")
        return passed
    }

    /// Independently runnable with a session that installs the local URLProtocol.
    /// Endpoint validation is exercised before any request reaches that protocol.
    static func runAzure(session: URLSession) async throws -> [String] {
        let client = HTTPTranslationService(session: session, timeout: 10)
        let input = TranslationRequest(text: "Hello\n\nWorld", source: "auto", target: "zh-Hans")
        var service = ServiceConfig(name: "Azure fixture", kind: .openAI, endpoint: "https://resource.example/", model: "", options: ["provider": "azure", "deploymentName": "production", "stream": "false"])
        let root = try client.buildRequest(input, service: service, apiKey: "fixture-azure-key")
        try require(root.url?.absoluteString == "https://resource.example/openai/deployments/production/chat/completions?api-version=2023-03-15-preview", "Azure 资源根地址、部署路径或默认 API Version 错误")
        try require(root.value(forHTTPHeaderField: "api-key") == "fixture-azure-key" && root.value(forHTTPHeaderField: "Authorization") == nil, "Azure 必须使用 api-key，不能发送 Bearer")
        try require(try object(root)["model"] == nil, "Azure 空模型应省略，部署名足以构造请求")

        var escaped = service
        escaped.options["deploymentName"] = "production /?#%中文"
        let escapedURL = try client.endpointURL(escaped)
        let encodedPath = URLComponents(url: escapedURL, resolvingAgainstBaseURL: false)?.percentEncodedPath
        try require(encodedPath == "/openai/deployments/production%20%2F%3F%23%25%E4%B8%AD%E6%96%87/chat/completions", "Azure 部署名必须编码成单个路径段")
        var full = service
        full.endpoint = "https://resource.example/openai/deployments/a%2Fb/chat/completions/?api-version=2024-02-29"
        full.options["deploymentName"] = "ignored"
        full.options["apiVersion"] = "2020-01-01"
        try require(try client.endpointURL(full).absoluteString == "https://resource.example/openai/deployments/a%2Fb/chat/completions?api-version=2024-02-29", "Azure 完整地址的部署名/版本应优先且不得重复编码")
        var customVersion = service; customVersion.options["apiVersion"] = "2024-06-01"
        try require(try client.endpointURL(customVersion).query == "api-version=2024-06-01", "Azure 显式 API Version 未传入")

        var invalidServices: [ServiceConfig] = []
        var missing = service; missing.options.removeValue(forKey: "deploymentName"); invalidServices.append(missing)
        var badVersion = service; badVersion.options["apiVersion"] = "2023-02-29"; invalidServices.append(badVersion)
        for endpoint in ["", "http://remote.example", "https://u:p@resource.example", "https://resource.example/#fragment", "https://resource.example:99999", "https://resource.example/prefix", "https://resource.example/?api-version=2024-01-01&api-version=2024-02-01", "https://resource.example/?api-version=2024-01-01&key=secret", "https://resource.example/?api-version=invalid", "https://resource.example/?api-version", "https://resource.example/openai/deployments/a/b/chat/completions", "https://resource.example/openai/deployments/%0A/chat/completions"] {
            var invalid = service; invalid.endpoint = endpoint; invalidServices.append(invalid)
        }
        for invalid in invalidServices {
            try expectConfigurationError { _ = try client.buildRequest(input, service: invalid, apiKey: "fixture-azure-key") }
        }
        try expectConfigurationError { _ = try client.buildRequest(input, service: service, apiKey: "") }
        let regular = ServiceConfig(name: "OpenAI fixture", kind: .openAI, endpoint: "https://resource.example/v1", model: "original-model")
        let unchanged = try client.buildRequest(input, service: regular, apiKey: "fixture-bearer", streaming: true)
        try require(unchanged.url?.absoluteString == "https://resource.example/v1/chat/completions" && unchanged.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer" && unchanged.value(forHTTPHeaderField: "api-key") == nil, "普通 OpenAI 地址与鉴权被 Azure 分支改变")
        try require(try object(unchanged)["model"] as? String == "original-model", "普通 OpenAI 模型被 Azure 分支改变")
        var passed = ["Azure：资源根地址/完整部署地址、单路径段转义、合法唯一api-version及优先级、缺部署/非法地址/空密钥拒绝，普通OpenAI回归通过"]

        service.model = "gpt-4.1-mini"
        SelfCheckTranslationProtocol.setHandler { request in
            let json = try object(request)
            try require(request.url == root.url && request.value(forHTTPHeaderField: "api-key") == "fixture-azure-key" && request.value(forHTTPHeaderField: "Authorization") == nil, "Azure URLSession 最终地址或认证错误")
            try require(json["model"] as? String == "gpt-4.1-mini" && json["stream"] as? Bool == false, "Azure 用户配置模型或非流式参数被改写")
            let expectedUser = "The passage between the ~~~ markers needs a 简体中文 translation. Return the translated passage without the markers.\n~~~\nHello\n\nWorld\n~~~"
            try require((json["messages"] as? [[String: String]])?.last?["content"] == expectedUser, "Azure messages 未应用配置模式或保留原文")
            return (200, Data(#"{"choices":[{"message":{"content":"你好\n\n世界"}}]}"#.utf8))
        }
        let plain = try await client.translate(input, service: service, apiKey: #"{"apiKey":"fixture-azure-key"}"#)
        try require(plain.text == "你好\n\n世界", "Azure 非流式响应解析错误")
        passed.append("Azure：本地URLProtocol实际URLSession非流式POST、api-key、已配置模型/messages及Chat响应解析通过")

        service.options["stream"] = "true"
        let updates = CloudServiceCheckCollector()
        SelfCheckTranslationProtocol.setHandler(contentType: "text/event-stream", chunkWidth: 1) { request in
            let json = try object(request)
            try require(request.value(forHTTPHeaderField: "api-key") == "fixture-azure-key" && request.value(forHTTPHeaderField: "Accept") == "text/event-stream" && json["stream"] as? Bool == true, "Azure SSE 请求头或stream参数错误")
            return (200, Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        }
        let streamed = try await client.translate(input, service: service, apiKey: "fixture-azure-key", onStream: { updates.add($0) })
        try require(streamed.text == "你好" && updates.items.contains(where: { $0.text == "你" }), "Azure SSE 未产生逐段结果或最终正文错误")
        passed.append("Azure：本地URLProtocol实际URLSession SSE跨块UTF8、增量正文和结束解析通过；未调用真实付费API")
        return passed
    }

    private static func expectConfigurationError(_ operation: () throws -> Void) throws {
        do { try operation() } catch let error as HTTPTranslationError {
            guard case .configuration = error else { throw error }; return
        }
        throw PopError.message("云协议验收失败：无效的服务配置未被拒绝")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw PopError.message("云协议验收失败：" + message) } }
    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw PopError.message("云协议验收失败：缺少body") }
        stream.open(); defer { stream.close() }; var output = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true { let count = stream.read(&bytes, maxLength: bytes.count); if count == 0 { return output }; if count < 0 { throw URLError(.cannotDecodeRawData) }; output.append(contentsOf: bytes.prefix(count)) }
    }
    private static func object(_ request: URLRequest) throws -> [String: Any] { try JSONSerialization.jsonObject(with: body(request)) as? [String: Any] ?? [:] }
    private static func formValues(_ request: URLRequest) throws -> [String: String] {
        let text = String(decoding: try body(request), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map { part in let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false); return (String(pair[0]).removingPercentEncoding ?? "", pair.count > 1 ? String(pair[1]).removingPercentEncoding ?? "" : "") })
    }
}

private final class CloudServiceCheckCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranslationOutput] = []
    var items: [TranslationOutput] { lock.lock(); defer { lock.unlock() }; return values }
    func add(_ value: TranslationOutput) { lock.lock(); values.append(value); lock.unlock() }
}

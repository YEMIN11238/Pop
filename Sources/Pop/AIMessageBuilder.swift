import Foundation

struct AIMessageContent {
    let system: String?
    let user: String
}

/// Independently assembled from the observed mode/template contract and REA
/// 0x100490c98 / 0x10044c1f4 / 0x1004b41b4. Detection and language naming remain
/// local implementations; this is not the original application's Swift source.
enum AIMessageBuilder {
    static func resolve(_ input: TranslationRequest, service: ServiceConfig) -> AIMessageContent {
        let options = service.options
        let legacy = options["mode"] == nil && !(options["prompt"] ?? "").isEmpty
        let configured = options["mode"] ?? (legacy ? "custom" : "translate")
        let source = input.source == "auto" ? TextUtilities.detectLanguage(input.text) : input.source
        let sourceName = languageName(source), targetName = languageName(input.target)
        let polish = configured == "polish" || (configured == "translate" && source != "auto" && source == input.target)

        if configured == "custom" {
            // Legacy {{source}} deliberately keeps its old code/auto-detect
            // meaning. Bob-style $query variables use human language names.
            func substitute(_ text: String, includeText: Bool) -> String {
                var result = text
                    .replacingOccurrences(of: "$query.detectFromLang", with: sourceName)
                    .replacingOccurrences(of: "$query.detectToLang", with: targetName)
                    .replacingOccurrences(of: "{{source}}", with: input.source == "auto" ? "auto-detect" : input.source)
                    .replacingOccurrences(of: "{{target}}", with: input.target)
                if includeText {
                    // One regex pass avoids interpreting template-like text
                    // inserted from the user's source as another placeholder.
                    let regex = try! NSRegularExpression(pattern: #"\$query\.text|\{\{text\}\}"#)
                    let original = result as NSString
                    let matches = regex.matches(in: result, range: NSRange(location: 0, length: original.length))
                    for match in matches.reversed() {
                        let range = Range(match.range, in: result)!
                        result.replaceSubrange(range, with: input.text)
                    }
                }
                return result
            }
            let system = substitute(options["systemPrompt"] ?? options["prompt"] ?? "", includeText: false)
            let template = options["userPrompt"] ?? ""
            return AIMessageContent(system: system.isEmpty ? nil : system,
                                    user: template.isEmpty ? input.text : substitute(template, includeText: true))
        }

        if polish {
            let name = source == "auto" ? "the original language" : sourceName
            return AIMessageContent(
                system: "Revise the supplied passage in \(name). Improve clarity, flow and concision while keeping its meaning and language.\nReturn the revised passage alone, with no preface, notes or commentary. Keep the existing layout, line breaks and punctuation, and leave variable names, markup tags and placeholders unchanged.",
                user: "Edit this \(name) passage:\n\n\(input.text)")
        }

        let system = "Render the supplied text in \(targetName). Respond with the translation alone; omit introductions, explanations and comments."
        let user = input.text.contains("~~~")
            ? "\(targetName):\n\n\(input.text)"
            : "The passage between the ~~~ markers needs a \(targetName) translation. Return the translated passage without the markers.\n~~~\n\(input.text)\n~~~"
        return AIMessageContent(system: system, user: user)
    }

    static func messages(_ input: TranslationRequest, service: ServiceConfig, model: String) -> [[String: String]] {
        let content = resolve(input, service: service)
        let suppressSystem = ["o1-mini", "qwen-mt-", "doubao-seed-translation-"].contains { model.hasPrefix($0) }
        var result: [[String: String]] = []
        if let system = content.system, !suppressSystem { result.append(["role": "system", "content": system]) }
        result.append(["role": "user", "content": content.user])
        return result
    }

    static func languageName(_ code: String) -> String {
        let names = ["auto": "the original language", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "zh": "中文", "en": "English", "ja": "日本語", "ko": "한국어", "yue": "粵語", "wyw": "文言文", "pysx": "拼音缩写"]
        return names[code] ?? Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }
}

enum AIMessageBuilderSelfCheck {
    static func run() throws -> [String] {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw PopError.message("AI 模式自检：" + message) } }
        let input = TranslationRequest(text: "Hello\n\n世界 😀 {{text}} $query.text", source: "en", target: "zh-Hans")
        var service = ServiceConfig(name: "Fixture", kind: .openAI, model: "fixture-model")
        let translated = AIMessageBuilder.resolve(input, service: service)
        try check(translated.system?.contains("简体中文") == true && translated.user.hasSuffix(input.text + "\n~~~"), "翻译模式保留原文段落并使用分隔线")
        let fenced = AIMessageBuilder.resolve(.init(text: "~~~原文~~~", source: "en", target: "zh-Hans"), service: service)
        try check(fenced.user == "简体中文:\n\n~~~原文~~~", "原文已有分隔线时使用无嵌套分隔线分支")
        service.options = ["mode": "polish"]
        let polished = AIMessageBuilder.resolve(input, service: service)
        try check(polished.system?.contains("passage in English") == true && !polished.user.contains("简体中文") && polished.user.hasSuffix(input.text), "润色保持原语言而非目标语言")
        service.options = ["mode": "translate"]
        let same = AIMessageBuilder.resolve(.init(text: "Hello.", source: "en", target: "en"), service: service)
        try check(same.system == polished.system, "源语言与目标语言相同时采用润色指令")
        service.options = ["mode": "custom", "systemPrompt": "From $query.detectFromLang to $query.detectToLang", "userPrompt": "$query.text | {{text}} | {{source}}/{{target}}"]
        let custom = AIMessageBuilder.resolve(input, service: service)
        try check(custom.system == "From English to 简体中文" && custom.user == input.text + " | " + input.text + " | en/zh-Hans", "双模板变量替换必须保持原文中的模板样式文本")
        service.options = ["mode": "custom"]
        let blank = AIMessageBuilder.resolve(input, service: service)
        try check(blank.system == nil && blank.user == input.text, "自定义空system省略，空user回退原文")
        service.options = ["prompt": "Translate {{source}} to {{target}}"]
        let legacy = AIMessageBuilder.resolve(.init(text: "Hello", source: "auto", target: "zh-Hans"), service: service)
        try check(legacy.system == "Translate auto-detect to zh-Hans" && legacy.user == "Hello", "旧prompt配置兼容")
        service.options = [:]
        let oldModel = AIMessageBuilder.messages(input, service: service, model: "o1-mini-2024-09-12")
        let normal = AIMessageBuilder.messages(input, service: service, model: "fixture-model")
        try check(oldModel.count == 1 && oldModel.first?["role"] == "user" && normal.map { $0["role"]! } == ["system", "user"], "受限模型省system，普通模型保持双消息")
        let client = HTTPTranslationService()
        for kind in [ServiceKind.openAI, .claude, .gemini] {
            let configured = ServiceConfig(name: "Fixture", kind: kind, model: "fixture-model", options: ["mode": "custom", "systemPrompt": "", "userPrompt": "Original: $query.text"])
            let request = try client.buildRequest(input, service: configured, apiKey: "fixture-key", streaming: false)
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if kind == .gemini {
                let parts = (payload["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: String]]
                try check(payload["systemInstruction"] == nil && parts?.first?["text"] == "Original: " + input.text, "Gemini未使用自定义user或没有省略空system")
            } else {
                let messages = payload["messages"] as? [[String: String]]
                try check(payload["system"] == nil && messages?.count == 1 && messages?.first?["role"] == "user" && messages?.first?["content"] == "Original: " + input.text, "\(kind.title)未使用自定义user或没有省略空system")
            }
        }
        return ["AI 模式：REA翻译/润色/同语种分支、原文含分隔线、双模板、Unicode与模板样式原文、旧prompt兼容、受限模型消息角色检查通过",
                "AI 模式请求接入：OpenAI/Claude/Gemini实际构造请求使用自定义user，省略空system；没有发起网络请求"]
    }
}

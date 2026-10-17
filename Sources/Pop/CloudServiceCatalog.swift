import Foundation

/// UI metadata only. Secret values belong in Keychain, never ServiceConfig.options.
struct CloudServiceField: Identifiable, Equatable {
    let key: String
    let title: String
    var placeholder = ""
    var required = false
    var defaultValue = ""
    var choices: [String] = []
    var id: String { key }
    func choiceTitle(_ value: String) -> String {
        if key == "mode" { return ["translate": "翻译", "polish": "润色", "custom": "自定义 Prompt"][value] ?? value }
        if key == "thinking" { return ["default": "默认", "disabled": "禁用", "enabled": "启用", "auto": "自动"][value] ?? value }
        return value.isEmpty ? "默认" : value == "true" ? "开启" : value == "false" ? "关闭" : value
    }
}

struct CloudServicePreset: Identifiable {
    let id: String
    let title: String
    let kind: ServiceKind
    let endpoint: String
    var model = ""
    var options: [String: String] = [:]
}

/// A suggested API model identifier, not a hosted account or downloaded model.
struct CloudModelPreset: Identifiable, Equatable {
    let id: String
    let title: String
}

enum CloudServiceCatalog {
    static func secretFields(for kind: ServiceKind, options: [String: String] = [:]) -> [CloudServiceField] {
        func field(_ key: String, _ title: String) -> CloudServiceField { CloudServiceField(key: key, title: title, required: true) }
        switch kind.rawValue {
        case "apple", "plugin", "dictionary": return []
        case "baidu": return [field("appId", "APP ID"), field("secretKey", "密钥")]
        case "youdao": return [field("appKey", "应用 ID / appKey"), field("appSecret", "应用密钥 / appSecret")]
        case "tencent": return [field("secretId", "SecretId"), field("secretKey", "SecretKey")]
        case "aliyun": return [field("accessKeyId", "AccessKey ID"), field("accessKeySecret", "AccessKey Secret")]
        case "volcano", "amazon": return [field("accessKeyId", "Access Key ID"), field("secretAccessKey", "Secret Access Key"), CloudServiceField(key: "sessionToken", title: "临时凭据 Token（可选）")]
        case "openAI":
            let required = ["azure", "zhipu", "siliconflow"].contains(options["provider"] ?? "")
            return [CloudServiceField(key: "apiKey", title: required ? "API Key" : "API Key（可选）", required: required)]
        default: return [field("apiKey", "API Key")]
        }
    }

    static func optionFields(for kind: ServiceKind, options: [String: String] = [:]) -> [CloudServiceField] {
        let region = CloudServiceField(key: "region", title: "地区 / Region", required: true, defaultValue: defaultOptions(for: kind)["region"] ?? "")
        switch kind.rawValue {
        case "openAI", "claude", "gemini":
            var fields = [
                CloudServiceField(key: "mode", title: "模式", defaultValue: mode(for: options), choices: ["translate", "polish", "custom"]),
                CloudServiceField(key: "stream", title: "流式输出", defaultValue: "true", choices: ["true", "false"]),
                CloudServiceField(key: "format", title: "译文显示格式", defaultValue: "plain", choices: ["plain", "markdown"]),
                CloudServiceField(key: "maxTokens", title: "最大输出 Tokens（可选）"),
                CloudServiceField(key: "temperature", title: "Temperature（可选）")
            ]
            fields.insert(contentsOf: [
                CloudServiceField(key: "systemPrompt", title: "角色设定（system）", placeholder: "仅自定义 Prompt 模式有效。可使用 $query.detectFromLang、$query.detectToLang；兼容 {{source}}、{{target}}。", defaultValue: options["prompt"] ?? ""),
                CloudServiceField(key: "userPrompt", title: "用户指令（user）", placeholder: "仅自定义 Prompt 模式有效。可使用 $query.text、$query.detectFromLang、$query.detectToLang；留空直接发送原文。兼容 {{text}}、{{source}}、{{target}}。")
            ], at: 1)
            if kind.rawValue == "openAI" {
                switch options["provider"] {
                case "azure":
                    fields.insert(contentsOf: [CloudServiceField(key: "deploymentName", title: "部署名称 / Deployment Name", placeholder: "资源根地址时必填；完整部署 URL 可留空"), CloudServiceField(key: "apiVersion", title: "API 版本", defaultValue: "2023-03-15-preview")], at: 0)
                case "doubao":
                    fields.insert(CloudServiceField(key: "accessPointName", title: "推理接入点名称（可选）", placeholder: "非空时优先于模型名称，填写实际创建的接入点"), at: 0)
                    fields.append(CloudServiceField(key: "thinking", title: "思考模式（按模型支持）", defaultValue: "default", choices: ["default", "disabled", "enabled", "auto"]))
                case "ollama":
                    fields.append(CloudServiceField(key: "thinking", title: "思考模式（按模型支持）", defaultValue: "default", choices: ["default", "disabled", "enabled"]))
                default: break
                }
                if options["provider"] != "ollama" {
                    fields.append(CloudServiceField(key: "reasoningEffort", title: "推理强度（按模型支持填写）", choices: ["", "none", "minimal", "low", "medium", "high", "xhigh"]))
                    fields.append(CloudServiceField(key: "maxTokensParameter", title: "输出额度参数（兼容服务）", choices: ["", "max_completion_tokens", "max_tokens"]))
                }
            }
            if kind.rawValue == "claude" {
                fields.append(CloudServiceField(key: "thinkingBudget", title: "思考预算 Tokens（留空关闭；至少1024）"))
            }
            if kind.rawValue == "gemini" {
                fields.append(CloudServiceField(key: "thinkingBudget", title: "思考预算（按模型支持填写）"))
                fields.append(CloudServiceField(key: "thinkingLevel", title: "思考等级（按模型支持填写）", choices: ["", "minimal", "low", "medium", "high"]))
            }
            return fields
        case "tencent": return [region, CloudServiceField(key: "projectId", title: "Project ID", defaultValue: "0")]
        case "microsoft": return [CloudServiceField(key: "region", title: "资源地区（全局资源可留空）"), CloudServiceField(key: "category", title: "自定义翻译 Category（可选）")]
        case "aliyun": return [region, CloudServiceField(key: "scene", title: "场景 Scene", defaultValue: "general")]
        case "volcano", "amazon": return [region]
        case "deepL": return [CloudServiceField(key: "modelType", title: "模型类别（可选）", choices: ["", "latency_optimized", "quality_optimized", "prefer_quality_optimized"]), CloudServiceField(key: "formality", title: "正式程度（按语言支持填写）", choices: ["", "default", "more", "less", "prefer_more", "prefer_less"])]
        default: return []
        }
    }

    static func defaultOptions(for kind: ServiceKind) -> [String: String] {
        switch kind.rawValue {
        case "openAI", "claude", "gemini": return ["stream": "true", "format": "plain", "mode": "translate"]
        case "tencent": return ["region": "ap-guangzhou", "projectId": "0"]
        case "aliyun": return ["region": "cn-hangzhou", "scene": "general"]
        case "volcano": return ["region": "cn-north-1"]
        case "amazon": return ["region": "us-east-1"]
        default: return [:]
        }
    }

    static func defaultEndpoint(for kind: ServiceKind, options: [String: String] = [:]) -> String {
        switch kind.rawValue {
        case "openAI":
            if let provider = options["provider"], let preset = openAIPresets.first(where: { $0.id == provider }) { return preset.endpoint }
            return "https://api.openai.com/v1"
        case "claude": return "https://api.anthropic.com/v1/messages"
        case "gemini": return "https://generativelanguage.googleapis.com/v1beta"
        case "deepL": return "https://api-free.deepl.com/v2/translate"
        case "google": return "https://translation.googleapis.com/language/translate/v2"
        case "baidu": return "https://fanyi-api.baidu.com/api/trans/vip/translate"
        case "youdao": return "https://openapi.youdao.com/api"
        case "tencent": return "https://tmt.tencentcloudapi.com"
        case "microsoft": return "https://api.cognitive.microsofttranslator.com/translate"
        case "aliyun": return "https://mt.\(options["region"] ?? "cn-hangzhou").aliyuncs.com"
        case "caiyun": return "https://api.interpreter.caiyunai.com/v1/translator"
        case "niutrans": return "https://api.niutrans.com/NiuTransServer/translation"
        case "volcano": return "https://translate.volcengineapi.com"
        case "amazon":
            let region = options["region"] ?? "us-east-1"
            return "https://translate.\(region).amazonaws.com" + (region.hasPrefix("cn-") ? ".cn" : "")
        default: return ""
        }
    }

    /// The 30 self-key entries and their two orderings are recovered from the
    /// installed reference binary. These are independent API configurations;
    /// the catalog never creates a hosted account or promises a free allowance.
    static func translationPresets(preferredLanguages: [String] = Locale.preferredLanguages) -> [CloudServicePreset] {
        let chinese = preferredLanguages.first?.lowercased().hasPrefix("zh") == true
        let ids = chinese
            ? ["aihubmix", "sophnet", "302ai", "volcano", "tencent", "aliyun", "baidu", "youdao", "caiyun", "niutrans", "deepl", "google", "microsoft", "amazon", "openai", "azure", "gemini", "claude", "grok", "groq", "openrouter", "ollama", "lmstudio", "deepseek", "qwen", "ernie", "doubao", "hunyuan", "gitee", "kimi"]
            : ["aihubmix", "deepl", "google", "microsoft", "amazon", "openai", "azure", "gemini", "claude", "grok", "groq", "openrouter", "ollama", "lmstudio", "volcano", "tencent", "aliyun", "baidu", "youdao", "caiyun", "niutrans", "sophnet", "302ai", "deepseek", "qwen", "ernie", "doubao", "hunyuan", "gitee", "kimi"]
        let traditional: [(ServiceKind, String)] = [(.volcano, "火山翻译"), (.tencent, "腾讯翻译君"), (.aliyun, "阿里翻译"), (.baidu, "百度翻译"), (.youdao, "有道翻译"), (.caiyun, "彩云小译"), (.niutrans, "小牛翻译"), (.deepL, chinese ? "DeepL 翻译" : "DeepL"), (.google, chinese ? "Google 翻译" : "Google"), (.microsoft, chinese ? "Microsoft 翻译" : "Microsoft"), (.amazon, chinese ? "Amazon 翻译" : "Amazon"), (.gemini, "Gemini"), (.claude, "Claude")]
        let native = traditional.map { kind, title in
            CloudServicePreset(id: kind.rawValue.lowercased(), title: title, kind: kind, endpoint: defaultEndpoint(for: kind), options: defaultOptions(for: kind))
        }
        let available = Dictionary(uniqueKeysWithValues: (native + openAIPresets.filter { !["zhipu", "siliconflow"].contains($0.id) }).map { ($0.id, $0) })
        return ids.compactMap { available[$0] }
    }

    /// Existing self-key additions are kept apart from reference hosted services.
    static var extensionPresets: [CloudServicePreset] { builtInAIPresets }

    /// Bundled configuration templates only. Both require the user's own Key.
    static var builtInAIPresets: [CloudServicePreset] {
        ["zhipu", "siliconflow"].compactMap { provider in openAIPresets.first { $0.id == provider } }
    }

    /// Display metadata for legacy official endpoints only. This never rewrites
    /// stored options or changes the provider used by the request transport.
    static func configurationProvider(for service: ServiceConfig) -> String? {
        let explicit = service.options["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !explicit.isEmpty { return explicit }
        guard service.kind == .openAI else { return nil }
        switch URLComponents(string: service.endpoint)?.host?.lowercased() {
        case "open.bigmodel.cn": return "zhipu"
        case "api.siliconflow.cn": return "siliconflow"
        default: return nil
        }
    }

    static func requiresPersonalKey(for service: ServiceConfig) -> Bool {
        service.kind == .openAI && ["zhipu", "siliconflow"].contains(configurationProvider(for: service) ?? "")
    }

    static func modelPresets(for service: ServiceConfig) -> [CloudModelPreset] {
        guard service.kind == .openAI else { return [] }
        switch configurationProvider(for: service) {
        case "zhipu": return [
            CloudModelPreset(id: "glm-4-flash-250414", title: "GLM-4-Flash-250414"),
            CloudModelPreset(id: "glm-4-flashx-250414", title: "GLM-4-FlashX-250414"),
            CloudModelPreset(id: "glm-4-plus", title: "GLM-4-Plus")
        ]
        case "siliconflow": return [
            CloudModelPreset(id: "Qwen/Qwen2.5-7B-Instruct", title: "Qwen2.5-7B-Instruct"),
            CloudModelPreset(id: "deepseek-ai/DeepSeek-V3.2", title: "DeepSeek-V3.2"),
            CloudModelPreset(id: "deepseek-ai/DeepSeek-V4-Flash", title: "DeepSeek-V4-Flash")
        ]
        default: return []
        }
    }

    static func configurationURL(for service: ServiceConfig) -> URL? {
        switch configurationProvider(for: service) {
        case "zhipu": return URL(string: "https://docs.bigmodel.cn/cn/guide/develop/openai/introduction")
        case "siliconflow": return URL(string: "https://docs.siliconflow.cn/docs/userguide/quickstart")
        default: return nil
        }
    }

    static func usesDeploymentName(_ service: ServiceConfig) -> Bool {
        service.kind == .openAI && service.options["provider"] == "azure"
    }

    /// Preset-specific fields must not leak to another provider. Preserve only
    /// user-facing settings shared by both protocols, then apply new defaults.
    static func applying(_ preset: CloudServicePreset, to service: ServiceConfig) -> ServiceConfig {
        var result = service
        let common: Set<String>
        if [.openAI, .claude, .gemini].contains(preset.kind) {
            common = ["stream", "format", "mode", "prompt", "systemPrompt", "userPrompt", "maxTokens", "temperature", "triggerStrategy"]
        } else if preset.kind == service.kind {
            common = Set(optionFields(for: preset.kind).map(\.key) + ["triggerStrategy"])
        } else { common = ["triggerStrategy"] }
        result.kind = preset.kind; result.endpoint = preset.endpoint; result.model = preset.model
        result.options = preset.options
        for (key, value) in service.options where common.contains(key) { result.options[key] = value }
        if [.openAI, .claude, .gemini].contains(preset.kind), service.options["mode"] == nil, !(service.options["prompt"] ?? "").isEmpty {
            result.options["mode"] = "custom"
        }
        return result
    }

    static func mode(for options: [String: String]) -> String {
        if let mode = options["mode"], ["translate", "polish", "custom"].contains(mode) { return mode }
        return (options["prompt"] ?? "").isEmpty ? "translate" : "custom"
    }

    static func settingOption(_ key: String, value: String, in service: ServiceConfig) -> ServiceConfig {
        var updated = service
        if key == "systemPrompt" {
            // A legacy prompt implies custom mode. Materialize that mode before
            // removing its old key, including when the edited system is empty.
            updated.options["mode"] = mode(for: service.options)
            updated.options.removeValue(forKey: "prompt")
        }
        updated.options[key] = value
        return updated
    }

    static func optionValue(_ field: CloudServiceField, in service: ServiceConfig) -> String {
        if field.key == "thinking", service.options[field.key]?.isEmpty == true { return "default" }
        return service.options[field.key] ?? field.defaultValue
    }

    static func isSpecializedTranslationModel(_ service: ServiceConfig) -> Bool {
        ProviderTranslationModels.mode(service) != .ordinary
    }

    static func isOptionApplicable(_ key: String, to service: ServiceConfig) -> Bool {
        guard isSpecializedTranslationModel(service) else { return true }
        return !Set(["mode", "prompt", "systemPrompt", "userPrompt", "maxTokens", "temperature", "reasoningEffort", "maxTokensParameter", "thinking", "thinkingBudget", "thinkingLevel"]).contains(key)
    }

    static let specializedModelNotice = "此翻译专用模型按当前目标语言处理原文，以下通用模式、Prompt 和生成参数不参与请求。切回普通模型后将恢复编辑并保留原值。"

    static func configurationHint(for service: ServiceConfig) -> String {
        switch configurationProvider(for: service) {
        case "azure": return "填写 Azure 资源地址、部署名称和 API 版本；使用 api-key 认证，部署名称决定请求的模型。"
        case "qwen": return "普通模型使用 Chat Completions。qwen-mt 翻译模型使用专用翻译参数，目标语言来自当前翻译任务，不使用通用翻译指令。"
        case "doubao": return "推理接入点非空时优先使用。doubao-seed-translation- 模型使用 Responses 翻译协议，其余模型使用 Chat Completions。"
        case "zhipu": return "已预置智谱官方接口和 GLM 模型选项。需填写你自己的智谱 API Key；模型可用性和费用以智谱账户为准。Pop 不提供 Bob 的合作免密钥额度。"
        case "siliconflow": return "已预置硅基流动官方接口和模型选项。需填写你自己的硅基流动 API Key；模型可用性和费用以硅基流动账户为准。Pop 不提供 Bob 的合作免密钥额度。"
        case "ollama": return "请先安装并运行 Ollama，再下载所需模型。这里连接的是你电脑上的 Ollama 服务，模型名称须与本机已有模型一致。"
        case "lmstudio": return "使用本机服务提供的 OpenAI 兼容接口。模型名称必须填写本机实际已安装或已加载的模型。"
        default: return "支持 OpenAI 兼容接口。填写账户实际可用的模型名称；密钥留空时不发送认证头，接口可能要求认证。"
        }
    }

    private static var openAIPresets: [CloudServicePreset] {
        func preset(_ id: String, _ title: String, _ endpoint: String, model: String = "", options: [String: String] = [:]) -> CloudServicePreset {
            var values = defaultOptions(for: .openAI)
            values["provider"] = id
            for (key, value) in options { values[key] = value }
            return CloudServicePreset(id: id, title: title, kind: .openAI, endpoint: endpoint, model: id == "azure" ? "gpt-4.1-mini" : model, options: values)
        }
        return [
            preset("openai", "OpenAI", "https://api.openai.com/v1"),
            preset("ollama", "Ollama", "http://localhost:11434"),
            preset("lmstudio", "LM Studio", "http://localhost:1234/v1", options: ["maxTokensParameter": "max_tokens"]),
            preset("deepseek", "DeepSeek", "https://api.deepseek.com/chat/completions", options: ["maxTokensParameter": "max_tokens"]),
            preset("groq", "Groq", "https://api.groq.com/openai/v1/chat/completions"),
            preset("azure", "Azure OpenAI", "", options: ["apiVersion": "2023-03-15-preview"]),
            preset("aihubmix", "AiHubMix", "https://api.inferera.com/v1/chat/completions"),
            preset("sophnet", "SophNet", "https://www.sophnet.com/api/open-apis/v1/chat/completions"),
            preset("302ai", "302AI", "https://api.302.ai/v1/chat/completions"),
            preset("grok", "Grok", "https://api.x.ai/v1/chat/completions"),
            preset("openrouter", "OpenRouter", "https://openrouter.ai/api/v1/chat/completions"),
            preset("qwen", "千问", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"),
            preset("ernie", "文心", "https://qianfan.baidubce.com/v2/chat/completions"),
            preset("doubao", "豆包", "https://ark.cn-beijing.volces.com/api/v3/chat/completions"),
            preset("hunyuan", "混元", "https://tokenhub.tencentmaas.com/v1/chat/completions"),
            preset("gitee", "模力方舟", "https://ai.gitee.com/v1/chat/completions"),
            preset("kimi", "Kimi", "https://api.moonshot.cn/v1/chat/completions"),
            preset("zhipu", "智谱翻译", "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash-250414", options: ["maxTokensParameter": "max_tokens"]),
            preset("siliconflow", "硅基流动翻译", "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct", options: ["maxTokensParameter": "max_tokens"])
        ]
    }

    static func presets(for kind: ServiceKind) -> [CloudServicePreset] {
        if kind == .openAI { return openAIPresets }
        if kind.rawValue == "deepL" {
            return [CloudServicePreset(id: "deepl-free", title: "DeepL API Free", kind: kind, endpoint: "https://api-free.deepl.com/v2/translate"),
                    CloudServicePreset(id: "deepl-pro", title: "DeepL API Pro", kind: kind, endpoint: "https://api.deepl.com/v2/translate")]
        }
        let endpoint = defaultEndpoint(for: kind)
        return endpoint.isEmpty ? [] : [CloudServicePreset(id: kind.rawValue, title: kind.title, kind: kind, endpoint: endpoint, options: defaultOptions(for: kind))]
    }
}

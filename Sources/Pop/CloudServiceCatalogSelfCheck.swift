import Foundation

enum CloudServiceCatalogSelfCheck {
    static func run() throws -> [String] {
        var checks: [String] = []
        let chinese = CloudServiceCatalog.translationPresets(preferredLanguages: ["zh-Hans"])
        let english = CloudServiceCatalog.translationPresets(preferredLanguages: ["en-US"])
        let chineseIDs = ["aihubmix", "sophnet", "302ai", "volcano", "tencent", "aliyun", "baidu", "youdao", "caiyun", "niutrans", "deepl", "google", "microsoft", "amazon", "openai", "azure", "gemini", "claude", "grok", "groq", "openrouter", "ollama", "lmstudio", "deepseek", "qwen", "ernie", "doubao", "hunyuan", "gitee", "kimi"]
        let englishIDs = ["aihubmix", "deepl", "google", "microsoft", "amazon", "openai", "azure", "gemini", "claude", "grok", "groq", "openrouter", "ollama", "lmstudio", "volcano", "tencent", "aliyun", "baidu", "youdao", "caiyun", "niutrans", "sophnet", "302ai", "deepseek", "qwen", "ernie", "doubao", "hunyuan", "gitee", "kimi"]
        guard chinese.map(\.id) == chineseIDs, Set(chinese.map(\.id)).count == 30,
              CloudServiceCatalog.translationPresets(preferredLanguages: ["zh-Hant"]).map(\.id) == chineseIDs else { throw PopError.message("30 项中文服务目录顺序或繁体分支复核失败") }
        checks.append("30 项自带密钥服务按已恢复中文/繁体顺序排列，ID 唯一")
        guard english.map(\.id) == englishIDs,
              CloudServiceCatalog.translationPresets(preferredLanguages: []).map(\.id) == englishIDs else { throw PopError.message("30 项英文回退服务目录顺序复核失败") }
        checks.append("30 项英文及未知语言回退目录顺序正确")

        let additions: Set<String> = ["azure", "qwen", "doubao", "gitee", "ernie", "hunyuan", "aihubmix", "sophnet", "302ai", "grok", "openrouter", "kimi"]
        for preset in chinese where additions.contains(preset.id) {
            guard preset.kind == .openAI, preset.options["provider"] == preset.id, preset.id == preset.id.lowercased() else { throw PopError.message("新增服务未使用稳定的 OpenAI 提供商标识") }
        }
        guard chinese.first(where: { $0.id == "302ai" })?.title == "302AI",
              chinese.first(where: { $0.id == "qwen" })?.title == "千问",
              chinese.first(where: { $0.id == "ernie" })?.title == "文心",
              chinese.first(where: { $0.id == "tencent" })?.title == "腾讯翻译君" else { throw PopError.message("服务目录短名称与实机证据不符") }
        checks.append("新增 12 项使用稳定 provider 标识，目录短名称按实机观察保留")

        guard let azure = chinese.first(where: { $0.id == "azure" }) else { throw PopError.message("目录缺少 Azure") }
        let azureFields = CloudServiceCatalog.optionFields(for: .openAI, options: azure.options)
        guard azure.endpoint.isEmpty, azure.model == "gpt-4.1-mini", azure.options["apiVersion"] == "2023-03-15-preview",
              CloudServiceCatalog.defaultEndpoint(for: .openAI, options: azure.options).isEmpty,
              azureFields.contains(where: { $0.key == "deploymentName" && !$0.required }),
              azureFields.first(where: { $0.key == "apiVersion" })?.defaultValue == "2023-03-15-preview" else { throw PopError.message("Azure 根地址/完整 URL 的编辑字段复核失败") }
        guard chinese.filter({ $0.id != "azure" }).allSatisfy({ $0.model.isEmpty }) else { throw PopError.message("目录包含未经确认的默认模型") }
        checks.append("Azure 保留已实测默认模型和 API 版本，完整部署 URL 可省独立部署名，其余未知模型留空")

        var previous = ServiceConfig(name: "用户名称", kind: .openAI)
        previous.enabled = false
        previous.endpoint = "https://example.invalid/old"
        previous.model = "old-model"
        previous.options = ["provider": "azure", "deploymentName": "old-deployment", "apiVersion": "old-version", "accessPointName": "old-point", "thinking": "old-thinking", "thinkingBudget": "4096", "reasoningEffort": "high", "region": "old-region", "voices": "old-voice", "stream": "false", "format": "markdown", "mode": "custom", "systemPrompt": "fixture system", "userPrompt": "$query.text", "maxTokens": "100", "temperature": "0.2", "triggerStrategy": "pinned"]
        for preset in CloudServiceCatalog.presets(for: .openAI) {
            let switched = CloudServiceCatalog.applying(preset, to: previous)
            guard switched.id == previous.id, switched.name == previous.name, !switched.enabled,
                  switched.endpoint == preset.endpoint, switched.model == preset.model,
                  switched.options["provider"] == preset.id,
                  switched.options["stream"] == "false", switched.options["format"] == "markdown",
                  switched.options["systemPrompt"] == "fixture system", switched.options["userPrompt"] == "$query.text",
                  switched.options["triggerStrategy"] == "pinned" else { throw PopError.message("切换预设未保留通用设置或记录身份") }
            for stale in ["deploymentName", "accessPointName", "thinking", "thinkingBudget", "reasoningEffort", "region", "voices"] {
                guard switched.options[stale] == preset.options[stale] else { throw PopError.message("切换预设遗留旧提供商字段：\(stale)") }
            }
            guard switched.options["apiVersion"] == preset.options["apiVersion"] else { throw PopError.message("切换预设遗留旧 API 版本") }
        }
        checks.append("全部 OpenAI 预设切换清除旧部署/接入点/思考/地区/音色，只保留通用选项和服务身份")

        var deepL = ServiceConfig(name: "DeepL", kind: .deepL)
        deepL.options = ["formality": "more", "modelType": "quality_optimized", "region": "stale", "provider": "azure"]
        guard let pro = CloudServiceCatalog.presets(for: .deepL).last else { throw PopError.message("DeepL 目录为空") }
        let switchedDeepL = CloudServiceCatalog.applying(pro, to: deepL)
        guard switchedDeepL.options["formality"] == "more", switchedDeepL.options["modelType"] == "quality_optimized",
              switchedDeepL.options["provider"] == nil, switchedDeepL.options["region"] == nil else { throw PopError.message("DeepL Free/Pro 切换错误继承专用字段") }
        checks.append("DeepL Free/Pro 切换保留适用选项并清除其他提供商字段")

        var legacy = ServiceConfig(name: "Legacy", kind: .openAI)
        legacy.options = ["prompt": "legacy {{source}}"]
        let fields = CloudServiceCatalog.optionFields(for: .openAI, options: legacy.options)
        guard CloudServiceCatalog.mode(for: legacy.options) == "custom",
              fields.first(where: { $0.key == "systemPrompt" })?.defaultValue == legacy.options["prompt"],
              fields.contains(where: { $0.key == "userPrompt" }),
              CloudServiceCatalog.optionFields(for: .openAI, options: ["mode": "translate"]).filter({ $0.key == "systemPrompt" || $0.key == "userPrompt" }).count == 2,
              CloudServiceCatalog.applying(azure, to: legacy).options["mode"] == "custom" else { throw PopError.message("旧自定义指令未兼容迁移至自定义模式") }
        checks.append("旧 prompt 仍展示为自定义角色设定，双 Prompt 在所有模式可见并注明仅 custom 生效")

        let editedLegacy = CloudServiceCatalog.settingOption("systemPrompt", value: "edited system", in: legacy)
        let editedUser = CloudServiceCatalog.settingOption("userPrompt", value: "edited $query.text", in: editedLegacy)
        let clearedSystem = CloudServiceCatalog.settingOption("systemPrompt", value: "", in: editedUser)
        let fixture = TranslationRequest(text: "Hello", source: "en", target: "zh-Hans")
        let editedMessage = AIMessageBuilder.resolve(fixture, service: editedUser)
        let clearedMessage = AIMessageBuilder.resolve(fixture, service: clearedSystem)
        guard editedLegacy.options["mode"] == "custom", editedLegacy.options["prompt"] == nil,
              editedLegacy.options["systemPrompt"] == "edited system", legacy.options["prompt"] == "legacy {{source}}",
              editedUser.options["mode"] == "custom", editedUser.options["userPrompt"] == "edited $query.text",
              clearedSystem.options["mode"] == "custom", clearedSystem.options["systemPrompt"] == "",
              editedMessage.system == "edited system", editedMessage.user == "edited Hello",
              clearedMessage.system == nil, clearedMessage.user == "edited Hello",
              CloudServiceCatalog.optionFields(for: .openAI, options: clearedSystem.options).contains(where: { $0.key == "systemPrompt" }) else {
            throw PopError.message("旧 prompt 的真实选项更新路径丢失自定义模式")
        }
        checks.append("旧 prompt 经两编辑器共用更新函数编辑及清空后，custom 模式和双 Prompt 控件保持有效")

        var dedicated = ServiceConfig(name: "MT Fixture", kind: .openAI, model: "qwen-mt-plus")
        dedicated.options = ["provider": "qwen", "mode": "custom", "systemPrompt": "keep system", "userPrompt": "keep user", "maxTokens": "100", "temperature": "0.2"]
        let preservedOptions = dedicated.options
        let inactive = ["mode", "prompt", "systemPrompt", "userPrompt", "maxTokens", "temperature", "reasoningEffort", "maxTokensParameter", "thinking"]
        guard CloudServiceCatalog.isSpecializedTranslationModel(dedicated),
              inactive.allSatisfy({ !CloudServiceCatalog.isOptionApplicable($0, to: dedicated) }),
              ["stream", "format"].allSatisfy({ CloudServiceCatalog.isOptionApplicable($0, to: dedicated) }) else { throw PopError.message("专用翻译模型的参数可用状态错误") }
        dedicated.model = "ordinary-fixture"
        guard !CloudServiceCatalog.isSpecializedTranslationModel(dedicated), dedicated.options == preservedOptions,
              inactive.allSatisfy({ CloudServiceCatalog.isOptionApplicable($0, to: dedicated) }) else { throw PopError.message("切回普通模型后未恢复参数编辑或参数丢失") }
        dedicated.options["provider"] = "doubao"
        dedicated.options["accessPointName"] = "doubao-seed-translation-fixture"
        guard CloudServiceCatalog.isSpecializedTranslationModel(dedicated),
              CloudServiceCatalog.isOptionApplicable("accessPointName", to: dedicated),
              CloudServiceCatalog.isOptionApplicable("stream", to: dedicated),
              !CloudServiceCatalog.isOptionApplicable("thinking", to: dedicated) else { throw PopError.message("豆包接入点覆盖模型的 UI 可用状态错误") }
        dedicated.options.removeValue(forKey: "accessPointName")
        guard CloudServiceCatalog.isOptionApplicable("thinking", to: dedicated) else { throw PopError.message("普通豆包模型思考参数未恢复编辑") }
        checks.append("专用模型禁用无效通用参数但保留布局和值，切回普通模型恢复，stream/format/接入点保持可用")

        let thinkingFields = CloudServiceCatalog.optionFields(for: .openAI, options: ["provider": "doubao"])
        guard let thinking = thinkingFields.first(where: { $0.key == "thinking" }),
              thinking.choices == ["default", "disabled", "enabled", "auto"],
              thinking.choices.map({ thinking.choiceTitle($0) }) == ["默认", "禁用", "启用", "自动"],
              thinking.defaultValue == "default" else { throw PopError.message("豆包思考选项与协议枚举不一致") }
        dedicated.options["thinking"] = ""
        guard CloudServiceCatalog.optionValue(thinking, in: dedicated) == "default" else { throw PopError.message("豆包旧空思考值未显示为默认") }
        checks.append("豆包思考使用四项中文枚举下拉，旧空值兼容默认状态")

        let extensions = CloudServiceCatalog.extensionPresets
        guard extensions.map(\.id) == ["zhipu", "siliconflow"],
              extensions.allSatisfy({ $0.kind == .openAI && !$0.model.isEmpty }),
              extensions.allSatisfy({ !Set(chinese.map(\.id)).contains($0.id) }) else { throw PopError.message("自有接口扩展与参考托管服务发生混淆") }
        checks.append("智谱和硅基流动提供可编辑的自有密钥模型预设，未混入 30 项或冒充托管免费额度")
        return checks
    }
}

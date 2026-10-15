import Foundation

enum FeatureSelfCheck {
    static func run() throws -> [String] {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw PopError.message("功能自检：" + message) } }
        var preferences = AppPreferences()
        try check(SelectionTiming.resolve(mode: "effect", applicationID: nil) == SelectionTiming(attempts: 2, polls: 10) && SelectionTiming.resolve(mode: "speed", applicationID: nil) == SelectionTiming(attempts: 1, polls: 1), "效果和速度取词按REA证据使用不同复制尝试次数")
        try check(SelectionTiming.resolve(mode: "smart", applicationID: "com.google.Chrome") == SelectionTiming(attempts: 2, polls: 3) && SelectionTiming.resolve(mode: "smart", applicationID: "com.apple.iBooksX") == SelectionTiming(attempts: 2, polls: 10) && SelectionTiming.resolve(mode: "smart", applicationID: "unlisted") == SelectionTiming(attempts: 1, polls: 2), "智能模式按应用使用对应取词等待策略")
        try check(TextUtilities.processedInput("  helloWorld  ", preferences: preferences) == "hello World", "保留标识符拆分")
        preferences.mergeLineBreaks = true; preferences.removeCommentMarkers = true; preferences.joinHyphenatedWords = true; preferences.compactBlankLines = true
        let text = "// First line\n// second line\n\n/* inter-\nnational */\n\n\nlast"
        try check(TextUtilities.processedInput(text, preferences: preferences) == "First line second line\n\ninternational\n\nlast", "预处理组合与段落边界")
        try check(TextUtilities.processedInput("insignif- icant\nword - word", preferences: preferences) == "insignificant word - word", "连接单词内部连字符空格，不合并独立连字符")
        preferences.autoTargetLanguage = true
        preferences.sourceLanguage = "en"
        try check(TextUtilities.targetLanguage(for: "hello", preferences: preferences) == "zh-Hans", "外语自动译为主要语言")
        preferences.sourceLanguage = "zh-Hant"
        try check(TextUtilities.targetLanguage(for: "你好", preferences: preferences) == "en", "中文脚本变体自动译为第二语言")
        preferences.primaryLanguage = "auto"; preferences.secondaryLanguage = "auto"
        try check(TextUtilities.resolvedPrimaryLanguage(preferences, preferredLanguages: ["zh-Hans-CN"]) == "zh-Hans", "自动主要语言采用系统语言")
        try check(TextUtilities.resolvedSecondaryLanguage(preferences, preferredLanguages: ["zh-Hans-CN"]) == "en", "自动第二语言选择英语")
        try check(TextUtilities.resolvedPrimaryLanguage(preferences, preferredLanguages: ["en-US"]) == "en" && TextUtilities.resolvedSecondaryLanguage(preferences, preferredLanguages: ["en-US"]) == "zh-Hans", "英语系统的自动第二语言与主要语言不同")
        preferences.autoTargetLanguage = false; preferences.targetLanguage = "auto"
        try check(!["", "auto", "und"].contains(TextUtilities.targetLanguage(for: "hello", preferences: preferences)), "自动设置不作为提供商目标语言发送")
        preferences.autoCopyFirstResult = true; preferences.showCopySnake = true; preferences.maxInputHeight = 320
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data("{\"services\":[],\"sourceLanguage\":\"en\"}".utf8))
        try check(old.hideOnBlur && old.renderMarkdown && old.enableDictionary && old.historyLimit == 10000 && old.sourceLanguage == "en" && !old.autoCopyFirstResult && old.showLanguageBar && old.recognizeQRCode && old.maxInputHeight == 200, "旧配置默认迁移")
        let encoded = try JSONEncoder().encode(preferences)
        try check(try JSONDecoder().decode(AppPreferences.self, from: encoded) == preferences, "新增设置编码往返")
        try check(preferences.services.contains(where: { $0.kind == .dictionary && $0.capability == "translate" && $0.enabled }), "新安装包含启用的独立词典服务")
        let previousTranslate = ServiceConfig.system
        let previousObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previousTranslate))
        for enabled in [false, true] {
            let legacyDictionary = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: ["services": [previousObject], "enableDictionary": enabled]))
            let dictionaries = legacyDictionary.services.filter { $0.kind == .dictionary }
            try check(dictionaries.count == 1 && dictionaries[0].enabled == enabled && legacyDictionary.services.first?.id == previousTranslate.id, "旧词典开关一次迁移为同序服务")
            try check(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(legacyDictionary)) == legacyDictionary, "词典迁移编码后不重复添加")
        }
        var removedDictionary = preferences
        removedDictionary.services.removeAll { $0.kind == .dictionary }
        try check(!(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(removedDictionary))).services.contains(where: { $0.kind == .dictionary }), "用户删除词典后重载不复活服务")
        var disabledDictionary = ServiceConfig.dictionary
        disabledDictionary.enabled = false
        let dictionaryObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(disabledDictionary))
        let existingDictionary = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: ["services": [dictionaryObject], "enableDictionary": true]))
        try check(existingDictionary.services.first?.id == disabledDictionary.id && existingDictionary.services.filter({ $0.kind == .dictionary }).count == 1 && existingDictionary.services.first?.enabled == false, "已有词典服务不被旧开关覆盖或复制")
        let legacyOCRID = UUID()
        let legacyOCR = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: ["ocrServiceID": legacyOCRID.uuidString]))
        try check(legacyOCR.selectedOCRService(forTranslation: false)?.kind == .apple && legacyOCR.selectedOCRService(forTranslation: true)?.kind == .apple, "旧OCR服务ID失效时归一到系统服务")
        var independentOCR = legacyOCR
        var screenshotService = ServiceConfig(name: "Screenshot OCR", kind: .google); screenshotService.capability = "ocr"; screenshotService.scope = "translation"
        var windowService = ServiceConfig(name: "Window OCR", kind: .baidu); windowService.capability = "ocr"; windowService.scope = "standaloneOCR"
        independentOCR.services = [screenshotService, windowService]
        independentOCR.translationOCRServiceID = screenshotService.id; independentOCR.ocrServiceID = windowService.id
        try check(independentOCR.selectedOCRService(forTranslation: true)?.id == screenshotService.id && independentOCR.selectedOCRService(forTranslation: false)?.id == windowService.id, "截图翻译与独立OCR选择各自服务")
        independentOCR.translationOCRServiceID = nil
        let independentRoundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(independentOCR))
        try check(independentRoundTrip.selectedOCRService(forTranslation: true)?.id == screenshotService.id && independentRoundTrip.selectedOCRService(forTranslation: false)?.id == windowService.id, "服务列表选中状态按用途生效，不再依赖多余选择器")
        var legacyService = ServiceConfig(name: "Legacy OCR", kind: .google); legacyService.capability = "ocr"
        legacyService.options = ["region": "old-region"]
        let oldServiceObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyService))
        let migrated = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: ["services": [oldServiceObject], "ocrServiceID": legacyService.id.uuidString]))
        let translatedOCR = migrated.selectedOCRService(forTranslation: true)
        try check(migrated.selectedOCRService(forTranslation: false)?.id == legacyService.id && translatedOCR?.id != legacyService.id && translatedOCR?.credentialID == legacyService.id, "旧OCR复制为独立配置并保留凭据引用")
        try check(translatedOCR?.options == legacyService.options && migrated.ocrServices(forTranslation: true).count == 2 && migrated.ocrServices(forTranslation: false).count == 2, "迁移保留各项配置并列出系统OCR")
        let migratedAgain = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(migrated))
        try check(migratedAgain == migrated, "OCR列表迁移只执行一次，不重复克隆")
        var editedMigration = migrated
        if let index = editedMigration.services.firstIndex(where: { $0.id == translatedOCR?.id }) { editedMigration.services[index].name = "Translation only"; editedMigration.services[index].options["region"] = "new-region" }
        try check(editedMigration.selectedOCRService(forTranslation: false)?.name == "Legacy OCR" && editedMigration.selectedOCRService(forTranslation: false)?.options["region"] == "old-region", "截图翻译编辑不会修改独立OCR配置")
        var copyPolicy = FirstResultCopyPolicy()
        let copyJob = UUID(), firstService = UUID(), secondService = UUID(), dictionaryService = UUID()
        var copyCards = [ResultCard(serviceID: firstService, name: "First"), ResultCard(serviceID: secondService, name: "Second", text: "second ready", loading: false)]
        try check(copyPolicy.nextText(in: copyCards, queryID: copyJob, enabled: true) == nil, "自动复制等待排在前面的服务")
        copyCards[0].loading = false; copyCards[0].text = "first ready"
        try check(copyPolicy.nextText(in: copyCards, queryID: copyJob, enabled: true) == "first ready" && copyPolicy.nextText(in: copyCards, queryID: copyJob, enabled: true) == nil, "同次查询只自动复制首个服务一次")
        copyCards[0].error = "failed"; copyCards[0].text = ""
        try check(copyPolicy.nextText(in: copyCards, queryID: UUID(), enabled: true) == "second ready", "新查询可复制且失败服务回退")
        copyCards.insert(ResultCard(serviceID: dictionaryService, name: "Dictionary", text: "dictionary", loading: false), at: 0)
        let disabledJob = UUID()
        try check(copyPolicy.nextText(in: copyCards, queryID: disabledJob, enabled: false) == nil && copyPolicy.nextText(in: copyCards, queryID: disabledJob, enabled: true) == "dictionary", "关闭自动复制不消费状态，词典作为普通服务按顺序参与首结果复制")
        let actions = ["selectionTranslate", "silentSelectionTranslate", "silentInputBoxTranslate", "snipTranslate", "inputTranslate", "pasteboardTranslate", "showWindow", "translateText"]
        for action in actions {
            let value: [String: Any] = ["path": "translate", "body": ["action": action, "text": "Hello", "windowLocation": "mouse", "inputBoxState": "alwaysFold"]]
            let request = try ExternalRequest.parse(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
            try check(request.action == action && request.windowLocation == "mouse" && request.inputBoxState == "alwaysFold", "path/body动作解析")
        }
        let image = try ExternalRequest.parse("{\"path\":\"ocr\",\"body\":{\"action\":\"ocrImage\",\"imageBase64\":\"AQID\",\"isSilent\":true}}")
        try check(image.imageData == Data([1, 2, 3]) && image.isSilent, "图片载荷与静默参数")
        for invalid in ["{", "{\"path\":\"other\"}", "{\"action\":\"unknown\"}", "{\"action\":\"translateText\"}", "{\"text\":\"hi\",\"target\":\"auto\"}", "{\"path\":\"ocr\",\"body\":{\"action\":\"ocrImage\",\"imageBase64\":\"***\"}}"] {
            do { _ = try ExternalRequest.parse(invalid); throw PopError.message("无效脚本请求被受理") }
            catch let error as PopError { if error.localizedDescription == "无效脚本请求被受理" { throw error } }
            catch { }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pop-backup-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ConfigurationExport(preferences: AppPreferences(), shortcuts: [:])
        let backup = PortableBackup(configuration: config, history: [], plugins: [.init(path: "example/info.json", contents: Data("{}".utf8)), .init(path: "example/main.js", contents: Data("exports.test=true".utf8))])
        try backup.restorePlugins(at: root)
        let restored = try PortableBackup.collectPlugins(at: root)
        try check(restored.count == 2 && restored.first?.contents == Data("{}".utf8), "便携插件备份恢复")
        for path in ["../escape", "/absolute", "example/../escape", "example//file", "example\\escape"] {
            var invalid = backup; invalid.plugins = [.init(path: path, contents: Data())]
            do { try PortableBackup.validate(invalid); throw PopError.message("危险备份路径被接受") }
            catch let error as PopError { if error.localizedDescription == "危险备份路径被接受" { throw error } }
        }
        try check(LanguageCatalog.choices.count >= 390 && Set(LanguageCatalog.choices.map(\.0)).count == LanguageCatalog.choices.count, "语言目录去重")
        return ["文本与设置：预处理组合、自动语言解析、旧配置兼容/新字段往返；自动复制按服务顺序、失败回退和每查询一次策略通过（未操作剪贴板）。", "词典服务配置：默认启用、旧开关一次迁移、保留服务顺序/停用状态、删除后不复活；词典结果按真实服务顺序参与复制。", "脚本：Bob path/body翻译动作、窗口参数、图片base64及无效请求拒绝。", "备份：插件文件往返恢复与路径逃逸拒绝；公开语言目录去重。"]
    }

    /// Exercises real local service dispatch without saving preferences/history,
    /// speaking, reading the pasteboard, selecting text, or requesting a capture.
    @MainActor static func runDictionary() async throws -> [String] {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw PopError.message("词典服务自检：" + message) }
        }
        func waitForCompletion(_ state: AppState) async throws {
            let deadline = Date().addingTimeInterval(8)
            while state.working, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!state.working, "本地查询未能及时结束")
        }
        let state = AppState()
        var preferences = AppPreferences()
        preferences.saveHistory = false
        preferences.autoCopyFirstResult = false
        preferences.autoCopyOCR = false
        preferences.autoCopyTranslationOCR = false
        preferences.autoSpeakSource = false
        preferences.pinnedServiceIDs = []
        preferences.sourceLanguage = "en"
        preferences.targetLanguage = "zh-Hans"
        var first = ServiceConfig.dictionary
        first.name = "词典一"
        // These intentionally unusable cloud values must be ignored locally.
        first.endpoint = "https://dictionary.invalid/no-http"
        first.credentialSourceID = UUID()
        var second = ServiceConfig.dictionary
        second.name = "词典二"
        var disabled = ServiceConfig.dictionary
        disabled.enabled = false
        preferences.services = [second, disabled, first]
        preferences.enableDictionary = false // Legacy flag cannot disable new records.
        state.preferences = preferences
        state.input = "HELLO"
        state.translate()
        try await waitForCompletion(state)
        try check(NativeDictionary.bundledEntryCount == 770_611, "词库条目数与实际分发文案不一致")
        try check(state.results.map(\.serviceID) == [second.id, first.id] && state.results.allSatisfy { $0.dictionary?.word == "hello" && $0.error == nil && !$0.loading }, "启用、顺序或独立结构化结果卡错误")
        state.translateService(second.id)
        try await waitForCompletion(state)
        try check(state.results.map(\.serviceID) == [second.id, first.id] && state.results[0].dictionary?.word == "hello", "单卡重试改变顺序或未使用本地词典")
        state.input = "This full sentence has no entry in this dictionary, fixture 2026."
        state.translate()
        try await waitForCompletion(state)
        try check(state.results.count == 2 && state.results.allSatisfy { $0.error?.contains("不支持翻译句子") == true && !$0.loading && $0.dictionary == nil }, "句子未命中应保留独立错误卡")
        let direct = try await state.translateDirect(TranslationRequest(text: "running", source: "en", target: "zh-Hans"), service: first)
        try check(direct.dictionary?.exchanges.contains(where: { $0.name == "原形" && $0.words.contains("run") }) == true, "静默共用的 direct 分发没有返回本地词形")
        do {
            _ = try await state.translateDirect(TranslationRequest(text: "pop_fixture_missing_word_2026", source: "en", target: "zh-Hans"), service: first)
            throw PopError.message("自检未命中未被拒绝")
        } catch {
            try check(error.localizedDescription.contains("未找到对应词条"), "direct 未命中错误不正确")
        }
        state.preferences.services = [first]
        state.ocrDocument = OCRDocument(text: "hello", lines: [OCRLine(text: "hello", x: 0.1, y: 0.1, width: 0.5, height: 0.1, confidence: 1)], qrCodes: [])
        state.translateImage()
        try await waitForCompletion(state)
        try check(state.imageTranslations[0]?.contains("hello") == true, "图片逐行翻译没有走本地词典")
        state.cancelTranslation()
        return ["词典服务实际查询：770611 条独立 ECDICT、停用与顺序、两张独立结果卡、单卡重试通过；旧全局开关不再参与运行。", "词典本地分发：句子/不存在词条保留明确错误，direct 返回 running→run 词形，图片逐行译文通过；未发 HTTP、未执行真实静默回填、未写配置/历史或操作剪贴板。"]
    }

    @MainActor static func runServiceStrategies() async throws -> [String] {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw PopError.message("服务触发自检：" + message) }
        }
        func waitForCompletion(_ state: AppState) async throws {
            let deadline = Date().addingTimeInterval(8)
            while state.working, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!state.working, "本地任务未结束")
        }
        func service(_ name: String, _ strategy: ServiceTriggerStrategy) -> ServiceConfig {
            var value = ServiceConfig.dictionary
            value.name = name; value.options["triggerStrategy"] = strategy.rawValue
            return value
        }
        let normal = service("普通", .normal), remember = service("记住折叠", .rememberCollapse)
        let always = service("总是折叠", .alwaysCollapsed), pinned = service("钉住", .pinned)
        var preferences = AppPreferences()
        preferences.services = [remember, normal, always, pinned]
        preferences.collapsedServiceIDs = [remember.id, normal.id]
        preferences.pinnedServiceIDs = [pinned.id]
        preferences.resultDisplay = "remember"
        preferences.saveHistory = false; preferences.autoCopyFirstResult = false; preferences.autoSpeakSource = false
        let state = AppState()
        state.preferences = preferences; state.input = "hello"
        state.translate()
        try await waitForCompletion(state)
        try check(state.results.map(\.serviceID) == [remember.id, normal.id, always.id], "待触发卡顺序或钉住服务排除错误")
        try check(state.results[0].deferred && !state.results[0].loading && state.results[0].text.isEmpty,
                  "记住折叠服务错误地发起了请求")
        try check(state.results[1].dictionary?.word == "hello" && !state.results[1].deferred, "普通服务在折叠时仍应自动查询")
        try check(state.results[2].deferred && preferences.collapsedServiceIDs.contains(always.id) == false && state.preferences.collapsedServiceIDs.contains(always.id), "总是折叠没有在新查询强制折叠/延后请求")
        var copyPolicy = FirstResultCopyPolicy()
        try check(copyPolicy.nextText(in: state.results, queryID: UUID(), enabled: true) == state.results[1].text,
                  "未触发占位阻止了已完成服务的自动复制决策")
        state.toggleServiceCollapsed(remember.id, persist: false)
        try await waitForCompletion(state)
        try check(state.results[0].dictionary?.word == "hello" && !state.results[0].deferred, "展开没有触发延后服务")
        let completedCard = state.results[0].id
        state.toggleServiceCollapsed(remember.id, persist: false)
        state.toggleServiceCollapsed(remember.id, persist: false)
        try check(state.results[0].id == completedCard && !state.working, "同查询折叠后重开重复发起了请求")
        state.toggleServiceCollapsed(always.id, persist: false)
        try await waitForCompletion(state)
        try check(state.results.first(where: { $0.serviceID == always.id })?.dictionary?.word == "hello", "总是折叠服务首次展开未查询")
        let alwaysCard = state.results.first(where: { $0.serviceID == always.id })!.id
        state.toggleServiceCollapsed(always.id, persist: false)
        state.toggleServiceCollapsed(always.id, persist: false)
        try check(state.results.first(where: { $0.serviceID == always.id })?.id == alwaysCard && !state.working, "总是折叠同查询重开重复请求")
        state.translateService(pinned.id)
        try await waitForCompletion(state)
        try check(state.results.map(\.serviceID) == [remember.id, normal.id, always.id, pinned.id] && state.results.last?.dictionary?.word == "hello", "点击钉住服务未独立查询/插入正确顺序")
        state.toggleServiceCollapsed(remember.id, persist: false)
        state.input = "apple"; state.translate()
        try await waitForCompletion(state)
        try check(state.results[0].deferred && state.results[2].deferred && state.results[1].dictionary?.word == "apple" && state.results.count == 3,
                  "下一查询未保留记住折叠/重置总是折叠/清除钉住结果")
        state.setServiceTriggerStrategy(always.id, strategy: .pinned, persist: false)
        try check(state.preferences.pinnedServiceIDs.contains(always.id) && state.preferences.services.first(where: { $0.id == always.id })?.options["triggerStrategy"] == "pinned", "策略保存未同步钉住标记")
        state.setServiceTriggerStrategy(always.id, strategy: .normal, persist: false)
        try check(!state.preferences.pinnedServiceIDs.contains(always.id) && !state.preferences.collapsedServiceIDs.contains(always.id), "普通策略未清理钉住/折叠标记")
        state.cancelTranslation()
        return ["服务触发实际离线查询：普通折叠仍请求、记住折叠保留待触发卡、总是折叠每查询重置、钉住仅点击请求；顺序与展开仅一次通过。", "服务触发隔离状态：延后卡不计working且不阻止首结果复制决策，策略与旧钉住/折叠数组同步；未写用户配置、历史、剪贴板或发送网络请求。"]
    }
}

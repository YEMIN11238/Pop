import Foundation

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case apple, openAI, deepL, google, baidu, youdao, tencent, microsoft, aliyun, caiyun, niutrans, volcano, amazon, claude, gemini, plugin, dictionary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return "系统翻译"
        case .dictionary: return "简明英汉词典"
        case .openAI: return "通用 AI（OpenAI 兼容）"
        case .deepL: return "DeepL"
        case .google: return "Google Cloud Translation"
        case .baidu: return "百度翻译"
        case .youdao: return "有道翻译"
        case .tencent: return "腾讯云翻译"
        case .microsoft: return "Microsoft Translator"
        case .aliyun: return "阿里云机器翻译"
        case .caiyun: return "彩云小译"
        case .niutrans: return "小牛翻译"
        case .volcano: return "火山翻译"
        case .amazon: return "Amazon Translate"
        case .claude: return "Claude（原生接口）"
        case .gemini: return "Gemini（原生接口）"
        case .plugin: return "JavaScript 插件"
        }
    }
    func title(for capability: String) -> String {
        guard capability != "translate" else { return title }
        let vendor: String
        switch self {
        case .google: vendor = "Google Cloud"
        case .microsoft: vendor = "Microsoft Azure"
        case .baidu: vendor = "百度智能云"
        case .tencent: vendor = "腾讯云"
        case .amazon: vendor = "Amazon AWS"
        default: vendor = title
        }
        return vendor + (capability == "ocr" ? " OCR" : " 语音合成")
    }
}

struct ServiceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: ServiceKind
    var enabled = true
    var endpoint = ""
    var model = ""
    var pluginID = ""
    var capability = "translate"
    var options: [String: String] = [:]
    /// OCR configurations belong either to screenshot translation or to the OCR window.
    /// A missing scope identifies a configuration saved before these lists were split.
    var scope: String?
    /// Legacy copies may read the original Keychain account until explicitly saved.
    /// Only the account UUID is stored in preferences; no secret is exported here.
    var credentialSourceID: UUID?
    var credentialID: UUID { credentialSourceID ?? id }
    func triggerStrategy(legacyPinned: Bool = false) -> ServiceTriggerStrategy {
        if let value = options["triggerStrategy"], let strategy = ServiceTriggerStrategy(rawValue: value) { return strategy }
        return legacyPinned ? .pinned : .normal
    }
    static var system: ServiceConfig { ServiceConfig(name: "系统翻译", kind: .apple) }
    static var dictionary: ServiceConfig { ServiceConfig(name: "简明英汉词典", kind: .dictionary) }
    static func systemMedia(capability: String, scope: String = "translation") -> ServiceConfig {
        var service = ServiceConfig(name: capability == "ocr" ? "离线文本识别" : "离线语音合成", kind: .apple)
        service.capability = capability; service.scope = scope
        return service
    }
}

enum ServiceTriggerStrategy: String, CaseIterable {
    case normal, rememberCollapse, alwaysCollapsed, pinned

    func defersQuery(isCollapsed: Bool) -> Bool {
        self == .alwaysCollapsed || (self == .rememberCollapse && isCollapsed)
    }
}

struct TranslationRequest {
    let text: String
    let source: String
    let target: String
    /// Bob passes this separately from normalized text to PluginTranslateJSQuery.
    let originalText: String

    init(text: String, source: String, target: String, originalText: String? = nil) {
        self.text = text; self.source = source; self.target = target
        self.originalText = originalText ?? text
    }
}

struct TranslationOutput: Equatable {
    var text: String
    var detectedSource: String?
    var pronunciation: String?
    var details: [String] = []
    var reasoning: String?
    var format: String?
    var dictionary: DictionaryResult?
}

struct ResultCard: Identifiable {
    let id = UUID()
    let serviceID: UUID
    let name: String
    var text = ""
    var error: String?
    var loading = true
    var pronunciation: String?
    var details: [String] = []
    var reasoning: String?
    var format: String?
    var dictionary: DictionaryResult?
    /// A collapsed service awaiting an explicit expansion, not an active task.
    var deferred = false
}

/// Decides which completed service result may be copied, without touching the
/// system pasteboard. AppState rejects stale callbacks before consulting this.
struct FirstResultCopyPolicy {
    private var copiedFor: UUID?

    mutating func nextText(in results: [ResultCard], queryID: UUID, enabled: Bool, excluding excluded: Set<UUID> = []) -> String? {
        guard enabled, copiedFor != queryID else { return nil }
        for result in results where !excluded.contains(result.serviceID) && !result.deferred {
            if result.loading { return nil }
            if result.error == nil, !result.text.isEmpty {
                copiedFor = queryID
                return result.text
            }
        }
        return nil
    }
}

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var source: String
    var sourceLanguage: String
    var targetLanguage: String
    var results: [String: String]
    var favorite = false
}

struct AppPreferences: Codable, Equatable {
    var sourceLanguage = "auto"
    var targetLanguage = "zh-Hans"
    var fontSize = 14.0
    var autoCopyOCR = true
    var closeAfterCopy = false
    var normalizeIdentifiers = true
    var saveHistory = true
    var ocrAccurate = true
    var ocrLanguageCorrection = true
    var ocrLanguages = ["zh-Hans", "en-US"]
    var appearance = "system"
    var ocrServiceID: UUID?
    var translationOCRServiceID: UUID?
    private var ocrServiceConfigurationVersion = 3
    var ttsServiceID: UUID?
    var services = [ServiceConfig.system, .dictionary, .systemMedia(capability: "ocr"),
                    .systemMedia(capability: "ocr", scope: "standaloneOCR"), .systemMedia(capability: "tts")]
    private var dictionaryServiceConfigurationVersion = 1
    var pinnedServiceIDs: [UUID] = []
    var collapsedServiceIDs: [UUID] = []
    var translationPinned = false
    var ocrPinned = false
    var hideOnBlur = true
    var windowPosition = "last"
    var maxWindowHeight = 720.0
    var inputDisplay = "remember"
    var inputVisible = true
    var resultDisplay = "remember"
    var renderMarkdown = true
    var showReasoning = false
    var autoTargetLanguage = false
    var primaryLanguage = "zh-Hans"
    var secondaryLanguage = "en"
    var mergeLineBreaks = false
    var removeCommentMarkers = false
    var joinHyphenatedWords = false
    var compactBlankLines = false
    var smartOCRParagraphs = true
    var silentServiceID: UUID?
    var historyLimit = 10000
    // Legacy compatibility only; dictionary service.enabled controls new queries.
    var enableDictionary = true
    var renderRemoteImages = false
    var autoCopyTranslationOCR = false
    var autoCopyFirstResult = false
    var autoSpeakSource = false
    var copyHighlightedWord = false
    var favoriteLanguages = ["zh-Hans", "en", "ja"]
    var selectionWindowPosition = "center"
    var inputWindowPosition = "center"
    var ocrWindowPosition = "center"
    var selectionInputDisplay = "remember"
    var screenshotInputDisplay = "remember"
    var maxInputHeight = 200.0
    var showLanguageBar = true
    var showInputToggle = false
    var showScreenshotButton = true
    var showClipboardButton = false
    var showHistoryButton = false
    var showFavoriteButton = true
    var showReplaceButton = true
    var showOCRScreenshotButton = true
    var showOCRFileButton = true
    var showOCRClipboardButton = false
    var pinToDesktop = false
    var enhancedWindowLevel = false
    var removeScreenMargins = false
    var linkConfirmation = "suspicious"
    var hideSelectionError = false
    var maxWindowHeightFraction = 0.8
    var showCopyCamel = false
    var showCopyPascal = false
    var showCopySnake = false
    var showCopyKebab = false
    var showCopyMacro = false
    var recognizeQRCode = true
    var hideStatusItem = false
    var statusIconStyle = "pop"
    var statusIconPath = ""
    var statusRightClickAction = "menu"
    var statusImageDropAction = "ocr"
    var tooltipBehavior = "immediate"
    var screenshotCompatibilityMode = false
    var screenshotShowsTips = true
    var hideSilentOCRLoading = false
    var selectionMode = "smart"
    var keepLanguageBarWhenPinned = false
    var localLoggingEnabled = true
    var proxyEnabled = false
    var proxyHost = ""
    var proxyPort = 7890
    var proxyUsername = ""

    init() {}
    enum CodingKeys: String, CodingKey {
        case sourceLanguage, targetLanguage, fontSize, autoCopyOCR, closeAfterCopy, normalizeIdentifiers, saveHistory
        case ocrAccurate, ocrLanguageCorrection, ocrLanguages, appearance, ocrServiceID, translationOCRServiceID, ocrServiceConfigurationVersion, ttsServiceID, services
        case pinnedServiceIDs, collapsedServiceIDs
        case translationPinned, ocrPinned, hideOnBlur, windowPosition, maxWindowHeight, inputDisplay, inputVisible, resultDisplay
        case renderMarkdown, showReasoning, autoTargetLanguage, primaryLanguage, secondaryLanguage
        case mergeLineBreaks, removeCommentMarkers, joinHyphenatedWords, compactBlankLines, smartOCRParagraphs
        case silentServiceID, historyLimit
        case enableDictionary, dictionaryServiceConfigurationVersion, renderRemoteImages
        case autoCopyTranslationOCR, autoCopyFirstResult, autoSpeakSource, copyHighlightedWord, favoriteLanguages
        case selectionWindowPosition, inputWindowPosition, ocrWindowPosition, selectionInputDisplay, screenshotInputDisplay
        case maxInputHeight, showLanguageBar, showInputToggle, showScreenshotButton, showClipboardButton
        case showHistoryButton, showFavoriteButton, showReplaceButton, showOCRScreenshotButton, showOCRFileButton
        case showOCRClipboardButton, pinToDesktop, enhancedWindowLevel, removeScreenMargins, linkConfirmation
        case hideSelectionError, maxWindowHeightFraction, showCopyCamel, showCopyPascal, showCopySnake
        case showCopyKebab, showCopyMacro, recognizeQRCode
        case hideStatusItem, statusIconStyle, statusIconPath, statusRightClickAction, statusImageDropAction, tooltipBehavior, screenshotCompatibilityMode, screenshotShowsTips, hideSilentOCRLoading, selectionMode, keepLanguageBarWhenPinned, localLoggingEnabled, proxyEnabled, proxyHost, proxyPort, proxyUsername
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? sourceLanguage
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        autoCopyOCR = try values.decodeIfPresent(Bool.self, forKey: .autoCopyOCR) ?? autoCopyOCR
        closeAfterCopy = try values.decodeIfPresent(Bool.self, forKey: .closeAfterCopy) ?? closeAfterCopy
        normalizeIdentifiers = try values.decodeIfPresent(Bool.self, forKey: .normalizeIdentifiers) ?? normalizeIdentifiers
        saveHistory = try values.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? saveHistory
        ocrAccurate = try values.decodeIfPresent(Bool.self, forKey: .ocrAccurate) ?? ocrAccurate
        ocrLanguageCorrection = try values.decodeIfPresent(Bool.self, forKey: .ocrLanguageCorrection) ?? ocrLanguageCorrection
        ocrLanguages = try values.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? ocrLanguages
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        ocrServiceID = try values.decodeIfPresent(UUID.self, forKey: .ocrServiceID)
        let ocrConfigurationVersion = try values.decodeIfPresent(Int.self, forKey: .ocrServiceConfigurationVersion) ?? 0
        if values.contains(.translationOCRServiceID) || ocrConfigurationVersion >= 2 {
            translationOCRServiceID = try values.decodeIfPresent(UUID.self, forKey: .translationOCRServiceID)
        } else {
            // Before the split, both entry points deliberately shared this value.
            // The version marker preserves an explicit new "system OCR" (nil)
            // even though synthesized Optional encoding omits the nil field.
            translationOCRServiceID = ocrServiceID
        }
        ttsServiceID = try values.decodeIfPresent(UUID.self, forKey: .ttsServiceID)
        services = try values.decodeIfPresent([ServiceConfig].self, forKey: .services) ?? services
        pinnedServiceIDs = try values.decodeIfPresent([UUID].self, forKey: .pinnedServiceIDs) ?? []
        collapsedServiceIDs = try values.decodeIfPresent([UUID].self, forKey: .collapsedServiceIDs) ?? []
        translationPinned = try values.decodeIfPresent(Bool.self, forKey: .translationPinned) ?? translationPinned
        ocrPinned = try values.decodeIfPresent(Bool.self, forKey: .ocrPinned) ?? ocrPinned
        hideOnBlur = try values.decodeIfPresent(Bool.self, forKey: .hideOnBlur) ?? hideOnBlur
        windowPosition = try values.decodeIfPresent(String.self, forKey: .windowPosition) ?? windowPosition
        maxWindowHeight = try values.decodeIfPresent(Double.self, forKey: .maxWindowHeight) ?? maxWindowHeight
        inputDisplay = try values.decodeIfPresent(String.self, forKey: .inputDisplay) ?? inputDisplay
        inputVisible = try values.decodeIfPresent(Bool.self, forKey: .inputVisible) ?? inputVisible
        resultDisplay = try values.decodeIfPresent(String.self, forKey: .resultDisplay) ?? resultDisplay
        renderMarkdown = try values.decodeIfPresent(Bool.self, forKey: .renderMarkdown) ?? renderMarkdown
        showReasoning = try values.decodeIfPresent(Bool.self, forKey: .showReasoning) ?? showReasoning
        autoTargetLanguage = try values.decodeIfPresent(Bool.self, forKey: .autoTargetLanguage) ?? autoTargetLanguage
        primaryLanguage = try values.decodeIfPresent(String.self, forKey: .primaryLanguage) ?? primaryLanguage
        secondaryLanguage = try values.decodeIfPresent(String.self, forKey: .secondaryLanguage) ?? secondaryLanguage
        mergeLineBreaks = try values.decodeIfPresent(Bool.self, forKey: .mergeLineBreaks) ?? mergeLineBreaks
        removeCommentMarkers = try values.decodeIfPresent(Bool.self, forKey: .removeCommentMarkers) ?? removeCommentMarkers
        joinHyphenatedWords = try values.decodeIfPresent(Bool.self, forKey: .joinHyphenatedWords) ?? joinHyphenatedWords
        compactBlankLines = try values.decodeIfPresent(Bool.self, forKey: .compactBlankLines) ?? compactBlankLines
        smartOCRParagraphs = try values.decodeIfPresent(Bool.self, forKey: .smartOCRParagraphs) ?? smartOCRParagraphs
        silentServiceID = try values.decodeIfPresent(UUID.self, forKey: .silentServiceID)
        historyLimit = max(100, min(100000, try values.decodeIfPresent(Int.self, forKey: .historyLimit) ?? historyLimit))
        enableDictionary = try values.decodeIfPresent(Bool.self, forKey: .enableDictionary) ?? enableDictionary
        let dictionaryConfigurationVersion = try values.decodeIfPresent(Int.self, forKey: .dictionaryServiceConfigurationVersion) ?? 0
        renderRemoteImages = try values.decodeIfPresent(Bool.self, forKey: .renderRemoteImages) ?? renderRemoteImages
        autoCopyTranslationOCR = try values.decodeIfPresent(Bool.self, forKey: .autoCopyTranslationOCR) ?? autoCopyTranslationOCR
        autoCopyFirstResult = try values.decodeIfPresent(Bool.self, forKey: .autoCopyFirstResult) ?? autoCopyFirstResult
        autoSpeakSource = try values.decodeIfPresent(Bool.self, forKey: .autoSpeakSource) ?? autoSpeakSource
        copyHighlightedWord = try values.decodeIfPresent(Bool.self, forKey: .copyHighlightedWord) ?? copyHighlightedWord
        favoriteLanguages = try values.decodeIfPresent([String].self, forKey: .favoriteLanguages) ?? favoriteLanguages
        selectionWindowPosition = try values.decodeIfPresent(String.self, forKey: .selectionWindowPosition) ?? selectionWindowPosition
        inputWindowPosition = try values.decodeIfPresent(String.self, forKey: .inputWindowPosition) ?? inputWindowPosition
        ocrWindowPosition = try values.decodeIfPresent(String.self, forKey: .ocrWindowPosition) ?? ocrWindowPosition
        selectionInputDisplay = try values.decodeIfPresent(String.self, forKey: .selectionInputDisplay) ?? selectionInputDisplay
        screenshotInputDisplay = try values.decodeIfPresent(String.self, forKey: .screenshotInputDisplay) ?? screenshotInputDisplay
        maxInputHeight = max(60, min(800, try values.decodeIfPresent(Double.self, forKey: .maxInputHeight) ?? maxInputHeight))
        showLanguageBar = try values.decodeIfPresent(Bool.self, forKey: .showLanguageBar) ?? showLanguageBar
        showInputToggle = try values.decodeIfPresent(Bool.self, forKey: .showInputToggle) ?? showInputToggle
        showScreenshotButton = try values.decodeIfPresent(Bool.self, forKey: .showScreenshotButton) ?? showScreenshotButton
        showClipboardButton = try values.decodeIfPresent(Bool.self, forKey: .showClipboardButton) ?? showClipboardButton
        showHistoryButton = try values.decodeIfPresent(Bool.self, forKey: .showHistoryButton) ?? showHistoryButton
        showFavoriteButton = try values.decodeIfPresent(Bool.self, forKey: .showFavoriteButton) ?? showFavoriteButton
        showReplaceButton = try values.decodeIfPresent(Bool.self, forKey: .showReplaceButton) ?? showReplaceButton
        showOCRScreenshotButton = try values.decodeIfPresent(Bool.self, forKey: .showOCRScreenshotButton) ?? showOCRScreenshotButton
        showOCRFileButton = try values.decodeIfPresent(Bool.self, forKey: .showOCRFileButton) ?? showOCRFileButton
        showOCRClipboardButton = try values.decodeIfPresent(Bool.self, forKey: .showOCRClipboardButton) ?? showOCRClipboardButton
        pinToDesktop = try values.decodeIfPresent(Bool.self, forKey: .pinToDesktop) ?? pinToDesktop
        enhancedWindowLevel = try values.decodeIfPresent(Bool.self, forKey: .enhancedWindowLevel) ?? enhancedWindowLevel
        removeScreenMargins = try values.decodeIfPresent(Bool.self, forKey: .removeScreenMargins) ?? removeScreenMargins
        linkConfirmation = try values.decodeIfPresent(String.self, forKey: .linkConfirmation) ?? linkConfirmation
        hideSelectionError = try values.decodeIfPresent(Bool.self, forKey: .hideSelectionError) ?? hideSelectionError
        maxWindowHeightFraction = max(0.3, min(1, try values.decodeIfPresent(Double.self, forKey: .maxWindowHeightFraction) ?? maxWindowHeightFraction))
        showCopyCamel = try values.decodeIfPresent(Bool.self, forKey: .showCopyCamel) ?? showCopyCamel
        showCopyPascal = try values.decodeIfPresent(Bool.self, forKey: .showCopyPascal) ?? showCopyPascal
        showCopySnake = try values.decodeIfPresent(Bool.self, forKey: .showCopySnake) ?? showCopySnake
        showCopyKebab = try values.decodeIfPresent(Bool.self, forKey: .showCopyKebab) ?? showCopyKebab
        showCopyMacro = try values.decodeIfPresent(Bool.self, forKey: .showCopyMacro) ?? showCopyMacro
        recognizeQRCode = try values.decodeIfPresent(Bool.self, forKey: .recognizeQRCode) ?? recognizeQRCode
        hideStatusItem = try values.decodeIfPresent(Bool.self, forKey: .hideStatusItem) ?? hideStatusItem
        statusIconStyle = try values.decodeIfPresent(String.self, forKey: .statusIconStyle) ?? statusIconStyle
        statusIconPath = try values.decodeIfPresent(String.self, forKey: .statusIconPath) ?? statusIconPath
        statusRightClickAction = try values.decodeIfPresent(String.self, forKey: .statusRightClickAction) ?? statusRightClickAction
        statusImageDropAction = try values.decodeIfPresent(String.self, forKey: .statusImageDropAction) ?? statusImageDropAction
        tooltipBehavior = try values.decodeIfPresent(String.self, forKey: .tooltipBehavior) ?? tooltipBehavior
        screenshotCompatibilityMode = try values.decodeIfPresent(Bool.self, forKey: .screenshotCompatibilityMode) ?? screenshotCompatibilityMode
        screenshotShowsTips = try values.decodeIfPresent(Bool.self, forKey: .screenshotShowsTips) ?? screenshotShowsTips
        hideSilentOCRLoading = try values.decodeIfPresent(Bool.self, forKey: .hideSilentOCRLoading) ?? hideSilentOCRLoading
        selectionMode = try values.decodeIfPresent(String.self, forKey: .selectionMode) ?? selectionMode
        keepLanguageBarWhenPinned = try values.decodeIfPresent(Bool.self, forKey: .keepLanguageBarWhenPinned) ?? keepLanguageBarWhenPinned
        localLoggingEnabled = try values.decodeIfPresent(Bool.self, forKey: .localLoggingEnabled) ?? localLoggingEnabled
        proxyEnabled = try values.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? proxyEnabled
        proxyHost = try values.decodeIfPresent(String.self, forKey: .proxyHost) ?? proxyHost
        proxyPort = try values.decodeIfPresent(Int.self, forKey: .proxyPort) ?? proxyPort
        proxyUsername = try values.decodeIfPresent(String.self, forKey: .proxyUsername) ?? proxyUsername
        if ocrConfigurationVersion < 3 {
            migrateOCRServiceScopes()
            if let index = services.firstIndex(where: { $0.id == ttsServiceID && $0.capability == "tts" }) {
                for item in services.indices where services[item].capability == "tts" { services[item].enabled = item == index }
            }
        }
        if dictionaryConfigurationVersion < 1 {
            // Preserve existing service records (including their order and disabled
            // state). A removed dictionary must stay removed after the first save.
            if !services.contains(where: { $0.kind == .dictionary && $0.capability == "translate" }) {
                var dictionary = ServiceConfig.dictionary
                dictionary.enabled = enableDictionary
                services.append(dictionary)
            } else if !values.contains(.services), let index = services.firstIndex(where: { $0.kind == .dictionary }) {
                services[index].enabled = enableDictionary
            }
        }
        normalizeMediaSelections()
    }

    private mutating func migrateOCRServiceScopes() {
        var copies: [ServiceConfig] = []
        for index in services.indices where services[index].capability == "ocr" && services[index].scope == nil {
            let oldID = services[index].id
            services[index].scope = "standaloneOCR"
            var copy = services[index]
            copy.id = UUID(); copy.scope = "translation"
            copy.credentialSourceID = services[index].credentialID
            copies.append(copy)
            if translationOCRServiceID == oldID { translationOCRServiceID = copy.id }
        }
        services.append(contentsOf: copies)
        for scope in ["translation", "standaloneOCR"] where !services.contains(where: { $0.capability == "ocr" && $0.scope == scope && $0.kind == .apple }) {
            services.append(.systemMedia(capability: "ocr", scope: scope))
        }
        if !services.contains(where: { $0.capability == "tts" && $0.kind == .apple }) {
            services.append(.systemMedia(capability: "tts"))
        }
        for translation in [true, false] {
            let choices = ocrServices(forTranslation: translation)
            let previous = translation ? translationOCRServiceID : ocrServiceID
            let selected = choices.first(where: { $0.id == previous }) ?? choices.first(where: { $0.kind == .apple }) ?? choices.first
            if let selected { selectOCRService(selected.id, forTranslation: translation) }
        }
    }

    func ocrServices(forTranslation: Bool) -> [ServiceConfig] {
        services.filter { $0.capability == "ocr" && $0.scope == (forTranslation ? "translation" : "standaloneOCR") }
    }

    func selectedOCRService(forTranslation: Bool) -> ServiceConfig? {
        let choices = ocrServices(forTranslation: forTranslation)
        return choices.first(where: \.enabled)
    }

    var selectedTTSService: ServiceConfig? { services.first { $0.capability == "tts" && $0.enabled } }

    private mutating func normalizeMediaSelections() {
        for scope in ["translation", "standaloneOCR"] {
            let indices = services.indices.filter { services[$0].capability == "ocr" && services[$0].scope == scope }
            if let selected = indices.first(where: { services[$0].enabled }) ?? indices.first {
                for index in indices { services[index].enabled = index == selected }
            }
        }
        let indices = services.indices.filter { services[$0].capability == "tts" }
        if let selected = indices.first(where: { services[$0].enabled }) ?? indices.first {
            for index in indices { services[index].enabled = index == selected }
        }
    }

    mutating func selectOCRService(_ id: UUID, forTranslation: Bool) {
        let scope = forTranslation ? "translation" : "standaloneOCR"
        guard services.contains(where: { $0.id == id && $0.capability == "ocr" && $0.scope == scope }) else { return }
        for index in services.indices where services[index].capability == "ocr" && services[index].scope == scope {
            services[index].enabled = services[index].id == id
        }
        if forTranslation { translationOCRServiceID = id } else { ocrServiceID = id }
    }
}

enum LanguageCatalog {
    static let choices: [(String, String)] = [
        ("auto", "自动"),
        ("zh-Hans", "中文简体"),
        ("zh-Hant", "中文繁体"),
        ("yue", "粤语"),
        ("wyw", "文言文"),
        ("pysx", "拼音缩写"),
        ("en", "英语"),
        ("ja", "日语"),
        ("ko", "韩语"),
        ("fr", "法语"),
        ("de", "德语"),
        ("es", "西班牙语"),
        ("it", "意大利语"),
        ("ru", "俄语"),
        ("pt", "葡萄牙语"),
        ("pt-pt", "葡萄牙语（葡萄牙）"),
        ("pt-br", "葡萄牙语（巴西）"),
        ("nl", "荷兰语"),
        ("pl", "波兰语"),
        ("ar", "阿拉伯语"),
        ("ab", "阿布哈兹语"),
        ("ace", "亚齐语"),
        ("acr", "阿奇语"),
        ("acu", "阿丘雅语"),
        ("adh", "阿多拉语"),
        ("af", "南非语"),
        ("agr", "阿瓜鲁纳语"),
        ("ak", "阿肯语"),
        ("ake", "阿卡瓦伊语"),
        ("am", "阿姆哈拉语"),
        ("amk", "安拜语"),
        ("amu", "阿穆斯戈语"),
        ("an", "阿拉贡语"),
        ("any", "阿格尼桑维语"),
        ("as", "阿萨姆语"),
        ("ast", "阿斯图里亚斯语"),
        ("ata", "佩勒-阿塔语"),
        ("ay", "艾马拉语"),
        ("az", "阿塞拜疆语"),
        ("azb", "南阿塞拜疆语"),
        ("ba", "巴什基尔语"),
        ("bal", "俾路支语"),
        ("bam", "班巴拉语"),
        ("bba", "巴里巴语"),
        ("bch", "巴里亚语"),
        ("bdh", "巴卡语"),
        ("bdu", "奥罗科语"),
        ("be", "白俄罗斯语"),
        ("bem", "本巴语"),
        ("ber", "柏柏尔语"),
        ("bfa", "巴里语"),
        ("bg", "保加利亚语"),
        ("bho", "博杰普尔语"),
        ("bi", "比斯拉马语"),
        ("bm", "班巴拉语"),
        ("bn", "孟加拉语"),
        ("bno", "班通安隆语"),
        ("bnp", "波拉语"),
        ("bo", "藏语"),
        ("bqj", "班迪亚勒语"),
        ("bqp", "布萨语"),
        ("br", "布列塔尼语"),
        ("bs", "波斯尼亚语"),
        ("bsn", "巴拉萨纳语"),
        ("bus", "博科巴鲁语"),
        ("byn", "比林语"),
        ("byr", "伊普马语"),
        ("ca", "加泰罗尼亚语"),
        ("cak", "卡克奇克尔语"),
        ("cas", "齐马内语"),
        ("cbk", "查瓦卡诺语"),
        ("cbl", "布阿尔考钦语"),
        ("ccp", "查克玛语"),
        ("cdf", "茨鲁语"),
        ("ceb", "宿务语"),
        ("cfm", "法兰钦语"),
        ("ch", "查莫罗语"),
        ("che", "车臣语"),
        ("chm", "马里语（俄罗斯）"),
        ("chq", "瓦哈卡语"),
        ("chr", "切罗基语"),
        ("cjp", "卡韦卡尔语"),
        ("ckb", "中库尔德语"),
        ("cki", "喀克其奎语"),
        ("cnh", "哈卡钦语"),
        ("cni", "坎帕语"),
        ("cnr", "黑山语"),
        ("co", "科西嘉语"),
        ("cop", "科普特语"),
        ("cpb", "阿舍宁卡语"),
        ("crh", "克里米亚鞑靼语"),
        ("crs", "塞舌尔克里奥尔语"),
        ("cs", "捷克语"),
        ("csb", "卡舒比语"),
        ("ctd", "特丁钦语"),
        ("cv", "楚瓦什语"),
        ("cy", "威尔士语"),
        ("czt", "佐通钦语"),
        ("da", "丹麦语"),
        ("dik", "丁卡语"),
        ("dje", "哲尔马语"),
        ("djk", "恩都卡语"),
        ("dop", "卢克帕语"),
        ("dtp", "杜顺语"),
        ("duo", "东部卡加延-阿格塔语"),
        ("dv", "迪维西语"),
        ("dyu", "迪尤拉语"),
        ("dz", "宗喀语"),
        ("ee", "埃维语"),
        ("el", "希腊语"),
        ("enx", "恩舍特语"),
        ("eo", "世界语"),
        ("et", "爱沙尼亚语"),
        ("eu", "巴斯克语"),
        ("fa", "波斯语"),
        ("fi", "芬兰语"),
        ("fil", "菲律宾语"),
        ("fj", "斐济语"),
        ("fo", "法罗语"),
        ("fur", "弗留利语"),
        ("fuv", "尼日利亚富拉语"),
        ("fvr", "富尔语"),
        ("fy", "弗里斯兰语"),
        ("ga", "爱尔兰语"),
        ("gbi", "加莱拉语"),
        ("gbo", "北部格雷博语"),
        ("gd", "苏格兰盖尔语"),
        ("gil", "基里巴斯语"),
        ("gl", "加利西亚语"),
        ("gn", "瓜拉尼语"),
        ("gnw", "西部玻利维亚瓜拉尼语"),
        ("gof", "果发语"),
        ("gos", "格罗宁根方言"),
        ("gu", "古吉拉特语"),
        ("gub", "瓜哈哈拉语"),
        ("gur", "法拉法拉语"),
        ("gv", "马恩语"),
        ("ha", "豪萨语"),
        ("haw", "夏威夷语"),
        ("hbs", "塞尔维亚语-克罗地亚语"),
        ("he", "希伯来语"),
        ("hi", "印地语"),
        ("hil", "希利盖农语"),
        ("hlb", "亥比语"),
        ("hmn", "苗语"),
        ("hmo", "希里莫图语"),
        ("hr", "克罗地亚语"),
        ("hsb", "上索布语"),
        ("ht", "海地克里奥尔语"),
        ("hu", "匈牙利语"),
        ("hui", "胡里语"),
        ("hup", "胡帕语"),
        ("huv", "圣马特奥德马尔-瓦维语"),
        ("hwc", "夏威夷克里奥尔英语"),
        ("hy", "亚美尼亚语"),
        ("ia", "因特语"),
        ("iba", "伊班语"),
        ("id", "印尼语"),
        ("ie", "西方国际语"),
        ("ifa", "中部伊富高语"),
        ("ifb", "阿雅安伊富高语"),
        ("ify", "安蒂波洛伊富高语"),
        ("ig", "伊博语"),
        ("ikk", "伊卡语"),
        ("ilo", "伊洛卡诺语"),
        ("inh", "印古什语"),
        ("io", "伊多语"),
        ("iou", "图马伊鲁穆语"),
        ("is", "冰岛语"),
        ("iu", "伊努克提图特语"),
        ("izz", "伊兹语"),
        ("jac", "雅加达语"),
        ("jae", "雅比姆语"),
        ("jbo", "逻辑语"),
        ("jiv", "舒阿尔语"),
        ("jmc", "斯哈语"),
        ("jv", "印尼爪哇语"),
        ("jw", "爪哇语"),
        ("jy", "格鲁吉亚语"),
        ("ka", "格鲁吉亚语"),
        ("kab", "卡拜尔语"),
        ("kac", "景颇语"),
        ("kbh", "科奇语"),
        ("kbo", "克利科语"),
        ("kdx", "侗语"),
        ("kek", "玛雅语"),
        ("keo", "卡库瓦语"),
        ("kg", "刚果语"),
        ("kha", "卡西语"),
        ("ki", "基库尤语"),
        ("kj", "宽亚玛语"),
        ("kk", "哈萨克语"),
        ("kl", "格陵兰语"),
        ("kle", "库隆语"),
        ("km", "高棉语"),
        ("kmr", "北库尔德语"),
        ("kn", "卡纳达语"),
        ("knj", "阿卡特克语"),
        ("kpg", "卡平阿马朗伊语"),
        ("kr", "卡努里语"),
        ("krs", "格巴亚语"),
        ("ks", "克什米尔语"),
        ("ksd", "库阿努阿语"),
        ("ku", "库尔德语"),
        ("kw", "康沃尔语"),
        ("ky", "柯尔克孜语"),
        ("kyu", "西部克耶语"),
        ("la", "拉丁语"),
        ("lb", "卢森堡语"),
        ("lcm", "通加格语"),
        ("lcp", "西部拉威语"),
        ("lfn", "新共同语言"),
        ("lg", "卢干达语"),
        ("li", "林堡语"),
        ("ln", "林加拉语"),
        ("lnd", "弄巴湾语"),
        ("lo", "老挝语"),
        ("lsi", "勒期语"),
        ("lt", "立陶宛语"),
        ("ltg", "拉特加莱语"),
        ("lu", "卢巴卡丹加语"),
        ("lv", "拉脱维亚语"),
        ("mad", "马都拉语"),
        ("mah", "马绍尔语"),
        ("mai", "迈蒂利语"),
        ("mam", "马姆语"),
        ("map", "北部马姆语"),
        ("mbb", "西布基农马诺布语"),
        ("mdy", "马勒语"),
        ("me", "黑山语"),
        ("meu", "摩图语"),
        ("mfe", "毛里求斯克里奥尔语"),
        ("mg", "马尔加什语"),
        ("mh", "马绍尔语"),
        ("mhr", "马里语"),
        ("mi", "毛利语"),
        ("mk", "马其顿语"),
        ("ml", "马拉雅拉姆语"),
        ("mn", "蒙古语"),
        ("mni", "曼尼普尔语"),
        ("mos", "莫西语"),
        ("mps", "达迪比语"),
        ("mr", "马拉地语"),
        ("mrj", "山地马里语"),
        ("mrw", "马拉瑙语"),
        ("ms", "马来语"),
        ("mt", "马耳他语"),
        ("mus", "克里克语"),
        ("muv", "穆图凡语"),
        ("mww", "白苗语"),
        ("my", "缅甸语"),
        ("nb", "挪威布克莫尔语"),
        ("nch", "阿兹特克语"),
        ("nd", "北恩德贝勒语"),
        ("nds", "低地德语"),
        ("ne", "尼泊尔语"),
        ("ng", "恩敦加语"),
        ("ngl", "隆韦语"),
        ("ngu", "格雷罗纳瓦特尔语"),
        ("nhg", "纳瓦特尔语"),
        ("niu", "纽埃语"),
        ("no", "挪威语"),
        ("nop", "努曼干语"),
        ("nr", "南恩德贝勒语"),
        ("nso", "北索托语"),
        ("ntm", "纳特尼语"),
        ("nv", "纳瓦霍语"),
        ("ny", "齐切瓦语"),
        ("nyy", "尼亚库萨语"),
        ("oc", "奥克语"),
        ("oj", "奥杰布瓦语"),
        ("ojb", "奥吉布瓦语"),
        ("om", "奥罗莫语"),
        ("ond", "临高语"),
        ("or", "奥里亚语"),
        ("os", "奥塞梯语"),
        ("otq", "克雷塔罗奥托米语"),
        ("pa", "旁遮普语"),
        ("pag", "邦阿西楠语"),
        ("pap", "帕皮阿门托语"),
        ("pck", "派特语"),
        ("pil", "约姆语"),
        ("pmn", "帕姆语"),
        ("poh", "波孔奇语"),
        ("pot", "波塔瓦托米语"),
        ("ppk", "乌玛语"),
        ("prk", "佤语"),
        ("ps", "普什图语"),
        ("pss", "卡乌龙语"),
        ("ptu", "邦邦语"),
        ("qu", "克丘亚语"),
        ("quc", "基切语"),
        ("quh", "南玻利维亚克丘亚语"),
        ("quw", "盖丘亚语"),
        ("quz", "库斯科克丘亚语"),
        ("qxr", "卡纳尔高地-基丘亚语"),
        ("rm", "罗曼什语"),
        ("rmn", "罗姆语"),
        ("rn", "基隆迪语"),
        ("ro", "罗马尼亚语"),
        ("rom", "罗姆语"),
        ("rue", "卢森尼亚语"),
        ("rug", "罗维那语"),
        ("rw", "卢旺达语"),
        ("sa", "梵语"),
        ("sco", "低地苏格兰语"),
        ("sd", "信德语"),
        ("se", "北萨米语"),
        ("sg", "桑戈语"),
        ("shi", "希尔哈语"),
        ("shn", "掸语"),
        ("shp", "西皮沃语"),
        ("si", "僧伽罗语"),
        ("sid", "锡达莫语"),
        ("sk", "斯洛伐克语"),
        ("sl", "斯洛文尼亚语"),
        ("sm", "萨摩亚语"),
        ("sn", "修纳语"),
        ("so", "索马里语"),
        ("spy", "萨鲍特语"),
        ("sq", "阿尔巴尼亚语"),
        ("sr", "塞尔维亚语"),
        ("sr-Cyrl", "塞尔维亚语-西里尔文"),
        ("sr-Latn", "塞尔维亚语-拉丁文"),
        ("ss", "史瓦帝语"),
        ("ssd", "西罗伊语"),
        ("ssx", "桑贝里吉语"),
        ("st", "塞索托语"),
        ("su", "巽他语"),
        ("sv", "瑞典语"),
        ("sw", "斯瓦希里语"),
        ("swp", "苏奥语"),
        ("syc", "叙利亚语"),
        ("syr", "叙利亚语"),
        ("szl", "西里西亚语"),
        ("ta", "泰米尔语"),
        ("tbz", "迪塔马利语"),
        ("te", "泰卢固语"),
        ("teo", "特索语"),
        ("tet", "德顿语"),
        ("tex", "腾内特语"),
        ("tg", "塔吉克语"),
        ("th", "泰语"),
        ("ti", "提格雷尼亚语"),
        ("tig", "提格雷语"),
        ("tih", "蒂穆贡-穆鲁特语"),
        ("tk", "土库曼语"),
        ("tl", "菲律宾语"),
        ("tlh", "克林贡语"),
        ("tmh", "图阿雷格语"),
        ("tn", "茨瓦纳语"),
        ("to", "汤加语"),
        ("toi", "汤加语（赞比亚）"),
        ("tpi", "巴布亚皮钦语"),
        ("tpm", "坦普尔马语"),
        ("tr", "土耳其语"),
        ("ts", "聪加语"),
        ("tt", "鞑靼语"),
        ("tvl", "图瓦卢语"),
        ("tw", "契维语"),
        ("ty", "塔希提语"),
        ("tyv", "图瓦语"),
        ("udm", "乌德穆尔特语"),
        ("ug", "维吾尔语"),
        ("uk", "乌克兰语"),
        ("umb", "姆班杜语"),
        ("ur", "乌尔都语"),
        ("usp", "乌斯潘坦语"),
        ("uz", "乌兹别克语"),
        ("ve", "文达语"),
        ("vi", "越南语"),
        ("vo", "沃拉普克语"),
        ("vun", "文约语"),
        ("wa", "瓦隆语"),
        ("wal", "瓦拉莫语"),
        ("war", "瓦瑞语（菲律宾）"),
        ("wlx", "瓦利语"),
        ("wo", "沃洛夫语"),
        ("wrs", "瓦里斯语"),
        ("wsk", "瓦吉语"),
        ("xal", "卡尔梅克卫拉特语"),
        ("xh", "科萨语"),
        ("xsm", "格森语"),
        ("yi", "意第绪语"),
        ("yo", "约鲁巴语"),
        ("yon", "永贡语"),
        ("yua", "尤卡坦玛雅语"),
        ("zu", "祖鲁语"),
        ("zyb", "邕北壮语"),
        ("zza", "扎扎其语")
    ]
    static func title(_ code: String) -> String { choices.first { $0.0 == code }?.1 ?? code }
}

struct OCRLine {
    let text: String
    /// Normalized Vision coordinates (origin at bottom-left).
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float
}

struct OCRDocument {
    var text: String
    var lines: [OCRLine]
    var qrCodes: [String]
}

enum PopError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}

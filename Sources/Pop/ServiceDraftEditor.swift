import AppKit
import SwiftUI
import Translation
import Vision
import AVFoundation

private enum SystemTTSSettings {
    static let rates = (0...8).map { String(format: "%.1f", Double($0) / 10) }
    static func rate(_ stored: String?) -> String {
        let raw = Double(stored ?? "") ?? 0.5
        let finite = raw.isFinite ? raw : 0.5
        return String(format: "%.1f", (max(0, min(0.8, finite)) * 10).rounded() / 10)
    }
    static func rateTitle(_ raw: String) -> String { String(format: "%g 倍", (Double(raw) ?? 0.5) * 2) }
    static func languageKey(_ language: String) -> String {
        let value = language.replacingOccurrences(of: "_", with: "-").lowercased()
        if value.hasPrefix("zh") {
            return value.contains("hant") || value.hasSuffix("-tw") || value.hasSuffix("-hk") || value.hasSuffix("-mo") ? "zh-Hant" : "zh-Hans"
        }
        return value.split(separator: "-").first.map(String.init) ?? value
    }
}

/// Transient UI state. This type deliberately does not conform to Codable:
/// credentials remain in memory until the user explicitly saves this service.
struct ServiceEditDraft {
    var service: ServiceConfig
    var baseline: ServiceConfig
    var secrets: [String: String] = [:]
    var savedSecrets: [String: String] = [:]
    var credentialsLoaded = false
    var isNew = false
    let createdAt = Date()
    var isDirty: Bool { isNew || service != baseline || secrets != savedSecrets }
    init(service: ServiceConfig, isNew: Bool = false) { self.service = service; baseline = service; self.isNew = isNew }

    mutating func loadCredentials(plugins: [PluginDescriptor], read: (String) -> String = SecretStore.read) {
        guard !credentialsLoaded else { return }
        if service.kind == .dictionary { secrets = [:]; savedSecrets = [:]; credentialsLoaded = true; return }
        if !isNew || service.credentialSourceID != nil {
            if service.kind == .plugin, let plugin = plugins.first(where: { $0.id == service.pluginID }) {
                for field in plugin.options where field.isSecure {
                    secrets[field.identifier] = read(SecretStore.pluginKey(service.credentialID, option: field.identifier))
                }
            } else if service.kind != .apple && service.kind != .plugin {
                let stored = read(SecretStore.serviceKey(service.credentialID))
                if let data = stored.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) { secrets = values }
                else { secrets = stored.isEmpty ? [:] : ["apiKey": stored] }
            }
        }
        savedSecrets = secrets; credentialsLoaded = true
    }

    func credentialString() throws -> String {
        if service.kind == .dictionary { return "" }
        let fields = service.capability == "translate" ? CloudServiceCatalog.secretFields(for: service.kind) : CloudMediaCatalog.secretFields(for: service.kind, capability: service.capability)
        if fields.count == 1, fields.first?.key == "apiKey" { return secrets["apiKey"] ?? "" }
        let declared = Dictionary(uniqueKeysWithValues: fields.compactMap { field -> (String, String)? in
            guard let value = secrets[field.key], !value.isEmpty else { return nil }; return (field.key, value)
        })
        guard !declared.isEmpty else { return "" }
        return String(data: try JSONSerialization.data(withJSONObject: declared, options: [.sortedKeys]), encoding: .utf8) ?? ""
    }

    func credentialUpdates(plugins: [PluginDescriptor]) throws -> [String: String] {
        if service.kind == .dictionary { return [:] }
        let detach = service.credentialSourceID != nil
        if service.kind == .plugin {
            guard let plugin = plugins.first(where: { $0.id == service.pluginID }) else {
                if detach || secrets != savedSecrets { throw PopError.message("请先安装此服务对应的插件，再保存其凭据。") }
                return [:]
            }
            var updates: [String: String] = [:]
            for field in plugin.options where field.isSecure && (detach || secrets[field.identifier] != savedSecrets[field.identifier]) {
                updates[SecretStore.pluginKey(service.id, option: field.identifier)] = secrets[field.identifier] ?? ""
            }
            return updates
        }
        if service.kind != .apple && (detach || secrets != savedSecrets) {
            return [SecretStore.serviceKey(service.id): try credentialString()]
        }
        return [:]
    }
}

/// Exercises credential plans in memory. It never reads or writes the real
/// Keychain, changes preferences, invokes plugins, or sends network requests.
enum ServiceDraftOfflineSelfCheck {
    static func run() throws -> [String] {
        var checks = try SettingsServiceListSelfCheck.run()
        let sourceID = UUID()
        var config = ServiceConfig(name: "Fixture", kind: .openAI)
        config.credentialSourceID = sourceID
        var clone = ServiceEditDraft(service: config)
        var accounts: [String] = []
        clone.loadCredentials(plugins: [], read: { account in accounts.append(account); return "fixture-secret" })
        let own = SecretStore.serviceKey(config.id)
        let source = SecretStore.serviceKey(sourceID)
        let cloneUpdates = try clone.credentialUpdates(plugins: [])
        guard accounts == [source], !clone.isDirty, cloneUpdates == [own: "fixture-secret"], cloneUpdates[source] == nil else {
            throw PopError.message("服务凭据别名迁移计划复核失败")
        }
        var newClone = ServiceEditDraft(service: config, isNew: true)
        accounts = []
        newClone.loadCredentials(plugins: [], read: { account in accounts.append(account); return "fixture-secret" })
        guard accounts == [source], try newClone.credentialUpdates(plugins: []) == [own: "fixture-secret"] else { throw PopError.message("新副本未读取已声明的凭据来源") }
        checks.append("服务别名从来源账号读取，未改密钥也完整计划写入自身账号")

        var newDraft = ServiceEditDraft(service: ServiceConfig(name: "New", kind: .openAI), isNew: true)
        var readCount = 0
        newDraft.loadCredentials(plugins: [], read: { _ in readCount += 1; return "must-not-read" })
        guard readCount == 0, newDraft.secrets.isEmpty, newDraft.credentialsLoaded else { throw PopError.message("新服务草稿错误读取已有凭据") }
        var cleared = clone; cleared.service.credentialSourceID = nil; cleared.secrets["apiKey"] = ""
        guard try cleared.credentialUpdates(plugins: []) == [own: ""] else { throw PopError.message("清空凭据的写入计划复核失败") }
        checks.append("新服务不读取钥匙串；清空密钥产生明确删除计划")

        var multi = ServiceEditDraft(service: ServiceConfig(name: "Multi", kind: .baidu))
        multi.secrets = ["appId": "fixture-id", "secretKey": "fixture-key", "undeclared": "excluded"]
        let encoded = try multi.credentialString()
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
        guard decoded == ["appId": "fixture-id", "secretKey": "fixture-key"] else { throw PopError.message("多密钥序列化未限制声明字段") }
        checks.append("多密钥只序列化提供商声明字段")

        let field = PluginOption(identifier: "token", type: "text", title: "Token", defaultValue: "", description: "", isSecure: true, menuValues: [])
        let plugin = PluginDescriptor(id: "offline.fixture", name: "Fixture", version: "1", path: URL(fileURLWithPath: "/nonexistent/offline.fixture"), summary: "", author: "", homepage: "", category: "ocr", options: [field])
        var pluginConfig = ServiceConfig(name: "Plugin", kind: .plugin)
        pluginConfig.pluginID = plugin.id; pluginConfig.capability = "ocr"; pluginConfig.scope = "translation"; pluginConfig.credentialSourceID = sourceID
        var pluginDraft = ServiceEditDraft(service: pluginConfig)
        accounts = []
        pluginDraft.loadCredentials(plugins: [plugin], read: { account in accounts.append(account); return "fixture-plugin-token" })
        let pluginUpdates = try pluginDraft.credentialUpdates(plugins: [plugin])
        guard accounts == [SecretStore.pluginKey(sourceID, option: "token")], pluginUpdates == [SecretStore.pluginKey(pluginConfig.id, option: "token"): "fixture-plugin-token"] else {
            throw PopError.message("插件凭据别名迁移计划复核失败")
        }
        var missingPluginBlocked = false
        do { _ = try pluginDraft.credentialUpdates(plugins: []) } catch { missingPluginBlocked = true }
        guard missingPluginBlocked else { throw PopError.message("缺失插件元数据时仍允许清除凭据别名") }
        checks.append("插件安全字段独立计划迁移；缺少插件声明时保留别名并报错")
        guard SystemTTSSettings.rates.count == 9, SystemTTSSettings.rate(nil) == "0.5", SystemTTSSettings.rate("1") == "0.8", SystemTTSSettings.rate("-1") == "0.0", SystemTTSSettings.rateTitle("0.5") == "1 倍", SystemTTSSettings.rateTitle("0.8") == "1.6 倍", SystemTTSSettings.languageKey("en-GB") == "en", SystemTTSSettings.languageKey("zh-TW") == "zh-Hant", SystemTTSSettings.languageKey("zh-CN") == "zh-Hans" else { throw PopError.message("系统语速与声音分组选项复核失败") }
        checks.append("系统语速按原始0…0.8映射9项0…1.6倍，默认1倍")
        var dictionary = ServiceEditDraft(service: .dictionary)
        readCount = 0
        dictionary.loadCredentials(plugins: [], read: { _ in readCount += 1; return "must-not-read" })
        dictionary.secrets["apiKey"] = "ignored-fixture-value"
        guard dictionary.service.kind == .dictionary, dictionary.service.capability == "translate", readCount == 0,
              try dictionary.credentialString().isEmpty, try dictionary.credentialUpdates(plugins: []).isEmpty else { throw PopError.message("离线词典错误请求或保存凭据") }
        checks.append("简明英汉词典是独立翻译服务，草稿不读取或写入凭据")
        checks += try SettingsPluginPageSelfCheck.run()
        return checks
    }
}

@MainActor
struct ServiceDraftEditor: View {
    @Binding var edit: ServiceEditDraft
    @ObservedObject var state: AppState
    let plugins: [PluginDescriptor]
    @ViewState private var message: String?
    @ViewState private var testing = false
    @ViewState private var testTask: Task<Void, Never>?
    @ViewState private var testTicket = UUID()
    @ViewState private var supportedLanguages: [Locale.Language] = []
    @ViewState private var showingLanguages = false
    @ViewState private var loadingLanguages = false
    @ViewState private var showingOCROptions = false
    @ViewState private var showingVoices = false
    @ViewState private var ttsVoices: [AVSpeechSynthesisVoice] = []
    @ViewState private var voicePreview = AVSpeechSynthesizer()

    private var service: ServiceConfig { edit.service }
    private var isTranslation: Bool { service.capability == "translate" }
    private var isAI: Bool { isTranslation && [.openAI, .claude, .gemini].contains(service.kind) }
    private var plugin: PluginDescriptor? { plugins.first { $0.id == service.pluginID } }
    private var fields: [CloudServiceField] { isTranslation ? CloudServiceCatalog.secretFields(for: service.kind, options: service.options) : CloudMediaCatalog.secretFields(for: service.kind, capability: service.capability) }
    private var options: [CloudServiceField] { isTranslation ? CloudServiceCatalog.optionFields(for: service.kind, options: service.options) : CloudMediaCatalog.optionFields(for: service.kind, capability: service.capability) }
    private var defaultEndpoint: String { isTranslation ? CloudServiceCatalog.defaultEndpoint(for: service.kind, options: service.options) : CloudMediaCatalog.defaultEndpoint(for: service.kind, capability: service.capability, options: service.options) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !(service.kind == .apple && service.capability == "tts" && ttsVoices.isEmpty) {
                        VStack(alignment: .leading, spacing: 8) { Text("服务名称").font(.system(size: 13)); TextField("服务名称", text: $edit.service.name) }
                    }
                    if service.kind == .apple { systemFields
                    } else if service.kind == .dictionary { dictionaryFields }
                    else if service.kind == .plugin { pluginFields }
                    else { cloudFields }
                    if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { loadCredentialsIfNeeded(); ttsVoices = AVSpeechSynthesisVoice.speechVoices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in ttsVoices = AVSpeechSynthesisVoice.speechVoices() }
        .onChange(of: edit.credentialsLoaded) { _, loaded in if !loaded { loadCredentialsIfNeeded() } }
        .onChange(of: edit.service.pluginID) { _, _ in
            edit.secrets = [:]; edit.savedSecrets = [:]
            loadPluginFields()
        }
        .onChange(of: edit.service) { _, _ in cancelTest() }
        .onChange(of: edit.secrets) { _, _ in cancelTest() }
        .onDisappear { testTicket = UUID(); testTask?.cancel(); testTask = nil; testing = false; voicePreview.stopSpeaking(at: .immediate) }
        .contextMenu {
            if service.kind == .apple && service.capability == "ocr" { Button("高级识别选项…") { showingOCROptions = true } }
            if service.kind == .apple && service.capability == "tts" {
                Menu("固定朗读语言") {
                    Picker("朗读语言", selection: Binding(get: { service.options["language"] ?? "auto" }, set: { edit.service.options["language"] = $0 })) {
                        ForEach(LanguageCatalog.choices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            }
        }
        .sheet(isPresented: $showingOCROptions) { advancedOCRSheet }
        .sheet(isPresented: $showingVoices) { voiceSettingsSheet }
        .sheet(isPresented: $showingLanguages) {
            VStack(spacing: 0) {
                Text(service.capability == "ocr" ? "系统文字识别支持的语言" : "系统翻译支持的语言").font(.system(size: 16, weight: .semibold)).padding(20)
                List(supportedLanguages, id: \.self) { language in Text(Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier) }
                HStack { Spacer(); Button("完成") { showingLanguages = false } }.padding(14)
            }.frame(width: 360, height: 420)
        }
    }

    @ViewBuilder private var systemFields: some View {
        if service.capability == "ocr" {
            Text("系统内置的文本识别服务，可离线使用。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("支持语言").font(.system(size: 13))
                Spacer()
                Button("查看支持语言") {
                    do {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        supportedLanguages = try request.supportedRecognitionLanguages().map { Locale.Language(identifier: $0) }
                        showingLanguages = true
                    } catch { message = error.localizedDescription }
                }
            }
        } else if service.capability == "tts" {
            if ttsVoices.isEmpty {
                Text("没有找到可用的系统朗读声音。你可以用服务列表下方的 + 添加其他朗读服务，再将其启用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("使用 macOS 已安装的声音朗读，无需联网。").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Text("语速").font(.system(size: 13)); Spacer()
                    BobSettingsPicker("语速", selection: Binding(get: { SystemTTSSettings.rate(service.options["rate"]) }, set: { edit.service.options["rate"] = $0 }), options: SystemTTSSettings.rates.map { (SystemTTSSettings.rateTitle($0), $0) }).frame(width: 150, height: 24)
                }
                HStack {
                    Text("选择声音").font(.system(size: 13)); Spacer()
                    Button("设置声音") { showingVoices = true }
                }
            }
        } else {
            Divider().padding(.vertical, 4)
            HStack {
                Text("使用须知").font(.system(size: 13)); Spacer()
                Button("使用教程") { if let url = URL(string: "https://support.apple.com/guide/mac-help/translate-text-mchl666b5510/mac") { NSWorkspace.shared.open(url) } }
            }
            Text("使用 macOS 的本地翻译模型，首次使用可能需要下载对应语言。下载后可以离线翻译，支持的语言取决于当前系统版本。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            HStack {
                Text("冷却时间").font(.system(size: 13)); Spacer()
                BobSettingsPicker("冷却时间", selection: Binding(get: { service.options["cooldownSeconds"] ?? "0" }, set: { edit.service.options["cooldownSeconds"] = $0 }), options: ["0", "1", "2", "3", "5", "10", "30"].map { ($0 + " 秒", $0) }).frame(width: 110, height: 24)
            }
            Divider().padding(.vertical, 4)
            HStack {
                Text("支持语言").font(.system(size: 13)); Spacer()
                Button(loadingLanguages ? "读取中…" : "查看支持语言") {
                    loadingLanguages = true
                    Task { @MainActor in
                        supportedLanguages = await LanguageAvailability().supportedLanguages
                        loadingLanguages = false; showingLanguages = true
                    }
                }.disabled(loadingLanguages)
            }
        }
    }

    private var dictionaryFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("使用须知").font(.system(size: 13)).foregroundStyle(.primary)
                Spacer()
                Button("前往项目主页") {
                    if let url = URL(string: "https://github.com/skywind3000/ECDICT") { NSWorkspace.shared.open(url) }
                }
            }
            Text("简明英汉词典基于 ECDICT 开源词典，内置 770611 个词条，可离线查词，无需 API 密钥。")
            Text("支持英文单词和词组查询，不支持整句翻译。词库已内置，无需另行下载。")
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var advancedOCRSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("高级识别选项").font(.system(size: 16, weight: .semibold))
            systemToggle("精确识别", key: "accurate", defaultValue: state.preferences.ocrAccurate)
            Divider()
            systemToggle("语言纠错", key: "languageCorrection", defaultValue: state.preferences.ocrLanguageCorrection)
            Divider()
            labeled("优先识别语言") {
                TextField("例如 zh-Hans,en-US", text: Binding(get: { service.options["languages"] ?? state.preferences.ocrLanguages.joined(separator: ",") }, set: { edit.service.options["languages"] = $0 }))
                Text("多个语言代码使用英文逗号分隔，留空时使用 OCR 设置中的语言。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("段落处理").font(.system(size: 13)); Spacer()
                BobSettingsPicker("段落处理", selection: Binding(get: { service.options["paragraphMode"] ?? (state.preferences.smartOCRParagraphs ? "smart" : "provider") }, set: { edit.service.options["paragraphMode"] = $0 }), options: [("智能段落", "smart"), ("保留识别结果", "provider")]).frame(width: 150, height: 24)
            }
            Text("此处修改保留在当前服务草稿中，返回后点击“保存”生效。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { showingOCROptions = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 430)
    }

    private var voiceLanguages: [String] {
        Array(Set(ttsVoices.map { SystemTTSSettings.languageKey($0.language) })).sorted { voiceLanguageTitle($0).localizedStandardCompare(voiceLanguageTitle($1)) == .orderedAscending }
    }
    private func voiceLanguageTitle(_ code: String) -> String {
        let title = LanguageCatalog.title(code)
        return title == code ? (Locale.current.localizedString(forLanguageCode: code) ?? code) : title
    }
    private func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        ttsVoices.filter { SystemTTSSettings.languageKey($0.language) == language }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.identifier < $1.identifier : nameOrder == .orderedAscending
        }
    }
    private var voiceOverrides: [String: String] {
        guard let json = service.options["voices"], let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }
    private func selectedVoice(for language: String) -> String {
        if let stored = voiceOverrides[language], !stored.isEmpty { return stored }
        return AVSpeechSynthesisVoice(language: TextUtilities.readingLanguageCode(language))?.identifier ?? voices(for: language).first?.identifier ?? ""
    }
    private func voiceSelection(_ language: String) -> Binding<String> {
        Binding(get: { selectedVoice(for: language) }, set: { value in
            var values = voiceOverrides
            if value.isEmpty { values.removeValue(forKey: language) } else { values[language] = value }
            do {
                if values.isEmpty { edit.service.options.removeValue(forKey: "voices") }
                else {
                    let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                    edit.service.options["voices"] = String(decoding: data, as: UTF8.self)
                }
            } catch { message = error.localizedDescription }
        })
    }
    private func voiceMenuOptions(language: String, available: [AVSpeechSynthesisVoice], selected: String) -> [(String, String)] {
        var options = [("系统默认", "")]
        if !selected.isEmpty && !available.contains(where: { $0.identifier == selected }) { options.append(("已不可用的声音", selected)) }
        options += available.map { ($0.name + "（" + (Locale.current.localizedString(forIdentifier: $0.language) ?? $0.language) + "）", $0.identifier) }
        return options
    }
    private var voiceSettingsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择声音").font(.system(size: 14, weight: .medium)).padding(.leading, 24).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(voiceLanguages, id: \.self) { language in
                        let available = voices(for: language)
                        let selected = selectedVoice(for: language)
                        HStack(spacing: 14) {
                            Text(voiceLanguageTitle(language)).font(.system(size: 13)).frame(width: 115, alignment: .leading)
                            BobSettingsPicker("\(voiceLanguageTitle(language))声音", selection: voiceSelection(language), options: voiceMenuOptions(language: language, available: available, selected: selected), disabledValues: available.contains(where: { $0.identifier == selected }) ? [] : [selected]).frame(maxWidth: .infinity).frame(height: 24)
                            Button("试听") { previewVoice(language: language) }.frame(width: 52).disabled(AVSpeechSynthesisVoice(identifier: selected) == nil)
                        }.padding(.horizontal, 24).frame(height: 40)
                    }
                }
            }.frame(height: min(520, max(160, CGFloat(voiceLanguages.count * 40))))
            HStack {
                Spacer()
                Button {
                    voicePreview.stopSpeaking(at: .immediate); showingVoices = false
                } label: { Text("好").font(.system(size: 12)).frame(width: 70, height: 24).background(SettingsPalette.sidebar, in: RoundedRectangle(cornerRadius: 7)) }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 20)
        }.frame(width: 620).background(SettingsPalette.page)
            .onDisappear { voicePreview.stopSpeaking(at: .immediate) }
    }
    private func previewVoice(language: String) {
        guard let voice = AVSpeechSynthesisVoice(identifier: selectedVoice(for: language)) else { return }
        let samples = ["zh-Hans": "你好，这是语音试听。", "zh-Hant": "你好，這是語音試聽。", "en": "Hello, this is a voice preview.", "ja": "こんにちは。音声のサンプルです。", "ko": "안녕하세요. 음성 미리 듣기입니다.", "fr": "Bonjour, voici un exemple de voix.", "de": "Hallo, dies ist eine Sprachprobe.", "es": "Hola, esta es una muestra de voz.", "it": "Ciao, questo è un esempio di voce.", "pt": "Olá, esta é uma amostra de voz.", "ru": "Здравствуйте, это образец голоса.", "ar": "مرحبًا، هذه عينة صوتية."]
        state.speak(""); SpeechPlayer.shared.stop(); voicePreview.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: samples[language] ?? Locale(identifier: language).localizedString(forLanguageCode: language) ?? "Hello.")
        utterance.voice = voice; utterance.rate = Float(SystemTTSSettings.rate(service.options["rate"])) ?? AVSpeechUtteranceDefaultSpeechRate
        voicePreview.speak(utterance)
    }

    private func systemToggle(_ title: String, key: String, defaultValue: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 13)); Spacer()
            Toggle(title, isOn: Binding(get: { service.options[key].flatMap(Bool.init) ?? defaultValue }, set: { edit.service.options[key] = String($0) }))
                .labelsHidden().toggleStyle(BobSettingsSwitchStyle(label: title))
        }
    }

    @ViewBuilder private var cloudFields: some View {
        if service.kind == .openAI {
            Text(CloudServiceCatalog.configurationHint(for: service))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if service.kind == .gemini {
            Text("使用 Gemini 原生协议。中转商提供 OpenAI 兼容地址时，请添加通用 AI 服务。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if isTranslation && CloudServiceCatalog.presets(for: service.kind).count > 1 {
            Menu("选择接口预设") {
                ForEach(CloudServiceCatalog.presets(for: service.kind)) { preset in
                    Button(preset.title) {
                        edit.service = CloudServiceCatalog.applying(preset, to: edit.service)
                    }
                }
            }
        }
        labeled("服务地址") {
            if CloudServiceCatalog.usesDeploymentName(service) {
                CloudServiceRevealField(placeholder: "Azure 资源根地址或完整部署请求 URL", text: $edit.service.endpoint)
            } else { TextField(defaultEndpoint, text: $edit.service.endpoint) }
        }
        if service.kind == .openAI {
            Text(CloudServiceCatalog.usesDeploymentName(service) ? "完整部署 URL 的部署名称和 api-version 优先；使用资源根地址时需填写下方部署名称。地址和部署名的隐藏仅用于屏幕显示，配置文件仍保存其原文。" : "可填基础地址或完整 /chat/completions 地址；留空密钥时不发送认证头。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if isAI { labeled("模型名称") { TextField("填写账户可用或本地已安装的模型", text: $edit.service.model) } }
        ForEach(fields) { field in labeled(field.title) { SecureField(field.placeholder, text: secret(field.key)) } }
        if CloudServiceCatalog.isSpecializedTranslationModel(service) {
            Text(CloudServiceCatalog.specializedModelNotice).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        ForEach(options) { field in
            labeled(field.title) {
                if ["prompt", "systemPrompt", "userPrompt"].contains(field.key) {
                    TextEditor(text: option(field)).font(.system(size: 12)).frame(minHeight: 85)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    Text(field.placeholder).font(.system(size: 10)).foregroundStyle(.secondary)
                } else if !field.choices.isEmpty {
                    BobSettingsPicker(field.title, selection: option(field), options: field.choices.map { (field.choiceTitle($0), $0) }).frame(height: 24)
                } else if field.key == "deploymentName" { CloudServiceRevealField(placeholder: field.placeholder, text: option(field)) }
                else { TextField(field.placeholder, text: option(field)) }
            }.disabled(!CloudServiceCatalog.isOptionApplicable(field.key, to: service))
        }
        Button(testing ? "测试中…" : "测试连接") { testConnection() }.disabled(testing)
        Text("测试使用当前草稿，不会保存配置。凭据仅在点击下方“保存”后写入系统钥匙串。")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var pluginFields: some View {
        BobSettingsPicker("插件", selection: $edit.service.pluginID, options: [("选择插件", "")] + plugins.filter { $0.category == service.capability }.map { ($0.name, $0.id) }).frame(height: 24)
        if let plugin {
            Text(plugin.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(plugin.options) { field in
                labeled(field.title) {
                    if field.isSecure { SecureField(field.description, text: secret(field.identifier)) }
                    else if !field.menuValues.isEmpty {
                        BobSettingsPicker(field.title, selection: pluginOption(field), options: field.menuValues.map { ($0.title, $0.value) }).frame(height: 24)
                    } else { TextField(field.description, text: pluginOption(field)) }
                }
            }
            Button(testing ? "正在校验…" : "校验插件配置") { testConnection() }.disabled(testing)
            Text("校验使用当前草稿并调用插件接口，不会保存配置。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); content() }
    }
    private func secret(_ key: String) -> Binding<String> {
        Binding(get: { edit.secrets[key] ?? "" }, set: { edit.secrets[key] = $0 })
    }
    private func option(_ field: CloudServiceField) -> Binding<String> {
        Binding(get: { CloudServiceCatalog.optionValue(field, in: edit.service) }, set: {
            edit.service = CloudServiceCatalog.settingOption(field.key, value: $0, in: edit.service)
        })
    }
    private func pluginOption(_ field: PluginOption) -> Binding<String> {
        Binding(get: { edit.service.options[field.identifier] ?? field.defaultValue }, set: { edit.service.options[field.identifier] = $0 })
    }
    private func loadCredentialsIfNeeded() {
        edit.loadCredentials(plugins: plugins)
    }
    private func loadPluginFields() {
        guard let plugin, service.pluginID == edit.baseline.pluginID else { return }
        for field in plugin.options where field.isSecure && edit.secrets[field.identifier] == nil {
            let value = SecretStore.read(SecretStore.pluginKey(service.credentialID, option: field.identifier))
            edit.secrets[field.identifier] = value; edit.savedSecrets[field.identifier] = value
        }
    }
    private func credentialString(_ secrets: [String: String]) throws -> String {
        var copy = edit; copy.secrets = secrets
        return try copy.credentialString()
    }

    private func cancelTest() {
        testTicket = UUID(); testTask?.cancel(); testTask = nil; testing = false; message = nil
    }

    private func testConnection() {
        testTask?.cancel(); testTicket = UUID()
        let ticket = testTicket
        var config = service
        let key: String
        do { key = try credentialString(edit.secrets) } catch { message = error.localizedDescription; return }
        if config.kind == .plugin, let plugin {
            for field in plugin.options where field.isSecure { config.options[field.identifier] = edit.secrets[field.identifier] ?? "" }
        }
        testing = true; message = nil
        testTask = Task { @MainActor in
            defer { if testTicket == ticket { testing = false; testTask = nil } }
            do {
                let result: String
                if config.kind == .plugin {
                    let validation = try await PluginService.shared.validate(service: config)
                    result = validation.supported ? ((validation.isValid ? "校验通过" : "校验失败") + ((validation.message ?? "").isEmpty ? "" : "：" + (validation.message ?? ""))) : "此插件未提供配置校验接口。"
                } else if config.capability == "ocr" {
                    let image = NSImage(size: NSSize(width: 600, height: 140))
                    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 140).fill()
                    ("Hello Pop 123" as NSString).draw(at: NSPoint(x: 20, y: 45), withAttributes: [.font: NSFont.systemFont(ofSize: 50), .foregroundColor: NSColor.black])
                    image.unlockFocus()
                    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw PopError.message("无法生成测试图。") }
                    result = "连接成功：" + (try await CloudMediaService().recognize(imageData: png, service: config, apiKey: key)).text
                } else if config.capability == "tts" {
                    let data = try await CloudMediaService().synthesize(text: "Hello", language: "en", service: config, apiKey: key)
                    result = "连接成功，收到 \(data.count) 字节音频。"
                } else {
                    let output = try await HTTPTranslationService().translate(TranslationRequest(text: "Hello", source: "en", target: "zh-Hans"), service: config, apiKey: key)
                    result = "连接成功：" + output.text
                }
                try Task.checkCancellation()
                if testTicket == ticket { message = result }
            } catch is CancellationError { }
            catch { if testTicket == ticket { message = error.localizedDescription } }
        }
    }
}

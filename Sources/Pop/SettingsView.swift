import AppKit
import Carbon
import SwiftUI
import ServiceManagement

private enum PreferencesPage: String, CaseIterable {
    case translationSettings = "translate"
    case translationServices, favorites, history
    case ocrSettings = "ocr"
    case ocrServices, plugins
    case generalSettings = "general"
    case importExport, enhancements, integration, about

    var title: String {
        switch self {
        case .translationSettings: return "翻译设置"
        case .translationServices, .ocrServices: return "服务"
        case .favorites: return "收藏夹"
        case .history: return "历史记录"
        case .ocrSettings: return "OCR 设置"
        case .plugins: return "插件列表"
        case .generalSettings: return "通用设置"
        case .importExport: return "导入导出"
        case .enhancements: return "功能增强"
        case .integration: return "集成"
        case .about: return "关于"
        }
    }
    var icon: String {
        switch self {
        case .translationSettings, .ocrSettings, .generalSettings: return "hexagon"
        case .translationServices, .ocrServices: return "cube"
        case .favorites: return "star"
        case .history: return "clock"
        case .plugins: return "puzzlepiece.extension"
        case .importExport: return "arrow.up.arrow.down"
        case .enhancements: return "paperplane"
        case .integration: return "atom"
        case .about: return "crown"
        }
    }
    var referenceIcon: String {
        switch self {
        case .translationSettings, .ocrSettings, .generalSettings: return "pw_sidebar_setting"
        case .translationServices, .ocrServices: return "pw_sidebar_service"
        case .favorites: return "pw_sidebar_favorite"
        case .history: return "pw_sidebar_history"
        case .plugins: return "pw_sidebar_plugin"
        case .importExport: return "pw_sidebar_export"
        case .enhancements: return "pw_sidebar_enhance"
        case .integration: return "pw_sidebar_integration"
        case .about: return "pw_sidebar_about"
        }
    }
}

enum SettingsPalette {
    static let page = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    })
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1) : NSColor(srgbRed: 237.0/255, green: 237.0/255, blue: 237.0/255, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1) : NSColor(srgbRed: 247.0/255, green: 247.0/255, blue: 247.0/255, alpha: 1)
    })
    static let line = Color.primary.opacity(0.055)
    static let header = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.labelColor : NSColor(srgbRed: 85.0/255, green: 85.0/255, blue: 85.0/255, alpha: 1)
    })
}

private struct ServiceListDraft {
    var baseline: [ServiceConfig]
    var orderedIDs: [UUID]
    var selectedID: UUID?
    var baselineSelectedID: UUID?
    var isDirty: Bool { orderedIDs != baseline.map(\.id) || selectedID != baselineSelectedID }

    mutating func remove(_ id: UUID) {
        orderedIDs.removeAll { $0 == id }
        if selectedID == id { selectedID = nil }
    }
    mutating func move(_ source: UUID, before target: UUID) -> Bool {
        guard source != target, orderedIDs.contains(source), orderedIDs.contains(target) else { return false }
        orderedIDs.removeAll { $0 == source }
        guard let index = orderedIDs.firstIndex(of: target) else { return false }
        orderedIDs.insert(source, at: index); return true
    }
    func replacingServices(in all: [ServiceConfig], with replacements: [ServiceConfig]) -> [ServiceConfig] {
        let originalIDs = Set(baseline.map(\.id))
        let insertion = all.firstIndex { originalIDs.contains($0.id) } ?? all.endIndex
        var result = all.filter { !originalIDs.contains($0.id) }
        result.insert(contentsOf: replacements, at: min(insertion, result.count))
        return result
    }
    static func selecting(_ id: UUID, enabled: Bool = true, in services: [ServiceConfig]) -> [ServiceConfig]? {
        guard services.contains(where: { $0.id == id }) else { return nil }
        return services.map { service in
            var copy = service
            if enabled { copy.enabled = copy.id == id } else if copy.id == id { copy.enabled = false }
            return copy
        }
    }
    static func validateSelection(in services: [ServiceConfig]) throws {
        guard !services.isEmpty, services.contains(where: \.enabled) else { throw PopError.message("请至少开启1个服务") }
    }
}

enum SettingsServiceListSelfCheck {
    static func run() throws -> [String] {
        var a = ServiceConfig.systemMedia(capability: "ocr")
        a.name = "A"
        var b = ServiceConfig.systemMedia(capability: "ocr"); b.name = "B"
        let outside = ServiceConfig.systemMedia(capability: "ocr", scope: "standaloneOCR")
        let untouched = ServiceConfig.system
        var draft = ServiceListDraft(baseline: [a, b], orderedIDs: [a.id, b.id], selectedID: b.id, baselineSelectedID: b.id)
        guard draft.move(b.id, before: a.id), draft.orderedIDs == [b.id, a.id], draft.baseline == [a, b], draft.isDirty else {
            throw PopError.message("服务排序草稿复核失败")
        }
        guard !draft.move(outside.id, before: a.id) else { throw PopError.message("服务排序错误接受其他用途的服务") }
        guard let selected = ServiceListDraft.selecting(b.id, in: [a, b]), selected.filter(\.enabled).map(\.id) == [b.id],
              ServiceListDraft.selecting(outside.id, in: [a, b]) == nil else { throw PopError.message("OCR 服务单选错误跨越列表范围") }
        var disabledA = a; disabledA.enabled = false
        var disabledB = b; disabledB.enabled = false
        guard let disabled = ServiceListDraft.selecting(b.id, enabled: false, in: selected), disabled.allSatisfy({ !$0.enabled }) else { throw PopError.message("OCR 草稿不能暂时取消选中") }
        var emptyBlocked = false
        do { try ServiceListDraft.validateSelection(in: [disabledA, disabledB]) } catch { emptyBlocked = true }
        guard emptyBlocked else { throw PopError.message("OCR 零选中未阻止保存") }
        emptyBlocked = false
        do { try ServiceListDraft.validateSelection(in: []) } catch { emptyBlocked = true }
        guard emptyBlocked else { throw PopError.message("OCR 空列表未阻止保存") }
        try ServiceListDraft.validateSelection(in: selected)
        draft.remove(b.id)
        guard draft.orderedIDs == [a.id], draft.selectedID == nil, draft.baselineSelectedID == b.id else { throw PopError.message("服务删除草稿复核失败") }
        let committed = draft.replacingServices(in: [untouched, a, outside, b], with: [a])
        guard committed == [untouched, a, outside], outside.scope == "standaloneOCR" else { throw PopError.message("服务事务修改了其他用途的列表") }
        let restored = ServiceListDraft(baseline: draft.baseline, orderedIDs: draft.baseline.map(\.id), selectedID: draft.baselineSelectedID, baselineSelectedID: draft.baselineSelectedID)
        guard !restored.isDirty, restored.selectedID == b.id else { throw PopError.message("服务撤销复核失败") }
        return ["服务排序、删除仅改草稿；OCR/TTS 启用互斥，保存拒绝零选中和空表", "服务列表提交保留其他用途配置，撤销恢复列表和选用项"]
    }
}

enum SettingsPluginPackageExporter {
    static func export(folder: URL, destination: URL) throws {
        let root = folder.standardizedFileURL
        let target = destination.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              target.path != root.path, !target.path.hasPrefix(root.path + "/") else {
            throw PopError.message("请选择插件目录之外的导出位置。")
        }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("pop-plugin-export-" + UUID().uuidString + ".noindex", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("package.bobplugin")
        let archive = Process(); archive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        archive.arguments = ["-c", "-k", "--norsrc", root.path, file.path]
        archive.standardInput = FileHandle.nullDevice; archive.standardOutput = FileHandle.nullDevice; archive.standardError = FileHandle.nullDevice
        try archive.run(); archive.waitUntilExit()
        guard archive.terminationStatus == 0 else { throw PopError.message("无法生成插件压缩包。") }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= 50 * 1024 * 1024 else { throw PopError.message("导出插件为空或超过 50 MB。") }
        try Data(contentsOf: file).write(to: target, options: .atomic)
    }
}

enum SettingsPluginPageSelfCheck {
    static func run() throws -> [String] {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("pop-plugin-page-check-" + UUID().uuidString + ".noindex", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let plugin = temporary.appendingPathComponent("plugin folder with spaces", isDirectory: true)
        try manager.createDirectory(at: plugin.appendingPathComponent("resources"), withIntermediateDirectories: true)
        try Data("{\"identifier\":\"offline.fixture\",\"version\":\"1\"}".utf8).write(to: plugin.appendingPathComponent("info.json"))
        try Data("// Never executed or installed".utf8).write(to: plugin.appendingPathComponent("main.js"))
        try Data([0, 1, 2, 3]).write(to: plugin.appendingPathComponent("resources/data.bin"))
        let archive = temporary.appendingPathComponent("fixture.bobplugin")
        try SettingsPluginPackageExporter.export(folder: plugin, destination: archive)
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-Z1", archive.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let names = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        guard process.terminationStatus == 0, names.contains("info.json"), names.contains("main.js"), names.contains("resources/data.bin"), !names.contains(where: { $0.hasPrefix("plugin folder with spaces/") }) else {
            throw PopError.message("插件导出 ZIP 的根目录结构复核失败")
        }
        var rejected = false
        do { try SettingsPluginPackageExporter.export(folder: plugin, destination: plugin.appendingPathComponent("bad.bobplugin")) } catch { rejected = true }
        guard rejected, !manager.fileExists(atPath: plugin.appendingPathComponent("bad.bobplugin").path) else { throw PopError.message("插件导出错误写入源目录") }
        return ["插件导出使用真实ZIP，保留根info/main及子目录，支持含空格路径且不执行插件", "插件导出拒绝将输出写入插件源目录"]
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ViewState private var plugins: [PluginDescriptor] = []
    @ViewState private var permissionStatus = PermissionHelper.status()
    @ViewState private var serviceCategory = "translate"
    @ViewState private var selectedServiceID: UUID?
    @ViewState private var pluginUpdates: [String: PluginUpdate] = [:]
    @ViewState private var updatingPlugins: Set<String> = []
    @ViewState private var pluginCategory = "all"
    @ViewState private var checkingPlugins: Set<String> = []
    @ViewState private var pluginCheckMessages: [String: String] = [:]
    @ViewState private var serviceDrafts: [UUID: ServiceEditDraft] = [:]
    @ViewState private var serviceLists: [String: ServiceListDraft] = [:]
    @ViewState private var showServicePicker = false
    @ViewState private var addingCapability = "translate"
    @ViewState private var addingScope = "translation"
    @ViewState private var showProxySettings = false
    @ViewState private var showContinuousShortcut = false
    @ViewState private var showAdvancedTranslation = false
    @ViewState private var showEnhancementHelp = false
    @ViewState private var loginEnabled = SMAppService.mainApp.status == .enabled

    private var selectedPage: PreferencesPage {
        get { PreferencesPage(rawValue: state.settingsSection) ?? .translationSettings }
        nonmutating set { state.settingsSection = newValue.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                if selectedPage != .favorites && selectedPage != .history {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedPage.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(SettingsPalette.header)
                        if selectedPage == .translationServices || selectedPage == .ocrServices {
                            Text(selectedPage == .ocrServices ? "添加和管理识别服务，启用的服务用于 OCR。" : "在这里管理翻译服务；启用后即可用于查询。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.offset(y: 3)
                    Spacer()
                    if selectedPage == .translationServices || selectedPage == .ocrServices || selectedPage == .plugins {
                        Button {
                            if let url = URL(string: "https://github.com/YEMIN11238/Pop#主要功能") { NSWorkspace.shared.open(url) }
                        } label: { Text("使用教程").font(.system(size: 12)).frame(width: 76, height: 24).background(SettingsPalette.sidebar, in: RoundedRectangle(cornerRadius: 6)) }
                            .buttonStyle(.plain).bobTooltip("查看 Pop 项目的功能介绍与配置说明。")
                    }
                }.padding(.horizontal, 20).frame(height: selectedPage == .translationServices || selectedPage == .ocrServices || selectedPage == .plugins ? 52 : 48)
                    .overlay(alignment: .bottom) { if selectedPage == .translationServices || selectedPage == .ocrServices || selectedPage == .plugins { Divider() } }
                }
                pageContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let notice = state.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.vertical, 10)
                }
            }.background(SettingsPalette.page)
        }
        .frame(minWidth: 820, minHeight: 620)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { plugins = PluginService.shared.listPlugins(); loginEnabled = SMAppService.mainApp.status == .enabled; serviceCategory = state.settingsServiceCategory }
        .onChange(of: state.settingsServiceCategory) { _, category in
            if ["translate", "ocr", "tts"].contains(category) { serviceCategory = category }
        }
        .onChange(of: selectedPage) { _, _ in
            plugins = PluginService.shared.listPlugins()
            permissionStatus = PermissionHelper.status()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionStatus = PermissionHelper.status()
            plugins = PluginService.shared.listPlugins()
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: state.preferences) { _, _ in state.savePreferences() }
        .onDisappear { serviceDrafts = [:]; serviceLists = [:] }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title == "Pop 设置" { serviceDrafts = [:]; serviceLists = [:] }
        }
        .sheet(isPresented: $showServicePicker) {
            AddServicePicker(capability: addingCapability, plugins: plugins, onChoose: chooseService, onCancel: { showServicePicker = false })
        }
        .sheet(isPresented: $showProxySettings) {
            ProxySettingsSheet(state: state, onClose: { showProxySettings = false })
        }
        .sheet(isPresented: $showAdvancedTranslation) { advancedTranslationSettings }
        .sheet(isPresented: $showEnhancementHelp) { enhancementHelp }
        .sheet(isPresented: $showContinuousShortcut) {
            VStack(alignment: .leading, spacing: 20) {
                Text("连续截图 OCR").font(.system(size: 16, weight: .semibold))
                settingsCard { shortcutRow(.continuousOCR, detail: "将本次截图的识别文字追加到已有内容。") }
                HStack { Spacer(); Button("完成") { showContinuousShortcut = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560)
        }
    }

    private var sidebar: some View {
        SettingsSidebarView(sections: [
            sidebarSection("翻译", pages: [.translationSettings, .translationServices, .favorites, .history]),
            sidebarSection("OCR", pages: [.ocrSettings, .ocrServices]),
            sidebarSection("插件", pages: [.plugins]),
            sidebarSection("通用", pages: [.generalSettings, .importExport, .enhancements, .integration, .about])
        ], selection: Binding(get: { selectedPage.rawValue }, set: { value in
            if let page = PreferencesPage(rawValue: value) { selectedPage = page }
        }))
        .frame(width: 180).background(SettingsPalette.sidebar)
    }

    private func sidebarSection(_ title: String, pages: [PreferencesPage]) -> SettingsSidebarSection {
        SettingsSidebarSection(title: title, items: pages.map {
            SettingsSidebarItem(id: $0.rawValue, title: $0.title, image: $0.referenceIcon, fallback: $0.icon)
        })
    }

    @ViewBuilder private var pageContent: some View {
        switch selectedPage {
        case .translationSettings: translationSettings
        case .translationServices: servicePage(ocrOnly: false)
        case .favorites: BobHistorySettingsView(state: state, favoritesOnly: true)
        case .history: BobHistorySettingsView(state: state, favoritesOnly: false)
        case .ocrSettings: ocrSettings
        case .ocrServices: servicePage(ocrOnly: true)
        case .plugins: pluginPage
        case .generalSettings: generalSettings
        case .importExport: importExport
        case .enhancements: enhancements
        case .integration: integration
        case .about: about
        }
    }

    private var translationSettings: some View {
        settingsScroll {
            settingsGroup("全局快捷键", topSpacing: 0) {
                shortcutRow(.selection, detail: "先选中文字，再用此快捷键查看译文。")
                rowDivider
                shortcutRow(.silentSelection, detail: "用于可编辑的选区：按下快捷键后，Pop 在后台翻译所选文字，再把译文填回原位置，过程中不打开翻译窗口。")
                rowDivider
                shortcutRow(.silentInput, detail: "在输入框写好内容后使用此快捷键。Pop 会读取整个输入框，在后台翻译并回填；适用于聊天软件等可编辑输入框。")
                rowDivider
                shortcutRow(.screenshotTranslation)
                rowDivider
                shortcutRow(.input, detail: "打开一个空白翻译输入框，准备输入新的内容。")
                rowDivider
                shortcutRow(.clipboardTranslation, detail: "读取剪贴板文字，或先识别其中的图片，再开始翻译。")
                rowDivider
                shortcutRow(.showTranslationWindow, detail: "重新显示翻译窗口，保留已有输入和结果，便于继续查看。")
            }
            settingsCard {
                shortcutRow(.imageTranslation, detail: "选取屏幕区域后，在截图上叠加译文，使用图片浮层展示结果。")
            }
            settingsGroup("语言") {
                cardRow("第一语言", detail: "通常是你的母语。") {
                    languagePicker($state.preferences.primaryLanguage, resolved: TextUtilities.resolvedPrimaryLanguage(state.preferences))
                }
                rowDivider
                cardRow("第二语言", detail: "通常是你最常使用的外语。") {
                    languagePicker($state.preferences.secondaryLanguage, resolved: TextUtilities.resolvedSecondaryLanguage(state.preferences))
                }
                rowDivider
                cardRow("常用语言", detail: "把经常使用的语言放到语言菜单前面；其余选项仍可从「更多语言」找到。") { favoriteLanguagesMenu }
            }
            settingsGroup("自动化处理") {
                switchRow("将翻译原文的「换行符」替换为「空格」", value: $state.preferences.mergeLineBreaks)
                rowDivider
                switchRow("将翻译原文的代码注释符号「/*#」去掉", value: $state.preferences.removeCommentMarkers)
                rowDivider
                switchRow("将翻译原文的「-空格」去掉", value: $state.preferences.joinHyphenatedWords)
                rowDivider
                switchRow("自动复制截图翻译 OCR 结果", value: $state.preferences.autoCopyTranslationOCR)
                rowDivider
                switchRow("自动复制首个翻译结果", value: $state.preferences.autoCopyFirstResult)
                rowDivider
                switchRow("点击翻译结果中的高亮单词时将其复制", detail: "词典结果里的高亮单词可以继续点击查询。启用后，同一次点击还会复制该单词，方便粘贴到其他应用。", value: $state.preferences.copyHighlightedWord)
                rowDivider
                switchRow("自动播放翻译原文", detail: "开始翻译时，同时使用当前朗读服务读出原文。", value: $state.preferences.autoSpeakSource)
            }
            settingsGroup("UI 元素") {
                cardRow("划词翻译 & 截图翻译窗口位置") { positionPicker($state.preferences.selectionWindowPosition) }
                rowDivider
                cardRow("输入翻译窗口位置") { positionPicker($state.preferences.inputWindowPosition) }
                rowDivider
                cardRow("翻译窗口最大高度", detail: "设置窗口相对于当前屏幕的最大高度，同时为屏幕中央、左侧和右侧位置预留空间。") {
                    HStack(spacing: 8) { Slider(value: $state.preferences.maxWindowHeightFraction, in: 0.3...1, step: 0.05).frame(width: 140); Text("\(Int(state.preferences.maxWindowHeightFraction * 100))%").monospacedDigit().frame(width: 34) }
                }
            }
            settingsCard {
                cardRow("划词翻译输入框状态") { displayPicker($state.preferences.selectionInputDisplay) }
                rowDivider
                cardRow("截图翻译输入框状态") { displayPicker($state.preferences.screenshotInputDisplay) }
                rowDivider
                cardRow("输入框最大高度") {
                    HStack(spacing: 8) { Slider(value: $state.preferences.maxInputHeight, in: 80...600, step: 10).frame(width: 140); Text("\(Int(state.preferences.maxInputHeight))").monospacedDigit().frame(width: 34) }
                }
                rowDivider
                switchRow("显示语言切换栏", value: $state.preferences.showLanguageBar)
                rowDivider
                switchRow("钉住翻译服务后禁止隐藏语言切换栏", value: $state.preferences.keepLanguageBarWhenPinned)
            }
            settingsCard {
                switchRow("导航栏显示控制输入框显隐状态的按钮", detail: "在窗口顶部增加输入框开关，可随时收起或展开原文区域。", value: $state.preferences.showInputToggle)
                rowDivider
                switchRow("导航栏显示截图翻译按钮", value: $state.preferences.showScreenshotButton)
                rowDivider
                switchRow("导航栏显示剪贴板翻译按钮", value: $state.preferences.showClipboardButton)
                rowDivider
                switchRow("导航栏显示历史记录按钮", value: $state.preferences.showHistoryButton)
                rowDivider
                switchRow("导航栏显示收藏按钮", value: $state.preferences.showFavoriteButton)
            }
            settingsCard {
                switchRow("翻译结果为英文时显示复制为驼峰命名的按钮", detail: "复制成首字母小写的驼峰形式，例如 open file 转为 openFile。", value: $state.preferences.showCopyCamel)
                rowDivider
                switchRow("翻译结果为英文时显示复制为大驼峰命名的按钮", detail: "复制成各词首字母大写的连写形式，例如 open file 转为 OpenFile。", value: $state.preferences.showCopyPascal)
                rowDivider
                switchRow("翻译结果为英文时显示复制为蛇形命名的按钮", detail: "复制时用下划线连接单词，例如 open file 转为 open_file。", value: $state.preferences.showCopySnake)
                rowDivider
                switchRow("翻译结果为英文时显示复制为短横线命名的按钮", detail: "复制时用短横线连接单词，例如 open file 转为 open-file。", value: $state.preferences.showCopyKebab)
                rowDivider
                switchRow("翻译结果为英文时显示复制为宏定义命名的按钮", detail: "复制为大写单词与下划线组合，例如 open file 转为 OPEN_FILE。", value: $state.preferences.showCopyMacro)
                rowDivider
                switchRow("划词翻译时显示使用译文替换原文的按钮", detail: "从可编辑选区发起翻译时，提供回填按钮，将当前译文写回刚才选中的位置。", value: $state.preferences.showReplaceButton)
            }
            settingsGroup("Markdown") {
                switchRow("渲染翻译结果中的 Markdown", detail: "支持代码高亮、数学公式和 Mermaid 图表。", value: $state.preferences.renderMarkdown)
                rowDivider
                cardRow("打开翻译结果中的链接") {
                    BobSettingsPicker("链接确认", selection: $state.preferences.linkConfirmation, options: [("仅可疑链接确认", "suspicious"), ("总是确认", "always"), ("从不确认", "never")]).frame(width: 188, height: 24)
                }
                rowDivider
                switchRow("默认展开思考过程", value: $state.preferences.showReasoning)
                rowDivider
                switchRow("加载结果中的 HTTPS 图片", value: $state.preferences.renderRemoteImages)
            }
            settingsGroup("其他") {
                cardRow("历史记录容量") {
                    BobSettingsPicker("保留条数", selection: $state.preferences.historyLimit, options: [("最近 1,000 条", 1000), ("最近 10,000 条", 10000), ("最近 100,000 条", 100000)]).frame(width: 188, height: 24)
                }
                rowDivider
                cardRow("划词翻译取词模式", detail: "智能模式根据应用选择等待时间；效果优先会给取词留出更多时间，速度优先则缩短等待。可按常用应用的表现调整。") {
                    BobSettingsPicker("取词模式", selection: $state.preferences.selectionMode, options: [("智能模式", "smart"), ("效果优先", "effect"), ("速度优先", "speed")]).frame(width: 188, height: 24)
                }
                rowDivider
                switchRow("不显示划词翻译获取文本失败的提示", value: $state.preferences.hideSelectionError)
                rowDivider
                switchRow("窗口钉住后固定在同一个桌面", detail: "启用后，钉住的窗口留在原来的桌面空间。关闭时，新查询会把窗口带到你当前使用的桌面。", value: $state.preferences.pinToDesktop)
            }
            if !state.shortcutErrors.isEmpty {
                ForEach(state.shortcutErrors, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 10) }
            }
        }.contextMenu { Button("高级设置…") { showAdvancedTranslation = true } }
    }

    private var advancedTranslationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("高级设置").font(.system(size: 16, weight: .semibold))
            ScrollView {
            settingsCard {
                cardRow("简明英汉词典", detail: "作为独立翻译服务，可在服务列表中排序和启停。") {
                    Button("设置词典服务…") {
                        showAdvancedTranslation = false; chooseServiceCategory("translate"); selectedPage = .translationServices
                        selectedServiceID = state.preferences.services.first(where: { $0.kind == .dictionary })?.id
                    }
                }
                rowDivider
                cardRow("静默翻译服务", detail: "仅在原输入内容和焦点仍有效时回填，可从菜单撤销。") { silentServicePicker }
                rowDivider
                cardRow("朗读服务") { Button("设置语音合成服务…") { showAdvancedTranslation = false; chooseServiceCategory("tts"); selectedPage = .translationServices } }
                rowDivider
                switchRow("保存翻译历史记录", value: $state.preferences.saveHistory)
                rowDivider
                switchRow("自动拆分驼峰和蛇形标识符", detail: "例如 helloWorld 和 hello_world 会整理为 hello world。", value: $state.preferences.normalizeIdentifiers)
                rowDivider
                switchRow("压缩连续空行", value: $state.preferences.compactBlankLines)
                rowDivider
                cardRow("显示翻译窗口时的输入框状态") { inputDisplayPicker }
                rowDivider
                cardRow("服务结果状态") { resultDisplayPicker }
                rowDivider
                switchRow("点击外部自动隐藏翻译窗口", detail: "钉住窗口时保持显示。", value: $state.preferences.hideOnBlur)
                rowDivider
                switchRow("复制译文后关闭窗口", value: $state.preferences.closeAfterCopy)
            }
            }
            HStack { Spacer(); Button("完成") { showAdvancedTranslation = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 660, height: 560).background(SettingsPalette.page)
    }



    private var ocrSettings: some View {
        settingsScroll {
            settingsGroup("全局快捷键", topSpacing: 0) {
                shortcutRow(.screenshotOCR)
                rowDivider
                shortcutRow(.silentOCR, detail: "截图识别完成后直接复制文字，全程在后台处理，不弹出结果窗口。")
                rowDivider
                shortcutRow(.fileOCR)
                rowDivider
                shortcutRow(.pasteboardOCR, detail: "读取剪贴板里的图片并识别其中的文字。")
                rowDivider
                shortcutRow(.showOCRWindow)
            }
            settingsGroup("自动化处理") {
                switchRow("自动复制 OCR 结果", value: $state.preferences.autoCopyOCR)
                rowDivider
                switchRow("自动识别二维码", value: $state.preferences.recognizeQRCode)
            }
            settingsGroup("UI 元素") {
                switchRow("导航栏显示截图 OCR 按钮", value: $state.preferences.showOCRScreenshotButton)
                rowDivider
                switchRow("导航栏显示访达选图 OCR 按钮", value: $state.preferences.showOCRFileButton)
                rowDivider
                switchRow("导航栏显示剪贴板 OCR 按钮", value: $state.preferences.showOCRClipboardButton)
            }
            settingsCard {
                cardRow("OCR 窗口位置") { positionPicker($state.preferences.ocrWindowPosition) }
                rowDivider
                switchRow("静默截图 OCR 隐藏加载提示", detail: "静默识别通常会在指针旁提示进度和完成状态。启用此项可隐藏这些提示，识别与复制照常进行。", value: $state.preferences.hideSilentOCRLoading)
            }
        }.contextMenu {
            Button("连续截图 OCR 快捷键…") { showContinuousShortcut = true }
            Button("识别服务设置…") { selectedPage = .ocrServices }
        }
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 28)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, topSpacing: CGFloat = 11, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.top, topSpacing)
            settingsCard(content: content)
        }.padding(.bottom, 4)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var rowDivider: some View { Rectangle().fill(SettingsPalette.line).frame(height: 1).padding(.horizontal, 10) }

    private func cardRow<Content: View>(_ title: String, detail: String? = nil, alignment: VerticalAlignment = .top, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .regular))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            content().font(.system(size: 12)).fixedSize(horizontal: true, vertical: false)
        }.padding(10).frame(minHeight: 36, alignment: .topLeading)
    }

    private func switchRow(_ title: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        cardRow(title, detail: detail) { Toggle(title, isOn: value).labelsHidden().toggleStyle(BobSettingsSwitchStyle(label: title)) }
    }

    private func shortcutRow(_ action: HotkeyAction, detail: String? = nil) -> some View {
        cardRow(action.displayTitle, detail: detail, alignment: detail == nil ? .center : .top) {
            BobShortcutRecorder(config: state.shortcuts[String(action.rawValue)], defaultKeyCode: action.defaultKeyCode, defaultModifiers: action.defaultModifiers, onRecord: { value in
                state.shortcuts[String(action.rawValue)] = value
                state.savePreferences(); state.onShortcutsChanged?()
            }, onClear: {
                state.shortcuts[String(action.rawValue)] = ShortcutConfig(keyCode: UInt32.max, modifiers: 0, label: "未设置")
                state.savePreferences(); state.onShortcutsChanged?()
            }).frame(width: 190, height: 28)
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        settingsCard { cardRow(title) { VStack(alignment: .leading, spacing: 8, content: content) } }
    }

    private func languagePicker(_ language: Binding<String>, resolved: String? = nil) -> some View {
        HStack(spacing: 10) {
            if language.wrappedValue == "auto", let resolved {
                Text(LanguageCatalog.title(resolved)).foregroundStyle(.secondary).lineLimit(1)
            }
            BobSettingsPicker("语言", selection: language, options: LanguageCatalog.choices.map { ($0.1, $0.0) }).frame(width: 124, height: 24)
        }.frame(width: 188, alignment: .trailing)
    }

    private var favoriteLanguagesMenu: some View {
        Menu {
            ForEach(LanguageCatalog.choices.filter { $0.0 != "auto" }, id: \.0) { code, title in
                Toggle(title, isOn: Binding(get: { state.preferences.favoriteLanguages.contains(code) }, set: { enabled in
                    state.preferences.favoriteLanguages.removeAll { $0 == code }
                    if enabled { state.preferences.favoriteLanguages.append(code) }
                }))
            }
        } label: { Text("点此设置").frame(width: 164, alignment: .leading) }
        .frame(width: 188)
    }

    private func positionPicker(_ position: Binding<String>) -> some View {
        BobSettingsPicker("显示位置", selection: position, options: [("上次位置", "last"), ("鼠标附近", "mouse"), ("屏幕中央", "center"), ("屏幕左侧", "left"), ("屏幕右侧", "right"), ("屏幕左上方", "topLeft"), ("屏幕右上方", "topRight"), ("屏幕左下方", "bottomLeft"), ("屏幕右下方", "bottomRight"), ("菜单栏图标下方", "statusIconBottom")]).frame(width: 138, height: 24)
    }
    private func displayPicker(_ display: Binding<String>) -> some View {
        BobSettingsPicker("输入框", selection: display, options: [("记住上次状态", "remember"), ("总是展开", "expanded"), ("总是折叠", "collapsed")]).frame(width: 188, height: 24)
    }
    private var windowPositionPicker: some View { positionPicker($state.preferences.windowPosition) }
    private var inputDisplayPicker: some View { displayPicker($state.preferences.inputDisplay) }
    private var resultDisplayPicker: some View {
        BobSettingsPicker("服务结果", selection: $state.preferences.resultDisplay, options: [("记住各服务状态", "remember"), ("总是展开", "expanded"), ("总是折叠", "collapsed")]).frame(width: 188, height: 24)
    }
    private var silentServicePicker: some View {
        BobSettingsPicker("静默翻译服务", selection: $state.preferences.silentServiceID, options: [("首个已开启的服务", nil as UUID?)] + state.preferences.services.filter { $0.enabled && $0.capability == "translate" }.map { ($0.name, Optional($0.id)) }).frame(width: 188, height: 24)
    }
    private func chooseServiceCategory(_ category: String) {
        serviceCategory = category; state.settingsServiceCategory = category
    }

    private func servicePage(ocrOnly: Bool) -> some View {
        let capability = ocrOnly ? "ocr" : serviceCategory
        let scope = ocrOnly ? "standaloneOCR" : "translation"
        let key = listKey(capability: capability, scope: scope)
        let services = editableServices(for: capability, scope: scope)
        let selected = services.first { $0.id == selectedServiceID } ?? services.first
        return VStack(alignment: .leading, spacing: 0) {
            if !ocrOnly {
                HStack(spacing: 0) {
                    ForEach([("translate", "文本翻译"), ("ocr", "文本识别"), ("tts", "语音合成")], id: \.0) { category, title in
                        Button { chooseServiceCategory(category) } label: {
                            Text(title).font(.system(size: 12)).frame(width: 100, height: 24)
                                .foregroundStyle(serviceCategory == category ? Color.white : Color.primary)
                                .background(serviceCategory == category ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 25)
            }
            HStack(spacing: 20) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(services) { service in
                                let editing = serviceEditBinding(service)
                                HStack(spacing: 7) {
                                    Button { selectedServiceID = service.id } label: {
                                        HStack(spacing: 9) {
                                            UIReferenceIcon(name: UIReferenceAssets.serviceName(service)).frame(width: 16, height: 16)
                                            Text(editing.wrappedValue.service.name).font(.system(size: 13)).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    if service.kind == .apple || service.kind == .dictionary { Text("内置").font(.system(size: 9)).foregroundStyle(.teal) }
                                    Toggle("启用", isOn: Binding(get: { editing.wrappedValue.service.enabled }, set: { value in
                                        selectedServiceID = service.id
                                        if capability != "translate" { stageSingleSelection(service.id, enabled: value, capability: capability, scope: scope) }
                                        else { var draft = editing.wrappedValue; draft.service.enabled = value; editing.wrappedValue = draft }
                                    })).labelsHidden().toggleStyle(BobSettingsSwitchStyle(label: "启用" + editing.wrappedValue.service.name))
                                }.padding(.horizontal, 10).frame(height: 44)
                                    .background(selected?.id == service.id ? Color(nsColor: NSColor(srgbRed: 221.0/255, green: 221.0/255, blue: 221.0/255, alpha: 1)) : Color.clear)
                                    .contentShape(Rectangle())
                                    .draggable(service.id.uuidString)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let value = items.first, let source = UUID(uuidString: value) else { return false }
                                        return stageMoveService(source, before: service.id, capability: capability, scope: scope)
                                    }
                            }
                            if services.isEmpty { Text("点击下方 + 添加服务").font(.system(size: 12)).foregroundStyle(.secondary).padding(20) }
                        }
                    }
                }.frame(width: 253).background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
                Group {
                    if let selected {
                        ServiceDraftEditor(edit: serviceEditBinding(selected), state: state, plugins: plugins).id(selected.id)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(capability == "ocr" ? "系统离线识别" : capability == "tts" ? "系统离线朗读" : "添加翻译服务").font(.system(size: 14))
                            Text(capability == "translate" ? "点击左下方 + 添加服务，填写自己的服务地址、模型和 API 密钥。" : "系统服务已内置，也可以添加你配置的网络或插件服务。")
                                .foregroundStyle(.secondary).font(.system(size: 12))
                            Spacer()
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12))
            }.frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button { addingCapability = capability; addingScope = scope; showServicePicker = true } label: { Image(systemName: "plus").frame(width: 53, height: 24) }
                    Rectangle().fill(SettingsPalette.line).frame(width: 1, height: 14)
                    Button {
                        if let selected { stageRemoveService(selected, capability: capability, scope: scope) }
                    } label: { Image(systemName: "minus").frame(width: 53, height: 24) }.disabled(selected == nil)
                }.buttonStyle(.plain).foregroundStyle(.secondary).background(SettingsPalette.sidebar, in: RoundedRectangle(cornerRadius: 7))
                Spacer()
                footerButton("撤销", enabled: serviceListDirty(key: key, services: services)) { revertServiceList(capability: capability, scope: scope) }
                footerButton("保存", enabled: serviceListDirty(key: key, services: services)) { saveServiceList(capability: capability, scope: scope) }.keyboardShortcut("s", modifiers: .command)
            }.frame(height: 24).padding(.top, 14)
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 28)
    }

    private func footerButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12)).frame(width: 70, height: 24).background(SettingsPalette.sidebar, in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.42)
    }

    private func serviceEditBinding(_ service: ServiceConfig) -> Binding<ServiceEditDraft> {
        Binding(get: { serviceDrafts[service.id] ?? ServiceEditDraft(service: service) }, set: {
            ensureServiceList(capability: service.capability, scope: service.scope ?? "translation")
            serviceDrafts[service.id] = $0
        })
    }
    private func listKey(capability: String, scope: String) -> String { scope + ":" + capability }
    private func savedServices(capability: String, scope: String) -> [ServiceConfig] {
        state.preferences.services.filter { $0.capability == capability && ($0.scope ?? "translation") == scope }
    }
    private func savedSelection(capability: String, scope: String) -> UUID? {
        if capability == "translate" { return nil }
        return capability == "tts" ? state.preferences.ttsServiceID : scope == "translation" ? state.preferences.translationOCRServiceID : state.preferences.ocrServiceID
    }
    private func ensureServiceList(capability: String, scope: String) {
        let key = listKey(capability: capability, scope: scope)
        guard serviceLists[key] == nil else { return }
        let saved = savedServices(capability: capability, scope: scope)
        let selection = savedSelection(capability: capability, scope: scope)
        serviceLists[key] = ServiceListDraft(baseline: saved, orderedIDs: saved.map(\.id), selectedID: selection, baselineSelectedID: selection)
    }
    private func editableServices(for capability: String, scope: String) -> [ServiceConfig] {
        let saved = savedServices(capability: capability, scope: scope)
        let all = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        let ids = serviceLists[listKey(capability: capability, scope: scope)]?.orderedIDs ?? saved.map(\.id)
        return ids.compactMap { serviceDrafts[$0]?.service ?? all[$0] }
    }
    private func serviceListDirty(key: String, services: [ServiceConfig]) -> Bool {
        serviceLists[key]?.isDirty == true || services.contains { serviceDrafts[$0.id]?.isDirty == true }
    }
    private func stageNewService(_ service: ServiceConfig) {
        let scope = service.scope ?? "translation"
        ensureServiceList(capability: service.capability, scope: scope)
        serviceLists[listKey(capability: service.capability, scope: scope)]?.orderedIDs.append(service.id)
        serviceDrafts[service.id] = ServiceEditDraft(service: service, isNew: true)
        if service.capability != "translate", service.enabled { stageSingleSelection(service.id, enabled: true, capability: service.capability, scope: scope) }
        selectedServiceID = service.id
    }

    private func stageRemoveService(_ service: ServiceConfig, capability: String, scope: String) {
        ensureServiceList(capability: capability, scope: scope)
        let key = listKey(capability: capability, scope: scope)
        serviceLists[key]?.remove(service.id)
        if serviceDrafts[service.id]?.isNew == true { serviceDrafts.removeValue(forKey: service.id) }
        selectedServiceID = nil
    }
    private func stageSingleSelection(_ id: UUID, enabled: Bool, capability: String, scope: String) {
        let services = editableServices(for: capability, scope: scope)
        guard let selected = ServiceListDraft.selecting(id, enabled: enabled, in: services) else { return }
        ensureServiceList(capability: capability, scope: scope)
        let original = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        for service in selected {
            var draft = serviceDrafts[service.id] ?? ServiceEditDraft(service: original[service.id] ?? service)
            draft.service.enabled = service.enabled; serviceDrafts[service.id] = draft
        }
        serviceLists[listKey(capability: capability, scope: scope)]?.selectedID = selected.first(where: \.enabled)?.id
    }
    private func stageMoveService(_ source: UUID, before target: UUID, capability: String, scope: String) -> Bool {
        ensureServiceList(capability: capability, scope: scope)
        let key = listKey(capability: capability, scope: scope)
        guard var list = serviceLists[key], list.move(source, before: target) else { return false }
        serviceLists[key] = list
        return true
    }
    private func revertServiceList(capability: String, scope: String) {
        let key = listKey(capability: capability, scope: scope)
        let ids = Set(serviceLists[key]?.orderedIDs ?? []).union(serviceLists[key]?.baseline.map(\.id) ?? [])
        for id in ids { serviceDrafts.removeValue(forKey: id) }
        serviceLists.removeValue(forKey: key); selectedServiceID = nil
    }
    private func saveServiceList(capability: String, scope: String) {
        let key = listKey(capability: capability, scope: scope)
        guard let list = serviceLists[key] else { return }
        let old = state.preferences
        let saved = savedServices(capability: capability, scope: scope)
        guard saved == list.baseline, savedSelection(capability: capability, scope: scope) == list.baselineSelectedID else {
            state.notice = "服务已在其他窗口中修改。请撤销当前草稿后重新编辑。"; return
        }
        var previous: [String: String] = [:]
        var configurationWriteAttempted = false
        do {
            let editing = editableServices(for: capability, scope: scope)
            if capability != "translate" { try ServiceListDraft.validateSelection(in: editing) }
            var nextServices: [ServiceConfig] = []
            var updates: [String: String] = [:]
            for item in editing {
                var draft = serviceDrafts[item.id] ?? ServiceEditDraft(service: item)
                if draft.isDirty || draft.service.credentialSourceID != nil {
                    draft.loadCredentials(plugins: plugins)
                    updates.merge(try draft.credentialUpdates(plugins: plugins)) { _, new in new }
                    draft.service.credentialSourceID = nil
                }
                nextServices.append(draft.service)
            }
            var next = old
            next.services = list.replacingServices(in: next.services, with: nextServices)
            let selected = capability != "translate" ? nextServices.first(where: \.enabled)?.id : list.selectedID.flatMap { id in nextServices.contains { $0.id == id } ? id : nil }
            if capability == "ocr" {
                if scope == "translation" { next.translationOCRServiceID = selected } else { next.ocrServiceID = selected }
            } else if capability == "tts" { next.ttsServiceID = selected }
            let retained = Set(next.services.map(\.id))
            next.pinnedServiceIDs.removeAll { !retained.contains($0) }; next.collapsedServiceIDs.removeAll { !retained.contains($0) }
            if let silent = next.silentServiceID, !retained.contains(silent) { next.silentServiceID = nil }
            for account in updates.keys.sorted() {
                let value = SecretStore.read(account)
                try SecretStore.write(updates[account]!, account: account); previous[account] = value
            }
            configurationWriteAttempted = true
            try ConfigurationRepository.shared.save(preferences: next, shortcuts: state.shortcuts)
            state.preferences = next
            revertServiceList(capability: capability, scope: scope)
        } catch {
            var rollbackFailed = false
            for (account, value) in previous { do { try SecretStore.write(value, account: account) } catch { rollbackFailed = true } }
            if configurationWriteAttempted { do { try ConfigurationRepository.shared.save(preferences: old, shortcuts: state.shortcuts) } catch { rollbackFailed = true } }
            let alert = NSAlert(); alert.messageText = "无法保存服务"
            alert.informativeText = error.localizedDescription + (rollbackFailed ? " 部分数据未能恢复，请检查配置目录与钥匙串权限。" : " 未提交本次修改。")
            alert.addButton(withTitle: "好"); alert.runModal()
        }
    }

    private var filteredPlugins: [PluginDescriptor] {
        plugins.filter { pluginCategory == "all" || $0.category == pluginCategory }
    }

    private var pluginPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach([("all", "全部插件"), ("translate", "文本翻译"), ("ocr", "文本识别"), ("tts", "语音合成")], id: \.0) { category, title in
                    Button { pluginCategory = category } label: {
                        Text(title).font(.system(size: 12)).frame(width: 100, height: 24)
                            .foregroundStyle(pluginCategory == category ? Color.white : Color.primary)
                            .background(pluginCategory == category ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }.background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 25)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredPlugins.enumerated()), id: \.element.id) { index, plugin in
                        pluginRow(plugin, first: index == 0)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 15) {
                pluginFooterButton("安装插件", action: importPlugin)
                pluginFooterButton("检查更新") { checkPluginUpdates(filteredPlugins) }.disabled(!checkingPlugins.isEmpty)
                Spacer()
            }.frame(height: 24).padding(.top, 20)
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 26)
    }

    private func pluginFooterButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12)).frame(width: 76, height: 24).background(SettingsPalette.sidebar, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
    }
    private func pluginRow(_ plugin: PluginDescriptor, first: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 25) {
                Group {
                    if let image = NSImage(contentsOf: plugin.path.appendingPathComponent("icon.png")) { Image(nsImage: image).resizable().scaledToFit() }
                    else { UIReferenceIcon(name: "service_default_" + plugin.category, fallback: "puzzlepiece.extension") }
                }.frame(width: 28, height: 28).padding(.top, 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name).font(.system(size: 15)).lineLimit(1)
                    Text(plugin.id).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if let status = pluginCheckMessages[plugin.id] { Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(plugin.version).font(.system(size: 15)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if checkingPlugins.contains(plugin.id) { ProgressView().controlSize(.mini).frame(width: 16, height: 16) }
                        Menu { pluginMenu(plugin) } label: {
                            UIReferenceIcon(name: "pw_more", fallback: "ellipsis", template: true).frame(width: 24, height: 24)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 20).frame(height: 83, alignment: .top)
                .overlay(alignment: .top) { if !first { Rectangle().fill(SettingsPalette.line).frame(height: 1).padding(.horizontal, 20) } }
            if let update = pluginUpdates[plugin.id] {
                HStack(spacing: 10) {
                    Text("可更新至 " + update.version).font(.system(size: 15))
                    if !update.notes.isEmpty { Button { let alert = NSAlert(); alert.messageText = "更新说明"; alert.informativeText = update.notes; alert.runModal() } label: { Image(systemName: "info.circle") }.buttonStyle(.plain) }
                    Spacer()
                    pluginFooterButton(updatingPlugins.contains(plugin.id) ? "更新中…" : "更新") { installPluginUpdate(update) }.disabled(updatingPlugins.contains(plugin.id))
                }.padding(.horizontal, 20).frame(height: 62).overlay(alignment: .top) { Rectangle().fill(SettingsPalette.line).frame(height: 1).padding(.horizontal, 20) }
            }
        }.contextMenu { pluginMenu(plugin) }
    }
    @ViewBuilder private func pluginMenu(_ plugin: PluginDescriptor) -> some View {
        let supportsUpdate = pluginSupportsUpdates(plugin)
        Button(supportsUpdate ? "检查更新" : "该插件不支持检查更新") { checkPluginUpdates([plugin]) }.disabled(!supportsUpdate || checkingPlugins.contains(plugin.id))
        let homepage = pluginHomepage(plugin)
        Button(homepage == nil ? "该插件未提供主页" : "前往插件主页") { if let homepage { NSWorkspace.shared.open(homepage) } }.disabled(homepage == nil)
        Divider()
        Button("导出插件") { exportPlugin(plugin) }
        Button("删除插件", role: .destructive) { removePlugin(plugin) }
    }
    private func pluginSupportsUpdates(_ plugin: PluginDescriptor) -> Bool {
        guard let data = try? Data(contentsOf: plugin.path.appendingPathComponent("info.json")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appcast = info["appcast"] as? String else { return false }
        return !appcast.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func pluginHomepage(_ plugin: PluginDescriptor) -> URL? {
        guard let components = URLComponents(string: plugin.homepage), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        return components.url
    }
    private func removePlugin(_ plugin: PluginDescriptor) {
        let related = state.preferences.services.filter { $0.kind == .plugin && $0.pluginID == plugin.id }
        guard !related.contains(where: \.enabled) else {
            let alert = NSAlert(); alert.messageText = "禁止删除正在使用的插件"
            alert.informativeText = "当前有 \(related.filter(\.enabled).count) 个服务使用了本插件，请先到服务中将其停用。"; alert.addButton(withTitle: "好"); alert.runModal(); return
        }
        let alert = NSAlert(); alert.messageText = "确定要删除「\(plugin.name)」吗？"
        let pendingIDs = serviceDrafts.values.filter { $0.service.kind == .plugin && $0.service.pluginID == plugin.id }.map { $0.service.id }
        let relatedIDs = Set(related.map(\.id)).union(pendingIDs)
        alert.informativeText = relatedIDs.isEmpty ? "" : "当前有 \(relatedIDs.count) 个服务或未保存草稿使用此插件，删除插件后，这些服务也将一并删除。确定要继续删除吗？"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try state.removeConfiguredPlugin(plugin)
            for id in relatedIDs { serviceDrafts.removeValue(forKey: id) }
            for key in Array(serviceLists.keys) {
                guard var list = serviceLists[key] else { continue }
                list.baseline.removeAll { relatedIDs.contains($0.id) }
                list.orderedIDs.removeAll { relatedIDs.contains($0) }
                if let selected = list.selectedID, relatedIDs.contains(selected) { list.selectedID = nil }
                if let selected = list.baselineSelectedID, relatedIDs.contains(selected) { list.baselineSelectedID = nil }
                serviceLists[key] = list
            }
            pluginUpdates.removeValue(forKey: plugin.id); pluginCheckMessages.removeValue(forKey: plugin.id)
            plugins = PluginService.shared.listPlugins()
        } catch { let failure = NSAlert(); failure.messageText = "删除失败"; failure.informativeText = error.localizedDescription; failure.runModal() }
    }
    private func exportPlugin(_ plugin: PluginDescriptor) {
        let panel = NSSavePanel(); panel.title = "导出插件"; panel.nameFieldStringValue = "\(plugin.id)(\(plugin.version)).bobplugin"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let current = PluginService.shared.listPlugins().first { $0.id == plugin.id }
            guard current?.version == plugin.version else { throw PopError.message("插件已变化，请重新选择后导出。") }
            try SettingsPluginPackageExporter.export(folder: plugin.path, destination: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { let alert = NSAlert(); alert.messageText = "导出失败"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }

    private var generalSettings: some View {
        settingsScroll {
            settingsGroup("全局快捷键", topSpacing: 0) {
                shortcutRow(.showPreferences, detail: "直接显示设置窗口，用于调整 Pop 的各项设置。")
            }
            settingsGroup("基础") {
                cardRow("开机自启动", detail: loginStatusDescription) {
                    HStack(spacing: 8) {
                        if SMAppService.mainApp.status == .requiresApproval {
                            Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        Toggle("开机自启动", isOn: Binding(get: { loginEnabled }, set: { enabled in
                            Task { @MainActor in
                                do {
                                    if enabled { try SMAppService.mainApp.register() }
                                    else { try await SMAppService.mainApp.unregister() }
                                    loginEnabled = SMAppService.mainApp.status == .enabled
                                } catch { loginEnabled = SMAppService.mainApp.status == .enabled; state.notice = error.localizedDescription }
                            }
                        })).labelsHidden().toggleStyle(BobSettingsSwitchStyle(label: "开机自启动"))
                    }
                }
            }
            settingsCard {
                cardRow("菜单栏图标") {
                    HStack(spacing: 8) {
                        BobSettingsPicker("菜单栏图标", selection: $state.preferences.statusIconStyle, options: [("Pop", "pop"), ("圆形 P", "letter"), ("翻译", "translate"), ("方形 P", "badge")] + (state.preferences.statusIconPath.isEmpty ? [] : [("自定义", "custom")])).frame(width: 112, height: 24)
                        Button("自定义") { AppDelegate.shared?.chooseStatusIcon() }
                    }.frame(width: 190)
                }
                rowDivider
                switchRow("隐藏菜单栏图标", detail: "隐藏后仍可通过快捷键或重新打开 Pop 显示设置。", value: $state.preferences.hideStatusItem)
                rowDivider
                cardRow("鼠标右键点击菜单栏图标") { statusRightClickPicker }
                rowDivider
                cardRow("拖拽图片到菜单栏图标", detail: "把图片放到菜单栏的 Pop 图标上时，按这里选择的方式处理。") {
                    BobSettingsPicker("拖入图片", selection: $state.preferences.statusImageDropAction, options: [("图片翻译", "translate"), ("图片 OCR", "ocr")]).frame(width: 188, height: 24)
                }
            }
            settingsCard {
                cardRow("字体大小", detail: "翻译和 OCR 窗口也可用 ⌘+ / ⌘− 调整文字大小。") {
                    VStack(spacing: 0) {
                        // The recovered OCRTextContainerView font table maps
                        // Preference_font cases 0...5 to 14...19pt. Clamp only
                        // the displayed knob; opening settings must not migrate
                        // a previously saved Pop font size outside this range.
                        Slider(value: Binding(get: { min(19, max(14, state.preferences.fontSize)) },
                                              set: { state.preferences.fontSize = $0 }), in: 14...19, step: 1)
                            .accessibilityLabel("字体大小")
                            .accessibilityValue("\(Int(state.preferences.fontSize))")
                        HStack { Text("小"); Spacer(); Text("大") }
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(width: 250)
                }
            }
            settingsCard {
                cardRow("界面语言", detail: "当前内置简体中文。可在系统设置管理语言，其他界面语言文本尚未提供。") {
                    HStack(spacing: 12) {
                        Text("中文简体").foregroundStyle(.secondary)
                        Button("修改语言") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }.contextMenu {
                Menu("外观") {
                    Button("跟随系统") { state.preferences.appearance = "system" }
                    Button("浅色") { state.preferences.appearance = "light" }
                    Button("深色") { state.preferences.appearance = "dark" }
                }
            }
            settingsGroup("高级") {
                cardRow("自定义代理", detail: "设置并开启自定义 HTTP 代理后，网络翻译、OCR、朗读和插件 HTTP 请求会使用该代理。") {
                    Button("点此设置") { showProxySettings = true }
                }
            }
            settingsCard {
                switchRow("窗口置顶使用增强模式", value: $state.preferences.enhancedWindowLevel)
                rowDivider
                switchRow("去掉窗口与屏幕的边缘空白", detail: "允许翻译和 OCR 窗口贴近屏幕可用区域的边界；关闭时会留出边距。", value: $state.preferences.removeScreenMargins)
                rowDivider
                cardRow("鼠标悬停提示", detail: "选择按钮说明何时出现。需要减少浮动提示时，可以让鼠标停留一会儿再显示。") {
                    BobSettingsPicker("鼠标悬停提示", selection: $state.preferences.tooltipBehavior, options: [("延迟显示", "delayed"), ("立即显示", "immediate")]).frame(width: 188, height: 24)
                }
            }
            settingsCard {
                switchRow("截图时是否使用兼容模式", value: $state.preferences.screenshotCompatibilityMode)
                rowDivider
                switchRow("截图时左下角是否显示操作提示", value: $state.preferences.screenshotShowsTips)
            }
            settingsGroup("应用优化") {
                cardRow("帮助改进应用体验", detail: "Pop 未接入远程体验统计，不收集或上传使用数据。") {
                    Text("未启用").foregroundStyle(.secondary)
                }
                rowDivider
                switchRow("启用日志系统", detail: "应用会将操作事件和错误类型记录到本地，不记录原文、译文或密钥。反馈问题时可自行导出日志。", value: $state.preferences.localLoggingEnabled)
                rowDivider
                cardRow("导出日志", detail: "导出后可自行检查文件内容，再决定是否分享。") { Button("点此导出", action: LocalDiagnostics.export) }
            }
        }
    }

    private var statusRightClickPicker: some View {
        BobSettingsPicker("右键点击", selection: $state.preferences.statusRightClickAction, options: [("显示菜单", "menu"), ("划词翻译", "selection"), ("截图翻译", "screenshotTranslation"), ("输入翻译", "input"), ("剪贴板翻译", "clipboardTranslation"), ("显示翻译窗口", "showTranslationWindow"), ("截图 OCR", "screenshotOCR"), ("静默截图 OCR", "silentOCR"), ("访达选图 OCR", "fileOCR"), ("剪贴板 OCR", "pasteboardOCR"), ("显示 OCR 窗口", "showOCRWindow"), ("显示设置窗口", "showPreferences")]).frame(width: 188, height: 24)
    }

    private var loginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .requiresApproval: return "需要在系统设置中允许"
        case .notRegistered: return "未开启"
        case .notFound: return "请将 Pop 放入应用程序目录后开启"
        @unknown default: return "在系统设置中管理登录项目"
        }
    }

    private var enhancements: some View {
        settingsScroll {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    enhancementIcon.frame(width: 80, height: 80)
                    Text("Pop 辅助功能").font(.system(size: 21, weight: .medium)).padding(.top, 8)
                    Text("选区读取、译文回填和截图功能已内置，无需另装辅助工具。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 2)
                    Button { showEnhancementHelp = true } label: {
                        Text("使用教程").font(.system(size: 12)).padding(.horizontal, 10).frame(height: 22)
                            .background(SettingsPalette.sidebar, in: Capsule())
                    }.buttonStyle(.plain).padding(.top, 10)
                }.frame(maxWidth: .infinity).frame(height: 196)
                    .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 7) {
                    Image(systemName: permissionStatus.accessibility && permissionStatus.screenRecording ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permissionStatus.accessibility && permissionStatus.screenRecording ? Color.green : Color.orange)
                    Text(permissionStatus.accessibility && permissionStatus.screenRecording
                         ? "辅助功能和屏幕录制权限已开启。"
                         : "请开启辅助功能和屏幕录制权限，以正常使用划词、回填和截图。")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).frame(minHeight: 36)
                    .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12))
                settingsCard {
                    enhancementPermissionRow("辅助功能", granted: permissionStatus.accessibility, action: PermissionHelper.openAccessibility)
                    rowDivider
                    enhancementPermissionRow("屏幕录制", granted: permissionStatus.screenRecording, action: PermissionHelper.openScreenRecording)
                }
            }
        }
    }

    @ViewBuilder private var enhancementIcon: some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().padding(8)
        } else {
            Image(systemName: "hand.raised.circle").resizable().scaledToFit().foregroundStyle(.secondary).padding(8)
        }
    }

    private func enhancementPermissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text(granted ? "已开启" : "未开启").font(.system(size: 12)).foregroundStyle(.secondary)
            Button(granted ? "打开设置" : "点此授权", action: action)
                .font(.system(size: 12)).padding(.leading, 8)
        }.padding(.horizontal, 10).frame(height: 44)
    }

    private var enhancementHelp: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("辅助功能使用教程").font(.system(size: 16, weight: .semibold))
            Text("Pop 的取词、回填和截图在应用内运行；设置中显示的是本机实际授权状态。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            settingsCard {
                cardRow("划词翻译与译文回填", detail: "先在系统设置中为 Pop 开启辅助功能权限，再回到原应用选中文字并按划词快捷键。需要替换时，保持原输入位置可编辑并使用译文回填操作。") {
                    Button("打开系统设置", action: PermissionHelper.openAccessibility)
                }
                rowDivider
                cardRow("截图翻译与截图 OCR", detail: "在系统设置中为 Pop 开启屏幕录制权限。按截图快捷键后拖选区域，按 Esc 可以取消；如果系统要求重新打开应用，请先完成重启。") {
                    Button("打开系统设置", action: PermissionHelper.openScreenRecording)
                }
            }
            HStack {
                Button("翻译快捷键设置") { showEnhancementHelp = false; selectedPage = .translationSettings }
                Button("OCR 快捷键设置") { showEnhancementHelp = false; selectedPage = .ocrSettings }
                Spacer()
                Button("完成") { showEnhancementHelp = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }

    private var importExport: some View {
        settingsScroll {
            settingsCard {
                navigationCardRow("导入设置", asset: "pw_export_import") { state.importConfiguration() }
                rowDivider
                navigationCardRow("导出设置", asset: "pw_export_export", action: state.exportConfiguration)
            }.padding(.top, 12)
                .contextMenu {
                    Button("完整备份所有数据…", action: state.exportBackup)
                    Button("恢复完整备份…") { state.importBackup() }
                    Divider()
                    Button("导入历史记录与收藏…", action: state.importHistory)
                    Button("前往历史记录") { selectedPage = .history }
                    Button("前往收藏夹") { selectedPage = .favorites }
                }
                .bobTooltip("右键可访问完整备份和历史记录操作")
        }
    }

    private var integration: some View {
        settingsScroll {
            settingsCard {
                navigationCardRow("PopClip", asset: "pw_integration_popclip") { PopIntegrationActions.showPopClip() }
                rowDivider
                navigationCardRow("AppleScript", asset: "pw_integration_applescript") { PopIntegrationActions.showAppleScript() }
            }.padding(.top, 12)
        }
    }

    private func navigationCardRow(_ title: String, asset: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                UIReferenceIcon(name: asset).frame(width: 26, height: 26)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).frame(height: 52).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var about: some View {
        VStack(spacing: 16) {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 100, height: 100)
            }
            Text("Pop").font(.system(size: 28, weight: .semibold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .font(.callout).foregroundStyle(.secondary)
            Text("翻译与 OCR 工具").font(.headline)
            Text("使用本机文字识别、macOS 系统翻译，以及你配置的网络和插件服务。")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 400)
            Spacer()
        }.padding(.top, 70).padding(.horizontal, 40).frame(maxWidth: .infinity)
    }

    private func addService(_ kind: ServiceKind, capability: String) {
        if kind == .plugin {
            guard let first = plugins.first(where: { $0.category == capability }) else {
                state.notice = "请先安装对应类型的插件，再添加插件服务。"
                return
            }
            addPluginService(first)
            return
        }
        var item = ServiceConfig(name: kind.title(for: capability), kind: kind)
        item.capability = capability
        item.scope = addingScope
        item.enabled = kind == .apple
        item.endpoint = capability == "translate" ? CloudServiceCatalog.defaultEndpoint(for: kind) : CloudMediaCatalog.defaultEndpoint(for: kind, capability: capability)
        item.options = capability == "translate" ? CloudServiceCatalog.defaultOptions(for: kind) : CloudMediaCatalog.defaultOptions(for: kind, capability: capability)
        stageNewService(item)
    }
    private func chooseService(_ choice: ServicePickerChoice) {
        showServicePicker = false
        switch choice {
        case .system:
            if addingCapability == "translate" { addService(.apple, capability: "translate") }
            else { stageNewService(.systemMedia(capability: addingCapability, scope: addingScope)) }
        case .dictionary:
            var item = ServiceConfig.dictionary
            item.scope = "translation"
            stageNewService(item)
        case .provider(let kind): addService(kind, capability: addingCapability)
        case .preset(let preset):
            var item = ServiceConfig(name: preset.title, kind: preset.kind)
            item.enabled = false; item.endpoint = preset.endpoint; item.model = preset.model; item.options = preset.options
            item.scope = addingScope
            stageNewService(item)
        case .plugin(let plugin): addPluginService(plugin)
        case .installPlugin: DispatchQueue.main.async { importPlugin() }
        }
    }
    private func addPluginService(_ plugin: PluginDescriptor) {
        var config = ServiceConfig(name: plugin.name, kind: .plugin)
        config.enabled = false
        config.pluginID = plugin.id; config.capability = plugin.category
        config.scope = selectedPage == .ocrServices || selectedPage == .plugins && plugin.category == "ocr" ? "standaloneOCR" : "translation"
        for option in plugin.options where !option.isSecure { config.options[option.identifier] = option.defaultValue }
        stageNewService(config)
        chooseServiceCategory(plugin.category)
        selectedPage = config.scope == "standaloneOCR" ? .ocrServices : .translationServices
        selectedServiceID = config.id
    }
    private func importPlugin() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let plugin = try PluginService.shared.importPlugin(from: url); plugins = PluginService.shared.listPlugins(); state.notice = "已安装 \(plugin.name)。请添加并配置对应服务。" }
        catch { state.notice = error.localizedDescription }
    }

    private func checkPluginUpdates(_ targets: [PluginDescriptor]) {
        guard !targets.isEmpty else {
            let alert = NSAlert(); alert.messageText = "请至少安装一个插件后再检查更新。"; alert.addButton(withTitle: "好"); alert.runModal(); return
        }
        let pending = targets.filter { !checkingPlugins.contains($0.id) }
        for plugin in pending { checkingPlugins.insert(plugin.id); pluginUpdates.removeValue(forKey: plugin.id); pluginCheckMessages[plugin.id] = "正在检查更新…" }
        Task { @MainActor in
            for plugin in pending {
                defer { checkingPlugins.remove(plugin.id) }
                do {
                    guard pluginSupportsUpdates(plugin) else { pluginCheckMessages[plugin.id] = "该插件不支持检查更新"; continue }
                    let update = try await PluginService.shared.checkForUpdate(id: plugin.id)
                    guard plugins.contains(where: { $0.id == plugin.id && $0.version == plugin.version }) else { continue }
                    if let update { pluginUpdates[plugin.id] = update; pluginCheckMessages[plugin.id] = nil }
                    else { pluginCheckMessages[plugin.id] = "已是最新版本" }
                } catch { if plugins.contains(where: { $0.id == plugin.id && $0.version == plugin.version }) { pluginCheckMessages[plugin.id] = "检查失败：" + error.localizedDescription } }
            }
        }
    }
    private func installPluginUpdate(_ update: PluginUpdate) {
        updatingPlugins.insert(update.pluginID)
        Task {
            defer { updatingPlugins.remove(update.pluginID) }
            do {
                let plugin = try await PluginService.shared.installUpdate(update)
                pluginUpdates.removeValue(forKey: update.pluginID)
                plugins = PluginService.shared.listPlugins()
                state.notice = "\(plugin.name) 已更新到 \(plugin.version)。"
            } catch { state.notice = error.localizedDescription }
        }
    }
}

private struct PreferencesHistoryView: View {
    @ObservedObject var state: AppState
    let favoritesOnly: Bool
    @ViewState private var query = ""
    @ViewState private var selection: UUID?

    private var items: [HistoryItem] {
        state.history.filter { item in
            (!favoritesOnly || item.favorite) && (query.isEmpty || item.source.localizedCaseInsensitiveContains(query) || item.results.values.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    private var selected: HistoryItem? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder).padding(10)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            Button { selection = item.id } label: {
                                Text(item.source).lineLimit(3).font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(selected?.id == item.id ? Color.primary.opacity(0.12) : Color.clear)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.background(Color(nsColor: .textBackgroundColor))
                HStack {
                    Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("导出当前列表…") { exportItems() }
                        if !favoritesOnly { Button("清空历史记录") { state.history = []; state.saveHistory() } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.padding(10)
            }.frame(width: 235)
            Divider()
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(selected.date, style: .date).foregroundStyle(.secondary)
                            Spacer()
                            Button { state.history.removeAll { $0.id == selected.id }; state.saveHistory() }
                                label: { Image(systemName: "trash") }
                            Button { state.toggleFavorite(selected.id) }
                                label: { Image(systemName: selected.favorite ? "star.fill" : "star") }.foregroundStyle(selected.favorite ? .orange : .secondary)
                        }.buttonStyle(.borderless)
                        historyCard(selected.source, service: nil)
                        HStack(spacing: 12) {
                            Text(LanguageCatalog.title(selected.sourceLanguage)).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 8))
                            Image(systemName: "chevron.right.2").foregroundStyle(.secondary)
                            Text(LanguageCatalog.title(selected.targetLanguage)).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }.font(.callout)
                        ForEach(selected.results.keys.sorted(), id: \.self) { name in
                            historyCard(selected.results[name] ?? "", service: name)
                        }
                        Button("载入翻译窗口") { state.loadHistory(selected) }
                    }.padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: favoritesOnly ? "star" : "clock").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(favoritesOnly ? "暂无收藏" : "暂无历史记录").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func historyCard(_ text: String, service: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text).font(.system(size: state.preferences.fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button { state.speak(text) } label: { Image(systemName: "speaker.wave.2") }
                Button { state.copy(text) } label: { Image(systemName: "doc.on.doc") }
                Spacer()
                if let service { Text(service).font(.caption).foregroundStyle(.secondary) }
            }.buttonStyle(.borderless)
        }.padding(16).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
    private func exportItems() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = favoritesOnly ? "Pop收藏.json" : "Pop历史.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted; try encoder.encode(items).write(to: url, options: .atomic) }
        catch { state.notice = error.localizedDescription }
    }
}


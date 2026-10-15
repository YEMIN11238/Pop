import AppKit
import Carbon
import SwiftUI
import Translation

// Explicit wrapper alias keeps builds compatible with CLT without SwiftUI macro plugins.
typealias ViewState<Value> = SwiftUI.State<Value>

private enum PopPalette {
    static let canvas = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.16 : 0.99, alpha: 1)
    }))
    static let panel = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.20 : 0.935, alpha: 1)
    }))
}

struct MainView: View {
    @ObservedObject var state: AppState
    var showSettings: () -> Void
    var ocrRole = false
    @ViewState private var showInput = true
    private var panelColor: Color { PopPalette.panel }

    var body: some View {
        let pendingRequest = state.systemRequest
        let pendingJob = state.systemJobID
        let pendingTicket = state.systemTicket
        let pendingBatch = state.systemImageBatch
        let pendingLines = state.ocrDocument?.lines ?? []
        VStack(spacing: 0) {
            toolbar
            if ocrRole && !state.ocrImages.tasks.isEmpty {
                ocrWorkspace
            } else { ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if state.mode == "history" { HistoryView(state: state).frame(minHeight: 360) }
                    else {
                        if showInput || ocrRole { sourcePanel }
                        if !ocrRole && state.mode != "ocr" && (state.preferences.showLanguageBar || (state.preferences.keepLanguageBarWhenPinned && !state.preferences.pinnedServiceIDs.isEmpty)) { languageBar }
                        if let notice = state.notice {
                            Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 8)
                        }
                        if state.recognizing {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 7) {
                                    UIReferenceIcon(name: state.recognizingService.map { UIReferenceAssets.serviceName($0) } ?? "service_default_ocr").frame(width: 14, height: 14)
                                    Text(state.recognizingService?.name ?? "OCR").font(.system(size: 11))
                                    Spacer()
                                    ProgressView().controlSize(.mini)
                                }
                                Text("正在识别…").font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(9).background(panelColor, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if (ocrRole || state.mode == "ocr"), let url = state.imageURL, let image = NSImage(contentsOf: url), let document = state.ocrDocument {
                            HStack {
                                Toggle("识别框", isOn: $state.showBoxes).toggleStyle(.checkbox)
                                Spacer()
                                Button("追加截图") { state.capture(translate: false, silent: false, append: true) }
                                Button("图片翻译", action: state.translateImage).disabled(document.lines.isEmpty)
                            }.font(.system(size: 11)).padding(.horizontal, 3)
                            OCRImageView(image: image, document: document, showBoxes: state.showBoxes,
                                         translations: state.imageOverlay ? state.imageTranslations : [:])
                                .frame(height: min(360, max(120, image.size.height / max(image.size.width, 1) * 380)))
                            if !document.qrCodes.isEmpty {
                                ForEach(document.qrCodes, id: \.self) { value in
                                    HStack { Image(systemName: "qrcode"); Text(value).textSelection(.enabled); Spacer(); Button("复制") { state.copy(value) } }.font(.caption).padding(8).background(panelColor, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        ForEach(state.results) { result in
                            ResultCardView(card: result, serviceIcon: state.preferences.services.first(where: { $0.id == result.serviceID }).map { UIReferenceAssets.serviceName($0) } ?? "service_default_translate", fontSize: state.preferences.fontSize,
                                           copy: state.copyResult, speak: state.speak, dictionaryAudio: { audio, word in state.playDictionaryAudio(audio: audio, word: word) }, retry: { state.translateService(result.serviceID) },
                                           insert: state.insertResult, canInsert: state.canInsertResult,
                                           showInsert: state.preferences.showReplaceButton,
                                           copyStyles: enabledCopyStyles,
                                           lookup: lookupWord,
                                           linkConfirmation: state.preferences.linkConfirmation,
                                           expanded: !state.preferences.collapsedServiceIDs.contains(result.serviceID),
                                           pinned: state.preferences.pinnedServiceIDs.contains(result.serviceID),
                                           markdownEnabled: state.preferences.renderMarkdown,
                                           remoteImages: state.preferences.renderRemoteImages,
                                           defaultShowReasoning: state.preferences.showReasoning,
                                           toggleExpanded: { state.toggleServiceCollapsed(result.serviceID) },
                                           togglePinned: { state.toggleServicePinned(result.serviceID) })
                        }
                        if !state.recognizing && state.results.isEmpty && state.input.isEmpty && state.ocrDocument == nil {
                            VStack(spacing: 8) {
                                Text(ocrRole ? "截图或选择图片开始识别文字" : "选中文字后按 ⌥ D，或输入文字后按回车").font(.system(size: 12))
                                HStack { Button(ocrRole ? "截图 OCR" : "截图翻译") { state.capture(translate: !ocrRole, silent: false, append: ocrRole && state.continuousOCR) }; Button("选图 OCR") { AppDelegate.shared?.recognizeFinderSelection() } }
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
                 .background(GeometryReader { geometry in Color.clear.preference(key: PanelContentHeight.self, value: geometry.size.height) })
            }
            }
            if ocrRole {
                HStack(spacing: 12) {
                    Button("复制") { state.copyResult(state.input) }.disabled(state.input.isEmpty)
                    Button("翻译") { AppDelegate.shared?.translateOCRText(state.input) }.disabled(state.input.isEmpty)
                    Spacer()
                    Toggle("连续识别", isOn: $state.continuousOCR).toggleStyle(.switch).tint(.orange).controlSize(.mini)
                }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 9)
            }
            if state.working {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("处理中…"); Spacer(); Button("取消") { state.cancelTranslation() } }
                    .font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 5)
            }
        }
        .frame(minWidth: 340, minHeight: 260)
        .background(PopPalette.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(PanelContentHeight.self) { height in
            // The image workspace fills the OCR window; removing the measured
            // text-only branch publishes its default zero height.
            guard !ocrRole || state.ocrImages.tasks.isEmpty else { return }
            state.onContentHeight?(height + 35 + (ocrRole ? 35 : 0) + (state.working ? 28 : 0))
        }
        .onAppear(perform: applyInputDisplay)
        .onChange(of: state.queryRevision) { _, _ in applyInputDisplay() }
        .onChange(of: state.preferences.inputDisplay) { _, _ in applyInputDisplay() }
        .translationTask(state.systemConfiguration) { session in
            guard let request = pendingRequest else { return }
            let job = pendingJob
            let ticket = pendingTicket
            let batch = pendingBatch
            let lines = pendingLines
            do {
                try await state.awaitSystemCooldown(job: job, ticket: ticket)
                if session.sourceLanguage != nil { try await session.prepareTranslation() }
                if batch {
                    let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
                    let responses = try await session.translations(from: requests)
                    var values: [Int: String] = [:]
                    for response in responses { if let key = response.clientIdentifier.flatMap(Int.init) { values[key] = response.targetText } }
                    state.imageTranslationCompleted(values, error: nil, job: job, ticket: ticket)
                } else {
                    let response = try await session.translate(request.text)
                    state.systemCompleted(TranslationOutput(text: response.targetText, detectedSource: response.sourceLanguage.languageCode?.identifier), error: nil, job: job, ticket: ticket)
                }
            } catch {
                let message = "系统翻译：\(error.localizedDescription) 首次使用需要下载相应语言。"
                if batch { state.imageTranslationCompleted([:], error: message, job: job, ticket: ticket) }
                else { state.systemCompleted(nil, error: message, job: job, ticket: ticket) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var images: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    guard let url else { continue }
                    if url.pathExtension.lowercased() == "bobplugin" {
                        do { let plugin = try PluginService.shared.importPlugin(from: url); state.notice = "已安装 \(plugin.name)，可在设置中添加插件服务。" }
                        catch { state.notice = error.localizedDescription }
                    } else if url.pathExtension.lowercased() == "yibanconfig" || url.pathExtension.lowercased() == "popconfig" { state.importConfiguration(url: url) }
                    else if url.pathExtension.lowercased() == "popbackup" { state.importBackup(url: url) }
                    else { images.append(url) }
                }
                if !images.isEmpty { state.recognize(urls: images, translateAfter: false, silent: false) }
            }
            return true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            tool(state.pinned ? "pin.fill" : "pin", "钉住 / 取消钉住窗口（⌘P）") { state.setPinned(!state.pinned) }
            Spacer(minLength: 5)
            if ocrRole || state.mode == "ocr" {
                Button { state.showsOCRImages.toggle() } label: {
                    UIReferenceIcon(name: "ow_navigation_image", fallback: "photo.on.rectangle").frame(width: 15, height: 16)
                }.bobTooltip(state.showsOCRImages ? "隐藏图片" : "显示图片").accessibilityLabel("显示 / 隐藏 OCR 图片")
                if state.preferences.showOCRScreenshotButton { tool("scissors", "截图 OCR") { state.capture(translate: false, silent: false, append: state.continuousOCR) } }
                if state.preferences.showOCRFileButton { tool("photo", "访达选图 OCR") { AppDelegate.shared?.recognizeFinderSelection() } }
                if state.preferences.showOCRClipboardButton { tool("clipboard", "剪贴板 OCR") { state.recognizeClipboard() } }
                ToolbarActionButton(symbol: "bubble.left", help: "左键选择识别服务；右键打开 OCR 服务", referenceAsset: "tw_navigation_service", menuActions: ocrServices,
                                    primary: {}, secondary: { state.settingsSection = "ocrServices"; showSettings() }).frame(width: 17, height: 18)
            } else {
                if state.preferences.showFavoriteButton {
                    ToolbarActionButton(symbol: "star.fill", help: "左键收藏 / 取消收藏；右键打开收藏夹", referenceAsset: state.currentTranslationFavorite ? "tw_navigation_favorite_yellow" : "tw_navigation_favorite", active: state.currentTranslationFavorite,
                                        primary: state.favoriteCurrentTranslation,
                                        secondary: { state.settingsSection = "favorites"; showSettings() }).frame(width: 17, height: 18)
                }
                if state.preferences.showHistoryButton { tool("clock", "历史记录") { state.settingsSection = "history"; showSettings() } }
                if state.preferences.showScreenshotButton { tool("scissors", "截图翻译") { state.capture(translate: true, silent: false) } }
                if state.preferences.showClipboardButton { tool("clipboard", "剪贴板翻译", state.translateClipboard) }
                if state.preferences.showInputToggle { tool(showInput ? "eraser" : "square.and.pencil", "隐藏 / 显示输入框") { showInput.toggle(); state.preferences.inputVisible = showInput; state.savePreferences() } }
                ServiceManagementPopover(state: state) { capability in
                    state.settingsServiceCategory = capability
                    showSettings()
                }.frame(width: 17, height: 18)
            }
            ToolbarActionButton(symbol: "switch.2", help: "左键打开快捷设置；右键打开偏好设置", referenceAsset: "tw_navigation_control", menuActions: quickSettings,
                                primary: {}, secondary: { state.settingsSection = (ocrRole || state.mode == "ocr") ? "ocr" : "translate"; showSettings() }).frame(width: 17, height: 18)
        }.font(.system(size: 13)).foregroundStyle(.secondary).buttonStyle(.borderless).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 9)
    }

    private var ocrServices: [ToolbarMenuAction] {
        let services = state.preferences.ocrServices(forTranslation: false)
        return services.map { service in
            ToolbarMenuAction(title: service.name, checked: state.preferences.selectedOCRService(forTranslation: false)?.id == service.id) {
                let changed = state.preferences.selectedOCRService(forTranslation: false)?.id != service.id
                state.preferences.selectOCRService(service.id, forTranslation: false)
                state.savePreferences()
                if changed { state.retryOCRImages() }
            }
        }
    }

    private var quickSettings: [ToolbarMenuAction] {
        let controls: [ToolbarMenuAction] = (ocrRole || state.mode == "ocr") ? [
            ToolbarMenuAction(title: "自动复制 OCR 结果", checked: state.preferences.autoCopyOCR) { state.preferences.autoCopyOCR.toggle(); state.savePreferences() },
            ToolbarMenuAction(title: "识别二维码", checked: state.preferences.recognizeQRCode) { state.preferences.recognizeQRCode.toggle(); state.savePreferences() },
            ToolbarMenuAction(title: "", action: {})
        ] : [
            ToolbarMenuAction(title: "显示语言切换栏", checked: state.preferences.showLanguageBar) { state.preferences.showLanguageBar.toggle(); state.savePreferences() },
            ToolbarMenuAction(title: "显示输入框", checked: showInput) { showInput.toggle(); state.preferences.inputVisible = showInput; state.savePreferences() },
            ToolbarMenuAction(title: "自动复制首个翻译结果", checked: state.preferences.autoCopyFirstResult) { state.preferences.autoCopyFirstResult.toggle(); state.savePreferences() },
            ToolbarMenuAction(title: "", action: {})
        ]
        return controls + [
            ToolbarMenuAction(title: "偏好设置") { state.settingsSection = (ocrRole || state.mode == "ocr") ? "ocr" : "translate"; showSettings() },
            ToolbarMenuAction(title: "截图 OCR") { state.handle(.screenshotOCR) },
            ToolbarMenuAction(title: "原图翻译", action: state.captureImageTranslation),
            ToolbarMenuAction(title: "连续截图 OCR") { state.handle(.continuousOCR) },
            ToolbarMenuAction(title: "剪贴板 OCR") { state.handle(.pasteboardOCR) },
            ToolbarMenuAction(title: "访达选图 OCR") { state.handle(.fileOCR) },
            ToolbarMenuAction(title: "撤销上次回填", enabled: state.canUndoReplacement, action: state.undoReplacement),
            ToolbarMenuAction(title: "", action: {}),
            ToolbarMenuAction(title: "新翻译窗口") { AppDelegate.shared?.newWindow() },
            ToolbarMenuAction(title: "增大字号") { state.preferences.fontSize = min(19, max(14, state.preferences.fontSize + 1)); state.savePreferences() },
            ToolbarMenuAction(title: "减小字号") { state.preferences.fontSize = min(19, max(14, state.preferences.fontSize - 1)); state.savePreferences() },
            ToolbarMenuAction(title: "", action: {}),
            ToolbarMenuAction(title: "清空", action: state.clearInput),
            ToolbarMenuAction(title: "关闭窗口") { state.dismissWindow() }
        ]
    }

    private var enabledCopyStyles: [String] {
        [(state.preferences.showCopyCamel, "camelCase"), (state.preferences.showCopyPascal, "PascalCase"),
         (state.preferences.showCopySnake, "snake_case"), (state.preferences.showCopyKebab, "kebab-case"),
         (state.preferences.showCopyMacro, "MACRO_CASE")].compactMap { $0.0 ? $0.1 : nil }
    }

    private func lookupWord(_ word: String) {
        if state.preferences.copyHighlightedWord { state.copy(word) }
        state.input = word
        state.translate()
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { UIReferenceIcon(name: navigationAsset(symbol), fallback: symbol).frame(width: 15, height: 16) }.bobTooltip(help).accessibilityLabel(help)
    }

    private func navigationAsset(_ symbol: String) -> String {
        switch symbol {
        case "pin": return "tw_navigation_pin_normal"
        case "pin.fill": return "tw_navigation_pin_selected"
        case "clock": return "tw_navigation_history"
        case "scissors": return "tw_navigation_snip"
        case "clipboard": return "tw_navigation_pasteboard"
        case "photo": return "ow_navigation_file"
        default: return "tw_navigation_input"
        }
    }

    private func applyInputDisplay() {
        let policy = state.inputDisplayOverride ?? state.preferences.inputDisplay
        switch policy {
        case "collapsed", "alwaysFold": showInput = false
        case "expanded", "alwaysUnfold": showInput = true
        default: showInput = state.preferences.inputVisible
        }
        state.inputDisplayOverride = nil
    }

    private func submitSource() {
        if ocrRole { AppDelegate.shared?.translateOCRText(state.input) } else { state.translate() }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            InputEditor(text: $state.input, fontSize: state.preferences.fontSize, onSubmit: submitSource)
                .frame(height: min(max(54, state.preferences.maxInputHeight), max(54, Double(max(1, state.input.count / 42 + state.input.components(separatedBy: "\n").count)) * state.preferences.fontSize * 1.3 + 12)))
            HStack(spacing: 12) {
                Button { state.speak(state.input) } label: { UIReferenceIcon(name: "tw_action_audio", fallback: "speaker.wave.2").frame(width: 12, height: 12) }.bobTooltip("朗读原文")
                Button { state.copy(state.input) } label: { UIReferenceIcon(name: "tw_action_copy", fallback: "doc.on.doc").frame(width: 12, height: 12) }.bobTooltip("复制原文")
                if !state.input.isEmpty && state.preferences.sourceLanguage == "auto" {
                    HStack(spacing: 3) { Text("识别为").foregroundStyle(.tertiary); Text(LanguageCatalog.title(TextUtilities.detectLanguage(state.input))).foregroundStyle(.blue) }.font(.system(size: 10))
                }
                Spacer()
                Button(action: submitSource) { Image(systemName: "arrow.right") }.bobTooltip("翻译（Enter）").disabled(state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless).padding(.horizontal, 3).padding(.bottom, 3)
        }.padding(8).background(panelColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ocrWorkspace: some View {
        HStack(spacing: 12) {
            if state.showsOCRImages {
                OCRImageListView(state: state).frame(minWidth: 300, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                InputEditor(text: Binding(get: { state.input }, set: { state.updateOCRText($0) }), fontSize: state.preferences.fontSize, onSubmit: submitSource)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = state.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !state.recognizing, state.ocrImages.selected?.status == .failed {
                    Button("重新识别") { state.retryOCRImages(state.ocrImages.selectedID) }
                }
                if state.canResumeOCRImages {
                    Button("继续识别") { state.resumeOCRImages() }
                }
                if state.recognizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在识别…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(state.ocrImages.qrCodes.enumerated()), id: \.offset) { _, value in
                    HStack {
                        Image(systemName: "qrcode")
                        Text(value).textSelection(.enabled).lineLimit(3)
                        Spacer()
                        Button("复制") { state.copy(value) }
                    }.font(.system(size: 12))
                }
            }.padding(10).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                .background(panelColor, in: RoundedRectangle(cornerRadius: 8))
        }.padding(.horizontal, 12).padding(.bottom, 8).frame(minHeight: 330, maxHeight: .infinity)
    }

    private var pinnedServices: [ServiceConfig] {
        state.preferences.services.filter { $0.enabled && $0.capability == "translate" && state.preferences.pinnedServiceIDs.contains($0.id) }
    }

    private var languageBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                languageMenu(code: state.preferences.sourceLanguage, source: true)
                Spacer(minLength: 4)
                Button(action: state.swapLanguages) { UIReferenceIcon(name: "tw_exchange", fallback: "arrow.left.arrow.right").frame(width: 13, height: 13) }.buttonStyle(.borderless).bobTooltip("交换语言")
                Spacer(minLength: 4)
                languageMenu(code: state.preferences.autoTargetLanguage ? "auto" : state.preferences.targetLanguage, source: false)
            }.padding(.horizontal, 6).padding(.vertical, 4).background(panelColor, in: RoundedRectangle(cornerRadius: 7))
            ForEach(pinnedServices.prefix(4)) { service in
                Button { state.translateService(service.id) } label: { UIReferenceIcon(name: UIReferenceAssets.serviceName(service)).frame(width: 17, height: 17) }
                    .buttonStyle(.borderless).bobTooltip(service.name)
            }
            if pinnedServices.count > 4 {
                Menu {
                    ForEach(Array(pinnedServices.dropFirst(4))) { service in Button(service.name) { state.translateService(service.id) } }
                } label: { Image(systemName: "ellipsis").frame(width: 17, height: 17) }
                .menuStyle(.borderlessButton).fixedSize().bobTooltip("更多固定服务")
            }
        }.font(.system(size: 11))
         .onChange(of: state.preferences.sourceLanguage) { _, _ in state.savePreferences() }
         .onChange(of: state.preferences.targetLanguage) { _, _ in state.savePreferences() }
    }

    private func languageMenu(code: String, source: Bool) -> some View {
        LanguageSelector(code: code, allowAuto: true, title: source ? "原文语言" : "译文语言", favorites: state.preferences.favoriteLanguages) { value in
            if source { state.preferences.sourceLanguage = value }
            else { state.preferences.autoTargetLanguage = value == "auto"; if value != "auto" { state.preferences.targetLanguage = value } }
            state.savePreferences()
        }
    }
}

private struct PanelContentHeight: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

private struct ResultCardView: View {
    let card: ResultCard
    let serviceIcon: String
    let fontSize: Double
    let copy: (String) -> Void
    let speak: (String) -> Void
    let dictionaryAudio: (DictionaryResult.Audio?, String) -> Void
    let retry: () -> Void
    let insert: (String) -> Void
    let canInsert: Bool
    let showInsert: Bool
    let copyStyles: [String]
    let lookup: (String) -> Void
    let linkConfirmation: String
    let expanded: Bool
    let pinned: Bool
    let markdownEnabled: Bool
    let remoteImages: Bool
    let defaultShowReasoning: Bool
    let toggleExpanded: () -> Void
    let togglePinned: () -> Void
    @ViewState private var reasoningExpanded = false
    @ViewState private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                UIReferenceIcon(name: serviceIcon).frame(width: 14, height: 14)
                Text(card.name).font(.system(size: 11))
                Spacer()
                if (hovering || pinned) {
                    Button(action: togglePinned) { Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 10)) }.bobTooltip(pinned ? "取消钉住服务" : "钉住服务")
                }
                if card.loading { ProgressView().controlSize(.mini) }
                Button(action: toggleExpanded) { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10)) }.bobTooltip(expanded ? "折叠服务" : "展开服务")
            }.buttonStyle(.borderless)
            if expanded {
                if let error = card.error {
                    Text(error).foregroundStyle(.orange).font(.system(size: 12)).textSelection(.enabled)
                    Button("重试", action: retry).font(.system(size: 11))
                } else {
                    if let reasoning = card.reasoning, !reasoning.isEmpty {
                        DisclosureGroup("思考过程", isExpanded: $reasoningExpanded) {
                            ResultContentView(text: reasoning, format: "markdown", fontSize: max(11, fontSize - 2), markdownEnabled: markdownEnabled, linkConfirmation: linkConfirmation).foregroundStyle(.secondary)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if card.loading && card.text.isEmpty { Text("正在翻译…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else if card.dictionary?.plainText != card.text { ResultContentView(text: card.text, format: card.format, fontSize: fontSize, markdownEnabled: markdownEnabled, remoteImages: remoteImages, linkConfirmation: linkConfirmation) }
                    if let dictionary = card.dictionary {
                        DictionaryResultView(dictionary: dictionary, fontSize: fontSize, speak: dictionaryAudio, lookup: lookup)
                    } else {
                        if let pronunciation = card.pronunciation { Text(pronunciation).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                        ForEach(card.details, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    HStack(spacing: 12) {
                        Button { speak(card.text) } label: { UIReferenceIcon(name: "tw_action_audio", fallback: "speaker.wave.2").frame(width: 12, height: 12) }.bobTooltip("朗读译文")
                        Button { copy(card.text) } label: { UIReferenceIcon(name: "tw_action_copy", fallback: "doc.on.doc").frame(width: 12, height: 12) }.bobTooltip("复制译文")
                        if showInsert { Button { insert(card.text) } label: { UIReferenceIcon(name: "tw_action_insert", fallback: "rectangle.portrait.and.arrow.right").frame(width: 12, height: 12) }.bobTooltip("将译文插入原文位置").disabled(!canInsert) }
                        if !copyStyles.isEmpty && card.text.range(of: "[A-Za-z]", options: .regularExpression) != nil {
                            ForEach(copyStyles, id: \.self) { style in Button { copy(Self.formattedCopy(card.text, style: style)) } label: { UIReferenceIcon(name: style == "camelCase" ? "tw_action_copy_camel" : style == "PascalCase" ? "tw_action_copy_upper_camel" : style == "snake_case" ? "tw_action_copy_snake" : style == "kebab-case" ? "tw_action_copy_kebab" : "tw_action_copy_macro").frame(width: 14, height: 14) }.bobTooltip("复制为 " + style) }
                        }
                        Spacer()
                    }.font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }.padding(9).background(PopPalette.panel, in: RoundedRectangle(cornerRadius: 8))
         .onAppear { reasoningExpanded = defaultShowReasoning }
         .onHover { hovering = $0 }
         .contextMenu {
             Button(pinned ? "取消钉住服务" : "钉住服务", action: togglePinned)
             Button(expanded ? "折叠服务" : "展开服务", action: toggleExpanded)
         }
    }
    private static func formattedCopy(_ text: String, style: String) -> String {
        let spaced = text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = spaced.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { $0.lowercased() }
        switch style {
        case "camelCase": return (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case "PascalCase": return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case "snake_case": return words.joined(separator: "_")
        case "kebab-case": return words.joined(separator: "-")
        default: return words.joined(separator: "_").uppercased()
        }
    }

}

struct HistoryView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack {
            HStack {
                TextField("搜索原文和译文", text: $state.historySearch).textFieldStyle(.roundedBorder)
                Toggle("仅收藏", isOn: $state.favoritesOnly).toggleStyle(.checkbox)
                Button("导出") { exportHistory() }
                Button("清空") { state.history = []; state.saveHistory() }
            }.padding()
            List(state.filteredHistory) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(item.source).font(.headline).lineLimit(3)
                        Spacer()
                        Button { state.toggleFavorite(item.id) } label: { Image(systemName: item.favorite ? "star.fill" : "star") }.buttonStyle(.borderless).foregroundStyle(item.favorite ? .orange : .secondary)
                        Button("载入") { state.loadHistory(item) }.buttonStyle(.borderless)
                    }
                    ForEach(item.results.keys.sorted(), id: \.self) { key in Text("\(key)：\(item.results[key] ?? "")").lineLimit(3).foregroundStyle(.secondary) }
                    Text(item.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                }.padding(.vertical, 7)
            }
        }
    }
    private func exportHistory() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Pop历史.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted; try encoder.encode(state.filteredHistory).write(to: url) }
        catch { state.notice = error.localizedDescription }
    }
}

struct OCRImageView: View {
    let image: NSImage
    let document: OCRDocument
    let showBoxes: Bool
    let translations: [Int: String]
    var onTextClick: ((String) -> Void)? = nil
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                ForEach(Array(document.lines.enumerated()), id: \.offset) { index, line in
                    let imageRatio = image.size.width / max(image.size.height, 1)
                    let containerRatio = geometry.size.width / max(geometry.size.height, 1)
                    let width = containerRatio > imageRatio ? geometry.size.height * imageRatio : geometry.size.width
                    let height = width / max(imageRatio, 0.01)
                    let offsetX = (geometry.size.width - width) / 2
                    let offsetY = (geometry.size.height - height) / 2
                    if let translated = translations[index] {
                        Text(translated).font(.system(size: max(9, min(18, height * line.height * 0.65))))
                            .padding(2).frame(width: max(18, width * line.width), alignment: .leading)
                            .background(.regularMaterial)
                            .position(x: offsetX + width * (line.x + line.width / 2), y: offsetY + height * (1 - line.y - line.height / 2))
                    } else if showBoxes {
                        Rectangle().stroke(.blue.opacity(0.7), lineWidth: 1)
                            .frame(width: width * line.width, height: height * line.height)
                            .contentShape(Rectangle())
                            .onTapGesture { onTextClick?(line.text) }
                            .position(x: offsetX + width * (line.x + line.width / 2), y: offsetY + height * (1 - line.y - line.height / 2))
                    }
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct InputEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = InputScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = SubmitTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        view.minSize = NSSize(width: 0, height: 54)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 3, height: 5)
        view.delegate = context.coordinator
        view.onSubmit = onSubmit
        scroll.needsLayout = true
        view.setAccessibilityLabel("原文输入")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SubmitTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = .labelColor
        view.onSubmit = onSubmit
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputEditor
        init(_ parent: InputEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView, parent.text != view.string { parent.text = view.string }
        }
    }
}

private final class InputScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, contentSize.width > 20, contentSize.height > 0 else { return }
        text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height)))
        text.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    }
}

private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.intersection([.shift, .command]).isEmpty && !hasMarkedText() { onSubmit?() }
        else if event.keyCode == 36 && event.modifierFlags.contains(.command) && !hasMarkedText() { insertNewline(nil) }
        else { super.keyDown(with: event) }
    }
}

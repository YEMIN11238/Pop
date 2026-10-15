import AppKit
import Combine
import SwiftUI
import Translation
import UniformTypeIdentifiers

@main
struct PopMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--plugin-worker") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in await PluginProcessIsolation.runWorker(); exit(0) }
            CFRunLoopRun()
            return
        }
        if CommandLine.arguments.contains("--self-check") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                var checks: [String] = []
                do {
                    checks = try FeatureSelfCheck.run()
                    checks += try await FeatureSelfCheck.runDictionary()
                    checks += try await FeatureSelfCheck.runServiceStrategies()
                    checks += try ScreenshotSelfCheck.run()
                    checks += try ScreenshotPresentationSelfCheck.run()
                    checks += try ImportFileTransactionSelfCheck.run()
                    checks += try await PopTransientFeedbackSelfCheck.run()
                    checks += try ServiceDraftOfflineSelfCheck.run()
                    checks += try BobSettingsPickerSelfCheck.run()
                    checks += try SettingsSidebarSelfCheck.run()
                    checks += try ImageFilePanelSelfCheck.run()
                    checks += try ImageFilePanelLifecycleSelfCheck.run()
                    checks += try OCRImageCollectionSelfCheck.run()
                    checks += try OCRWindowLayoutSelfCheck.run()
                    checks += try await OCRImageQueueSelfCheck.run()
                    checks += try OriginalTextSelfCheck.run()
                    checks += try AIMessageBuilderSelfCheck.run()
                    checks += try CloudServiceCatalogSelfCheck.run()
                    checks += try ProviderTranslationModelsSelfCheck.run()
                    checks += try await ServiceManagementSelfCheck.run()
                    checks += try await NetworkProxySelfCheck.run()
                    checks += try await NetworkProxyPluginSelfCheck.run()
                    checks += try await HTTPServiceSelfCheck.run()
                    checks += try await CloudMediaSelfCheck.run()
                    checks += try await PluginSelfCheck.run()
                    checks += try await NativeSelfCheck.run()
                    checks += try await SystemTranslationCooldownSelfCheck.run()
                    checks += try await RendererSelfCheck.run()
                    let availability = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
                    if #available(macOS 26.0, *), availability == .installed {
                        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
                        let response = try await session.translate("Hello, world!")
                        guard !response.targetText.isEmpty else { throw PopError.message("系统翻译返回空结果。") }
                        checks.append("Apple installed language model produced a nonempty translation")
                    } else { checks.append("Apple language availability checked; first-use language download remains a user action") }
                    let result: [String: Any] = ["passed": true, "checks": checks, "count": checks.count,
                                               "completedAt": ISO8601DateFormatter().string(from: Date()),
                                               "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unpackaged",
                                               "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unpackaged",
                                               "liveCloudAPIsTested": false, "screenPermissionsRequested": false]
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    FileHandle.standardOutput.write(data)
                    print()
                    exit(0)
                } catch {
                    let failure = error as NSError
                    let result: [String: Any] = ["passed": false, "checks": checks, "count": checks.count,
                                               "completedAt": ISO8601DateFormatter().string(from: Date()),
                                               "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unpackaged",
                                               "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unpackaged",
                                               "error": failure.localizedDescription, "errorDomain": failure.domain, "errorCode": failure.code,
                                               "liveCloudAPIsTested": false, "screenPermissionsRequested": false]
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(data); print() }
                    fputs("Self-check failed: \(failure.domain) (\(failure.code)): \(failure.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            CFRunLoopRun()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    static weak var shared: AppDelegate?
    let state = AppState()
    let ocrState = AppState(windowRole: "ocr")
    private var statusItem: NSStatusItem?
    private var statusContent: StatusBarContentView?
    private var mainWindow: NSWindow?
    private var ocrWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var extraWindows: [(NSWindow, AppState)] = []
    private var hotkeys: GlobalHotkeys?
    private var recordingShortcut = false
    private var preferencesObserver: AnyCancellable?
    private var ocrLayoutObserver: AnyCancellable?
    private var ocrWindowLayout = OCRWindowLayout()
    private static let ocrCompactWidthKey = "PopOCRCompactWidthV2"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let content = StatusBarContentView(frame: button.bounds)
            content.autoresizingMask = [.width, .height]
            content.onClick = { [weak self] right in self?.statusClicked(right: right) }
            content.onImages = { [weak self] urls in
                guard let self else { return }
                let translate = self.state.preferences.statusImageDropAction == "translate"
                (translate ? self.state : self.ocrState).recognize(urls: urls, translateAfter: translate, silent: false)
            }
            content.onImageData = { [weak self] data in
                guard let self else { return }
                let translate = self.state.preferences.statusImageDropAction == "translate"
                do { try (translate ? self.state : self.ocrState).recognizeImageData(data, translate: translate, silent: false) }
                catch { self.state.notice = error.localizedDescription; self.showMain() }
            }
            button.addSubview(content); statusContent = content
        }
        applyGeneralPreferences()
        state.onShowWindow = { [weak self] in self?.showMain() }
        state.isWindowVisible = { [weak self] in self?.mainWindow?.isVisible == true }
        state.onPinChange = { [weak self] _ in guard let self else { return }; self.applyWindowBehavior(self.mainWindow, model: self.state) }
        state.onCloseWindow = { [weak self] in self?.mainWindow?.orderOut(nil) }
        state.onShortcutsChanged = { [weak self] in self?.registerShortcuts() }
        state.onContentHeight = { [weak self] height in self?.resizePanel(self?.mainWindow, height: height) }
        ocrState.mode = "ocr"
        ocrState.onShowWindow = { [weak self] in self?.showOCR() }
        ocrState.isWindowVisible = { [weak self] in self?.ocrWindow?.isVisible == true }
        ocrState.onPinChange = { [weak self] _ in guard let self else { return }; self.applyWindowBehavior(self.ocrWindow, model: self.ocrState) }
        ocrState.onCloseWindow = { [weak self] in self?.ocrWindow?.orderOut(nil) }
        ocrState.onShortcutsChanged = { [weak self] in self?.registerShortcuts() }
        ocrState.onContentHeight = { [weak self] height in self?.resizePanel(self?.ocrWindow, height: height) }
        ocrLayoutObserver = ocrState.$showsOCRImages.combineLatest(ocrState.$ocrImages)
            .map { $0 && !$1.tasks.isEmpty }.removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateOCRWindowLayout() }
            }
        preferencesObserver = ConfigurationRepository.shared.$preferences.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyGeneralPreferences()
                self.applyWindowBehavior(self.mainWindow, model: self.state)
                self.applyWindowBehavior(self.ocrWindow, model: self.ocrState)
                for (window, model) in self.extraWindows { self.applyWindowBehavior(window, model: model) }
            }
        }
        hotkeys = GlobalHotkeys { [weak self] action in self?.dispatch(action) }
        registerShortcuts()
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutRecordingChanged(_:)), name: BobShortcutRecorder.recordingDidChange, object: nil)
        state.savePreferences()
        LocalDiagnostics.record("application_started")
        showSettings()
        if let index = CommandLine.arguments.firstIndex(of: "--demo-text"), CommandLine.arguments.indices.contains(index + 1) {
            state.input = CommandLine.arguments[index + 1]
            showMain()
        }
    }

    private func window(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.center()
        return window
    }

    @objc func showMain() {
        if mainWindow == nil {
            let created = window(title: "Pop", size: NSSize(width: 410, height: 680))
            created.contentView = NSHostingView(rootView: MainView(state: state, showSettings: { [weak self] in self?.showSettings() }))
            configureTranslationPanel(created)
            created.delegate = self
            created.setFrameAutosaveName("PopMainTranslationWindow")
            mainWindow = created
        }
        if let window = mainWindow, !window.isVisible || state.windowPositionOverride != nil {
            positionPanel(window, policy: state.windowPositionOverride ?? state.preferences.windowPosition)
            state.windowPositionOverride = nil
        }
        applyWindowBehavior(mainWindow, model: state)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if state.mode != "history" {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.mainWindow, let content = window.contentView else { return }
                func editor(in view: NSView) -> NSTextView? {
                    if let text = view as? NSTextView, text.isEditable { return text }
                    return view.subviews.lazy.compactMap { editor(in: $0) }.first
                }
                if let input = editor(in: content) { window.makeFirstResponder(input) }
            }
        }
    }

    @objc func showOCR() {
        ocrState.mode = "ocr"
        if ocrWindow == nil {
            ocrWindowLayout = OCRWindowLayout(savedCompactWidth: CGFloat(UserDefaults.standard.double(forKey: Self.ocrCompactWidthKey)))
            let visible = ocrState.showsOCRImages && !ocrState.ocrImages.tasks.isEmpty
            let initialFrame = ocrWindowLayout.frame(from: NSRect(x: 0, y: 0, width: 400, height: 620),
                                                     showImage: visible, screen: NSScreen.main?.visibleFrame)
            let created = window(title: "Pop · OCR", size: initialFrame.size)
            created.contentView = NSHostingView(rootView: MainView(state: ocrState, showSettings: { [weak self] in
                guard let self else { return }
                self.state.settingsSection = self.ocrState.settingsSection
                self.showSettings()
            }, ocrRole: true))
            configureTranslationPanel(created)
            created.delegate = self
            // Legacy frames may already have been expanded twice. The canonical
            // width below is persisted separately from this mode-specific frame.
            created.setFrameAutosaveName("PopOCRWindowV2")
            ocrWindow = created
        }
        updateOCRWindowLayout()
        if let window = ocrWindow, !window.isVisible || ocrState.windowPositionOverride != nil {
            positionPanel(window, policy: ocrState.windowPositionOverride ?? ocrState.preferences.ocrWindowPosition)
            ocrState.windowPositionOverride = nil
        }
        applyWindowBehavior(ocrWindow, model: ocrState)
        ocrWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func translateOCRText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ocrState.notice = "没有可翻译的识别文字。"
            showOCR()
            return
        }
        state.clearInput()
        state.input = text
        state.mode = "translate"
        state.windowPositionOverride = state.preferences.windowPosition
        state.inputDisplayOverride = state.preferences.screenshotInputDisplay
        showMain()
        state.translate()
    }

    private func dispatch(_ action: HotkeyAction) {
        switch action {
        case .screenshotOCR, .silentOCR, .continuousOCR, .fileOCR, .pasteboardOCR, .showOCRWindow:
            ocrState.handle(action)
        default: state.handle(action)
        }
    }

    private func model(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        if window == mainWindow { return state }
        if window == ocrWindow { return ocrState }
        return extraWindows.first(where: { $0.0 == window })?.1
    }

    private func configureTranslationPanel(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.contentMinSize = NSSize(width: 340, height: 260)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 12
        window.contentView?.layer?.masksToBounds = true
    }

    private func resizePanel(_ window: NSWindow?, height: Double) {
        guard let window, height.isFinite else { return }
        let limit = window.screen?.visibleFrame.height ?? 800
        let model = self.model(for: window) ?? state
        guard model.windowRole != "ocr" || model.ocrImages.tasks.isEmpty else { return }
        let configured = model.preferences.maxWindowHeightFraction > 0 ? limit * model.preferences.maxWindowHeightFraction : model.preferences.maxWindowHeight
        let next = CGFloat(min(max(260, height), max(260, min(configured, limit - 8))))
        guard abs(window.frame.height - next) > 2 else { return }
        DispatchQueue.main.async { [weak window, weak model] in
            guard let window, let model,
                  model.windowRole != "ocr" || model.ocrImages.tasks.isEmpty else { return }
            var frame = window.frame
            frame.origin.y += frame.height - next
            frame.size.height = next
            window.setFrame(frame, display: true)
        }
    }

    private func updateOCRWindowLayout() {
        guard let window = ocrWindow else { return }
        let visible = ocrState.showsOCRImages && !ocrState.ocrImages.tasks.isEmpty
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        ocrWindowLayout.apply(to: window, showImage: visible, screen: screen)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === ocrWindow else { return }
        ocrWindowLayout.recordUserResize(width: window.frame.width)
        UserDefaults.standard.set(Double(ocrWindowLayout.compactWidth), forKey: Self.ocrCompactWidthKey)
    }

    private func positionPanel(_ window: NSWindow, policy: String) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? window.screen ?? NSScreen.main
        guard let screen else { return }
        let bounds = screen.visibleFrame
        var frame = window.frame
        switch policy {
        case "mouse": frame.origin = NSPoint(x: mouse.x + 10, y: mouse.y - frame.height - 10)
        case "center": frame.origin = NSPoint(x: bounds.midX - frame.width / 2, y: bounds.midY - frame.height / 2)
        case "left": frame.origin = NSPoint(x: bounds.minX, y: bounds.midY - frame.height / 2)
        case "right": frame.origin = NSPoint(x: bounds.maxX - frame.width, y: bounds.midY - frame.height / 2)
        case "topLeft": frame.origin = NSPoint(x: bounds.minX, y: bounds.maxY - frame.height)
        case "topRight": frame.origin = NSPoint(x: bounds.maxX - frame.width, y: bounds.maxY - frame.height)
        case "bottomLeft": frame.origin = NSPoint(x: bounds.minX, y: bounds.minY)
        case "bottomRight": frame.origin = NSPoint(x: bounds.maxX - frame.width, y: bounds.minY)
        case "statusIconBottom":
            if let button = statusItem?.button, let host = button.window {
                let rect = host.convertToScreen(button.convert(button.bounds, to: nil))
                frame.origin = NSPoint(x: rect.midX - frame.width / 2, y: rect.minY - frame.height - 5)
            }
        default: break
        }
        let model = self.model(for: window) ?? state
        let visibleBounds = policy == "last" ? (NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })?.visibleFrame ?? bounds) : bounds
        let screenBounds = model.preferences.removeScreenMargins ? visibleBounds : visibleBounds.insetBy(dx: 8, dy: 8)
        frame.size.height = min(frame.height, screenBounds.height)
        frame.origin.x = max(screenBounds.minX, min(frame.origin.x, screenBounds.maxX - frame.width))
        frame.origin.y = max(screenBounds.minY, min(frame.origin.y, screenBounds.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let model = self.model(for: window)
        guard let model, model.preferences.hideOnBlur, !model.pinned,
              !NativeImageFilePanel.suppressesAutoHide(of: window) else { return }
        DispatchQueue.main.async { [weak window, weak model] in
            guard let window, let model, !window.isKeyWindow, !model.pinned, model.preferences.hideOnBlur,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !NativeImageFilePanel.suppressesAutoHide(of: window) else { return }
            if let key = NSApp.keyWindow, window.childWindows?.contains(key) == true { return }
            window.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            state.settingsSection = "translate"
            return
        }
        if let index = extraWindows.firstIndex(where: { $0.0 == window }) {
            extraWindows[index].1.cleanup()
            extraWindows.remove(at: index)
        } else { model(for: window)?.cancelTranslation() }
    }

    @objc private func showPreferencesForActiveWindow() {
        if let model = model(for: NSApp.keyWindow) { state.settingsSection = model.windowRole == "ocr" ? "ocr" : "translate" }
        showSettings()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let created = window(title: "Pop 设置", size: NSSize(width: 925, height: 700))
            created.titleVisibility = .hidden
            created.delegate = self
            created.contentMinSize = NSSize(width: 820, height: 580)
            created.isMovableByWindowBackground = false
            created.setFrameAutosaveName("PopPreferencesWindowV3")
            created.contentView = NSHostingView(rootView: SettingsView(state: state))
            created.backgroundColor = .windowBackgroundColor
            created.contentView?.wantsLayer = true
            SettingsWindowChrome.install(on: created)
            settingsWindow = created
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newWindow() {
        let model = AppState()
        model.preferences = state.preferences
        let created = window(title: "Pop · 新翻译", size: NSSize(width: 410, height: 680))
        created.contentView = NSHostingView(rootView: MainView(state: model, showSettings: { [weak self, weak model] in
            guard let self, let model else { return }; self.state.settingsSection = model.settingsSection; self.state.settingsServiceCategory = model.settingsServiceCategory; self.showSettings()
        }))
        model.onShowWindow = { [weak created] in created?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        model.isWindowVisible = { [weak created] in created?.isVisible == true }
        model.onPinChange = { [weak self, weak created, weak model] _ in guard let model else { return }; self?.applyWindowBehavior(created, model: model) }
        model.onCloseWindow = { [weak created] in created?.orderOut(nil) }
        model.onContentHeight = { [weak self, weak created] height in self?.resizePanel(created, height: height) }
        configureTranslationPanel(created)
        created.delegate = self
        extraWindows.append((created, model))
        applyWindowBehavior(created, model: model)
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func shortcutRecordingChanged(_ notification: Notification) {
        recordingShortcut = notification.userInfo?["recording"] as? Bool ?? false
        if recordingShortcut { hotkeys?.unregister() } else { registerShortcuts() }
    }

    private func applyWindowBehavior(_ window: NSWindow?, model: AppState) {
        guard let window else { return }
        window.level = model.pinned ? (model.preferences.enhancedWindowLevel ? .statusBar : .floating) : .normal
        window.collectionBehavior = model.pinned && model.preferences.pinToDesktop ? [.fullScreenAuxiliary] : [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    private func registerShortcuts() {
        hotkeys?.unregister()
        guard !recordingShortcut else { return }
        state.shortcutErrors = HotkeyAction.allCases.compactMap { action in
            let custom = state.shortcuts[String(action.rawValue)]
            return hotkeys?.register(action: action, keyCode: custom?.keyCode ?? action.defaultKeyCode,
                                     modifiers: custom?.modifiers ?? action.defaultModifiers)
        }
        // The menu is created on click so changed shortcut labels are current.
    }

    private func applyGeneralPreferences() {
        let preferences = state.preferences
        statusItem?.isVisible = !preferences.hideStatusItem
        let image: NSImage?
        switch preferences.statusIconStyle {
        case "custom": image = NSImage(contentsOfFile: preferences.statusIconPath)
        case "letter": image = NSImage(systemSymbolName: "p.circle.fill", accessibilityDescription: "Pop")
        case "translate": image = NSImage(systemSymbolName: "translate", accessibilityDescription: "翻译")
        case "badge": image = NSImage(systemSymbolName: "p.square.fill", accessibilityDescription: "Pop")
        default: image = Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        }
        statusContent?.image = image ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Pop")
        NetworkProxy.configure(preferences: preferences)
    }

    private func statusClicked(right: Bool) {
        let action = right ? state.preferences.statusRightClickAction : "menu"
        let mapping: [String: HotkeyAction] = ["selection": .selection, "screenshotTranslation": .screenshotTranslation,
            "input": .input, "clipboardTranslation": .clipboardTranslation, "showTranslationWindow": .showTranslationWindow,
            "screenshotOCR": .screenshotOCR, "silentOCR": .silentOCR, "fileOCR": .fileOCR,
            "pasteboardOCR": .pasteboardOCR, "showOCRWindow": .showOCRWindow, "showPreferences": .showPreferences]
        if let action = mapping[action] { dispatch(action); return }
        guard let view = statusContent else { return }
        makeStatusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY), in: view)
    }

    func chooseStatusIcon() {
        let panel = NSOpenPanel()
        panel.title = "自定义菜单栏图标"; panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            let destination = AppStorage.directory.appendingPathComponent("status-icon.png")
            try FileManager.default.createDirectory(at: AppStorage.directory, withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            state.preferences.statusIconPath = destination.path; state.preferences.statusIconStyle = "custom"
            state.savePreferences()
        } catch { state.notice = error.localizedDescription }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        func shortcut(_ action: HotkeyAction) -> String {
            let label = state.shortcuts[String(action.rawValue)]?.label ?? action.defaultShortcut
            return label == "未设置" ? "" : "  " + label
        }
        let actions: [(String, Selector)] = [
            ("输入翻译" + shortcut(.input), #selector(inputTranslation)), ("划词翻译" + shortcut(.selection), #selector(selectionTranslation)),
            ("截图翻译" + shortcut(.screenshotTranslation), #selector(screenshotTranslation)), ("截图 OCR" + shortcut(.screenshotOCR), #selector(screenshotOCR)),
            ("静默截图 OCR" + shortcut(.silentOCR), #selector(silentOCR)), ("选图 OCR…", #selector(chooseImages)),
            ("剪贴板 OCR" + shortcut(.pasteboardOCR), #selector(pasteboardOCR)), ("显示 OCR 窗口" + shortcut(.showOCRWindow), #selector(showOCR)),
            ("静默划词翻译" + shortcut(.silentSelection), #selector(silentSelectionTranslation)), ("静默输入框翻译" + shortcut(.silentInput), #selector(silentInputTranslation)),
            ("原位图片翻译" + shortcut(.imageTranslation), #selector(locatedImageTranslation)), ("连续截图 OCR" + shortcut(.continuousOCR), #selector(continuousScreenshotOCR)),
            ("撤销上次回填", #selector(undoLastReplacement)),
            ("新翻译窗口", #selector(newWindow)), ("历史与收藏", #selector(showHistory))
        ]
        for (title, action) in actions { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let quit = NSMenuItem(title: "退出 Pop", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        return menu
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 Pop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        let setting = NSMenuItem(title: "设置…", action: #selector(showPreferencesForActiveWindow), keyEquivalent: ","); setting.target = self; appMenu.addItem(setting)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 Pop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu; main.addItem(appItem)
        let actionItem = NSMenuItem(); let actions = NSMenu(title: "操作")
        let commands: [(String, Selector, String)] = [
            ("重试", #selector(retryActiveTranslation), "r"),
            ("收藏 / 取消收藏", #selector(favoriteActiveTranslation), "s"),
            ("交换语言", #selector(swapActiveLanguages), ""),
            ("朗读", #selector(speakActiveTranslation), ""),
            ("增大字号", #selector(increaseActiveFont), "+"),
            ("减小字号", #selector(decreaseActiveFont), "-"),
            ("钉住 / 取消钉住窗口", #selector(pinActiveWindow), "p"),
            ("关闭翻译窗口", #selector(closeActiveTranslation), "\u{1b}")
        ]
        for (title, selector, key) in commands {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            if key == "\u{1b}" { item.keyEquivalentModifierMask = [] }
            actions.addItem(item)
        }
        actionItem.submenu = actions; main.addItem(actionItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (name, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                     ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                     ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: name, action: selector, keyEquivalent: key))
        }
        editItem.submenu = edit; main.addItem(editItem)
        let windowsItem = NSMenuItem(); let windows = NSMenu(title: "窗口")
        windows.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let new = NSMenuItem(title: "新翻译窗口", action: #selector(newWindow), keyEquivalent: "n"); new.target = self; windows.addItem(new)
        windowsItem.submenu = windows; main.addItem(windowsItem)
        NSApp.mainMenu = main
    }

    @objc private func inputTranslation() { state.handle(.input) }
    @objc private func selectionTranslation() { state.handle(.selection) }
    @objc private func screenshotTranslation() { state.handle(.screenshotTranslation) }
    @objc private func screenshotOCR() { dispatch(.screenshotOCR) }
    @objc private func silentOCR() { dispatch(.silentOCR) }
    @objc private func silentSelectionTranslation() { state.handle(.silentSelection) }
    @objc private func silentInputTranslation() { state.handle(.silentInput) }
    @objc private func locatedImageTranslation() { state.handle(.imageTranslation) }
    @objc private func continuousScreenshotOCR() { dispatch(.continuousOCR) }
    @objc private func pasteboardOCR() { dispatch(.pasteboardOCR) }
    @objc private func undoLastReplacement() { state.undoReplacement() }
    @objc private func chooseImages() { recognizeFinderSelection() }
    @objc private func showHistory() { state.settingsSection = "history"; showSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private var activeState: AppState { model(for: NSApp.keyWindow) ?? state }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let windowActions: [Selector] = [#selector(retryActiveTranslation), #selector(favoriteActiveTranslation),
                                         #selector(swapActiveLanguages), #selector(speakActiveTranslation),
                                         #selector(increaseActiveFont), #selector(decreaseActiveFont),
                                         #selector(pinActiveWindow), #selector(closeActiveTranslation)]
        if let action = menuItem.action, windowActions.contains(action) { return model(for: NSApp.keyWindow) != nil }
        return true
    }
    @objc private func retryActiveTranslation() { activeState.retry() }
    @objc private func favoriteActiveTranslation() { activeState.favoriteCurrentTranslation() }
    @objc private func swapActiveLanguages() { activeState.swapLanguages() }
    @objc private func speakActiveTranslation() { activeState.speak(activeState.results.first(where: { !$0.text.isEmpty })?.text ?? activeState.input) }
    @objc private func increaseActiveFont() { activeState.preferences.fontSize = min(19, max(14, activeState.preferences.fontSize + 1)); activeState.savePreferences() }
    @objc private func decreaseActiveFont() { activeState.preferences.fontSize = min(19, max(14, activeState.preferences.fontSize - 1)); activeState.savePreferences() }
    @objc private func pinActiveWindow() { activeState.setPinned(!activeState.pinned) }
    @objc private func closeActiveTranslation() { model(for: NSApp.keyWindow)?.dismissWindow() }

    func application(_ application: NSApplication, open urls: [URL]) {
        var images: [URL] = []
        for url in urls {
            if url.scheme == "pop" { _ = route(url) }
            else if url.pathExtension == "bobplugin" {
                do { let plugin = try PluginService.shared.importPlugin(from: url); state.notice = "已安装 \(plugin.name)。请在设置中添加对应服务。"; showSettings() }
                catch { state.notice = error.localizedDescription; showMain() }
            } else if url.pathExtension == "popconfig" || url.pathExtension == "yibanconfig" { state.importConfiguration(url: url); showSettings() }
            else if url.pathExtension.lowercased() == "popbackup" { state.importBackup(url: url); showSettings() }
            else { images.append(url) }
        }
        if !images.isEmpty { ocrState.recognize(urls: images, translateAfter: false, silent: false) }
    }

    func route(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "invalid URL" }
        let values = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { _, next in next })
        if components.host == "ocr", let path = values["path"] {
            ocrState.recognize(urls: [URL(fileURLWithPath: path)], translateAfter: false, silent: false)
        } else {
            state.input = values["text"] ?? ""
            if let source = values["source"] { state.preferences.sourceLanguage = source }
            if let target = values["target"] { state.preferences.targetLanguage = target; state.preferences.autoTargetLanguage = false }
            state.mode = "translate"; showMain(); state.translate()
        }
        return "accepted"
    }

    func scriptRequest(_ string: String) -> String {
        do {
            let request = try ExternalRequest.parse(string)
            let model = request.path == "ocr" ? ocrState : state
            model.windowPositionOverride = request.windowLocation
            model.inputDisplayOverride = request.inputBoxState
            if let source = request.source { model.preferences.sourceLanguage = source }
            if let target = request.target { model.preferences.targetLanguage = target; model.preferences.autoTargetLanguage = false }
            switch (request.path, request.action) {
            case ("translate", "selectionTranslate"): state.handle(.selection)
            case ("translate", "silentSelectionTranslate"): state.handle(.silentSelection)
            case ("translate", "silentInputBoxTranslate"): state.handle(.silentInput)
            case ("translate", "snipTranslate"): state.handle(.screenshotTranslation)
            case ("translate", "imageTranslate"): state.handle(.imageTranslation)
            case ("translate", "inputTranslate"): state.handle(.input)
            case ("translate", "pasteboardTranslate"): state.translateClipboard()
            case ("translate", "translateText"), ("translate", "translate"):
                state.input = request.text; state.mode = "translate"; showMain(); state.translate()
            case ("translate", "translateImage"):
                try state.recognizeImageData(request.imageData!, translate: true, silent: request.isSilent)
            case ("ocr", "snipOCR"): ocrState.capture(translate: false, silent: request.isSilent)
            case ("ocr", "continuousOCR"): ocrState.capture(translate: false, silent: request.isSilent, append: true)
            case ("ocr", "pasteboardOCR"): ocrState.recognizeClipboard(silent: request.isSilent)
            case ("ocr", "fileOCR"): recognizeFinderSelection()
            case ("ocr", "ocrImage"): try ocrState.recognizeImageData(request.imageData!, translate: false, silent: request.isSilent)
            case (_, "showWindow"):
                model.mode = request.path == "ocr" ? "ocr" : "translate"; model.queryRevision += 1
                if request.path == "ocr" { showOCR() } else { showMain() }
            default: throw PopError.message("不支持的脚本动作。")
            }
            return ExternalRequest.reply(status: "accepted")
        } catch { return ExternalRequest.reply(status: "error", message: error.localizedDescription) }
    }

    func recognizeFinderSelection() {
        // Bob's documented "Finder image OCR" opens a multi-select file panel;
        // it does not read Finder's current selection or require automation access.
        NSApp.activate(ignoringOtherApps: true)
        ocrState.chooseImages()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregister()
        SpeechPlayer.shared.stop()
        state.cleanup()
        ocrState.cleanup()
        preferencesObserver?.cancel()
        for (_, model) in extraWindows { model.cleanup() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}

@objc(PopTranslateCommand)
final class PopTranslateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let text = directParameter as? String ?? ""
        DispatchQueue.main.async {
            guard let delegate = AppDelegate.shared else { return }
            delegate.state.input = text; delegate.state.mode = "translate"
            delegate.showMain(); delegate.state.translate()
        }
        return nil
    }
}

@objc(PopRequestCommand)
final class PopRequestCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let text = directParameter as? String ?? ""
        if Thread.isMainThread { return MainActor.assumeIsolated { AppDelegate.shared?.scriptRequest(text) ?? "{\"status\":\"unavailable\"}" } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { AppDelegate.shared?.scriptRequest(text) ?? "{\"status\":\"unavailable\"}" } }
    }
}

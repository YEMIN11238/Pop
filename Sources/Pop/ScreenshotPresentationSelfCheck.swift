import AppKit

/// Exercises presentation state without opening a window, invoking OCR, or
/// accessing the screen, clipboard, credentials or persistent preferences.
@MainActor
enum ScreenshotPresentationSelfCheck {
    static func run() throws -> [String] {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PopError.message("截图显示自检：" + message) }
        }

        let tips = ScreenshotTipsView()
        func labels() -> [String] { tips.subviews.compactMap { ($0 as? NSTextField)?.stringValue } }
        try require(labels() == ["退出截图"], "尚未开始选择时显示了 Space/D")
        let restingHeight = tips.frame.height
        tips.update(selectionStarted: true)
        try require(labels() == ["退出截图", "按住整体移动截图区域", "锁定截图位置并退出截图"] && tips.frame.height > restingHeight,
                    "开始选择后提示没有展开")
        tips.update(selectionStarted: false)
        try require(labels() == ["退出截图"] && tips.frame.height == restingHeight,
                    "返回悬停后仍保留拖选提示或高度")

        for (translate, silent, append) in [(true, false, false), (false, false, false), (false, false, true), (false, true, false)] {
            let state = AppState(windowRole: translate ? "translation" : "ocr")
            state.preferences.saveHistory = false
            state.preferences.autoCopyOCR = false
            state.preferences.autoCopyTranslationOCR = false
            state.preferences.hideSilentOCRLoading = true
            state.input = "previous text"
            state.ocrDocument = OCRDocument(text: "previous text", lines: [], qrCodes: [])
            state.results = [ResultCard(serviceID: UUID(), name: "previous result", text: "old", loading: false)]
            state.inputDisplayOverride = "alwaysFold"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pop-unread-presentation-\(UUID().uuidString).png")
            var shows = 0
            var loadingAtShow = false
            state.onShowWindow = {
                shows += 1
                loadingAtShow = state.recognizing && state.working && state.results.isEmpty && state.ocrDocument == nil
                    && state.imageURL == url && state.recognizingService?.capability == "ocr"
                    && state.input == (append ? "previous text" : "")
                    && state.mode == (translate ? "translate" : "ocr")
            }
            state.recognize(urls: [url], translateAfter: translate, silent: silent, append: append)
            // No actor suspension occurs before cancellation: the provider task
            // cannot read this deliberately nonexistent file or start OCR.
            let pending = state.recognizing && state.working
            let explicitInputPresentation = state.inputDisplayOverride
            state.cancelTranslation()
            state.onShowWindow = nil
            try require(pending && shows == (silent ? 0 : 1) && (silent || loadingAtShow),
                        "普通识别未在 provider 前显示新加载状态，或静默识别打开窗口")
            try require(explicitInputPresentation == "alwaysFold", "识别入口覆盖了显式输入框显示参数")
            try require(!state.recognizing && state.recognizingService == nil && !state.working,
                        "取消识别后仍残留加载状态")
        }
        return [
            "截图提示：未开始选择仅 Esc 退出截图，开始选择显示 Space/D，回到悬停恢复单行和高度（REA 0x1004fa1c8）。",
            "OCR 显示时序：普通翻译/独立OCR在 provider 前显示新加载状态，连续OCR保留待追加内容；静默OCR不打开窗口，取消清除加载状态。未访问屏幕、剪贴板或识别服务。"
        ]
    }
}

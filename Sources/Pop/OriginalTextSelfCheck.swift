import Foundation

/// Exercises request creation through AppState. No view attaches a system
/// translation task, so the Apple service only publishes a request/configuration.
@MainActor
enum OriginalTextSelfCheck {
    static func run() throws -> [String] {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PopError.message("原文传递自检：" + message) }
        }
        let state = AppState()
        defer { state.cleanup() }
        let service = ServiceConfig.system
        var preferences = AppPreferences()
        preferences.services = [service]
        preferences.sourceLanguage = "en"
        preferences.targetLanguage = "zh-Hans"
        preferences.autoTargetLanguage = false
        preferences.removeCommentMarkers = true
        preferences.mergeLineBreaks = true
        preferences.normalizeIdentifiers = false
        preferences.saveHistory = false
        preferences.autoSpeakSource = false
        preferences.autoCopyFirstResult = false
        preferences.autoCopyOCR = false
        preferences.autoCopyTranslationOCR = false
        state.preferences = preferences

        let original = "// first\n// second"
        let processed = "first second"
        state.input = original
        state.translate()
        try expect(state.input == processed && state.systemRequest?.text == processed,
                   "真实 AppState 没有执行注释移除与换行合并")
        try expect(state.systemRequest?.originalText == original && state.systemRequest?.source == "en" && state.systemRequest?.target == "zh-Hans",
                   "普通查询未保留处理前原文或语言对")

        state.retry()
        try expect(state.systemRequest?.text == processed && state.systemRequest?.originalText == original,
                   "无输入改动的整次重试丢失处理前原文")
        // The system session is deliberately never run. Mark the card finished
        // in memory to exercise the same retry gate as a completed translation.
        state.results[0].loading = false
        state.systemRequest = nil
        state.translateService(service.id)
        try expect(state.systemRequest?.text == processed && state.systemRequest?.originalText == original,
                   "无输入改动的单卡重试丢失处理前原文")

        let equivalentNewInput = " first second\n"
        state.input = equivalentNewInput
        state.results[0].loading = false
        state.systemRequest = nil
        state.translateService(service.id)
        try expect(state.systemRequest?.text == processed && state.systemRequest?.originalText == equivalentNewInput,
                   "规范化结果相同的新输入被单卡重试误判为旧查询")

        // Selection and clipboard acquisition both assign the newly captured
        // text, even when its value matches the currently displayed input.
        try expect(state.input == processed, "新采集场景前输入未规范化")
        state.input = processed
        state.translate()
        try expect(state.systemRequest?.text == processed && state.systemRequest?.originalText == processed,
                   "新采集内容等于显示文本时仍残留上一轮原文")

        return [
            "原文传递：真实 AppState 预处理后分别构造 text/originalText 通过；未调用系统翻译 API。",
            "原文传递：无输入改动的整次重试与单服务重试均保留处理前原文通过。",
            "原文传递：不同原文规范化为相同文本时，单服务重试重建新原文请求通过。",
            "原文传递：新采集赋值等于当前显示值时清除旧原文通过；未操作界面、剪贴板、取词或持久化配置。"
        ]
    }
}

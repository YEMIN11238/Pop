import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

/// The text and QR detection run on a worker task. No camera or screen access is involved
/// when recognizing an image file supplied by the user.
enum VisionOCR {
    static func recognize(
        url: URL,
        accurate: Bool,
        languages: [String],
        languageCorrection: Bool,
        recognizeQRCodes: Bool = true
    ) async throws -> OCRDocument {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                throw PopError.message("图片文件不存在，或当前路径不是本地文件。")
            }

            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = accurate ? .accurate : .fast
            textRequest.usesLanguageCorrection = languageCorrection
            textRequest.automaticallyDetectsLanguage = true
            // Fast and accurate recognition support different language sets. Avoid
            // forwarding unsupported preference values to Vision, which can fail the job.
            let supported = try textRequest.supportedRecognitionLanguages()
            let chosen = supportedLanguages(requested: languages, supported: supported)
            if !chosen.isEmpty { textRequest.recognitionLanguages = chosen }

            let barcodeRequest = VNDetectBarcodesRequest()
            barcodeRequest.symbologies = [.qr]
            // The URL initializer lets Vision honor the image's orientation metadata.
            let handler = VNImageRequestHandler(url: url, options: [:])
            try handler.perform(recognizeQRCodes ? [textRequest, barcodeRequest] : [textRequest])
            try Task.checkCancellation()

            let detected = (textRequest.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first,
                      !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let rect = observation.boundingBox
                return OCRLine(
                    text: candidate.string,
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.width,
                    height: rect.height,
                    confidence: candidate.confidence
                )
            }
            let lines = readingOrder(detected)
            var qrCodes: [String] = []
            for barcode in barcodeRequest.results ?? [] {
                if let payload = barcode.payloadStringValue, !qrCodes.contains(payload) {
                    qrCodes.append(payload)
                }
            }
            return OCRDocument(text: OCRTextLayout.text(from: lines), lines: lines, qrCodes: qrCodes)
        }
        return try await withTaskCancellationHandler {
            let document = try await worker.value
            try Task.checkCancellation()
            return document
        } onCancel: {
            worker.cancel()
        }
    }

    private static func supportedLanguages(requested: [String], supported: [String]) -> [String] {
        var output: [String] = []
        for language in requested where language != "auto" {
            let lower = language.lowercased()
            let match = supported.first { $0.lowercased() == lower }
                ?? supported.first { $0.lowercased().hasPrefix(lower + "-") }
            if let match, !output.contains(match) { output.append(match) }
        }
        return output
    }

    /// Orders horizontal rows and clear multi-column layouts using shared OCR heuristics.
    static func readingOrder(_ input: [OCRLine]) -> [OCRLine] { OCRTextLayout.orderedLines(input) }

}

@MainActor
enum NativeSelection {
    static func selectedText(mode: String = "smart") async throws -> String {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else {
            throw PopError.message("划词取词需要辅助功能权限。请在设置中开启 Pop 的辅助功能权限，再重新选中文字。")
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw PopError.message("请先在其他软件中选中文字，再按划词翻译快捷键。")
        }
        let timing = SelectionTiming.resolve(mode: mode, applicationID: application.bundleIdentifier)
        return try await copySelection(from: application.processIdentifier, timing: timing)
    }

    private static func accessibilitySelection(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String, !text.isEmpty {
            return text
        }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range {
            var substring: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                range,
                &substring
            ) == .success {
                return substring as? String
            }
        }
        return nil
    }

    private static func copySelection(from processID: pid_t, timing: SelectionTiming) async throws -> String {
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        var oldCount = pasteboard.changeCount
        // Preserve every format that is materialized on the pasteboard, including
        // rich text and images. Delayed/promise providers cannot be reconstructed.
        let snapshot: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type] = value }
            }
            return data
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            throw PopError.message("取词时前台软件发生变化，请重新选中文字后再试。")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            throw PopError.message("系统无法创建复制事件，请直接复制文字后使用输入翻译。")
        }
        var copiedCount: Int?
        defer {
            // A separate user copy may happen during this operation. Restore only
            // while our observed clipboard version is still current.
            if let copiedCount, pasteboard.changeCount == copiedCount {
                pasteboard.clearContents()
                let restored = snapshot.map { data -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, value) in data { item.setData(value, forType: type) }
                    return item
                }
                if !restored.isEmpty { pasteboard.writeObjects(restored) }
            }
        }
        for _ in 0..<timing.attempts {
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
                throw PopError.message("取词时前台软件发生变化，请重新选中文字后再试。")
            }
            oldCount = pasteboard.changeCount
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            for _ in 0..<timing.polls {
                // Observe a posted Copy even if the caller cancels, then restore
                // its pasteboard version before propagating cancellation.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
                }
                if pasteboard.changeCount != oldCount {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
                        throw PopError.message("取词时前台软件发生变化，请重新选中文字后再试。")
                    }
                    copiedCount = pasteboard.changeCount
                    if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try Task.checkCancellation()
                        return text
                    }
                    break
                }
            }
        }
        try Task.checkCancellation()
        throw PopError.message("当前软件没有提供所选文字。请手动复制文字，或使用截图翻译。")
    }
}

enum NativeScreenshot {
    @MainActor static func captureRegion() async throws -> URL {
        try await captureLocatedRegion().url
    }
}

@MainActor
final class SpeechPlayer {
    static let shared = SpeechPlayer()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, language: String, rate: Float? = nil, voiceID: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let code: String
        if language == "auto" || language.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            code = recognizer.dominantLanguage?.rawValue ?? "en"
        } else {
            code = language
        }
        let canonical = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "en": "en-US" ][code] ?? code
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: canonical)
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(code + "-") }
        utterance.rate = rate.map { max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, $0)) } ?? AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

enum HotkeyAction: UInt32, CaseIterable, Identifiable {
    case selection = 1, screenshotTranslation, input, screenshotOCR, silentOCR
    case silentSelection = 6, silentInput, continuousOCR, imageTranslation
    case clipboardTranslation = 10, showTranslationWindow, fileOCR, pasteboardOCR, showOCRWindow, showPreferences
    var id: UInt32 { rawValue }

    var displayTitle: String {
        switch self {
        case .selection: return "划词翻译"
        case .screenshotTranslation: return "截图翻译"
        case .input: return "输入翻译"
        case .screenshotOCR: return "截图 OCR"
        case .silentOCR: return "静默截图 OCR"
        case .silentSelection: return "静默划词翻译"
        case .silentInput: return "静默输入框翻译"
        case .continuousOCR: return "连续截图 OCR"
        case .imageTranslation: return "原图翻译"
        case .clipboardTranslation: return "剪贴板翻译"
        case .showTranslationWindow: return "显示翻译窗口"
        case .fileOCR: return "访达选图 OCR"
        case .pasteboardOCR: return "剪贴板 OCR"
        case .showOCRWindow: return "显示 OCR 窗口"
        case .showPreferences: return "偏好设置"
        }
    }

    var defaultKeyCode: UInt32 {
        switch self {
        case .selection: return UInt32(kVK_ANSI_D)
        case .screenshotTranslation, .screenshotOCR: return UInt32(kVK_ANSI_S)
        case .input: return UInt32(kVK_ANSI_A)
        case .silentOCR: return UInt32(kVK_ANSI_C)
        case .silentSelection, .silentInput, .continuousOCR, .imageTranslation, .clipboardTranslation, .showTranslationWindow, .fileOCR, .pasteboardOCR, .showOCRWindow, .showPreferences: return UInt32.max
        }
    }

    var defaultModifiers: UInt32 {
        self == .screenshotOCR ? UInt32(optionKey | shiftKey) : UInt32(optionKey)
    }

    var defaultShortcut: String {
        switch self {
        case .selection: return "⌥ D"
        case .screenshotTranslation: return "⌥ S"
        case .input: return "⌥ A"
        case .screenshotOCR: return "⇧ ⌥ S"
        case .silentOCR: return "⌥ C"
        case .silentSelection, .silentInput, .continuousOCR, .imageTranslation, .clipboardTranslation, .showTranslationWindow, .fileOCR, .pasteboardOCR, .showOCRWindow, .showPreferences: return "未设置"
        }
    }
}

private let popHotkeySignature: OSType = 0x5969626E // Yibn

private let popHotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotkey = EventHotKeyID()
    let result = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey
    )
    guard result == noErr, hotkey.signature == popHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let owner = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
    let actionID = hotkey.id
    DispatchQueue.main.async { owner.dispatch(actionID: actionID) }
    return noErr
}

@MainActor
final class GlobalHotkeys {
    private let handler: (HotkeyAction) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotkeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var registeredBindings: [HotkeyAction: (keyCode: UInt32, modifiers: UInt32)] = [:]

    init(handler: @escaping (HotkeyAction) -> Void) { self.handler = handler }

    @discardableResult
    func registerDefaults() -> [String] {
        unregister()
        return HotkeyAction.allCases.compactMap {
            register(action: $0, keyCode: $0.defaultKeyCode, modifiers: $0.defaultModifiers)
        }
    }

    /// Registers one combination, replacing only this action's previous key.
    /// Carbon modifiers are required (optionKey, cmdKey, controlKey, shiftKey).
    @discardableResult
    func register(action: HotkeyAction, keyCode: UInt32, modifiers: UInt32) -> String? {
        if keyCode == UInt32.max {
            if let previous = hotkeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(previous) }
            registeredBindings.removeValue(forKey: action)
            return nil
        }
        if let binding = registeredBindings[action], hotkeyRefs[action] != nil,
           binding.keyCode == keyCode, binding.modifiers == modifiers { return nil }
        let previousBinding = registeredBindings[action]
        if let previous = hotkeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(previous) }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), popHotkeyCallback, 1, &eventType,
                Unmanaged.passUnretained(self).toOpaque(), &eventHandler
            )
            if status != noErr { return "无法初始化全局快捷键（\(status)）。" }
        }
        var reference: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: popHotkeySignature, id: action.rawValue)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference
        )
        guard status == noErr, let reference else {
            registeredBindings.removeValue(forKey: action)
            if let previousBinding {
                var restored: EventHotKeyRef?
                let restoration = RegisterEventHotKey(
                    previousBinding.keyCode, previousBinding.modifiers, hotkeyID,
                    GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &restored
                )
                if restoration == noErr, let restored {
                    hotkeyRefs[action] = restored
                    registeredBindings[action] = previousBinding
                }
            }
            return "\(action.displayTitle)的快捷键注册失败（\(status)），可能已被其他软件占用。"
        }
        hotkeyRefs[action] = reference
        registeredBindings[action] = (keyCode, modifiers)
        return nil
    }

    func unregister() {
        for reference in hotkeyRefs.values { UnregisterEventHotKey(reference) }
        hotkeyRefs.removeAll()
        registeredBindings.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    fileprivate func dispatch(actionID: UInt32) {
        guard let action = HotkeyAction(rawValue: actionID), hotkeyRefs[action] != nil else { return }
        handler(action)
    }

    deinit {
        for reference in hotkeyRefs.values { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

struct PermissionStatus {
    let accessibility: Bool
    let screenRecording: Bool
    var summary: String {
        "辅助功能：\(accessibility ? "已授权" : "未授权")；屏幕录制：\(screenRecording ? "已授权" : "未授权")"
    }
}

@MainActor
enum PermissionHelper {
    static func status() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openAccessibility() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openScreenRecording() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private static func openPrivacyPane(_ name: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)") {
            NSWorkspace.shared.open(url)
        }
    }
}

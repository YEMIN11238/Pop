import AppKit
import Carbon
import SwiftUI

/// A compact recorder with the four modifier positions kept visible, including
/// when no shortcut is assigned. UInt32.max represents an explicitly cleared key.
struct BobShortcutRecorder: NSViewRepresentable {
    static let recordingDidChange = Notification.Name("PopShortcutRecorderRecordingDidChange")
    let config: ShortcutConfig?
    let defaultKeyCode: UInt32
    let defaultModifiers: UInt32
    let onRecord: (ShortcutConfig) -> Void
    let onClear: () -> Void

    init(config: ShortcutConfig?, defaultKeyCode: UInt32, defaultModifiers: UInt32,
         onRecord: @escaping (ShortcutConfig) -> Void, onClear: @escaping () -> Void) {
        self.config = config
        self.defaultKeyCode = defaultKeyCode
        self.defaultModifiers = defaultModifiers
        self.onRecord = onRecord
        self.onClear = onClear
    }

    func makeNSView(context: Context) -> BobShortcutRecorderControl {
        let view = BobShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BobShortcutRecorderControl, context: Context) {
        view.onRecord = onRecord
        view.onClear = onClear
        view.isEnabled = context.environment.isEnabled
        view.update(config ?? ShortcutConfig(keyCode: defaultKeyCode, modifiers: defaultModifiers, label: ""))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BobShortcutRecorderControl, context: Context) -> CGSize? {
        CGSize(width: 190, height: 28)
    }

    static func dismantleNSView(_ view: BobShortcutRecorderControl, coordinator: ()) {
        view.finishRecording(restoreFocus: false)
    }
}

@MainActor
final class BobShortcutRecorderControl: NSControl {
    var onRecord: ((ShortcutConfig) -> Void)?
    var onClear: (() -> Void)?

    private var shortcut = ShortcutConfig(keyCode: UInt32.max, modifiers: 0, label: "未设置")
    private var recording = false
    private var pendingModifiers: UInt32 = 0
    private var needsModifier = false
    private var eventMonitor: Any?
    private var inactiveObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?
    private let clearButton = NSButton()
    private let activeColor = NSColor.systemBlue
    private let inactiveColor = NSColor(calibratedWhite: 0.68, alpha: 1)
    private let modifierSymbols: [(String, UInt32)] = [
        ("⌃", UInt32(controlKey)), ("⌥", UInt32(optionKey)),
        ("⇧", UInt32(shiftKey)), ("⌘", UInt32(cmdKey))
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除快捷键")
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.contentTintColor = NSColor(calibratedWhite: 0.74, alpha: 1)
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.toolTip = "清除快捷键"
        clearButton.setAccessibilityLabel("清除快捷键")
        addSubview(clearButton)
        toolTip = "点击录入快捷键；Esc 取消，Delete 清除。组合键须包含至少一个修饰键。"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("快捷键")
        setAccessibilityHelp(toolTip)
        update(shortcut)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 28) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        clearButton.frame = NSRect(x: bounds.width - 25, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    func update(_ config: ShortcutConfig) {
        shortcut = config
        clearButton.isHidden = config.keyCode == UInt32.max
        clearButton.isEnabled = isEnabled
        let name = keyName(config)
        setAccessibilityValue(config.keyCode == UInt32.max ? "未设置" : Self.label(modifiers: config.modifiers, key: name))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.65).setFill()
        outline.fill()
        (recording ? activeColor.withAlphaComponent(0.65) : NSColor(calibratedWhite: 0.83, alpha: 0.65)).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let flags = recording ? pendingModifiers : (shortcut.keyCode == UInt32.max ? 0 : shortcut.modifiers)
        for (index, item) in modifierSymbols.enumerated() {
            drawText(item.0, rect: NSRect(x: 8 + CGFloat(index) * 17, y: 0, width: 18, height: bounds.height),
                     font: .systemFont(ofSize: 17, weight: .medium),
                     color: flags & item.1 != 0 && isEnabled ? activeColor : inactiveColor)
        }
        let text = recording ? (needsModifier ? "加修饰键" : "录入…") : keyName(shortcut)
        drawText(text, rect: NSRect(x: 81, y: 0, width: max(0, bounds.width - 109), height: bounds.height),
                 font: .systemFont(ofSize: recording ? 11 : 16, weight: .regular),
                 color: recording || !isEnabled ? inactiveColor : activeColor)
    }

    private func drawText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let height = font.ascender - font.descender
        let frame = NSRect(x: rect.minX, y: rect.midY - height / 2 - 0.5, width: rect.width, height: height + 2)
        (text as NSString).draw(in: frame, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { startRecording() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        startRecording()
        return true
    }

    private func startRecording() {
        guard isEnabled, let window else { return }
        let wasRecording = recording
        if !recording { previousResponder = window.firstResponder === self ? nil : window.firstResponder }
        guard window.makeFirstResponder(self) else { return }
        recording = true
        if !wasRecording {
            NotificationCenter.default.post(name: BobShortcutRecorder.recordingDidChange, object: self, userInfo: ["recording": true])
        }
        pendingModifiers = Self.carbonModifiers(NSEvent.modifierFlags)
        needsModifier = false
        needsDisplay = true
        setAccessibilityValue("正在录入快捷键")
        guard eventMonitor == nil else { return }
        // A local monitor captures Command combinations before application menus
        // process them. It exists only while this specific control is recording.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.finishRecording(restoreFocus: false)
                }
                return event
            }
            guard event.window === self.window, self.window?.firstResponder === self else { return event }
            if event.type == .flagsChanged {
                self.pendingModifiers = Self.carbonModifiers(event.modifierFlags)
                self.needsModifier = false
                self.needsDisplay = true
                return event
            }
            self.record(event)
            return nil
        }
        inactiveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecording(restoreFocus: false) }
        }
    }

    func finishRecording(restoreFocus: Bool) {
        let wasRecording = recording
        recording = false
        needsModifier = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver); self.inactiveObserver = nil }
        if restoreFocus, window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
        update(shortcut)
        if wasRecording {
            NotificationCenter.default.post(name: BobShortcutRecorder.recordingDidChange, object: self, userInfo: ["recording": false])
        }
    }

    override func resignFirstResponder() -> Bool {
        finishRecording(restoreFocus: false)
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { finishRecording(restoreFocus: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if recording { record(event) }
        else if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) { startRecording() }
        else if Self.isDelete(event), Self.carbonModifiers(event.modifierFlags) == 0 { clearShortcut() }
        else { super.keyDown(with: event) }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { finishRecording(restoreFocus: true); return }
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        if Self.isDelete(event), modifiers == 0 { clearShortcut(); return }
        guard modifiers != 0 else {
            pendingModifiers = 0; needsModifier = true; needsDisplay = true
            setAccessibilityValue("请包含至少一个修饰键")
            return
        }
        let key = Self.keyName(UInt32(event.keyCode), event: event)
        let value = ShortcutConfig(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: Self.label(modifiers: modifiers, key: key))
        shortcut = value
        finishRecording(restoreFocus: true)
        onRecord?(value)
    }

    @objc private func clearShortcut() {
        guard isEnabled else { return }
        shortcut = ShortcutConfig(keyCode: UInt32.max, modifiers: 0, label: "未设置")
        finishRecording(restoreFocus: true)
        onClear?()
    }

    private func keyName(_ config: ShortcutConfig) -> String {
        guard config.keyCode != UInt32.max else { return "" }
        let saved = config.label.filter { !"⌃⌥⇧⌘".contains($0) }.trimmingCharacters(in: .whitespaces)
        return saved.isEmpty ? Self.keyName(config.keyCode) : saved
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func isDelete(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)
    }

    private static func label(modifiers: UInt32, key: String) -> String {
        let items: [(String, UInt32)] = [("⌃", UInt32(controlKey)), ("⌥", UInt32(optionKey)), ("⇧", UInt32(shiftKey)), ("⌘", UInt32(cmdKey))]
        return (items.compactMap { modifiers & $0.1 != 0 ? $0.0 : nil } + [key]).joined(separator: " ")
    }

    private static func keyName(_ keyCode: UInt32, event: NSEvent? = nil) -> String {
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 115: "↖", 117: "⌦",
            119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = special[keyCode] { return name }
        if let text = event?.charactersIgnoringModifiers, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0) }) {
            return text.uppercased()
        }
        let keys: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`", 65: ".", 67: "*", 69: "+", 75: "/",
            78: "−", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9"
        ]
        return keys[keyCode] ?? "Key \(keyCode)"
    }
}

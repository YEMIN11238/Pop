import AppKit
import ApplicationServices

/// The operation always binds to one editable AX element before translation starts.
/// It rejects changed content, changed focus, secure fields and unrelated foreground apps.
@MainActor
final class SelectionDestination {
    enum Scope { case selection, entireInput }

    private let element: AXUIElement
    private let processID: pid_t
    private let scope: Scope
    private let snapshot: EditableTextSnapshot
    private let supportsSelectedText: Bool
    private let supportsValue: Bool
    private let supportsRange: Bool
    private var replacement: ReplacementRecord?
    var originalText: String
    var canUndo: Bool { replacement != nil }

    private struct ReplacementRecord {
        let text: String
        let expectedValue: String?
        let selectedText: String?
        let selectedRange: NSRange?
    }

    private init(element: AXUIElement, processID: pid_t, scope: Scope,
                 snapshot: EditableTextSnapshot, selectedText: Bool, value: Bool, range: Bool) {
        self.element = element; self.processID = processID; self.scope = scope
        self.snapshot = snapshot; originalText = snapshot.text
        supportsSelectedText = selectedText; supportsValue = value; supportsRange = range
    }

    /// Compatible with the explicit result-card Insert action.
    static func capture() -> SelectionDestination? { try? capture(scope: .selection) }

    static func capture(scope: Scope) throws -> SelectionDestination {
        guard AXIsProcessTrusted() else {
            throw PopError.message("静默翻译与译文回填需要辅助功能权限，请在系统设置中为 Pop 开启。")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw PopError.message("请先在其他软件的可编辑输入框中选择文字或放置光标，再使用静默翻译。")
        }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.3)
        guard let element = focusedElement(in: target) else {
            throw PopError.message("无法读取当前输入框，请使用普通翻译后复制译文。")
        }
        AXUIElementSetMessagingTimeout(element, 0.3)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element) ?? ""
        guard !subrole.lowercased().contains("secure") && !subrole.lowercased().contains("password") else {
            throw PopError.message("密码输入框不能用于翻译或回填。")
        }
        let selectedSettable = isSettable(kAXSelectedTextAttribute, of: element)
        let valueSettable = isSettable(kAXValueAttribute, of: element)
        let rangeSettable = isSettable(kAXSelectedTextRangeAttribute, of: element)
        guard scope == .entireInput ? valueSettable : (selectedSettable || valueSettable) else {
            throw PopError.message("当前区域不是可回填的输入框，请使用普通翻译后复制译文。")
        }
        let value = stringAttribute(kAXValueAttribute, of: element)
        let range = selectedRange(of: element)
        var selected = stringAttribute(kAXSelectedTextAttribute, of: element)
        if selected == nil, let value, let range, EditableTextSnapshot.valid(range, in: value) {
            selected = (value as NSString).substring(with: range)
        }
        let text = scope == .entireInput ? value : selected
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PopError.message(scope == .entireInput ? "当前输入框没有可翻译的文字。" : "请先选中输入框中要翻译的文字。")
        }
        guard text.utf16.count <= 200_000 else {
            throw PopError.message("输入内容过长，请分段选取后翻译。")
        }
        if scope == .selection, !selectedSettable {
            guard let value, let range, EditableTextSnapshot.valid(range, in: value) else {
                throw PopError.message("当前软件未提供可验证的选区，已停止回填。")
            }
        }
        let snapshot = EditableTextSnapshot(text: text, value: value, selectedRange: range)
        return SelectionDestination(element: element, processID: app.processIdentifier, scope: scope,
                                    snapshot: snapshot, selectedText: selectedSettable,
                                    value: valueSettable, range: rangeSettable)
    }

    /// Silent actions should pass true. Explicit Insert may return from pop's own window.
    func replace(with text: String, requireOriginalAppInFront: Bool = false) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PopError.message("译文为空，已保留原输入内容。")
        }
        guard text.utf16.count <= 1_000_000 else { throw PopError.message("译文过长，已停止回填。") }
        try validateDestination(requireOriginalAppInFront: requireOriginalAppInFront)
        let currentValue = Self.stringAttribute(kAXValueAttribute, of: element)
        let currentSelection = Self.stringAttribute(kAXSelectedTextAttribute, of: element)
        let currentRange = Self.selectedRange(of: element)
        guard originalText == snapshot.text,
              snapshot.matches(value: currentValue, selection: currentSelection, range: currentRange, entireInput: scope == .entireInput) else {
            throw PopError.message("原输入内容或选区已经变化，已保留当前文字；请重新翻译。")
        }
        let expectedValue: String?
        if scope == .entireInput {
            expectedValue = text
            try set(kAXValueAttribute, value: text as CFString)
        } else if supportsSelectedText {
            expectedValue = snapshot.replacingSelection(with: text)
            try set(kAXSelectedTextAttribute, value: text as CFString)
        } else if supportsValue, let changed = snapshot.replacingSelection(with: text) {
            expectedValue = changed
            try set(kAXValueAttribute, value: changed as CFString)
            if supportsRange, let range = snapshot.selectedRange {
                setRange(NSRange(location: range.location + text.utf16.count, length: 0))
            }
        } else { throw PopError.message("当前输入框不支持直接替换，请复制译文后手动粘贴。") }
        replacement = ReplacementRecord(text: text, expectedValue: expectedValue,
                                        selectedText: Self.stringAttribute(kAXSelectedTextAttribute, of: element),
                                        selectedRange: Self.selectedRange(of: element))
        if !requireOriginalAppInFront { NSRunningApplication(processIdentifier: processID)?.activate() }
    }

    /// Reverts only this instance's latest successful fill; any later user edit refuses it.
    func undo(requireOriginalAppInFront: Bool = false) throws {
        guard let replacement else { throw PopError.message("没有可撤回的译文回填。") }
        try validateDestination(requireOriginalAppInFront: requireOriginalAppInFront)
        let currentValue = Self.stringAttribute(kAXValueAttribute, of: element)
        if let expected = replacement.expectedValue, let oldValue = snapshot.value {
            guard currentValue == expected else { throw PopError.message("回填后输入内容已经变化，不能自动撤回。") }
            if supportsValue { try set(kAXValueAttribute, value: oldValue as CFString) }
            else if supportsRange, supportsSelectedText, let range = snapshot.selectedRange {
                guard setRange(NSRange(location: range.location, length: replacement.text.utf16.count)) else {
                    throw PopError.message("无法恢复原选区，请使用原软件的撤销功能。")
                }
                try set(kAXSelectedTextAttribute, value: snapshot.text as CFString)
            } else { throw PopError.message("当前软件不支持安全撤回，请使用原软件的撤销功能。") }
            if supportsRange, let range = snapshot.selectedRange { setRange(range) }
        } else {
            let selected = Self.stringAttribute(kAXSelectedTextAttribute, of: element)
            let range = Self.selectedRange(of: element)
            guard supportsSelectedText, selected == replacement.text,
                  range == replacement.selectedRange else {
                throw PopError.message("当前软件未提供可验证的回填结果，请使用原软件的撤销功能。")
            }
            try set(kAXSelectedTextAttribute, value: snapshot.text as CFString)
        }
        self.replacement = nil
        if !requireOriginalAppInFront { NSRunningApplication(processIdentifier: processID)?.activate() }
    }

    private func validateDestination(requireOriginalAppInFront: Bool) throws {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else {
            throw PopError.message("原输入软件已退出或辅助功能权限不可用。")
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard front == processID || (!requireOriginalAppInFront && front == ProcessInfo.processInfo.processIdentifier) else {
            throw PopError.message("前台软件已经切换，已停止自动回填。")
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let focused = Self.focusedElement(in: application), CFEqual(focused, element) else {
            throw PopError.message("原软件的输入焦点已经变化，已停止自动回填。")
        }
    }
    private func set(_ attribute: String, value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success else {
            throw PopError.message("当前输入框拒绝回填，请复制译文后手动粘贴。")
        }
    }
    @discardableResult private func setRange(_ range: NSRange) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }
    private static func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func isSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

/// Pure UTF-16 validation used by AX and tests, including emoji and range boundaries.
struct EditableTextSnapshot {
    let text: String
    let value: String?
    let selectedRange: NSRange?
    func matches(value current: String?, selection: String?, range: NSRange?, entireInput: Bool) -> Bool {
        if let value, current != value { return false }
        if entireInput { return current == text }
        if let selectedRange, range != selectedRange { return false }
        if let selection { return selection == text }
        guard let current, let selectedRange, Self.valid(selectedRange, in: current) else { return false }
        return (current as NSString).substring(with: selectedRange) == text
    }
    func replacingSelection(with replacement: String) -> String? {
        guard let value, let selectedRange, Self.valid(selectedRange, in: value) else { return nil }
        return (value as NSString).replacingCharacters(in: selectedRange, with: replacement)
    }
    static func valid(_ range: NSRange, in text: String) -> Bool {
        let count = text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location else { return false }
        // CF/AX ranges use UTF-16. Explicitly reject a boundary between the two
        // units of a surrogate pair; Range(NSRange,in:) alone accepts this on some SDKs.
        let units = text.utf16
        func boundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < count else { return true }
            let index = units.index(units.startIndex, offsetBy: offset)
            let current = units[index], previous = units[units.index(before: index)]
            return !((0xDC00...0xDFFF).contains(current) && (0xD800...0xDBFF).contains(previous))
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }
}

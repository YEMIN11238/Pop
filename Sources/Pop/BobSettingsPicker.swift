import AppKit
import SwiftUI

/// Keep NSPopUpButton's real menu, keyboard navigation and accessibility while
/// drawing the compact, stable settings bezel used by the reference interface.
@MainActor
struct BobSettingsPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    let disabledValues: Set<Value>
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)], disabledValues: Set<Value> = []) {
        self.title = title; _selection = selection; self.options = options; self.disabledValues = disabledValues
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> BobSettingsPopUpButton {
        let view = BobSettingsPopUpButton(frame: NSRect(x: 0, y: 0, width: 138, height: 24), pullsDown: false)
        apply(to: view, coordinator: context.coordinator, enabled: isEnabled)
        return view
    }
    func updateNSView(_ view: BobSettingsPopUpButton, context: Context) {
        apply(to: view, coordinator: context.coordinator, enabled: isEnabled)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BobSettingsPopUpButton, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 138
        return CGSize(width: width, height: 24)
    }
    fileprivate func apply(to view: BobSettingsPopUpButton, coordinator: Coordinator, enabled: Bool) {
        coordinator.parent = self
        let changed = !coordinator.installedOptions.elementsEqual(options, by: { $0.0 == $1.0 && $0.1 == $1.1 })
        if changed || view.numberOfItems != options.count {
            // NSPopUpButton.addItems(withTitles:) reuses an existing item when a
            // title repeats. Languages and voices can share titles, so build
            // distinct menu items and preserve the value-to-item mapping.
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option.0, action: nil, keyEquivalent: "")
                item.tag = index
                menu.addItem(item)
            }
            view.menu = menu
            coordinator.installedOptions = options
        }
        let items = view.menu?.items ?? []
        if let index = options.firstIndex(where: { $0.1 == selection }), items.indices.contains(index) {
            view.select(items[index]); view.displayTitleOverride = nil
        }
        else { view.select(nil); view.displayTitleOverride = "未设置" }
        view.menu?.autoenablesItems = false
        for (item, option) in zip(items, options) { item.isEnabled = !disabledValues.contains(option.1) }
        view.target = coordinator; view.action = #selector(Coordinator.changed(_:))
        view.isEnabled = enabled; view.setAccessibilityLabel(title)
        view.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        var parent: BobSettingsPicker
        var installedOptions: [(String, Value)] = []
        init(_ parent: BobSettingsPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let item = sender.selectedItem, item.isEnabled else { return }
            let index = item.tag
            guard installedOptions.indices.contains(index), sender.menu?.items.contains(where: { $0 === item }) == true else { return }
            let value = installedOptions[index].1
            guard parent.options.contains(where: { $0.1 == value }), !parent.disabledValues.contains(value) else { return }
            if let view = sender as? BobSettingsPopUpButton { view.displayTitleOverride = nil; view.needsDisplay = true }
            parent.selection = value
        }
    }
}

final class BobSettingsPopUpButton: NSPopUpButton {
    var displayTitleOverride: String?
    override var intrinsicContentSize: NSSize { NSSize(width: 138, height: 24) }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shade: CGFloat = dark ? 62.0 / 255 : 229.0 / 255
        let pressed = isHighlighted ? (dark ? 0.05 : -0.04) : 0
        NSColor(srgbRed: shade + pressed, green: shade + pressed, blue: shade + pressed, alpha: isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let color = isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color, .paragraphStyle: paragraph]
        let text = (displayTitleOverride ?? title) as NSString
        let textHeight = text.size(withAttributes: attributes).height
        text.draw(in: NSRect(x: bounds.minX + 9, y: bounds.midY - textHeight / 2, width: max(0, bounds.width - 29), height: textHeight), withAttributes: attributes)
        let x = bounds.maxX - 11, y = bounds.midY
        let arrows = NSBezierPath(); arrows.lineWidth = 1.1; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
        arrows.move(to: NSPoint(x: x - 2.5, y: y + 2)); arrows.line(to: NSPoint(x: x, y: y + 4.5)); arrows.line(to: NSPoint(x: x + 2.5, y: y + 2))
        arrows.move(to: NSPoint(x: x - 2.5, y: y - 2)); arrows.line(to: NSPoint(x: x, y: y - 4.5)); arrows.line(to: NSPoint(x: x + 2.5, y: y - 2))
        color.setStroke(); arrows.stroke()
        if window?.firstResponder === self, NSApp.isFullKeyboardAccessEnabled {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5); focus.lineWidth = 1; focus.stroke()
        }
    }
}

@MainActor
enum BobSettingsPickerSelfCheck {
    static func run() throws -> [String] {
        var checks: [String] = []
        var value = "center"
        let picker = BobSettingsPicker("窗口位置", selection: Binding(get: { value }, set: { value = $0 }), options: [("屏幕中央", "center"), ("屏幕左侧", "left"), ("屏幕右侧", "right")])
        let coordinator = picker.makeCoordinator()
        let button = BobSettingsPopUpButton(frame: NSRect(x: 0, y: 0, width: 138, height: 24), pullsDown: false)
        picker.apply(to: button, coordinator: coordinator, enabled: true)
        guard button.numberOfItems == 3, button.indexOfSelectedItem == 0, button.title == "屏幕中央", button.intrinsicContentSize == NSSize(width: 138, height: 24) else { throw PopError.message("设置下拉框菜单或尺寸复核失败") }
        button.selectItem(at: 2); coordinator.changed(button)
        guard value == "right" else { throw PopError.message("设置下拉框未提交选中的真实选项") }
        value = "unknown"
        picker.apply(to: button, coordinator: coordinator, enabled: false)
        guard value == "unknown", button.indexOfSelectedItem == -1, !button.isEnabled else { throw PopError.message("设置下拉框错误改写未识别的配置") }
        checks.append("设置下拉框使用真实NSPopUpButton菜单，正确提交选择并保留未知配置值")

        let repeatedOptions = [("自动", "auto"), ("同名语言", "first"), ("同名语言", "second"), ("自动", "otherAuto"), ("", "emptyTitle")]
        value = "second"
        let repeated = BobSettingsPicker("重复标题", selection: Binding(get: { value }, set: { value = $0 }), options: repeatedOptions, disabledValues: ["first"])
        repeated.apply(to: button, coordinator: coordinator, enabled: true)
        let repeatedItems = button.menu?.items ?? []
        guard repeatedItems.count == repeatedOptions.count,
              repeatedItems.map(\.title) == repeatedOptions.map(\.0),
              repeatedItems.map(\.tag) == Array(repeatedOptions.indices),
              button.selectedItem === repeatedItems[2],
              !repeatedItems[1].isEnabled, repeatedItems[2].isEnabled else { throw PopError.message("设置下拉框未保留同名标题的独立菜单项") }
        button.select(repeatedItems[3]); coordinator.changed(button)
        guard value == "otherAuto" else { throw PopError.message("设置下拉框同名标题选中了错误的值") }
        button.select(repeatedItems[1]); coordinator.changed(button)
        guard value == "otherAuto" else { throw PopError.message("设置下拉框提交了禁用项") }
        checks.append("重复标题、自动项与空标题各保留独立菜单项，选择按值映射且禁用项不提交")

        let languages = LanguageCatalog.choices.map { ($0.1, $0.0) }
        guard languages.count >= 390, languages.contains(where: { $0.1 == "auto" }) else { throw PopError.message("完整语言目录复核未覆盖预期的语言集合") }
        value = "auto"
        let languagePicker = BobSettingsPicker("完整语言目录", selection: Binding(get: { value }, set: { value = $0 }), options: languages)
        languagePicker.apply(to: button, coordinator: coordinator, enabled: true)
        let languageItems = button.menu?.items ?? []
        guard languageItems.count == languages.count,
              languageItems.map(\.title) == languages.map(\.0),
              languageItems.map(\.tag) == Array(languages.indices),
              button.selectedItem === languageItems[languages.firstIndex(where: { $0.1 == "auto" })!] else { throw PopError.message("完整语言目录菜单丢失条目或顺序错误") }
        for (index, item) in languageItems.enumerated() {
            button.select(item); coordinator.changed(button)
            guard value == languages[index].1 else { throw PopError.message("完整语言目录选中值映射错误：\(index)") }
        }
        languagePicker.apply(to: button, coordinator: coordinator, enabled: true)
        guard button.numberOfItems == languages.count, button.indexOfSelectedItem == languages.count - 1 else { throw PopError.message("完整语言目录重复更新破坏了末尾选项") }
        checks.append("完整语言目录 \(languages.count) 项（含自动与同名语言）逐项选择及重复更新通过")

        let reversedOptions = Array(repeatedOptions.reversed())
        let reordered = BobSettingsPicker("动态菜单", selection: Binding(get: { value }, set: { value = $0 }), options: reversedOptions)
        value = "second"
        repeated.apply(to: button, coordinator: coordinator, enabled: true)
        reordered.apply(to: button, coordinator: coordinator, enabled: true)
        let reorderedItems = button.menu?.items ?? []
        guard reorderedItems.map(\.title) == reversedOptions.map(\.0), button.indexOfSelectedItem == 2 else { throw PopError.message("设置下拉框动态重排后未保留选择") }
        button.select(reorderedItems[0]); coordinator.changed(button)
        guard value == "emptyTitle" else { throw PopError.message("设置下拉框重排后仍使用了旧值映射") }
        let empty = BobSettingsPicker<String>("空菜单", selection: Binding(get: { value }, set: { value = $0 }), options: [])
        empty.apply(to: button, coordinator: coordinator, enabled: true)
        guard button.numberOfItems == 0, button.indexOfSelectedItem == -1, value == "emptyTitle", button.displayTitleOverride == "未设置" else { throw PopError.message("设置下拉框空集合未保留原配置") }
        languagePicker.apply(to: button, coordinator: coordinator, enabled: true)
        guard button.numberOfItems == languages.count, button.indexOfSelectedItem == -1, value == "emptyTitle" else { throw PopError.message("设置下拉框从空集合恢复时改写了未知配置") }
        checks.append("动态重排、相同数量更新、清空再恢复菜单均保留正确映射且不改写未知值")

        var optionalValue: UUID?
        let serviceID = UUID()
        let optionalPicker = BobSettingsPicker<UUID?>("可选服务", selection: Binding(get: { optionalValue }, set: { optionalValue = $0 }), options: [("自动", nil), ("自动", serviceID)])
        let optionalCoordinator = optionalPicker.makeCoordinator()
        optionalPicker.apply(to: button, coordinator: optionalCoordinator, enabled: true)
        let optionalItems = button.menu?.items ?? []
        guard optionalItems.count == 2, button.selectedItem === optionalItems[0] else { throw PopError.message("设置下拉框可选值自动项错误") }
        button.select(optionalItems[1]); optionalCoordinator.changed(button)
        guard optionalValue == serviceID else { throw PopError.message("设置下拉框未提交可选服务值") }
        optionalPicker.apply(to: button, coordinator: optionalCoordinator, enabled: false)
        button.select(optionalItems[0]); optionalCoordinator.changed(button)
        guard optionalValue == serviceID else { throw PopError.message("设置下拉框禁用控件仍提交了值") }
        checks.append("可选UUID与nil值的同名自动项正确映射，禁用控件不提交事件")
        return checks
    }
}

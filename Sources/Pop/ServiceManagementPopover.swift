import AppKit
import SwiftUI

enum ServiceManagementStrategy: String, CaseIterable {
    case normal, rememberCollapse, alwaysCollapsed, pinned
    var title: String {
        switch self {
        case .normal: return "普通模式"
        case .rememberCollapse: return "记住折叠状态"
        case .alwaysCollapsed: return "总是折叠"
        case .pinned: return "钉到语言栏"
        }
    }
    static func value(for service: ServiceConfig, preferences: AppPreferences) -> Self {
        if let raw = service.options["triggerStrategy"], let value = Self(rawValue: raw) { return value }
        return preferences.pinnedServiceIDs.contains(service.id) ? .pinned : .normal
    }
}

/// The popup commits only the controls it owns. Name/key/endpoint changes in a
/// different settings window are retained; concurrent list edits are rejected.
struct ServiceManagementDraft {
    struct Item: Equatable, Identifiable {
        var service: ServiceConfig
        var strategy: ServiceManagementStrategy
        var id: UUID { service.id }
    }
    var items: [Item]
    var ocrID: UUID?
    var ttsID: UUID?
    private let original: [Item]
    private let originalOCR: UUID?
    private let originalTTS: UUID?
    init(preferences: AppPreferences) {
        let list = preferences.services.filter { $0.capability == "translate" }.map {
            Item(service: $0, strategy: ServiceManagementStrategy.value(for: $0, preferences: preferences))
        }
        items = list; original = list
        ocrID = preferences.selectedOCRService(forTranslation: true)?.id; originalOCR = ocrID
        ttsID = preferences.selectedTTSService?.id; originalTTS = ttsID
    }
    var isDirty: Bool {
        items != original || ocrID != originalOCR || ttsID != originalTTS
    }
    mutating func move(id: UUID, before row: Int) -> Bool {
        guard let from = items.firstIndex(where: { $0.id == id }), (0...items.count).contains(row) else { return false }
        let target = row > from ? row - 1 : row
        guard from != target else { return false }
        let item = items.remove(at: from); items.insert(item, at: target); return true
    }
    func applying(to current: AppPreferences) throws -> AppPreferences {
        guard items.contains(where: { $0.service.enabled }) else { throw PopError.message("请至少开启 1 个文本翻译服务") }
        let now = current.services.filter { $0.capability == "translate" }
        guard now.map(\.id) == original.map(\.id), zip(now, original).allSatisfy({ service, old in
            service.enabled == old.service.enabled && ServiceManagementStrategy.value(for: service, preferences: current) == old.strategy
        }), current.selectedOCRService(forTranslation: true)?.id == originalOCR,
        current.selectedTTSService?.id == originalTTS else {
            throw PopError.message("服务已在其他窗口修改，请关闭面板后重新打开。")
        }
        var result = current
        let byID = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) })
        var replacements = items.map { item -> ServiceConfig in
            var service = byID[item.id] ?? item.service
            service.enabled = item.service.enabled; service.options["triggerStrategy"] = item.strategy.rawValue
            return service
        }.makeIterator()
        result.services = current.services.map { $0.capability == "translate" ? replacements.next()! : $0 }
        for item in items {
            result.pinnedServiceIDs.removeAll { $0 == item.id }
            if item.strategy == .pinned { result.pinnedServiceIDs.append(item.id) }
            if item.strategy == .alwaysCollapsed, !result.collapsedServiceIDs.contains(item.id) { result.collapsedServiceIDs.append(item.id) }
            if item.strategy == .normal { result.collapsedServiceIDs.removeAll { $0 == item.id } }
        }
        if let ocrID {
            guard current.ocrServices(forTranslation: true).contains(where: { $0.id == ocrID }) else { throw PopError.message("选择的文本识别服务已被删除。") }
            result.selectOCRService(ocrID, forTranslation: true)
        }
        if let ttsID {
            guard current.services.contains(where: { $0.id == ttsID && $0.capability == "tts" }) else { throw PopError.message("选择的语音合成服务已被删除。") }
            for index in result.services.indices where result.services[index].capability == "tts" { result.services[index].enabled = result.services[index].id == ttsID }
            result.ttsServiceID = ttsID
        }
        return result
    }
}

/// Replace the text-translation toolbar service menu with this view. The callback
/// receives translate/ocr/tts for the preferences capability to reveal.
struct ServiceManagementPopover: NSViewRepresentable {
    @ObservedObject var state: AppState
    var onShowSettings: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(state: state, onShowSettings: onShowSettings) }
    func makeNSView(context: Context) -> ServiceButton {
        let button = ServiceButton()
        button.isBordered = false; button.imagePosition = .imageOnly; button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator; button.action = #selector(Coordinator.toggle(_:))
        button.secondary = { [weak coordinator = context.coordinator] in coordinator?.openSettings("translate") }
        return button
    }
    func updateNSView(_ button: ServiceButton, context: Context) {
        context.coordinator.state = state; context.coordinator.onShowSettings = onShowSettings
        button.image = ToolbarIconLayout.image(UIReferenceAssets.image("tw_navigation_service", dark: context.environment.colorScheme == .dark)
            ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "服务管理"))
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel("服务管理，右键打开服务设置")
        BobTooltip.attach(to: button, text: "左键调整翻译服务，右键打开服务设置")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ServiceButton, context: Context) -> CGSize? {
        ToolbarIconLayout.fittingSize(proposal)
    }
    static func dismantleNSView(_ view: ServiceButton, coordinator: Coordinator) { coordinator.close() }
    final class ServiceButton: ToolbarIconButton {
        var secondary: () -> Void = {}
        override func rightMouseDown(with event: NSEvent) { secondary() }
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var state: AppState
        var onShowSettings: (String) -> Void
        private var popover: NSPopover?
        private var pending: AppPreferences?
        private var monitor: Any?
        private weak var owner: NSView?
        init(state: AppState, onShowSettings: @escaping (String) -> Void) { self.state = state; self.onShowSettings = onShowSettings }
        @objc func toggle(_ button: NSButton) {
            if popover?.isShown == true { close(); return }
            let draft = ServiceManagementDraft(preferences: state.preferences)
            let available = max(0, (button.window?.screen?.visibleFrame.height ?? 800) - 100)
            let controller = ServiceManagementController(draft: draft, preferences: state.preferences,
                height: min(CGFloat(draft.items.count * 36 + 172), available))
            controller.onSave = { [weak self, weak controller] draft in
                guard let self else { return }
                do { self.pending = try draft.applying(to: self.state.preferences); self.close() }
                catch {
                    let alert = NSAlert(); alert.messageText = error.localizedDescription
                    if let window = controller?.view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
            }
            controller.onSettings = { [weak self] capability in self?.openSettings(capability) }
            controller.onCancel = { [weak self] in self?.close() }
            let popup = NSPopover(); popup.contentViewController = controller
            popup.behavior = .semitransient; popup.delegate = self; popup.contentSize = controller.view.frame.size
            popover = popup; owner = button
            popup.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            popup.contentViewController?.view.window?.makeFirstResponder(controller.view)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53, self.popover?.isShown == true,
                      event.window === self.popover?.contentViewController?.view.window || event.window === self.owner?.window else { return event }
                controller.requestCancel(); return nil
            }
        }
        func openSettings(_ capability: String) {
            pending = nil; close(); state.settingsSection = "translationServices"; onShowSettings(capability)
        }
        func close() { popover?.performClose(nil) }
        func popoverDidClose(_ notification: Notification) {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            let window = owner?.window
            popover = nil; owner = nil
            if let next = pending {
                pending = nil; state.preferences = next; state.savePreferences()
                if let window { ServiceManagementToast.show(in: window) }
            }
        }
    }
}

@MainActor
final class ServiceManagementController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var draft: ServiceManagementDraft
    let preferences: AppPreferences
    let height: CGFloat
    var onSave: ((ServiceManagementDraft) -> Void)?
    var onSettings: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let table = NSTableView(), scroll = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "服务管理")
    private let section = NSTextField(labelWithString: "")
    private let save = NSButton(title: "保存", target: nil, action: nil)
    private let settings = NSButton()
    private let footer = FlippedView()
    private var infoPopup: NSPopover?
    private var mediaIDs: [String: [UUID]] = [:]
    private let dragType = NSPasteboard.PasteboardType("com.local.pop.service-management-row")

    init(draft: ServiceManagementDraft, preferences: AppPreferences, height: CGFloat) {
        self.draft = draft; self.preferences = preferences; self.height = height
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let root = CancelView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        root.onCancel = { [weak self] in self?.requestCancel() }; view = root
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold); titleLabel.frame = NSRect(x: 12, y: 12, width: 100, height: 20)
        save.font = .systemFont(ofSize: 13); save.bezelStyle = .rounded; save.target = self; save.action = #selector(saveDraft)
        save.frame = NSRect(x: 116, y: 10, width: 46, height: 24); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "更多设置")
        settings.isBordered = false; settings.target = self; settings.action = #selector(moreSettings)
        settings.frame = NSRect(x: 171, y: 13, width: 18, height: 18)
        section.font = .systemFont(ofSize: 12, weight: .medium); section.textColor = .secondaryLabelColor
        section.frame = NSRect(x: 12, y: 47, width: 162, height: 18)
        let info = infoButton(action: #selector(strategyInfo(_:))); info.identifier = NSUserInterfaceItemIdentifier("strategy-info")
        info.frame = NSRect(x: 176, y: 48, width: 12, height: 14)
        for item in [titleLabel, save, settings, section, info] as [NSView] { root.addSubview(item) }
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("service")))
        table.tableColumns[0].width = 200; table.headerView = nil; table.rowHeight = 36; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.selectionHighlightStyle = .none; table.allowsEmptySelection = true
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.frame = NSRect(x: 0, y: 70, width: 200, height: max(8, height - 164))
        root.addSubview(scroll)
        footer.frame = NSRect(x: 0, y: height - 94, width: 200, height: 94); root.addSubview(footer)
        let divider = NSBox(frame: NSRect(x: 0, y: 0, width: 200, height: 1)); divider.boxType = .separator; footer.addSubview(divider)
        mediaRow(title: "文本识别", capability: "ocr", y: 14, selected: draft.ocrID)
        mediaRow(title: "语音合成", capability: "tts", y: 54, selected: draft.ttsID)
        refresh()
    }
    private func refresh() {
        section.stringValue = "翻译服务（已启用 \(draft.items.filter { $0.service.enabled }.count)/\(draft.items.count)）"
        save.isEnabled = draft.isDirty
        table.reloadData()
    }
    @objc private func saveDraft() { onSave?(draft) }
    @objc private func moreSettings() { onSettings?("translate") }
    func numberOfRows(in tableView: NSTableView) -> Int { draft.items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 36 }
    // Native table dragging starts through row selection; no visual selection is
    // drawn because this list uses hover/checkmarks for its state.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = draft.items[row]
        let cell = ServiceManagementCell(frame: NSRect(x: 0, y: 0, width: 200, height: 36), item: item)
        cell.onToggle = { [weak self] in guard let self, let index = self.draft.items.firstIndex(where: { $0.id == item.id }) else { return }; self.draft.items[index].service.enabled.toggle(); self.refresh() }
        cell.onStrategy = { [weak self] strategy in guard let self, let index = self.draft.items.firstIndex(where: { $0.id == item.id }) else { return }; self.draft.items[index].strategy = strategy; self.refresh() }
        return cell
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let value = NSPasteboardItem(); value.setString(draft.items[row].id.uuidString, forType: dragType); return value
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView, operation == .above else { return [] }; return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: dragType), let id = UUID(uuidString: text), draft.move(id: id, before: row) else { return false }
        refresh(); return true
    }
    private func mediaRow(title: String, capability: String, y: CGFloat, selected: UUID?) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12); label.frame = NSRect(x: 16, y: y, width: 60, height: 16); footer.addSubview(label)
        let info = infoButton(action: #selector(mediaInfo(_:))); info.identifier = NSUserInterfaceItemIdentifier(capability)
        info.frame = NSRect(x: 68, y: y, width: 12, height: 14); footer.addSubview(info)
        let picker = NSPopUpButton(frame: NSRect(x: 84, y: y - 3, width: 104, height: 23), pullsDown: false)
        picker.font = .systemFont(ofSize: 12); picker.isBordered = false; picker.identifier = NSUserInterfaceItemIdentifier(capability)
        let choices = capability == "ocr" ? preferences.ocrServices(forTranslation: true) : preferences.services.filter { $0.capability == "tts" }
        mediaIDs[capability] = choices.map(\.id)
        for service in choices {
            picker.addItem(withTitle: service.name)
            let image = UIReferenceAssets.image(UIReferenceAssets.serviceName(service))?.copy() as? NSImage
            image?.size = NSSize(width: 16, height: 16); picker.lastItem?.image = image
        }
        if let index = choices.firstIndex(where: { $0.id == selected }) { picker.selectItem(at: index) }
        picker.menu?.addItem(.separator()); picker.addItem(withTitle: "更多设置…")
        picker.target = self; picker.action = #selector(selectMedia(_:)); footer.addSubview(picker)
    }
    @objc private func selectMedia(_ picker: NSPopUpButton) {
        let capability = picker.identifier?.rawValue ?? "ocr", ids = mediaIDs[capability] ?? []
        guard ids.indices.contains(picker.indexOfSelectedItem) else { onSettings?(capability); return }
        if capability == "ocr" { draft.ocrID = ids[picker.indexOfSelectedItem] } else { draft.ttsID = ids[picker.indexOfSelectedItem] }
        save.isEnabled = draft.isDirty
    }
    private func infoButton(action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "说明")!, target: self, action: action)
        button.isBordered = false; button.contentTintColor = .tertiaryLabelColor; return button
    }
    @objc private func strategyInfo(_ sender: NSButton) {
        showInfo("为各项服务分别选择何时发起查询：\n\n普通模式\n每次查询均请求此服务。\n\n记住折叠状态\n沿用上次卡片的展开或收起状态；收起时暂不请求，展开后再查询。\n\n总是折叠\n新查询先收起卡片，展开后才发送本次请求。\n\n钉到语言栏\n点击语言栏中的服务图标才发起请求。\n\n发送请求可能消耗对应服务的额度。", sender: sender)
    }
    @objc private func mediaInfo(_ sender: NSButton) {
        showInfo(sender.identifier?.rawValue == "ocr" ? "截图翻译会先调用此 OCR 服务提取文字，再用翻译服务处理识别结果。" : "播放按钮使用这里选定的服务朗读文字。", sender: sender)
    }
    private func showInfo(_ text: String, sender: NSView) {
        infoPopup?.close()
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 12)
        let measured = (text as NSString).boundingRect(with: NSSize(width: 240, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!])
        let content = CancelView(frame: NSRect(x: 0, y: 0, width: 264, height: ceil(measured.height) + 24))
        label.frame = content.bounds.insetBy(dx: 12, dy: 12); content.addSubview(label)
        let controller = NSViewController(); controller.view = content
        let popup = NSPopover(); popup.behavior = .transient; popup.contentViewController = controller
        content.onCancel = { [weak popup] in popup?.close() }; infoPopup = popup
        popup.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    func requestCancel() {
        if let infoPopup, infoPopup.isShown { infoPopup.performClose(nil); return }
        onCancel?()
    }
    private class FlippedView: NSView { override var isFlipped: Bool { true } }
    private final class CancelView: FlippedView {
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }
}

@MainActor
private final class ServiceManagementCell: NSTableCellView, NSGestureRecognizerDelegate {
    var onToggle: (() -> Void)?
    var onStrategy: ((ServiceManagementStrategy) -> Void)?
    private let strategy = NSPopUpButton(), background = NSView()
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(frame: NSRect, item: ServiceManagementDraft.Item) {
        super.init(frame: frame)
        background.frame = bounds.insetBy(dx: 6, dy: 1); background.wantsLayer = true; background.layer?.cornerRadius = 6; addSubview(background)
        let check = NSImageView(frame: NSRect(x: 10, y: 11, width: 14, height: 14))
        check.image = item.service.enabled ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已开启") : nil
        check.contentTintColor = .controlAccentColor; addSubview(check)
        let icon = NSImageView(frame: NSRect(x: 30, y: 8, width: 20, height: 20))
        icon.image = UIReferenceAssets.image(UIReferenceAssets.serviceName(item.service)); addSubview(icon)
        let name = NSTextField(labelWithString: item.service.name); name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 56, y: 2, width: 125, height: 16); addSubview(name)
        let badge = NSTextField(labelWithString: item.service.kind == .apple || item.service.kind == .dictionary ? "内置" : item.service.kind == .plugin ? "插件" : "密钥")
        badge.font = .systemFont(ofSize: 10); badge.textColor = .secondaryLabelColor; badge.frame = NSRect(x: 56, y: 19, width: 27, height: 14); addSubview(badge)
        strategy.frame = NSRect(x: 84, y: 17, width: 104, height: 18); strategy.font = .systemFont(ofSize: 11); strategy.isBordered = false
        strategy.addItems(withTitles: ServiceManagementStrategy.allCases.map(\.title)); strategy.selectItem(at: ServiceManagementStrategy.allCases.firstIndex(of: item.strategy) ?? 0)
        strategy.target = self; strategy.action = #selector(changeStrategy); addSubview(strategy)
        let drag = NSImageView(frame: NSRect(x: 187, y: 13, width: 7, height: 10))
        drag.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序"); drag.contentTintColor = .tertiaryLabelColor; addSubview(drag)
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle)); click.delegate = self; addGestureRecognizer(click)
        setAccessibilityElement(true); setAccessibilityRole(.checkBox); setAccessibilityLabel(item.service.name); setAccessibilityValue(item.service.enabled ? 1 : 0)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func toggle() { onToggle?() }
    @objc private func changeStrategy() { let values = ServiceManagementStrategy.allCases; if values.indices.contains(strategy.indexOfSelectedItem) { onStrategy?(values[strategy.indexOfSelectedItem]) } }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        !strategy.frame.contains(convert(event.locationInWindow, from: nil))
    }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(next); area = next; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { background.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override func mouseExited(with event: NSEvent) { background.layer?.backgroundColor = NSColor.clear.cgColor }
}

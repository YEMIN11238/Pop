import AppKit

/// Runs only self-created, in-memory services and local native controls.
@MainActor enum ServiceManagementSelfCheck {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "ServiceManagementFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func run() async throws -> [String] {
        var checks: [String] = [], preferences = AppPreferences()
        let a = ServiceConfig(name: "A", kind: .apple)
        var b = ServiceConfig(name: "B", kind: .openAI); b.endpoint = "https://fixture.invalid"; b.model = "fixture"
        var c = ServiceConfig(name: "C", kind: .plugin); c.enabled = false
        let o1 = ServiceConfig.systemMedia(capability: "ocr")
        var o2 = ServiceConfig.systemMedia(capability: "ocr"); o2.enabled = false
        let standalone = ServiceConfig.systemMedia(capability: "ocr", scope: "standaloneOCR")
        let t1 = ServiceConfig.systemMedia(capability: "tts")
        var t2 = ServiceConfig(name: "TTS 2", kind: .plugin); t2.capability = "tts"; t2.enabled = false
        preferences.services = [a, o1, b, standalone, c, o2, t1, t2]
        preferences.pinnedServiceIDs = [b.id]
        preferences.collapsedServiceIDs = [a.id, b.id]
        let unchanged = preferences
        var draft = ServiceManagementDraft(preferences: preferences)
        try require(!draft.isDirty && draft.items.map(\.id) == [a.id, b.id, c.id], "初始草稿/翻译分组不正确")
        try require(draft.items[1].strategy == .pinned && draft.ocrID == o1.id && draft.ttsID == t1.id, "旧钉住字段或媒体选择未迁移到草稿")
        draft.items[1].service.enabled = false
        try require(preferences == unchanged && draft.isDirty, "草稿编辑改变了原配置")
        checks.append("草稿隔离、旧 pinned 字段、OCR/TTS 当前选择通过。")

        draft.items[1].strategy = .rememberCollapse; draft.items[2].strategy = .alwaysCollapsed
        draft.items[0].strategy = .normal
        try require(draft.move(id: c.id, before: 0), "向前拖排失败")
        let next = try draft.applying(to: preferences)
        try require(next.services.map(\.id) == [c.id, o1.id, a.id, standalone.id, b.id, o2.id, t1.id, t2.id], "拖排未保留媒体槽位")
        try require(!next.pinnedServiceIDs.contains(b.id) && next.collapsedServiceIDs.contains(c.id) && !next.collapsedServiceIDs.contains(a.id) && next.collapsedServiceIDs.contains(b.id), "四种策略提交未正确同步钉住/折叠状态")
        checks.append("排序保留非翻译服务槽位；normal/rememberCollapse/alwaysCollapsed/pinned 持久字段通过。")

        var metadataChanged = preferences
        let bi = metadataChanged.services.firstIndex { $0.id == b.id }!
        metadataChanged.services[bi].name = "Edited in settings"; metadataChanged.services[bi].model = "new model"; metadataChanged.services[bi].options["unrelated"] = "retained"
        let merged = try draft.applying(to: metadataChanged)
        let edited = merged.services.first { $0.id == b.id }!
        try require(edited.name == "Edited in settings" && edited.model == "new model" && edited.options["unrelated"] == "retained", "提交覆盖了设置中的名称/模型/其他选项")
        var conflict = preferences; conflict.services.swapAt(0, 2)
        do { _ = try draft.applying(to: conflict); throw NSError(domain: "fixture", code: 2) }
        catch let error as NSError { try require(error.domain != "fixture", "并发服务排序未被拒绝") }
        checks.append("保留并发元数据更新；拒绝并发列表重排通过。")

        var disabled = ServiceManagementDraft(preferences: preferences)
        for index in disabled.items.indices { disabled.items[index].service.enabled = false }
        do { _ = try disabled.applying(to: preferences); throw NSError(domain: "fixture", code: 2) }
        catch { try require(error.localizedDescription == "请至少开启 1 个文本翻译服务", "全禁用错误不明确") }
        checks.append("至少一个文本翻译服务的保存约束通过。")

        var media = ServiceManagementDraft(preferences: preferences); media.ocrID = o2.id; media.ttsID = t2.id
        let selected = try media.applying(to: preferences)
        try require(selected.selectedOCRService(forTranslation: true)?.id == o2.id && selected.selectedOCRService(forTranslation: false)?.id == standalone.id && selected.selectedTTSService?.id == t2.id, "媒体选择未正确隔离 OCR scope 或 TTS")
        try require(selected.services.filter { $0.capability == "tts" && $0.enabled }.count == 1, "TTS 选择未归一化")
        checks.append("截图 OCR 与独立 OCR 隔离、TTS 单选提交通过。")

        let controller = ServiceManagementController(draft: ServiceManagementDraft(preferences: preferences), preferences: preferences, height: 280)
        controller.loadViewIfNeeded()
        let scroll = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!
        let table = scroll.documentView as! NSTableView
        try require(controller.view.frame.size == NSSize(width: 200, height: 280) && table.rowHeight == 36 && table.headerView == nil && table.intercellSpacing == .zero, "原生弹层几何错误")
        try require(table.numberOfRows == 3 && controller.tableView(table, shouldSelectRow: 0), "原生表格行数或拖动前提选择被禁用")
        let writer = controller.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem
        try require(writer?.string(forType: NSPasteboard.PasteboardType("com.local.pop.service-management-row")) == a.id.uuidString, "拖排序列化不是当前行 UUID")
        checks.append("实际 AppKit 控件实例的 200pt 宽、36pt 行、无表头与本地拖排数据源通过（未注入鼠标拖动）。")

        let cell = controller.tableView(table, viewFor: table.tableColumns.first, row: 0)!
        try require(cell.accessibilityPerformPress(), "行辅助功能按钮未接受 press")
        try require(controller.draft.items[0].service.enabled == false && preferences.services.first!.enabled, "原生行点击未隔离草稿")
        var saved: ServiceManagementDraft?, canceled = 0
        controller.onSave = { saved = $0 }; controller.onCancel = { canceled += 1 }
        let save = controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "保存" }!
        try require(save.isEnabled, "草稿改变后保存按钮未启用")
        save.performClick(nil)
        try require(saved?.items[0].service.enabled == false, "保存未传递当前草稿")
        controller.view.cancelOperation(nil)
        try require(canceled == 1 && preferences == unchanged, "取消未关闭或修改了原配置")
        checks.append("实际 AppKit 行 press、保存按钮 draft 回调、取消只关闭通过。")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toast = ServiceManagementToast.show(in: window)
        try require(toast.container.superview != nil && toast.banner.frame.height == 32 && toast.banner.layer?.cornerRadius == 16 && toast.container.hitTest(.zero) == nil, "保存提示的原生尺寸/穿透错误")
        try require(toast.banner.subviews.compactMap { $0 as? NSImageView }.first?.image != nil, "原版成功图资源缺失")
        try await Task.sleep(nanoseconds: 1_900_000_000)
        try require(toast.container.superview != nil, "保存提示在原版1.8秒最短期限前被清除")
        try await Task.sleep(nanoseconds: 800_000_000)
        try require(toast.container.superview == nil, "保存提示计时结束未清除")
        let old = ServiceManagementToast.show(in: window)
        let replacement = ServiceManagementToast.show(in: window)
        try require(old.container.superview == nil && replacement.container.superview != nil, "重复提示未替换旧计时状态")
        replacement.dismiss()
        checks.append("保存提示：真实AppKit绿色32pt/圆角16/成功资源/鼠标穿透、1.8秒最短停留与退出清理、重复替换通过。")
        return checks
    }
}

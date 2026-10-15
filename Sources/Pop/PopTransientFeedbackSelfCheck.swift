import AppKit

@MainActor
enum PopTransientFeedbackSelfCheck {
    static func run() async throws -> [String] {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "PopTransientFeedbackSelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "提示器自检失败：" + message]) }
        }
        // Both the product timer and this check resume on MainActor. A single
        // sleep just beyond the deadline can resume before the timer's actor
        // job under UI load, even when its clock deadline has already elapsed.
        // Check the lower bound while it is observable, then poll with a hard
        // upper bound instead of assuming an ordering between the two jobs.
        func retainUntil(_ deadline: TimeInterval, _ message: String, condition: () -> Bool) async throws {
            while ProcessInfo.processInfo.systemUptime < deadline {
                try require(condition(), message)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func eventually(_ message: String, timeout: TimeInterval = 2, condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !condition() {
                try require(ProcessInfo.processInfo.systemUptime < deadline, message + "（有界等待超时）")
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let visible = NSRect(x: -1440, y: -200, width: 1440, height: 900)
        try require(PopTransientHUD.frame(at: NSPoint(x: -800, y: 100), visibleFrame: visible) == NSRect(x: -815, y: 110, width: 30, height: 30), "HUD位于鼠标上方10pt并水平居中")
        try require(PopTransientHUD.frame(at: NSPoint(x: -1440, y: -200), visibleFrame: visible) == NSRect(x: -1430, y: -190, width: 30, height: 30), "负坐标屏幕左底约束")
        try require(PopTransientHUD.frame(at: NSPoint(x: 0, y: 700), visibleFrame: visible) == NSRect(x: -40, y: 670, width: 30, height: 30), "屏幕右顶约束")
        var checks = ["提示器：30×30、鼠标上方10pt、负坐标多屏及屏幕边缘布局通过。"]

        let timing = BobTooltipTiming.self
        try require(timing.delay(mode: "delayed", policy: .preference, isVisible: false, lastDismissed: nil, now: 100) == 1, "首次延迟1秒")
        try require(timing.delay(mode: "delayed", policy: .preference, isVisible: false, lastDismissed: 99.5, now: 100) == 0, "最近关闭快速悬停立即显示")
        try require(timing.delay(mode: "delayed", policy: .preference, isVisible: true, lastDismissed: 90, now: 100) == 0, "已有提示时切换立即显示")
        try require(timing.delay(mode: "immediate", policy: .delayed, isVisible: false, lastDismissed: 90, now: 100) == 1, "单提示强制延迟")
        try require(timing.delay(mode: "delayed", policy: .immediate, isVisible: false, lastDismissed: 90, now: 100) == 0, "单提示强制立即")
        checks.append("提示器：1秒延迟、1秒内连续悬停、可见提示切换与特殊提示覆盖策略通过。")

        let hud = PopTransientHUD()
        defer { hud.dismiss() }
        let keyBefore = NSApp.keyWindow
        let pointer = NSEvent.mouseLocation
        hud.loading(at: pointer)
        try require(hud.phase == .loading && hud.panel?.isVisible == true && hud.panel?.canBecomeKey == false && hud.panel?.canBecomeMain == false && NSApp.keyWindow === keyBefore, "真实HUD窗口不抢焦点")
        let firstFrame = hud.panel?.frame
        hud.success(at: NSPoint(x: pointer.x + 100, y: pointer.y + 100))
        let successDeadline = ProcessInfo.processInfo.systemUptime + 1.8
        try require(hud.phase == .success && hud.panel?.frame == firstFrame, "加载转完成保持最初鼠标位置")
        try await retainUntil(successDeadline, "成功提示不可在1.8秒前隐藏") { hud.phase == .success && hud.panel?.isVisible == true }
        try await eventually("成功1.8秒后隐藏") { hud.phase == nil && hud.panel?.isVisible == false }
        hud.failure(at: pointer)
        let failureDeadline = ProcessInfo.processInfo.systemUptime + 1.8
        try await retainUntil(failureDeadline, "失败提示不可在1.8秒前隐藏") { hud.phase == .failure && hud.panel?.isVisible == true }
        try await eventually("失败1.8秒后隐藏") { hud.phase == nil && hud.panel?.isVisible == false }
        checks.append("提示器：真实AppKit HUD不激活/不抢焦点、加载到终态位置保留、成功与失败1.8秒消失通过。")
        hud.success(at: pointer)
        try await Task.sleep(nanoseconds: 50_000_000)
        hud.loading(at: pointer)
        try await Task.sleep(nanoseconds: 1_850_000_000)
        try require(hud.phase == .loading && hud.panel?.isVisible == true, "旧完成计时器不可关闭新加载")
        var clicked = false
        hud.failure(at: pointer, onClick: { clicked = true })
        _ = hud.panel?.contentView?.accessibilityPerformPress()
        try require(clicked && hud.phase == nil, "点击提示关闭并调用显示OCR回调")
        checks.append("提示器：新请求覆盖旧终态计时器、真实窗口辅助点击回调及主动关闭通过。")

        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let screen else { throw NSError(domain: "PopTransientFeedbackSelfCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "当前无AppKit屏幕，悬停窗口实测不可用。"]) }
        // This fixture supplies its own pointer provider. Anchor it in the usable
        // screen area so AppKit menu-bar/Dock constraints cannot move it away
        // from that simulated pointer when the user's real pointer is at an edge.
        let fixturePointer = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let ownerFrame = NSRect(x: fixturePointer.x - 20, y: fixturePointer.y - 15, width: 40, height: 30)
        let parent = NSPanel(contentRect: ownerFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.backgroundColor = .clear; parent.isOpaque = false
        parent.ignoresMouseEvents = true
        let owner = BobTooltip.TrackingView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        owner.text = "本地悬停提示fixture"; owner.mode = "delayed"; owner.inside = true
        owner.pointerLocation = { fixturePointer } // No global input injection or user mouse motion dependency.
        parent.contentView = owner; parent.orderFrontRegardless()
        owner.inside = true
        let presenter = BobTooltipPresenter()
        defer { presenter.dismiss(); parent.close() }
        try require(owner.canShow, "悬停fixture所属窗口可见且鼠标位于其内")
        presenter.enter(owner)
        let tooltipDeadline = ProcessInfo.processInfo.systemUptime + 1
        try require(presenter.panel == nil, "延迟阶段尚未创建提示窗口")
        try await retainUntil(tooltipDeadline, "延迟提示不可在1秒前显示") { presenter.panel == nil }
        try await eventually("延迟后真实提示窗口可见") { presenter.panel?.isVisible == true }
        try require(presenter.panel?.isVisible == true && presenter.panel?.canBecomeKey == false && NSApp.keyWindow === keyBefore, "延迟后真实提示窗口可见且不抢焦点")
        presenter.leave(owner)
        try require(presenter.panel == nil, "mouseleave关闭提示")
        presenter.enter(owner)
        try require(presenter.panel?.isVisible == true, "最近关闭后再次悬停立即显示")
        presenter.dismiss()
        checks.append("提示器：真实AppKit悬停窗口1秒显示、离开关闭、连续悬停立即显示且不抢焦点通过。")
        let cancelled = BobTooltipPresenter()
        cancelled.enter(owner)
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.leave(owner)
        try await Task.sleep(nanoseconds: 1_050_000_000)
        try require(cancelled.panel == nil, "离开按钮取消尚未触发的延迟提示")
        cancelled.dismiss()
        checks.append("提示器：离开按钮取消待显示任务，旧任务不会延迟弹出通过。")
        return checks
    }
}

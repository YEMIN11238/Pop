import AppKit
import SwiftUI
import Combine

enum BobTooltipPolicy { case preference, immediate, delayed }

enum BobTooltipTiming {
    static func delay(mode: String, policy: BobTooltipPolicy, isVisible: Bool,
                      lastDismissed: TimeInterval?, now: TimeInterval) -> TimeInterval {
        let delayed = policy == .delayed || (policy == .preference && mode == "delayed")
        guard delayed, !isVisible, lastDismissed.map({ now - $0 >= 1 }) ?? true else { return 0 }
        return 1
    }
}

/// Put this in a control's background, or use .bobTooltip below. It deliberately
/// does not set NSView.toolTip, so the system will not show a duplicate tooltip.
struct BobTooltip: NSViewRepresentable {
    var text: String
    var mode = "immediate"
    var policy: BobTooltipPolicy = .preference
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.text = text; view.mode = mode; view.policy = policy
        if text.isEmpty { BobTooltipPresenter.shared.leave(view) }
    }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { BobTooltipPresenter.shared.leave(view) }

    /// AppKit controls use the same host and preference subscription as SwiftUI.
    /// The transparent tracking view does not intercept control clicks or drags.
    @MainActor static func attach(to owner: NSView, text: String, mode: String? = nil,
                                  policy: BobTooltipPolicy = .preference) {
        let identifier = NSUserInterfaceItemIdentifier("com.local.pop.tooltip-tracking")
        let tracking: TrackingView
        if let existing = owner.subviews.first(where: { $0.identifier == identifier }) as? TrackingView { tracking = existing }
        else {
            tracking = TrackingView(frame: owner.bounds); tracking.identifier = identifier
            tracking.autoresizingMask = [.width, .height]; owner.addSubview(tracking)
        }
        owner.toolTip = nil; tracking.text = text; tracking.policy = policy
        tracking.configurationSubscription?.cancel(); tracking.configurationSubscription = nil
        if let mode { tracking.mode = mode }
        else {
            tracking.mode = ConfigurationRepository.shared.preferences.tooltipBehavior
            tracking.configurationSubscription = ConfigurationRepository.shared.$preferences.sink { [weak tracking] prefs in
                Task { @MainActor in tracking?.mode = prefs.tooltipBehavior }
            }
        }
        if text.isEmpty { BobTooltipPresenter.shared.leave(tracking) }
    }

    final class TrackingView: NSView {
        var text = "", mode = "immediate"
        var policy: BobTooltipPolicy = .preference
        var inside = false
        var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
        var configurationSubscription: AnyCancellable?
        private var area: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(next); area = next; super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { inside = true; BobTooltipPresenter.shared.enter(self) }
        override func mouseExited(with event: NSEvent) { inside = false; BobTooltipPresenter.shared.leave(self) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { inside = false; BobTooltipPresenter.shared.leave(self) }
        }
        var screenRect: NSRect? {
            guard let window else { return nil }
            return window.convertToScreen(convert(bounds, to: nil))
        }
        var canShow: Bool {
            guard inside, !isHiddenOrHasHiddenAncestor, let window, window.isVisible, window.isOnActiveSpace,
                  let screen = window.screen, let rect = screenRect else { return false }
            return rect.contains(pointerLocation()) && screen.frame.contains(rect)
        }
    }
}

extension View {
    func bobTooltip(_ text: String, mode: String? = nil, policy: BobTooltipPolicy = .preference) -> some View {
        modifier(ConfiguredBobTooltip(text: text, mode: mode, policy: policy))
    }
}

private struct ConfiguredBobTooltip: ViewModifier {
    @ObservedObject private var configuration = ConfigurationRepository.shared
    var text: String
    var mode: String?
    var policy: BobTooltipPolicy
    func body(content: Content) -> some View {
        content.background(BobTooltip(text: text, mode: mode ?? configuration.preferences.tooltipBehavior, policy: policy))
            .accessibilityHint(text)
    }
}

@MainActor
final class BobTooltipPresenter {
    static let shared = BobTooltipPresenter()
    private(set) var panel: NSPanel?
    private(set) var lastDismissed: TimeInterval?
    private weak var pendingOwner: BobTooltip.TrackingView?
    private weak var shownOwner: BobTooltip.TrackingView?
    private var timer: Task<Void, Never>?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?

    func enter(_ owner: BobTooltip.TrackingView) {
        cancelPending()
        guard !owner.text.isEmpty else { return }
        let delay = BobTooltipTiming.delay(mode: owner.mode, policy: owner.policy, isVisible: panel?.isVisible == true,
                                           lastDismissed: lastDismissed, now: Date.timeIntervalSinceReferenceDate)
        if delay == 0 { show(owner); return }
        pendingOwner = owner
        installMonitor(shown: false)
        timer = Task { @MainActor [weak self, weak owner] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, let owner, self.pendingOwner === owner else { return }
            self.cancelPending(); self.show(owner)
        }
    }
    func leave(_ owner: BobTooltip.TrackingView) {
        if pendingOwner === owner { cancelPending() }
        if shownOwner === owner { dismiss() }
    }
    func dismiss() {
        cancelPending()
        if panel?.isVisible == true { lastDismissed = Date.timeIntervalSinceReferenceDate }
        panel?.orderOut(nil); panel = nil; shownOwner = nil
        removeObservers()
    }
    private func cancelPending() {
        timer?.cancel(); timer = nil; pendingOwner = nil
        if shownOwner == nil { removeObservers() }
    }
    private func show(_ owner: BobTooltip.TrackingView) {
        guard owner.canShow, let anchor = owner.screenRect, let screen = owner.window?.screen else { dismiss(); return }
        removeObservers()
        let window: NSPanel
        if let current = panel { window = current } else {
            window = TooltipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
            window.hasShadow = true; window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.level = .popUpMenu; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = window
        }
        let label = NSTextField(wrappingLabelWithString: owner.text)
        label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
        let measured = (owner.text as NSString).boundingRect(with: NSSize(width: 360, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!])
        let size = NSSize(width: max(30, ceil(measured.width) + 30), height: max(20, ceil(measured.height)) + 18)
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .toolTip; material.state = .active; material.blendingMode = .behindWindow
        material.wantsLayer = true; material.layer?.cornerRadius = 6; material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5; material.layer?.borderColor = NSColor.separatorColor.cgColor
        label.frame = NSRect(x: 15, y: 9, width: size.width - 30, height: size.height - 18)
        material.addSubview(label); window.contentView = material
        let visible = screen.visibleFrame
        // Tip's default direction0 is above its owner, gap5. Bob's20pt outer
        // shadow inset is omitted here; NSPanel supplies the external shadow.
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 5)
        if origin.y + size.height > visible.maxY - 4 { origin.y = anchor.minY - size.height - 5 }
        origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height - 4))
        window.setFrame(NSRect(origin: origin, size: size).integral, display: true)
        shownOwner = owner; window.orderFrontRegardless(); installMonitor(shown: true)
        if let parent = owner.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
    }
    private func installMonitor(shown: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        if shown { mask.formUnion([.mouseMoved, .scrollWheel]) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved || event.type == .scrollWheel {
                if self.shownOwner?.canShow != true { self.dismiss() }
            } else { self.dismiss() }
            return event
        }
    }
    private func removeObservers() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
    }
    private final class TooltipPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

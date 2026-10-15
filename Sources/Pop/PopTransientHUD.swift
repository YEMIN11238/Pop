import AppKit

/// Mouse-adjacent, nonactivating status feedback. Bob's recovered MiniHUD uses
/// a30pt square,6pt corner radius and1.8s terminal-state lifetime.
@MainActor
final class PopTransientHUD {
    static let shared = PopTransientHUD()
    enum Phase: Equatable { case loading, success, failure }
    private(set) var phase: Phase?
    private(set) var panel: NSPanel?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var onClick: (() -> Void)?

    func loading(at point: NSPoint = NSEvent.mouseLocation, onClick: (() -> Void)? = nil) {
        show(.loading, at: point, onClick: onClick)
    }
    func success(at point: NSPoint = NSEvent.mouseLocation, onClick: (() -> Void)? = nil) {
        show(.success, at: point, onClick: onClick)
    }
    func failure(at point: NSPoint = NSEvent.mouseLocation, onClick: (() -> Void)? = nil) {
        show(.failure, at: point, onClick: onClick)
    }
    func dismiss() {
        timer?.cancel(); timer = nil; generation = UUID()
        phase = nil; onClick = nil
        panel?.orderOut(nil)
    }

    /// The recovered code clamps the rectangle's origin, then converts it to
    /// setFrameTopLeftPoint. Thus its bottom edge is10pt ABOVE the pointer.
    static func frame(at point: NSPoint, visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: 30, height: 30)
        let x = max(visibleFrame.minX + 10, min(point.x - size.width / 2, visibleFrame.maxX - size.width - 10))
        let y = min(max(point.y + 10, visibleFrame.minY + 10), visibleFrame.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size).integral
    }

    private func show(_ next: Phase, at point: NSPoint, onClick: (() -> Void)?) {
        timer?.cancel(); timer = nil; generation = UUID()
        let token = generation
        let shouldPosition = phase != .loading || panel?.isVisible != true
        phase = next; self.onClick = onClick
        let window: NSPanel
        let content: HUDContent
        if let current = panel, let view = current.contentView as? HUDContent {
            window = current; content = view
        } else {
            window = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isOpaque = false
            window.backgroundColor = .clear; window.hasShadow = true
            window.hidesOnDeactivate = false; window.level = .popUpMenu
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            content = HUDContent(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            window.contentView = content; panel = window
        }
        content.clicked = { [weak self] in self?.activate() }
        content.update(next)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens.first
        if shouldPosition, let screen { window.setFrame(Self.frame(at: point, visibleFrame: screen.visibleFrame), display: true) }
        window.orderFrontRegardless()
        if next != .loading {
            timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 1_800_000_000) } catch { return }
                guard let self, self.generation == token else { return }
                self.dismiss()
            }
        }
    }
    private func activate() {
        let callback = onClick
        dismiss(); callback?()
    }

    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class HUDContent: NSView {
        private let material = NSVisualEffectView()
        private let progress = NSProgressIndicator()
        private let image = NSImageView()
        var clicked: (() -> Void)?
        private var phase: Phase = .loading
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true; layer?.cornerRadius = 6; layer?.masksToBounds = true
            material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
            material.frame = bounds; material.autoresizingMask = [.width, .height]
            addSubview(material)
            progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
            progress.frame = NSRect(x: 7, y: 7, width: 16, height: 16)
            image.frame = progress.frame; image.imageScaling = .scaleProportionallyUpOrDown
            addSubview(progress); addSubview(image)
            setAccessibilityElement(true); setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { nil }
        override func mouseUp(with event: NSEvent) { clicked?() }
        override func accessibilityPerformPress() -> Bool { clicked?(); return true }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update(phase) }
        func update(_ value: Phase) {
            phase = value
            progress.isHidden = value != .loading; image.isHidden = value == .loading
            if value == .loading { progress.startAnimation(nil) } else {
                progress.stopAnimation(nil)
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                image.image = Self.asset(value == .success ? "mini_hud_success" : "mini_hud_fail", dark: dark)
                    ?? NSImage(systemSymbolName: value == .success ? "checkmark" : "xmark", accessibilityDescription: nil)
            }
            setAccessibilityLabel(value == .loading ? "正在识别，点击显示 OCR 窗口" : value == .success ? "识别完成，点击显示 OCR 窗口" : "识别失败，点击显示 OCR 窗口")
        }
        private static func asset(_ name: String, dark: Bool) -> NSImage? {
            UIReferenceAssets.image(name, dark: dark)
        }
    }
}

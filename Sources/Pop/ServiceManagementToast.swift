import AppKit
import QuartzCore

/// Reconstructs the original service-save ProgressHUD path. The call requests
/// 1.5s, but its shared implementation clamps the timer to at least 1.8s.
@MainActor
final class ServiceManagementToast {
    private static var presentations: [ObjectIdentifier: ServiceManagementToast] = [:]
    private weak var window: NSWindow?
    private let identity: ObjectIdentifier
    private(set) var container = PassThroughView()
    private(set) var banner = PassThroughView()
    private var timer: Task<Void, Never>?
    private var closeObserver: NSObjectProtocol?

    @discardableResult static func show(in window: NSWindow, text: String = "保存成功", duration: TimeInterval = 1.5) -> ServiceManagementToast {
        let id = ObjectIdentifier(window)
        presentations[id]?.dismiss()
        let toast = ServiceManagementToast(window: window)
        presentations[id] = toast
        toast.present(text: text, duration: duration)
        return toast
    }
    private init(window: NSWindow) { self.window = window; identity = ObjectIdentifier(window) }
    private func present(text: String, duration: TimeInterval) {
        guard let content = window?.contentView, let parent = content.superview ?? window?.contentView else { dismiss(); return }
        container.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(container, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: parent.topAnchor),
            container.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            container.widthAnchor.constraint(equalToConstant: 600), container.heightAnchor.constraint(equalToConstant: 600)
        ])
        let font = NSFont.systemFont(ofSize: 14)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let width = min(200, ceil(textSize.width) + 47)
        banner.frame = NSRect(x: (300 - width / 2).rounded(), y: -32, width: width, height: 32)
        banner.wantsLayer = true; banner.layer?.cornerRadius = 16
        banner.layer?.backgroundColor = NSColor(srgbRed: 54 / 255, green: 197 / 255, blue: 44 / 255, alpha: 1).cgColor
        container.addSubview(banner)
        let image = NSImageView(frame: NSRect(x: 12, y: 7, width: 18, height: 18))
        image.image = UIReferenceAssets.image("hud_success")
        image.imageScaling = .scaleProportionallyDown; banner.addSubview(image)
        let label = NSTextField(labelWithString: text); label.font = font; label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 35, y: 7, width: max(0, width - 47), height: 18); banner.addSubview(label)
        parent.layoutSubtreeIfNeeded()
        animate(to: 0)
        if let window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
        timer = Task { @MainActor [weak self] in
            // The original timer is installed after the .3s entrance completes.
            do { try await Task.sleep(nanoseconds: UInt64((0.3 + max(1.8, duration)) * 1_000_000_000)) } catch { return }
            guard let self else { return }; self.animate(to: -32)
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self.dismiss()
        }
    }
    private func animate(to y: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            banner.animator().setFrameOrigin(NSPoint(x: banner.frame.minX, y: y))
        }
    }
    func dismiss() {
        timer?.cancel(); timer = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        container.removeFromSuperview()
        if Self.presentations[identity] === self { Self.presentations.removeValue(forKey: identity) }
    }
    final class PassThroughView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

import AppKit

/// The reference preferences window puts the standard traffic lights inside
/// its 52pt sidebar header instead of the system's compact titlebar.
@MainActor
enum SettingsWindowChrome {
    static func install(on window: NSWindow) {
        guard let content = window.contentView else { return }
        // NSHostingView owns the layout of its direct children. Put the chrome
        // beside it in an AppKit container so constraints drive both reliably.
        let container = NSView(frame: .zero)
        window.contentView = container
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        let overlay = Controls(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.widthAnchor.constraint(equalToConstant: 180),
            overlay.heightAnchor.constraint(equalToConstant: 52)
        ])
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.removeFromSuperview()
            button.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 19 + CGFloat(index) * 23),
                button.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 14),
                button.heightAnchor.constraint(equalToConstant: 14)
            ])
        }
    }

    private final class Controls: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }
}

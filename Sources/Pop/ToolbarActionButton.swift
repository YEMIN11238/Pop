import AppKit
import SwiftUI

struct ToolbarMenuAction {
    let title: String
    var enabled = true
    var checked = false
    let action: () -> Void
}

/// Raster assets carry their export dimensions, not the toolbar's point size.
enum ToolbarIconLayout {
    static let size = NSSize(width: 17, height: 18)

    static func image(_ source: NSImage?) -> NSImage? {
        guard let source, let image = source.copy() as? NSImage,
              source.size.width > 0, source.size.height > 0 else { return source }
        let scale = min(size.width / source.size.width, size.height / source.size.height)
        image.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        return image
    }

    static func fittingSize(_ proposal: ProposedViewSize) -> NSSize {
        let proposed = proposal.replacingUnspecifiedDimensions(by: size)
        return NSSize(width: proposed.width.isFinite ? max(0, proposed.width) : size.width,
                      height: proposed.height.isFinite ? max(0, proposed.height) : size.height)
    }
}

class ToolbarIconButton: NSButton {
    override var intrinsicContentSize: NSSize { ToolbarIconLayout.size }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

/// The navigation controls intentionally have separate primary and secondary clicks.
struct ToolbarActionButton: NSViewRepresentable {
    let symbol: String
    let help: String
    var referenceAsset: String? = nil
    var active = false
    var menuActions: [ToolbarMenuAction] = []
    let primary: () -> Void
    let secondary: () -> Void

    func makeNSView(context: Context) -> DualActionButton {
        let button = DualActionButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = button
        button.action = #selector(DualActionButton.activatePrimary)
        return button
    }
    func updateNSView(_ button: DualActionButton, context: Context) {
        button.image = ToolbarIconLayout.image(referenceAsset.flatMap { UIReferenceAssets.image($0, dark: context.environment.colorScheme == .dark) } ?? NSImage(systemSymbolName: symbol, accessibilityDescription: help))
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = active ? .systemOrange : .secondaryLabelColor
        button.toolTip = nil
        BobTooltip.attach(to: button, text: help)
        button.setAccessibilityLabel(help)
        button.primary = primary
        button.secondary = secondary
        button.menuActions = menuActions
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DualActionButton, context: Context) -> CGSize? {
        ToolbarIconLayout.fittingSize(proposal)
    }
}

final class DualActionButton: ToolbarIconButton {
    var primary: () -> Void = {}
    var secondary: () -> Void = {}
    var menuActions: [ToolbarMenuAction] = []
    private var retainedTargets: [MenuActionTarget] = []
    @objc func activatePrimary() {
        guard !menuActions.isEmpty else { primary(); return }
        let menu = NSMenu()
        retainedTargets = menuActions.map { MenuActionTarget($0.action) }
        for (index, action) in menuActions.enumerated() {
            if action.title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: action.title, action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
            item.target = retainedTargets[index]
            item.isEnabled = action.enabled
            item.state = action.checked ? .on : .off
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 3), in: self)
    }
    override func rightMouseDown(with event: NSEvent) { secondary() }
}

private final class MenuActionTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

import AppKit
import UniformTypeIdentifiers

@MainActor
final class StatusBarContentView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onClick: ((Bool) -> Void)?
    var onImages: (([URL]) -> Void)?
    var onImageData: ((Data) -> Void)?
    private var dragHighlighted = false
    private var rightPressed = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pop")
        BobTooltip.attach(to: self, text: "Pop · 翻译与 OCR")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if dragHighlighted || rightPressed { NSColor.controlAccentColor.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill() }
        let side = min(18, min(bounds.width - 4, bounds.height - 4))
        image?.draw(in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightPressed = true; needsDisplay = true }
        else { onClick?(false) }
    }
    override func mouseUp(with event: NSEvent) { finishRightAction() }
    override func rightMouseDown(with event: NSEvent) { rightPressed = true; needsDisplay = true }
    override func rightMouseUp(with event: NSEvent) { finishRightAction() }
    override func mouseExited(with event: NSEvent) { finishRightAction() }
    private func finishRightAction() {
        guard rightPressed else { return }
        rightPressed = false; needsDisplay = true; onClick?(true)
    }
    override func accessibilityPerformPress() -> Bool { onClick?(false); return true }

    private func imageURLs(_ board: NSPasteboard) -> [URL] {
        let values = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return values.filter { url in
            guard url.isFileURL else { return false }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        dragHighlighted = !imageURLs(board).isEmpty || board.availableType(from: [.png, .tiff]) != nil
        needsDisplay = true
        return dragHighlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragHighlighted = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dragHighlighted = false; needsDisplay = true }
        let board = sender.draggingPasteboard
        let urls = imageURLs(board)
        if !urls.isEmpty { onImages?(urls); return true }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) { onImageData?(data); return true }
        return false
    }
}

import AppKit
import Carbon

private let overlayEscapeSignature: OSType = 0x506F4F76 // PoOv
private let overlayEscapeHandler: EventHandlerUPP = { _, event, data in
    guard let event, let data else { return OSStatus(eventNotHandledErr) }
    var hotkey = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &hotkey) == noErr,
          hotkey.signature == overlayEscapeSignature else { return OSStatus(eventNotHandledErr) }
    let owner = Unmanaged<NativeImageOverlay>.fromOpaque(data).takeUnretainedValue()
    DispatchQueue.main.async { owner.close() }
    return noErr
}

/// A temporary click-through image at the captured screen location. Only its small
/// close toolbar receives input; interacting with the original app dismisses it.
@MainActor
final class NativeImageOverlay: NSObject {
    static let shared = NativeImageOverlay()
    private var imagePanel: NSPanel?
    private var toolbarPanel: NSPanel?
    private var canvas: NativeOverlayCanvas?
    private var countLabel: NSTextField?
    private var expiry: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var escapeRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onClose: (() -> Void)?
    var isVisible: Bool { imagePanel != nil }

    func show(capture: CapturedRegion, document: OCRDocument, translations: [Int: String]) throws {
        guard let image = NSImage(contentsOf: capture.url), capture.screenRect.width > 0,
              capture.screenRect.height > 0, capture.screenRect.minX.isFinite, capture.screenRect.minY.isFinite,
              capture.screenRect.width.isFinite, capture.screenRect.height.isFinite else {
            throw PopError.message("无法显示原图翻译：图片或屏幕坐标无效。")
        }
        close()
        let rect = capture.screenRect
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pop · 原图翻译"
        panel.isOpaque = true; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NativeOverlayCanvas(frame: NSRect(origin: .zero, size: rect.size))
        content.image = image; content.document = document; content.translations = translations
        panel.contentView = content
        imagePanel = panel; canvas = content
        panel.orderFrontRegardless()

        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect.insetBy(dx: -20, dy: -50)
        let toolbarWidth: CGFloat = min(270, max(210, visible.width))
        let x = min(max(rect.maxX - toolbarWidth, visible.minX + 4), visible.maxX - toolbarWidth - 4)
        let desiredY = rect.maxY + 7
        let y = desiredY + 36 <= visible.maxY ? desiredY : max(visible.minY + 4, rect.maxY - 43)
        let toolbar = NSPanel(contentRect: NSRect(x: x, y: y, width: toolbarWidth, height: 36),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.isOpaque = false; toolbar.backgroundColor = .clear; toolbar.hasShadow = true
        toolbar.level = .floating; toolbar.hidesOnDeactivate = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: toolbar.frame.size))
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 8
        let title = NSTextField(labelWithString: translations.isEmpty ? "原图翻译 · 翻译中…" : "原图翻译 · \(translations.count) 处")
        title.font = .systemFont(ofSize: 12)
        let close = NSButton(title: "关闭 (Esc)", target: self, action: #selector(closeClicked))
        close.bezelStyle = .inline; close.controlSize = .small
        let stack = NSStackView(views: [title, NSView(), close])
        stack.orientation = .horizontal; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: material.centerYAnchor)
        ])
        toolbar.contentView = material; toolbarPanel = toolbar; countLabel = title
        toolbar.orderFrontRegardless()
        installEscape()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.toolbarPanel { self.close() }
            return event
        }
        resetExpiry()
    }

    func update(translations: [Int: String]) {
        guard let canvas else { return }
        canvas.translations = translations; canvas.needsDisplay = true
        countLabel?.stringValue = "原图翻译 · \(translations.count) 处"
        resetExpiry()
    }

    @objc private func closeClicked() { close() }
    func close() {
        let wasVisible = imagePanel != nil
        expiry?.invalidate(); expiry = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil; localMouseMonitor = nil
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        escapeRef = nil; handlerRef = nil
        imagePanel?.orderOut(nil); imagePanel?.close(); imagePanel = nil
        toolbarPanel?.orderOut(nil); toolbarPanel?.close(); toolbarPanel = nil
        canvas = nil; countLabel = nil
        if wasVisible { onClose?() }
    }

    /// The same normalized-to-image mapping is used by the actual drawing view and tests.
    static func rect(for line: OCRLine, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + line.x * bounds.width, y: bounds.minY + line.y * bounds.height,
               width: line.width * bounds.width, height: line.height * bounds.height).intersection(bounds)
    }

    /// Offscreen fixture rendering exercises the actual overlay canvas without showing a window.
    static func render(image: NSImage, size: CGSize, document: OCRDocument, translations: [Int: String]) throws -> NSBitmapImageRep {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw PopError.message("无法创建原图翻译渲染缓冲区。") }
        let view = NativeOverlayCanvas(frame: NSRect(origin: .zero, size: size))
        view.image = image; view.document = document; view.translations = translations
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        context.flushGraphics()
        return bitmap
    }

    private func resetExpiry() {
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
    private func installEscape() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), overlayEscapeHandler, 1, &eventType,
                                  Unmanaged.passUnretained(self).toOpaque(), &handlerRef) == noErr else { return }
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: overlayEscapeSignature, id: 1),
                                        GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &escapeRef)
        if status != noErr { countLabel?.toolTip = "Esc 被其他软件占用，可点击关闭或在原软件中点击以收起。" }
    }
}

private final class NativeOverlayCanvas: NSView {
    var image: NSImage?
    var document = OCRDocument(text: "", lines: [], qrCodes: [])
    var translations: [Int: String] = [:]
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        for (index, line) in document.lines.enumerated() {
            guard let text = translations[index], !text.isEmpty else { continue }
            let rect = NativeImageOverlay.rect(for: line, in: bounds)
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
            NSColor.textBackgroundColor.withAlphaComponent(0.96).setFill(); rect.fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            var size = min(22, max(9, rect.height * 0.72))
            let available = rect.insetBy(dx: min(2, rect.width / 5), dy: min(1, rect.height / 5))
            while size > 7 {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]
                let measured = (text as NSString).boundingRect(with: available.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
                if measured.height <= available.height { break }
                size -= 0.5
            }
            (text as NSString).draw(in: available, withAttributes: [.font: NSFont.systemFont(ofSize: size),
                                                                 .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph])
        }
    }
}

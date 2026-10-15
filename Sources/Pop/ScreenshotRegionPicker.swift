import AppKit
import CoreGraphics

@MainActor
final class ScreenshotRegionPicker {
    struct Selection {
        let rect: CGRect
        let displayID: CGDirectDisplayID
        let lockRegion: Bool
    }
    private let snapshots: [ScreenshotDisplaySnapshot]
    private let candidates: [ScreenshotWindowCandidate]
    private let useNormalWindow: Bool
    private let showsTips: Bool
    private var windows: [NSWindow] = []
    private var views: [ScreenshotSelectionView] = []
    private var state: ScreenshotSelectionState
    private var activeDisplayID: CGDirectDisplayID = 0
    private var continuation: CheckedContinuation<Selection, Error>?
    private var eventMonitor: Any?
    private var cursorPushed = false

    init(snapshots: [ScreenshotDisplaySnapshot], candidates: [ScreenshotWindowCandidate], compatible: Bool, showsTips: Bool) {
        self.snapshots = snapshots; self.candidates = candidates; self.showsTips = showsTips
        // REA currentisNeedCompatibleApp() 0x1004f0738 compares exactly these
        // bundle IDs. Panel and normal window use the same capture API.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        useNormalWindow = compatible && ["com.google.Chrome", "com.microsoft.edgemac"].contains(front)
        state = ScreenshotSelectionState(bounds: snapshots.first?.screenFrame ?? .zero)
    }

    func select() async throws -> Selection {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let mouse = NSEvent.mouseLocation
            for snapshot in snapshots {
                let window: NSWindow
                if useNormalWindow {
                    window = ScreenshotNormalWindow(contentRect: snapshot.screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
                } else {
                    let panel = ScreenshotPanelWindow(contentRect: snapshot.screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = false
                    window = panel
                }
                window.isReleasedWhenClosed = false
                window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
                window.level = .screenSaver; window.hidesOnDeactivate = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.acceptsMouseMovedEvents = true
                let view = ScreenshotSelectionView(snapshot: snapshot, showsTips: showsTips)
                view.onHover = { [weak self] point in self?.hover(at: point, display: snapshot.displayID) }
                view.onDown = { [weak self] point in self?.begin(at: point, display: snapshot.displayID) }
                view.onDrag = { [weak self] point in self?.drag(to: point) }
                view.onUp = { [weak self] point in self?.complete(at: point) }
                view.onCancel = { [weak self] in self?.cancel() }
                window.contentView = view; views.append(view); windows.append(window)
                window.orderFrontRegardless()
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, self.continuation != nil,
                      let window = event.window, self.windows.contains(where: { $0 === window }) else { return event }
                if event.keyCode == 53 && event.type == .keyDown { self.cancel(); return nil }
                if event.keyCode == 49 { self.state.setSpaceHeld(event.type == .keyDown); self.refresh(); return nil }
                if event.keyCode == 2 && event.type == .keyDown {
                    if let rect = self.state.selectionRect, ScreenshotSelectionState.isValid(rect) {
                        self.finish(.success(Selection(rect: rect, displayID: self.activeDisplayID, lockRegion: true)))
                    }
                    return nil
                }
                return nil
            }
            if useNormalWindow { NSApp.activate(ignoringOtherApps: true) }
            if let index = snapshots.firstIndex(where: { $0.screenFrame.contains(mouse) }) {
                windows[index].makeKey(); windows[index].makeFirstResponder(views[index])
                hover(at: mouse, display: snapshots[index].displayID)
            } else if let window = windows.first, let view = views.first {
                window.makeKey(); window.makeFirstResponder(view)
            }
            NSCursor.crosshair.push(); cursorPushed = true
            if windows.isEmpty { cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }
    private func hover(at point: CGPoint, display: CGDirectDisplayID) {
        guard !state.isDragging, let snapshot = snapshots.first(where: { $0.displayID == display }) else { return }
        activeDisplayID = display
        state.hover(at: point, candidates: candidates, bounds: snapshot.screenFrame)
        if let index = snapshots.firstIndex(where: { $0.displayID == display }), !windows[index].isKeyWindow {
            windows[index].makeKey(); windows[index].makeFirstResponder(views[index])
        }
        refresh()
    }
    private func begin(at point: CGPoint, display: CGDirectDisplayID) {
        hover(at: point, display: display)
        state.begin(at: point); refresh()
    }
    private func drag(to point: CGPoint) { state.drag(to: point); refresh() }
    private func complete(at point: CGPoint) {
        guard let rect = state.finish(at: point) else { cancel(); return }
        finish(.success(Selection(rect: rect, displayID: activeDisplayID, lockRegion: false)))
    }
    private func refresh() {
        for view in views {
            let active = view.snapshot.displayID == activeDisplayID
            view.update(rect: active ? state.selectionRect : nil, pointer: state.pointer,
                        active: active, dragging: state.isDragging)
        }
    }
    private func finish(_ result: Result<Selection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll(); views.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        continuation.resume(with: result)
    }
}

private final class ScreenshotPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
private final class ScreenshotNormalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScreenshotSelectionView: NSView {
    let snapshot: ScreenshotDisplaySnapshot
    var onHover: ((CGPoint) -> Void)?
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private let screenImage: NSImage
    private var selected: CGRect?
    private var pointer = CGPoint.zero
    private var active = false
    private var dragging = false
    private var tracking: NSTrackingArea?
    private let tips: ScreenshotTipsView?
    private var magnifierRect = CGRect.zero

    init(snapshot: ScreenshotDisplaySnapshot, showsTips: Bool) {
        self.snapshot = snapshot
        screenImage = NSImage(cgImage: snapshot.image, size: snapshot.screenFrame.size)
        tips = showsTips ? ScreenshotTipsView() : nil
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
        if let tips { addSubview(tips) }
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
        super.updateTrackingAreas()
    }
    private func global(_ event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
    override func mouseEntered(with event: NSEvent) { onHover?(global(event)) }
    override func mouseMoved(with event: NSEvent) { onHover?(global(event)) }
    override func mouseDown(with event: NSEvent) { onDown?(global(event)) }
    override func mouseDragged(with event: NSEvent) { onDrag?(global(event)) }
    override func mouseUp(with event: NSEvent) { onUp?(global(event)) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }

    func update(rect: CGRect?, pointer: CGPoint, active: Bool, dragging: Bool) {
        selected = rect.map { $0.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY) }
        self.pointer = CGPoint(x: pointer.x - snapshot.screenFrame.minX, y: pointer.y - snapshot.screenFrame.minY)
        self.active = active; self.dragging = dragging
        positionAccessories(); needsDisplay = true
    }
    private func positionAccessories() {
        let margin: CGFloat = 16
        var origin = CGPoint(x: pointer.x + 22, y: pointer.y - 154)
        if origin.x + 100 > bounds.maxX - margin { origin.x = pointer.x - 122 }
        if origin.y < margin { origin.y = pointer.y + 22 }
        origin.x = min(max(margin, origin.x), max(margin, bounds.width - 100 - margin))
        origin.y = min(max(margin, origin.y), max(margin, bounds.height - 132 - margin))
        magnifierRect = CGRect(origin: origin, size: CGSize(width: 100, height: 132))
        guard let tips else { return }
        tips.update(selectionStarted: dragging)
        tips.isHidden = !active
        let size = tips.frame.size
        let origins = [CGPoint(x: bounds.maxX-size.width-margin, y: margin), CGPoint(x: margin,y: margin),
                       CGPoint(x: bounds.maxX-size.width-margin,y: bounds.maxY-size.height-margin),
                       CGPoint(x: margin,y: bounds.maxY-size.height-margin)]
        if let origin = origins.first(where: {
            let box = CGRect(origin: $0, size: size)
            return !box.insetBy(dx: -12, dy: -12).contains(self.pointer) && !box.intersects(magnifierRect)
                && !(selected?.intersects(box) ?? false)
        }) { tips.setFrameOrigin(origin) }
        else { tips.isHidden = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        screenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.30).setFill()
        let mask = NSBezierPath(rect: bounds)
        if let selected, !selected.isNull { mask.append(NSBezierPath(rect: selected)); mask.windingRule = .evenOdd }
        mask.fill()
        if let selected, !selected.isNull {
            NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect: selected); path.lineWidth = 1; path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let text = "\(Int(selected.width)) × \(Int(selected.height))"
            let size = (text as NSString).size(withAttributes: attributes)
            let label = CGRect(x: max(4, min(selected.minX, bounds.width-size.width-12)),
                               y: selected.minY > 26 ? selected.minY-24 : min(bounds.height-24, selected.maxY+4),
                               width: size.width+10, height: 20)
            NSColor.black.withAlphaComponent(0.72).setFill(); NSBezierPath(roundedRect: label, xRadius: 4,yRadius: 4).fill()
            (text as NSString).draw(at: CGPoint(x:label.minX+5,y:label.minY+3),withAttributes:attributes)
        }
        if active { drawMagnifier() }
    }
    private func drawMagnifier() {
        let box = magnifierRect
        NSColor.black.withAlphaComponent(0.88).setFill(); NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        let sx = CGFloat(snapshot.image.width) / bounds.width, sy = CGFloat(snapshot.image.height) / bounds.height
        let sampleSize: CGFloat = 25
        let sample = CGRect(x: pointer.x*sx-sampleSize/2, y: (bounds.height-pointer.y)*sy-sampleSize/2,
                            width:sampleSize,height:sampleSize).intersection(CGRect(x:0,y:0,width:snapshot.image.width,height:snapshot.image.height))
        let imageBox = CGRect(x:box.minX,y:box.minY+32,width:100,height:100)
        if let image = snapshot.image.cropping(to:sample) {
            NSImage(cgImage:image,size:sample.size).draw(in:imageBox,from:.zero,operation:.sourceOver,fraction:1,
                                                       respectFlipped:false,hints:[.interpolation:NSImageInterpolation.none])
        }
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        let cross = NSBezierPath(); cross.move(to:CGPoint(x:imageBox.midX,y:imageBox.minY));cross.line(to:CGPoint(x:imageBox.midX,y:imageBox.maxY))
        cross.move(to:CGPoint(x:imageBox.minX,y:imageBox.midY));cross.line(to:CGPoint(x:imageBox.maxX,y:imageBox.midY));cross.lineWidth=0.5;cross.stroke()
        NSColor.white.withAlphaComponent(0.8).setStroke();let border=NSBezierPath(roundedRect:box,xRadius:6,yRadius:6);border.lineWidth=0.5;border.stroke()
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:NSColor.white]
        let text = "\(Int(pointer.x)), \(Int(bounds.height-pointer.y))"
        let size=(text as NSString).size(withAttributes:attributes)
        (text as NSString).draw(at:CGPoint(x:box.midX-size.width/2,y:box.minY+10),withAttributes:attributes)
    }
}

@MainActor
final class ScreenshotTipsView: NSVisualEffectView {
    private var selectionStarted: Bool?
    init() {
        super.init(frame:CGRect(x:0,y:0,width:268,height:48))
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer=true;layer?.cornerRadius=10;layer?.borderWidth=0.5;layer?.borderColor=NSColor.white.withAlphaComponent(0.4).cgColor
        update(selectionStarted: false)
    }
    /// REA 0x1004fa1c8 gates Space/D prompt rows on SnipViewController.isStart.
    /// Rebuild only when the selection phase changes, before collision placement.
    func update(selectionStarted: Bool) {
        guard self.selectionStarted != selectionStarted else { return }
        self.selectionStarted = selectionStarted
        subviews.forEach { $0.removeFromSuperview() }
        var rows = [("Esc", "退出截图")]
        if selectionStarted {
            rows += [("Space", "按住整体移动截图区域"), ("D", "锁定截图位置并退出截图")]
        }
        setFrameSize(CGSize(width: 268, height: CGFloat(rows.count * 28 + 20)))
        for (index,row) in rows.enumerated() {
            let y=frame.height-32-CGFloat(index*28)
            let key=ScreenshotKeyCap(frame:CGRect(x:14,y:y,width:row.0 == "Space" ? 46 : 20,height:20),text:row.0)
            addSubview(key)
            let label=NSTextField(labelWithString:row.1);label.font = .systemFont(ofSize:12);label.textColor = .white
            label.frame=CGRect(x:key.frame.maxX+12,y:y+2,width:184,height:18);addSubview(label)
        }
    }
    required init?(coder:NSCoder){nil}
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}
private final class ScreenshotKeyCap:NSView {
    let text:String
    init(frame:NSRect,text:String){self.text=text;super.init(frame:frame)}
    required init?(coder:NSCoder){nil}
    override func draw(_ dirtyRect:NSRect){
        NSColor.white.setFill();NSBezierPath(roundedRect:bounds,xRadius:4,yRadius:4).fill()
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.black]
        let size=(text as NSString).size(withAttributes:attrs)
        (text as NSString).draw(at:CGPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attrs)
    }
}

import AppKit
import CoreGraphics

/// A live screen-region lock, not a captured image. Its interior stays click-through.
/// REA 0x1004ed49c reuses this frame on subsequent screenshot requests;
/// 0x1004f4700 drags the window using its 24pt grip, while close clears the lock.
@MainActor
final class ScreenshotRegionLock: NSObject, NSWindowDelegate {
    static let shared = ScreenshotRegionLock()
    static let didChange = Notification.Name("PopScreenshotRegionLockDidChange")
    private var border: NSPanel?
    private var controls: NSPanel?
    private var toolbarOffset = CGPoint.zero
    private var updating = false
    var region: CGRect? { border?.frame }
    var windowIDs: [CGWindowID] {
        [border, controls].compactMap { panel in
            guard let panel, panel.windowNumber > 0 else { return nil }
            return CGWindowID(panel.windowNumber)
        }
    }

    func show(rect: CGRect) {
        close()
        guard ScreenshotSelectionState.isValid(rect) else { return }
        let border = NSPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        border.isReleasedWhenClosed=false; border.backgroundColor = .clear; border.isOpaque=false; border.hasShadow=false
        border.level = .floating; border.hidesOnDeactivate=false; border.ignoresMouseEvents=true
        border.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        border.contentView = ScreenshotLockBorder(frame:CGRect(origin:.zero,size:rect.size))
        self.border=border
        let frame=controlFrame(for:rect)
        toolbarOffset=CGPoint(x:frame.minX-rect.minX,y:frame.minY-rect.minY)
        let controls=ScreenshotLockPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        controls.isReleasedWhenClosed=false;controls.backgroundColor = .clear;controls.isOpaque=false;controls.hasShadow=true
        controls.level = .floating;controls.hidesOnDeactivate=false
        controls.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        let view=ScreenshotLockControls(frame:CGRect(origin:.zero,size:frame.size))
        view.onClose={ [weak self] in self?.close() }
        controls.contentView=view;controls.delegate=self;self.controls=controls
        border.orderFrontRegardless();controls.orderFrontRegardless()
        NotificationCenter.default.post(name:Self.didChange,object:nil)
    }

    func close() {
        guard border != nil || controls != nil else { return }
        controls?.delegate=nil
        controls?.orderOut(nil);controls?.close();controls=nil
        border?.orderOut(nil);border?.close();border=nil
        NotificationCenter.default.post(name:Self.didChange,object:nil)
    }
    func windowDidMove(_ notification: Notification) {
        guard !updating, let controls, let border, notification.object as? NSWindow === controls else { return }
        updating=true;defer{updating=false}
        border.setFrameOrigin(CGPoint(x:controls.frame.minX-toolbarOffset.x,y:controls.frame.minY-toolbarOffset.y))
    }
    func windowDidEndLiveResize(_ notification:Notification) {
        NotificationCenter.default.post(name:Self.didChange,object:nil)
    }
    private func controlFrame(for rect:CGRect)->CGRect {
        let size=CGSize(width:64,height:32)
        let screen=NSScreen.screens.first(where:{$0.frame.contains(CGPoint(x:rect.midX,y:rect.midY))})?.frame ?? rect
        var origin=CGPoint(x:rect.maxX-size.width,y:rect.maxY+6)
        if origin.y+size.height>screen.maxY {origin.y=rect.maxY-size.height-6}
        origin.x=max(screen.minX,min(origin.x,screen.maxX-size.width))
        origin.y=max(screen.minY,min(origin.y,screen.maxY-size.height))
        return CGRect(origin:origin,size:size)
    }
}

private final class ScreenshotLockPanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}
private final class ScreenshotLockBorder:NSView {
    override func draw(_ dirtyRect:NSRect) {
        NSColor.systemBlue.setStroke()
        let path=NSBezierPath(rect:bounds.insetBy(dx:1.5,dy:1.5));path.lineWidth=3;path.stroke()
    }
}
@MainActor
private final class ScreenshotLockControls:NSVisualEffectView {
    var onClose:(()->Void)?
    override init(frame:NSRect){
        super.init(frame:frame)
        material = .hudWindow;blendingMode = .behindWindow;state = .active
        wantsLayer=true;layer?.cornerRadius=6
        let close=NSButton(frame:CGRect(x:4,y:4,width:24,height:24))
        close.bezelStyle = .regularSquare;close.isBordered=false
        close.image=Self.icon("snip_lock_close",fallback:"xmark");close.imagePosition = .imageOnly
        close.contentTintColor = .labelColor;close.toolTip="取消锁定截图区域"
        close.target=self;close.action=#selector(closePressed);addSubview(close)
        let drag=ScreenshotLockDragView(frame:CGRect(x:36,y:4,width:24,height:24))
        drag.toolTip="按下拖拽窗口";addSubview(drag)
    }
    required init?(coder:NSCoder){nil}
    @objc private func closePressed(){onClose?()}
    fileprivate static func icon(_ name:String,fallback:String)->NSImage? {
        UIReferenceAssets.image(name) ?? NSImage(systemSymbolName:fallback,accessibilityDescription:nil)
    }
}
@MainActor
private final class ScreenshotLockDragView:NSView {
    override func draw(_ dirtyRect:NSRect){
        ScreenshotLockControls.icon("snip_lock_drag",fallback:"arrow.up.and.down.and.arrow.left.and.right")?
            .draw(in:bounds.insetBy(dx:4,dy:4),from:.zero,operation:.sourceOver,fraction:1)
    }
    override func resetCursorRects(){addCursorRect(bounds,cursor:.openHand)}
    override func mouseDown(with event:NSEvent){
        NSCursor.closedHand.push();defer{NSCursor.pop()}
        window?.performDrag(with:event)
    }
}

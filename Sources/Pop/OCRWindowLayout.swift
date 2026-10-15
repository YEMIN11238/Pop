import AppKit

/// Keep a canonical single-pane width, independent of AppKit's minimum-size
/// enforcement, hosting-view fitting size, and the last autosaved frame mode.
struct OCRWindowLayout {
    private(set) var compactWidth: CGFloat
    private(set) var imageVisible = false

    init(savedCompactWidth: CGFloat = 400) {
        compactWidth = savedCompactWidth.isFinite && savedCompactWidth >= 400 && savedCompactWidth <= 16_384
            ? savedCompactWidth : 400
    }

    mutating func recordUserResize(width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let value = imageVisible ? (width - 36) * 0.5 + 24 : width
        compactWidth = max(400, value)
    }

    mutating func frame(from oldFrame: NSRect, showImage: Bool, screen: NSRect?) -> NSRect {
        imageVisible = showImage
        // Bob OCRViewController.changeImageSate(isHidden:), REA 0x10009f254.
        // The text pane retains its width and right edge when the image appears.
        let width = showImage ? (compactWidth - 24) * 2 + 36 : compactWidth
        var result = oldFrame
        result.size.width = width
        result.origin.x = oldFrame.maxX - width
        result.size.height = max(showImage ? 400 : 260, oldFrame.height)
        result.origin.y = oldFrame.maxY - result.height
        if let screen {
            let bounds = screen.insetBy(dx: 8, dy: 8)
            result.size.width = min(result.width, bounds.width)
            result.size.height = min(result.height, bounds.height)
            result.origin.x = max(bounds.minX, min(result.minX, bounds.maxX - result.width))
            result.origin.y = max(bounds.minY, min(result.minY, bounds.maxY - result.height))
        }
        return result
    }

    @MainActor
    mutating func apply(to window: NSWindow, showImage: Bool, screen: NSRect?) {
        // Compute from our canonical width before changing minimum size: AppKit
        // can immediately grow the frame when contentMinSize is raised.
        let next = frame(from: window.frame, showImage: showImage, screen: screen)
        window.contentMinSize = NSSize(width: min(showImage ? 788 : 400, next.width),
                                       height: min(showImage ? 400 : 260, next.height))
        window.setFrame(next, display: window.isVisible)
    }
}

@MainActor
enum OCRWindowLayoutSelfCheck {
    static func run() throws -> [String] {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw PopError.message("OCR 窗口尺寸自检：" + message) }
        }
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let compact = NSRect(x: 1000, y: 200, width: 400, height: 620)
        var layout = OCRWindowLayout()
        let expanded = layout.frame(from: compact, showImage: true, screen: screen)
        try require(expanded.width == 788 && expanded.maxX == compact.maxX, "首次展开应为 788，保留文本栏右侧位置")
        let repeated = layout.frame(from: expanded, showImage: true, screen: screen)
        try require(repeated == expanded, "重复显示二次放大了窗口")
        let hidden = layout.frame(from: expanded, showImage: false, screen: screen)
        try require(hidden == compact, "隐藏图片没有还原 400 的单栏宽度")
        // Simulate an autosaved expanded/previously inflated frame at launch.
        var relaunched = OCRWindowLayout(savedCompactWidth: layout.compactWidth)
        let corruptSavedFrame = NSRect(x: 20, y: 200, width: 1694, height: 620)
        try require(relaunched.frame(from: corruptSavedFrame, showImage: true, screen: screen).width == 788,
                    "重启把上次双栏 frame 再次当成单栏展开")
        relaunched.recordUserResize(width: 1000)
        try require(relaunched.compactWidth == 506, "手动双栏调整没有换算为单栏基准")
        var resizedRelaunch = OCRWindowLayout(savedCompactWidth: relaunched.compactWidth)
        try require(resizedRelaunch.frame(from: expanded, showImage: true, screen: screen).width == 1000,
                    "重启丢失用户手动调整的宽度")
        try require(resizedRelaunch.frame(from: expanded, showImage: false, screen: screen).width == 506,
                    "手动调整后的收起宽度错误")
        let smallScreen = NSRect(x: 0, y: 0, width: 700, height: 600)
        var constrained = OCRWindowLayout()
        let fitted = constrained.frame(from: compact, showImage: true, screen: smallScreen)
        try require(fitted.width == 684 && fitted.height <= 584 && smallScreen.contains(fitted), "小屏展开越界")
        try require(constrained.frame(from: fitted, showImage: false, screen: smallScreen).width == 400,
                    "屏幕限宽污染单栏基准，收起后无法恢复")
        try require(OCRWindowLayout(savedCompactWidth: .nan).compactWidth == 400
                    && OCRWindowLayout(savedCompactWidth: 0).compactWidth == 400, "异常保存值未回退默认值")
        // Exercise the real AppKit minimum-size side effect without displaying UI.
        let window = NSWindow(contentRect: compact, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var native = OCRWindowLayout()
        native.apply(to: window, showImage: true, screen: screen)
        try require(window.frame.width == 788 && window.contentMinSize.width == 788 && !window.isVisible,
                    "实际 NSWindow 设置最小宽度后仍发生二次放大")
        native.apply(to: window, showImage: false, screen: screen)
        try require(window.frame.width == 400 && window.contentMinSize.width == 400, "实际 NSWindow 收起失败")
        return ["OCR 窗口宽度：400↔788、重复显示不放大、已展开 frame 重启不再展开、用户调整持久化、小屏限宽后恢复、真实隐藏 NSWindow 最小尺寸副作用均通过。"]
    }
}

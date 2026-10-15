import CoreGraphics
import Foundation

/// Synthetic coordinates and generated pixels only. Never requests screen permission.
enum ScreenshotSelfCheck {
    static func run() throws -> [String] {
        let bounds = CGRect(x: -1280, y: -200, width: 1280, height: 1024)
        let front = ScreenshotWindowCandidate(id: 1, rect: CGRect(x: -900, y: 100, width: 200, height: 200))
        let back = ScreenshotWindowCandidate(id: 2, rect: CGRect(x: -1100, y: 0, width: 800, height: 600))
        var state = ScreenshotSelectionState(bounds: bounds)
        state.hover(at: CGPoint(x: -800, y: 200), candidates: [front, back], bounds: bounds)
        try require(state.hoveredWindow == front, "悬停没有命中最前方窗口")
        state.begin(at: CGPoint(x: -800, y: 200))
        state.drag(to: CGPoint(x: -798, y: 200))
        try require(state.phase == .pendingWindow && state.finish(at: CGPoint(x: -798, y: 200)) == front.rect, "2 点以内的点击没有保留整窗")
        state.drag(to: CGPoint(x: -797.9, y: 200))
        try require(state.phase == .dragging && state.hoveredWindow == nil, "超过 2 点没有切换拖选")
        try require(state.finish(at: CGPoint(x: -796, y: 204)) == nil, "小于 5×5 的选区没有拒绝")
        try require(state.finish(at: CGPoint(x: -795, y: 205)) == CGRect(x: -800, y: 200, width: 5, height: 5), "5×5 边界没有接受")

        var moving = ScreenshotSelectionState(bounds: CGRect(x: 0, y: 0, width: 200, height: 150))
        moving.begin(at: CGPoint(x: 100, y: 100))
        moving.drag(to: CGPoint(x: 40, y: 40))
        moving.setSpaceHeld(true)
        moving.drag(to: CGPoint(x: 60, y: 50))
        try require(moving.selectionRect == CGRect(x: 60, y: 50, width: 60, height: 60), "空格没有整体移动反向拖选框")
        moving.drag(to: CGPoint(x: 400, y: 400))
        try require(moving.selectionRect == CGRect(x: 140, y: 90, width: 60, height: 60), "空格移动超出屏幕或改变框大小")
        moving.setSpaceHeld(false)
        moving.drag(to: CGPoint(x: 80, y: 60))
        try require(moving.selectionRect == CGRect(x: 80, y: 60, width: 120, height: 90), "释放空格后没有恢复拖选")

        let selection = CGRect(x: -1100.25, y: 100.25, width: 400.5, height: 300.5)
        let pixels = NativeScreenCoordinates.pixelRect(globalRect: selection, screenFrame: bounds, pixelSize: CGSize(width: 2560, height: 2048))
        try require(pixels == CGRect(x: 359, y: 846, width: 802, height: 602), "Retina/负原点裁剪坐标错误")
        let aligned = NativeScreenCoordinates.globalRect(pixelRect: pixels, screenFrame: bounds, pixelSize: CGSize(width: 2560, height: 2048))
        try require(aligned.contains(selection) && aligned.width - selection.width < 1 && aligned.height - selection.height < 1, "像素取整后的原位区域没有覆盖所选内容")
        try require(NativeScreenCoordinates.appKitRect(quartzRect: CGRect(x: -500, y: 900, width: 200, height: 100), primaryDisplayTop: 800)
                    == CGRect(x: -500, y: -200, width: 200, height: 100), "Quartz/AppKit 多屏原点转换错误")
        try require(NativeScreenCoordinates.pixelRect(globalRect: CGRect(x: 4000, y: 4000, width: 10, height: 10), screenFrame: bounds, pixelSize: CGSize(width: 2560, height: 2048)).isNull,
                    "屏幕之外的裁剪没有拒绝")

        // Every row has a distinct color, proving that top-left crop coordinates
        // match CGImage's actual cropped pixels rather than only inverse formulas.
        var rgba = [UInt8]()
        for y in 0..<8 { for x in 0..<8 { rgba += [UInt8(x * 20), UInt8(y * 20), 90, 255] } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw failure("无法创建纯像素 fixture")
        }
        let frame = CGRect(x: -4, y: -4, width: 4, height: 4)
        let pixelCrop = NativeScreenCoordinates.pixelRect(globalRect: CGRect(x: -3, y: -2.5, width: 2, height: 1), screenFrame: frame, pixelSize: CGSize(width: 8, height: 8))
        guard let cropped = image.cropping(to: pixelCrop), let first = cropped.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { throw failure("fixture 裁剪失败") }
        var actual = [UInt8](repeating: 0, count: 4)
        let rendered = actual.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(first, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        try require(rendered && cropped.width == 4 && cropped.height == 2 && actual == [40, 60, 90, 255], "真实裁剪像素与屏幕原位坐标不一致：\(actual)")
        return [
            "截图窗口选择：前后层级、2pt 点击/拖动阈值、5×5 最小区域通过",
            "截图空格移动：反向选区保持大小、边缘约束、释放后恢复拖选通过",
            "截图多屏坐标：负原点、Retina 像素对齐、屏外拒绝和实际合成图片裁剪通过（未捕获屏幕）"
        ]
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw failure(message) }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PopScreenshotSelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

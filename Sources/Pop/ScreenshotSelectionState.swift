import CoreGraphics
import Foundation

struct ScreenshotWindowCandidate: Equatable {
    let id: UInt32
    let rect: CGRect
}

enum NativeScreenCoordinates {
    static func sourceRect(globalRect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: globalRect.minX - screenFrame.minX, y: screenFrame.maxY - globalRect.maxY,
               width: globalRect.width, height: globalRect.height)
    }
    static func rect(from start: CGPoint, to end: CGPoint, clippedTo bounds: CGRect) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x),
               height: abs(start.y - end.y)).intersection(bounds)
    }
    static func appKitRect(quartzRect: CGRect, primaryDisplayTop: CGFloat) -> CGRect {
        CGRect(x: quartzRect.minX, y: primaryDisplayTop - quartzRect.maxY,
               width: quartzRect.width, height: quartzRect.height)
    }
    static func pixelRect(globalRect: CGRect, screenFrame: CGRect, pixelSize: CGSize) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .null }
        let clipped = globalRect.intersection(screenFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return .null }
        let local = sourceRect(globalRect: clipped, screenFrame: screenFrame)
        let sx = pixelSize.width / screenFrame.width, sy = pixelSize.height / screenFrame.height
        return CGRect(x: floor(local.minX * sx), y: floor(local.minY * sy),
                      width: ceil(local.maxX * sx) - floor(local.minX * sx),
                      height: ceil(local.maxY * sy) - floor(local.minY * sy))
            .intersection(CGRect(origin: .zero, size: pixelSize))
    }
    static func globalRect(pixelRect: CGRect, screenFrame: CGRect, pixelSize: CGSize) -> CGRect {
        let sx = screenFrame.width / pixelSize.width, sy = screenFrame.height / pixelSize.height
        return CGRect(x: screenFrame.minX + pixelRect.minX * sx,
                      y: screenFrame.maxY - pixelRect.maxY * sy,
                      width: pixelRect.width * sx, height: pixelRect.height * sy)
    }
}

/// Pure interaction state, separated from window events and screen capture.
/// REA: SnipViewController mouseDragged 0x1004fb76c uses hypot > 2;
/// mouseUp 0x1004fc3a8 accepts both dimensions >= 5 screen points.
struct ScreenshotSelectionState {
    enum Phase: Equatable { case hovering, pendingWindow, dragging }
    var bounds: CGRect
    private(set) var phase: Phase = .hovering
    private(set) var hoveredWindow: ScreenshotWindowCandidate?
    private(set) var pointer = CGPoint.zero
    private(set) var spaceHeld = false
    private var anchor = CGPoint.zero
    private var end = CGPoint.zero
    private var downPoint = CGPoint.zero
    private var lastMovePoint = CGPoint.zero

    init(bounds: CGRect) {
        self.bounds = bounds
    }

    var isDragging: Bool { phase != .hovering }
    var selectionRect: CGRect? {
        if phase == .hovering || phase == .pendingWindow { return hoveredWindow?.rect.intersection(bounds) }
        return NativeScreenCoordinates.rect(from: anchor, to: end, clippedTo: bounds)
    }

    mutating func hover(at point: CGPoint, candidates: [ScreenshotWindowCandidate], bounds: CGRect) {
        guard phase == .hovering else { return }
        self.bounds = bounds
        pointer = point
        // CGWindowList's on-screen ordering is front to back; never select a
        // larger background window through a smaller foreground window.
        hoveredWindow = candidates.first { $0.rect.contains(point) }
    }

    mutating func begin(at point: CGPoint) {
        pointer = point
        downPoint = point
        anchor = clamped(point)
        end = anchor
        lastMovePoint = point
        phase = hoveredWindow == nil ? .dragging : .pendingWindow
    }

    mutating func drag(to point: CGPoint) {
        pointer = point
        if phase == .pendingWindow {
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) > 2 else { return }
            phase = .dragging
            hoveredWindow = nil
            anchor = clamped(downPoint)
            end = clamped(point)
            lastMovePoint = point
            return
        }
        guard phase == .dragging else { return }
        if spaceHeld, let rect = selectionRect {
            let dx = min(bounds.maxX - rect.maxX, max(bounds.minX - rect.minX, point.x - lastMovePoint.x))
            let dy = min(bounds.maxY - rect.maxY, max(bounds.minY - rect.minY, point.y - lastMovePoint.y))
            anchor.x += dx; anchor.y += dy
            end.x += dx; end.y += dy
        } else { end = clamped(point) }
        lastMovePoint = point
    }

    mutating func setSpaceHeld(_ held: Bool) {
        spaceHeld = held
        lastMovePoint = pointer
    }

    mutating func finish(at point: CGPoint) -> CGRect? {
        if phase != .hovering { drag(to: point) }
        guard let rect = selectionRect, Self.isValid(rect) else { return nil }
        return rect
    }

    static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width >= 5 && rect.height >= 5
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
    }
}

import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedRegion {
    let url: URL
    /// AppKit global screen points, including negative secondary-display origins.
    let screenRect: CGRect
    var displayID: CGDirectDisplayID = 0
    var pixelSize: CGSize = .zero
}

struct ScreenshotDisplaySnapshot {
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    let image: CGImage
}

/// Owns the one system-wide selector. Superseded requests cannot dismiss a newer one.
@MainActor
private enum ScreenshotCaptureCoordinator {
    static var request: UUID?
    static weak var picker: ScreenshotRegionPicker?
    static func begin() -> UUID {
        picker?.cancel()
        let id = UUID(); request = id
        return id
    }
    static func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard request == id else { throw CancellationError() }
    }
    static func finish(_ id: UUID) {
        guard request == id else { return }
        request = nil; picker = nil
    }
    static func cancel(_ id: UUID) {
        guard request == id else { return }
        picker?.cancel()
    }
}

extension NativeScreenshot {
    @MainActor static var isRegionLocked: Bool { ScreenshotRegionLock.shared.region != nil }
    @MainActor static func clearRegionLock() { ScreenshotRegionLock.shared.close() }

    /// A D lock ends with CancellationError so callers do not OCR a lock command.
    @MainActor static func captureLocatedRegion() async throws -> CapturedRegion {
        guard CGPreflightScreenCaptureAccess() else {
            throw PopError.message("截图需要屏幕录制权限，请先在系统设置中为 Pop 开启。")
        }
        let id = ScreenshotCaptureCoordinator.begin()
        defer { ScreenshotCaptureCoordinator.finish(id) }
        return try await withTaskCancellationHandler {
            try ScreenshotCaptureCoordinator.check(id)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try ScreenshotCaptureCoordinator.check(id)
            if let lock = ScreenshotRegionLock.shared.region {
                if let screen = NSScreen.screens.filter({ $0.frame.intersects(lock) }).max(by: {
                    let a = $0.frame.intersection(lock), b = $1.frame.intersection(lock)
                    return a.width * a.height < b.width * b.height
                }), let display = content.displays.first(where: { $0.displayID == screen.screenshotDisplayID }) {
                    let rect = lock.intersection(screen.frame)
                    if ScreenshotSelectionState.isValid(rect) {
                        let snapshot = try await snapshot(display: display, screen: screen, content: content,
                                                          excluding: ScreenshotRegionLock.shared.windowIDs)
                        try ScreenshotCaptureCoordinator.check(id)
                        return try write(snapshot: snapshot, rect: rect)
                    }
                }
                // A disconnected display or an entirely off-screen lock must not
                // leave an invisible lock preventing the next manual selection.
                ScreenshotRegionLock.shared.close()
            }
            // REA 0x1004ee47c/0x1004fb8c0: crop the frozen selector image,
            // rather than recapturing live desktop after the selector disappears.
            var snapshots: [ScreenshotDisplaySnapshot] = []
            for screen in NSScreen.screens {
                guard let display = content.displays.first(where: { $0.displayID == screen.screenshotDisplayID }) else { continue }
                snapshots.append(try await snapshot(display: display, screen: screen, content: content, excluding: []))
                try ScreenshotCaptureCoordinator.check(id)
            }
            guard !snapshots.isEmpty else { throw PopError.message("系统没有可用屏幕。") }
            let preferences = ConfigurationRepository.shared.preferences
            let picker = ScreenshotRegionPicker(snapshots: snapshots, candidates: windowCandidates(),
                                                compatible: preferences.screenshotCompatibilityMode,
                                                showsTips: preferences.screenshotShowsTips)
            ScreenshotCaptureCoordinator.picker = picker
            let selection = try await picker.select()
            try ScreenshotCaptureCoordinator.check(id)
            if selection.lockRegion {
                ScreenshotRegionLock.shared.show(rect: selection.rect)
                throw CancellationError()
            }
            guard let snapshot = snapshots.first(where: { $0.displayID == selection.displayID }) else {
                throw PopError.message("所选屏幕已断开，请重新截图。")
            }
            return try write(snapshot: snapshot, rect: selection.rect)
        } onCancel: {
            Task { @MainActor in ScreenshotCaptureCoordinator.cancel(id) }
        }
    }

    @MainActor private static func snapshot(display: SCDisplay, screen: NSScreen, content: SCShareableContent,
                                           excluding ids: [CGWindowID]) async throws -> ScreenshotDisplaySnapshot {
        let excluded = content.windows.filter { ids.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
        configuration.height = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return ScreenshotDisplaySnapshot(screenFrame: screen.frame, displayID: display.displayID, image: image)
    }

    private static func write(snapshot: ScreenshotDisplaySnapshot, rect: CGRect) throws -> CapturedRegion {
        try Task.checkCancellation()
        let size = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixels = NativeScreenCoordinates.pixelRect(globalRect: rect, screenFrame: snapshot.screenFrame, pixelSize: size)
        guard !pixels.isNull, let image = snapshot.image.cropping(to: pixels) else {
            throw PopError.message("截图区域无效，请重新选择。")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pop-region-\(UUID().uuidString).png")
        do {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw PopError.message("无法创建截图文件。")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw PopError.message("保存截图失败。") }
            try Task.checkCancellation()
            return CapturedRegion(url: url,
                                  screenRect: NativeScreenCoordinates.globalRect(pixelRect: pixels, screenFrame: snapshot.screenFrame, pixelSize: size),
                                  displayID: snapshot.displayID, pixelSize: CGSize(width: image.width, height: image.height))
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    @MainActor private static func windowCandidates() -> [ScreenshotWindowCandidate] {
        guard let primary = NSScreen.screens.first(where: { $0.screenshotDisplayID == CGMainDisplayID() }),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        // CGWindowList's on-screen ordering is front-to-back. No window titles or content
        // are retained; public geometry is used solely for hover hit-testing.
        return list.compactMap { item in
            guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  ((item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= 0 else { return nil }
            let rect = NativeScreenCoordinates.appKitRect(quartzRect: quartz, primaryDisplayTop: primary.frame.maxY)
            guard ScreenshotSelectionState.isValid(rect) else { return nil }
            return ScreenshotWindowCandidate(id: id, rect: rect)
        }
    }
}

extension NSScreen {
    fileprivate var screenshotDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

struct ContinuousOCRCapture {
    let capture: CapturedRegion
    let document: OCRDocument
}

enum NativeContinuousOCR {
    /// One explicit capture per call; the owner decides whether to append or stop.
    static func captureNext(accurate: Bool = true, languages: [String] = ["zh-Hans", "en-US"],
                            languageCorrection: Bool = true) async throws -> ContinuousOCRCapture {
        let capture = try await NativeScreenshot.captureLocatedRegion()
        do {
            let document = try await VisionOCR.recognize(url: capture.url, accurate: accurate,
                                                       languages: languages, languageCorrection: languageCorrection)
            return ContinuousOCRCapture(capture: capture, document: document)
        } catch { try? FileManager.default.removeItem(at: capture.url); throw error }
    }
}

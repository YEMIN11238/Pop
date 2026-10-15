import AppKit

@MainActor
enum OCRImageQueueSelfCheck {
    static func run() async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pop-OCR-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState(windowRole: "ocr")
        defer { state.cleanup(); try? FileManager.default.removeItem(at: directory) }
        state.preferences.services = [.systemMedia(capability: "ocr", scope: "standaloneOCR")]
        state.preferences.autoCopyOCR = false
        state.preferences.ocrLanguages = ["en-US"]
        state.preferences.recognizeQRCode = false
        state.preferences.saveHistory = false
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        let broken = directory.appendingPathComponent("broken.png")
        try fixture("ALPHA 123", to: first)
        try fixture("BETA 456", to: second)
        try Data("not an image".utf8).write(to: broken)
        state.recognize(urls: [first, broken, second], translateAfter: false, silent: false)
        try await finish(state)
        guard state.ocrImages.tasks.count == 3,
              state.ocrImages.tasks[0].status == .completed,
              state.ocrImages.tasks[1].status == .failed,
              state.ocrImages.tasks[2].status == .completed,
              state.input.contains("ALPHA"), state.input.contains("BETA"),
              state.notice?.contains("broken.png") == true,
              state.lastOCRBatchOutcome?.failedCount == 1,
              state.imageURL == first else { throw PopError.message("多图真实识别自检：中间损坏图片影响了其他图片结果或默认预览。") }
        let secondID = state.ocrImages.tasks[2].id
        state.selectOCRImage(secondID)
        guard state.input.contains("BETA"), !state.input.contains("ALPHA"), state.imageURL == second else {
            throw PopError.message("多图真实识别自检：切换图片没有切换真实识别结果。")
        }
        state.mergeOCRImageText()
        guard state.input.contains("ALPHA"), state.input.contains("BETA"), state.imageURL == second else {
            throw PopError.message("多图真实识别自检：合并文字改变了预览图片或漏掉结果。")
        }
        state.continuousOCR = true
        state.recognize(urls: [first], translateAfter: false, silent: false)
        try await finish(state)
        guard state.ocrImages.tasks.count == 4, state.input.components(separatedBy: "ALPHA").count == 3 else {
            throw PopError.message("多图真实识别自检：连续识别未追加，或重复合并旧文本。")
        }
        try fixture("GAMMA 789", to: broken)
        state.retryOCRImages(state.ocrImages.tasks[1].id)
        try await finish(state)
        guard state.ocrImages.tasks.allSatisfy({ $0.status == .completed }), state.input.contains("GAMMA"), state.input.contains("BETA") else {
            throw PopError.message("多图真实识别自检：失败任务重试未恢复，或破坏其他任务。")
        }
        state.selectOCRImage(secondID)
        state.updateOCRText("BETA corrected")
        state.selectOCRImage(state.ocrImages.tasks[0].id)
        state.selectOCRImage(secondID)
        guard state.input == "BETA corrected" else { throw PopError.message("OCR 正文纠错在切图后丢失。") }
        state.mergeOCRImageText()
        guard state.input.contains("BETA corrected") else { throw PopError.message("OCR 合并文字没有包含单图纠错。") }
        state.updateOCRText("Edited combined document")
        state.selectOCRImage(secondID)
        state.mergeOCRImageText()
        guard state.input == "Edited combined document" else { throw PopError.message("OCR 合并文本编辑在切图后丢失。") }
        state.recognize(urls: [first], translateAfter: false, silent: false)
        try await finish(state)
        guard state.input.hasPrefix("Edited combined document\n\n"), state.input.contains("ALPHA"), !state.input.contains("GAMMA") else {
            throw PopError.message("连续 OCR 追加覆盖了合并文本编辑，或重复加入了旧文字。")
        }
        let newBroken = directory.appendingPathComponent("new-broken.png")
        try Data("still not an image".utf8).write(to: newBroken)
        let retainedText = state.input
        state.recognize(urls: [newBroken], translateAfter: false, silent: false)
        try await finish(state)
        guard state.input == retainedText, state.notice?.contains("new-broken.png") == true,
              let outcome = state.lastOCRBatchOutcome, outcome.failedCount == 1, !outcome.succeeded,
              !outcome.shouldCopy(autoCopy: true, silent: true, text: state.input) else {
            throw PopError.message("连续 OCR 新批全失败后复制旧文字、显示成功或隐藏了错误。")
        }
        state.clearInput()
        state.continuousOCR = false
        state.recognize(urls: [first], translateAfter: false, silent: false)
        state.cancelTranslation()
        guard state.canResumeOCRImages, state.ocrImages.tasks.count == 1,
              state.ocrImages.tasks[0].status == .waiting else {
            throw PopError.message("单图 OCR 取消后没有可以继续的任务。")
        }
        state.resumeOCRImages()
        try await finish(state)
        guard state.input.contains("ALPHA"), state.ocrImages.tasks[0].status == .completed, !state.canResumeOCRImages else {
            throw PopError.message("单图 OCR 取消后继续识别未完成。")
        }
        state.updateOCRText("Corrected single page")
        state.mergeOCRImageText()
        state.continuousOCR = true
        state.recognize(urls: [second], translateAfter: false, silent: false)
        try await finish(state)
        guard state.input.hasPrefix("Corrected single page\n\n"), state.input.contains("BETA") else {
            throw PopError.message("单图 OCR 纠错在追加识别后丢失。")
        }
        state.clearInput()
        guard state.ocrImages.tasks.isEmpty, state.input.isEmpty, state.imageURL == nil else {
            throw PopError.message("多图真实识别自检：清空后残留图片或文本。")
        }
        return ["多图 OCR 原生实测：混合成功失败、逐图切换、合并、连续追加、失败图重试、单图及合并编辑保留、新批全失败反馈、单图取消后继续、清空全部通过；未打开窗口或读取/写入剪贴板。"]
    }

    private static func finish(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(20)
        while state.recognizing, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !state.recognizing else { throw PopError.message("多图真实识别自检超时。") }
    }

    private static func fixture(_ text: String, to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 220,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw PopError.message("无法创建 OCR 队列测试图。") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 220).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 35, y: 75))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PopError.message("无法编码 OCR 队列测试图。") }
        try data.write(to: url)
    }
}

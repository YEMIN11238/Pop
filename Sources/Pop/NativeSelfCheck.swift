import AppKit
import CoreImage
import Foundation

/// End-to-end tests use only locally generated image fixtures. They do not
/// capture the screen, inspect another app, read the clipboard, or ask for permissions.
@MainActor
enum NativeSelfCheck {
    static func run() async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Pop-native-check-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [String] = []

        let textURL = directory.appendingPathComponent("ocr-fixture.png")
        try drawTextFixture(to: textURL)
        let document = try await VisionOCR.recognize(
            url: textURL, accurate: true, languages: ["en-US"], languageCorrection: true
        )
        for expected in ["Test", "OCR", "123"] {
            guard document.text.range(of: expected, options: .caseInsensitive) != nil else {
                throw PopError.message("OCR 自检失败：未在合成图片中识别到 \(expected)。实际结果：\(document.text)")
            }
        }
        guard !document.lines.isEmpty,
              document.lines.allSatisfy({ line in
                  line.x >= 0 && line.y >= 0 && line.width > 0 && line.height > 0 &&
                  line.x + line.width <= 1.001 && line.y + line.height <= 1.001 &&
                  line.confidence >= 0 && line.confidence <= 1
              }) else {
            throw PopError.message("OCR 自检失败：文字行坐标或置信度不合法。")
        }
        checks.append("原生 Vision OCR：合成图片成功识别 Test OCR 123，行坐标及置信度有效")

        let payload = "https://example.org/pop-self-check?fixture=qr-2026"
        let qrURL = directory.appendingPathComponent("qr-fixture.png")
        try drawQRFixture(payload: payload, to: qrURL)
        let qrDocument = try await VisionOCR.recognize(
            url: qrURL, accurate: true, languages: ["en-US"], languageCorrection: false
        )
        guard qrDocument.qrCodes.contains(payload) else {
            throw PopError.message("二维码自检失败：未能还原合成二维码的固定 URL。")
        }
        let disabledQR = try await VisionOCR.recognize(url: qrURL, accurate: true, languages: ["en-US"], languageCorrection: false, recognizeQRCodes: false)
        guard disabledQR.qrCodes.isEmpty else { throw PopError.message("二维码关闭设置没有停止二维码结果。") }
        checks.append("原生 Vision 二维码：本地固定 URL 完整识别，关闭二维码识别后不返回二维码结果")

        let fixture: [OCRLine] = [
            line("第三行右", x: 0.55, y: 0.40),
            line("第一行右", x: 0.55, y: 0.805),
            line("第二行", x: 0.10, y: 0.60),
            line("第三行左", x: 0.10, y: 0.405),
            line("第一行左", x: 0.10, y: 0.80)
        ]
        let ordered = VisionOCR.readingOrder(fixture).map(\.text)
        let expected = ["第一行左", "第一行右", "第二行", "第三行左", "第三行右"]
        guard ordered == expected else {
            throw PopError.message("OCR 排序自检失败：预期 \(expected)，实际 \(ordered)。")
        }
        guard VisionOCR.readingOrder([]).isEmpty else {
            throw PopError.message("OCR 排序自检失败：空输入没有返回空结果。")
        }
        checks.append("OCR 空间排序：乱序坐标按从上到下、每行从左到右排列，空输入通过")

        let columnFixture = (0..<4).flatMap { index in [
            OCRLine(text: "L\(index)", x: 0.08, y: 0.82 - Double(index) * 0.065, width: 0.31, height: 0.045, confidence: 1),
            OCRLine(text: "R\(index)", x: 0.57, y: 0.82 - Double(index) * 0.065, width: 0.31, height: 0.045, confidence: 1)
        ] }
        let columns = OCRTextLayout.orderedLines(columnFixture.reversed()).map(\.text)
        guard columns == ["L0", "L1", "L2", "L3", "R0", "R1", "R2", "R3"] else {
            throw PopError.message("OCR 分栏排序自检失败：\(columns)")
        }
        let paragraphFixture = [
            OCRLine(text: "This sentence", x: 0.1, y: 0.80, width: 0.7, height: 0.05, confidence: 1),
            OCRLine(text: "continues here.", x: 0.1, y: 0.73, width: 0.7, height: 0.05, confidence: 1),
            OCRLine(text: "A new paragraph.", x: 0.1, y: 0.55, width: 0.7, height: 0.05, confidence: 1)
        ]
        guard OCRTextLayout.text(from: paragraphFixture) == "This sentence continues here.\n\nA new paragraph.",
              OCRTextLayout.text(from: paragraphFixture, smartParagraphs: false) == "This sentence\ncontinues here.\nA new paragraph." else {
            throw PopError.message("OCR 智能分段或保留换行自检失败。")
        }
        let chinese = [
            OCRLine(text: "这是第一行", x: 0.1, y: 0.8, width: 0.7, height: 0.05, confidence: 1),
            OCRLine(text: "这是第二行", x: 0.1, y: 0.73, width: 0.7, height: 0.05, confidence: 1)
        ]
        guard OCRTextLayout.text(from: chinese) == "这是第一行这是第二行" else {
            throw PopError.message("OCR 中文软换行拼接自检失败。")
        }
        checks.append("OCR 分栏与分段：双栏独立阅读顺序、英文软换行、中文拼接、段间空白与保留换行通过")

        let screen = CGRect(x: -1280, y: 0, width: 1280, height: 1024)
        let captureRect = CGRect(x: -1100, y: 200, width: 400, height: 300)
        guard NativeScreenCoordinates.sourceRect(globalRect: captureRect, screenFrame: screen) == CGRect(x: 180, y: 524, width: 400, height: 300),
              NativeScreenCoordinates.rect(from: CGPoint(x: 90, y: 80), to: CGPoint(x: -20, y: 30), clippedTo: CGRect(x: 0, y: 0, width: 100, height: 100)) == CGRect(x: 0, y: 30, width: 90, height: 50) else {
            throw PopError.message("原位截图的多显示器坐标或反向拖选自检失败。")
        }
        let sampleLine = OCRLine(text: "fixture", x: 0.1, y: 0.2, width: 0.5, height: 0.1, confidence: 1)
        guard NativeImageOverlay.rect(for: sampleLine, in: CGRect(x: 0, y: 0, width: 1000, height: 500)) == CGRect(x: 100, y: 100, width: 500, height: 50) else {
            throw PopError.message("原位浮层文字框的坐标映射自检失败。")
        }
        checks.append("原位截图坐标：负坐标副屏、上下原点转换、逆向拖选裁剪、译文框映射通过（未捕获屏幕）")

        let value = "Hello 👋 world"
        let selectedRange = (value as NSString).range(of: "👋")
        let snapshot = EditableTextSnapshot(text: "👋", value: value, selectedRange: selectedRange)
        guard snapshot.matches(value: value, selection: "👋", range: selectedRange, entireInput: false),
              snapshot.replacingSelection(with: "你好") == "Hello 你好 world",
              !snapshot.matches(value: "Changed 👋 world", selection: "👋", range: selectedRange, entireInput: false),
              !snapshot.matches(value: value, selection: "👋", range: NSRange(location: 0, length: 2), entireInput: false),
              !EditableTextSnapshot.valid(NSRange(location: selectedRange.location, length: 1), in: value),
              !EditableTextSnapshot.valid(NSRange(location: Int.max, length: Int.max), in: value) else {
            throw PopError.message("安全回填的 UTF-16、选区改变或越界保护自检失败。")
        }
        let full = EditableTextSnapshot(text: value, value: value, selectedRange: selectedRange)
        guard full.matches(value: value, selection: nil, range: nil, entireInput: true),
              !full.matches(value: "Changed", selection: nil, range: nil, entireInput: true) else {
            throw PopError.message("整个输入框的内容变化保护自检失败。")
        }
        checks.append("安全回填纯逻辑：emoji UTF-16、选区移动、旁侧内容改变、整个输入框改变与越界拒绝通过；未操作其他软件")

        guard let originalImage = NSImage(contentsOf: textURL) else { throw PopError.message("无法读取原位浮层自检图片。") }
        let rendered = try NativeImageOverlay.render(image: originalImage, size: CGSize(width: 1000, height: 260),
                                                    document: document, translations: [0: "Native overlay fixture"])
        let overlayURL = directory.appendingPathComponent("overlay-render.png")
        guard let renderedData = rendered.representation(using: .png, properties: [:]) else {
            throw PopError.message("原位浮层自检无法生成 PNG。")
        }
        try renderedData.write(to: overlayURL)
        let renderedOCR = try await VisionOCR.recognize(url: overlayURL, accurate: true, languages: ["en-US"], languageCorrection: false)
        guard renderedOCR.text.localizedCaseInsensitiveContains("overlay") else {
            throw PopError.message("原位浮层离屏渲染自检失败，实际识别：\(renderedOCR.text)")
        }
        checks.append("原位图文浮层：实际画布离屏渲染译文后，再由 Vision 成功识别 overlay（未显示窗口）")
        guard NativeDictionary.bundledEntryCount >= 770_000,
              let hello = await NativeDictionary.lookupBundledResult("HELLO"), hello.word == "hello",
              hello.parts.flatMap(\.means).contains(where: { $0.contains("喂") }),
              !hello.phonetics.isEmpty,
              let apple = await NativeDictionary.lookupBundledResult("apple"),
              apple.exchanges.contains(where: { $0.name == "复数" && $0.words.contains("apples") }),
              let running = await NativeDictionary.lookupBundledResult("running"),
              running.exchanges.contains(where: { $0.name == "原形" && $0.words.contains("run") }),
              running.relatedWordParts.flatMap(\.words).contains(where: { $0.word == "run" }),
              let alias = await NativeDictionary.lookupBundledResult("actioned"), alias.word == "action",
              await NativeDictionary.lookupBundledResult("pop-not-a-real-dictionary-word-938104") == nil else {
            throw PopError.message("内置 ECDICT 独立词库的词条、大小写、音标、词形或未命中自检失败。")
        }
        checks.append("内置 ECDICT：770,611 条独立英汉词条可检索；HELLO 大小写/中文义项/音标、apple复数、running原形、actioned反向词形及不存在词通过")
        let permissions = PermissionHelper.status()
        checks.append("自检进程权限只读检查：辅助功能\(permissions.accessibility ? "已授权" : "未授权")，屏幕录制\(permissions.screenRecording ? "已授权" : "未授权")；真实跨应用回填、交互截图与屏幕浮层显示未执行，未申请权限")

        return checks
    }

    private static func line(_ text: String, x: Double, y: Double) -> OCRLine {
        OCRLine(text: text, x: x, y: y, width: 0.25, height: 0.05, confidence: 0.99)
    }

    private static func drawTextFixture(to url: URL) throws {
        try bitmap(width: 1000, height: 260, to: url) { context in
            context.cgContext.setAllowsAntialiasing(true)
            context.cgContext.setShouldAntialias(true)
            let text = NSAttributedString(string: "Test OCR 123", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 70, weight: .bold),
                .foregroundColor: NSColor.black
            ])
            text.draw(at: NSPoint(x: 65, y: 88))
        }
    }

    private static func drawQRFixture(payload: String, to url: URL) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw PopError.message("二维码自检失败：系统未提供 CIQRCodeGenerator。")
        }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else {
            throw PopError.message("二维码自检失败：本地二维码生成器未返回图像。")
        }
        let enlarged = image.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(enlarged, from: enlarged.extent) else {
            throw PopError.message("二维码自检失败：无法渲染合成二维码。")
        }
        let side = max(cgImage.width, cgImage.height) + 120
        try bitmap(width: side, height: side, to: url) { context in
            context.cgContext.interpolationQuality = .none
            context.cgContext.draw(cgImage, in: CGRect(x: 60, y: 60, width: cgImage.width, height: cgImage.height))
        }
    }

    private static func bitmap(
        width: Int, height: Int, to url: URL,
        draw: (NSGraphicsContext) throws -> Void
    ) throws {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw PopError.message("原生自检失败：无法创建本地图像缓冲区。")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        try draw(context)
        context.flushGraphics()
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw PopError.message("原生自检失败：无法编码 PNG 图片。")
        }
        try data.write(to: url, options: .atomic)
    }
}

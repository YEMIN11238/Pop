import Foundation

enum OCRImageCollectionSelfCheck {
    static func run() throws -> [String] {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw PopError.message("多图 OCR 自检：" + message) }
        }
        let a = URL(fileURLWithPath: "/Pop-fixture/a.png")
        let b = URL(fileURLWithPath: "/Pop-fixture/b.png")
        let broken = URL(fileURLWithPath: "/Pop-fixture/broken.png")
        var collection = OCRImageCollection()
        collection.add([a, b, broken], append: false)
        let ids = collection.tasks.map(\.id)
        try require(collection.selectedID == ids[0] && collection.mergesAllText && collection.text.isEmpty,
                    "新批次应预览第一张图片，并默认合并文字")
        collection.complete(ids[1], document: OCRDocument(text: "second", lines: [], qrCodes: ["qr-2"]), text: "second")
        collection.fail(ids[2], message: "Unreadable image")
        collection.complete(ids[0], document: OCRDocument(text: "first", lines: [], qrCodes: []), text: "first")
        try require(collection.text == "first\n\nsecond" && collection.qrCodes == ["qr-2"],
                    "合并应按图片顺序保留成功结果，不能按完成顺序或丢弃部分成功")
        collection.select(ids[1])
        try require(!collection.mergesAllText && collection.text == "second" && collection.selected?.url == b,
                    "选择缩略图未同步图片和该图片文本")
        collection.merge()
        try require(collection.selectedID == ids[1] && collection.text == "first\n\nsecond",
                    "合并按钮不应改变当前预览图")
        collection.add([a], append: true)
        try require(collection.tasks.count == 4 && collection.selectedID == collection.tasks.last?.id && collection.selectedID != ids[0],
                    "连续识别应追加任务并选择新图，同一路径不能误覆盖旧结果")
        collection.markRecognizing(collection.tasks.last!.id)
        collection.interrupt()
        try require(collection.tasks.last?.status == .waiting && collection.tasks.first?.text == "first",
                    "中止识别破坏已完成任务或不能继续未完成任务")
        collection.retry(ids[1])
        try require(collection.tasks[1].status == .waiting && collection.tasks[1].document == nil && collection.tasks[1].text.isEmpty && collection.text == "first",
                    "单项重试应清掉该项旧结果并保留其他结果")
        collection.add([], append: false)
        try require(collection.tasks.count == 4, "取消选图或空选择不能清空现有任务")
        collection.add([b], append: false)
        try require(collection.tasks.count == 1 && collection.text.isEmpty && collection.qrCodes.isEmpty,
                    "普通新识别应替换旧队列")
        try checkEdits(a, b)
        try checkBatchOutcomes(a, broken)
        return [
            "多图 OCR：逐图结果与错误独立保存、合并按源顺序、双换行分隔、切图显示对应结果、合并不改变预览图。",
            "连续 OCR：追加并选择新图、重复路径独立任务、取消保留结果与待处理项、单项重试隔离、空选择保留队列、普通识别替换旧队列。",
            "OCR 编辑：单图纠错与合并编辑分别保留，切图与追加不丢失修改；重试覆盖对应图结果并重建受影响的合并文本。",
            "OCR 本批状态：旧成功不掩盖新失败；全失败或空识别不复制旧文，不显示成功；部分失败保留错误提示。"
        ]
    }

    private static func checkEdits(_ a: URL, _ b: URL) throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PopError.message("OCR 编辑自检：" + message) }
        }
        func document(_ text: String) -> OCRDocument { OCRDocument(text: text, lines: [], qrCodes: []) }
        var pages = OCRImageCollection()
        pages.add([a], append: false)
        let first = pages.selectedID!
        pages.complete(first, document: document("raw-a"), text: "raw-a")
        pages.editText("corrected-a")
        pages.select(first)
        try require(pages.text == "corrected-a", "单图编辑切换后丢失")
        pages.add([b], append: true)
        let second = pages.selectedID!
        pages.complete(second, document: document("raw-b"), text: "raw-b")
        try require(pages.text == "corrected-a\n\nraw-b", "追加没有使用之前的单图纠错")
        pages.editText("edited combined document")
        pages.select(first)
        try require(pages.text == "corrected-a", "合并编辑覆盖了每图独立文本")
        pages.editText("new page correction")
        pages.select(second)
        pages.merge()
        try require(pages.text == "edited combined document", "切图或单图编辑覆盖合并编辑")
        pages.add([a], append: true)
        let third = pages.selectedID!
        pages.complete(third, document: document("third"), text: "third")
        try require(pages.text == "edited combined document\n\nthird", "追加应在合并编辑后只加入新图文本")
        pages.retry(first)
        pages.complete(first, document: document("rerecognized"), text: "rerecognized")
        try require(pages.text == "rerecognized\n\nraw-b\n\nthird", "重试没有显式替换受影响的编辑结果")
        pages.editText("")
        pages.select(second)
        pages.merge()
        try require(pages.text.isEmpty, "用户清空合并文本后，刷新恢复了旧识别文字")
        pages.add([b], append: true)
        let pending = pages.selectedID!
        pages.editText("manual prefix")
        pages.complete(pending, document: document("arriving page"), text: "arriving page")
        try require(pages.text == "manual prefix\n\narriving page", "编辑已完成部分时，后续完成的页面未追加")
    }

    private static func checkBatchOutcomes(_ a: URL, _ broken: URL) throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PopError.message("OCR 本批状态自检：" + message) }
        }
        var pages = OCRImageCollection()
        pages.add([a], append: false)
        pages.complete(pages.selectedID!, document: OCRDocument(text: "old", lines: [], qrCodes: []), text: "old")
        pages.add([broken], append: true)
        let failed = pages.selectedID!
        pages.fail(failed, message: "Unreadable image")
        let failedBatch = pages.outcome(for: [failed])
        try require(!failedBatch.hasNewContent && !failedBatch.succeeded && failedBatch.notice?.contains("Unreadable image") == true,
                    "旧成功掩盖全失败的新批次")
        try require(!failedBatch.shouldCopy(autoCopy: true, silent: false, text: pages.text)
                    && !failedBatch.shouldCopy(autoCopy: false, silent: true, text: pages.text), "全失败仍复制了旧文字")
        pages.add([a], append: true)
        let fresh = pages.selectedID!
        pages.complete(fresh, document: OCRDocument(text: "fresh", lines: [], qrCodes: []), text: "fresh")
        let partial = pages.outcome(for: [failed, fresh])
        try require(partial.hasNewContent && !partial.succeeded && partial.failedCount == 1 && partial.notice != nil,
                    "部分失败没有保留失败提示")
        try require(partial.shouldCopy(autoCopy: true, silent: false, text: pages.text), "部分成功丢失可复制的新结果")
        pages.add([a], append: true)
        let empty = pages.selectedID!
        pages.complete(empty, document: OCRDocument(text: "", lines: [], qrCodes: []), text: "")
        let blank = pages.outcome(for: [empty])
        try require(!blank.succeeded && blank.notice == "没有识别到文字或二维码。"
                    && !blank.shouldCopy(autoCopy: true, silent: true, text: pages.text), "空白新图把旧文当作新成功")
        pages.complete(empty, document: OCRDocument(text: "", lines: [], qrCodes: ["qr-only"]), text: "")
        try require(pages.outcome(for: [empty]).succeeded, "仅二维码结果应视作本批有效内容")
    }
}

import Foundation

struct OCRImageTask: Identifiable {
    enum Status { case waiting, recognizing, completed, failed }
    let id: UUID
    let url: URL
    var status: Status = .waiting
    var document: OCRDocument?
    var text = ""
    var editedText: String?
    var error: String?

    var displayedText: String { editedText ?? text }

    init(url: URL) { self.id = UUID(); self.url = url }
}

/// Independent image results are retained even while the text pane shows their
/// merged text. REA 0x10009c5e4, 0x10009fc7c, 0x10009fbe0, 0x10009d550.
struct OCRImageCollection {
    private(set) var tasks: [OCRImageTask] = []
    private(set) var selectedID: UUID?
    private(set) var mergesAllText = true
    private var precedingText = ""
    private var mergedEdit: (text: String, coveredIDs: Set<UUID>)?

    var selected: OCRImageTask? { tasks.first { $0.id == selectedID } ?? tasks.first }
    var text: String {
        if mergesAllText {
            let included = tasks.filter { $0.status == .completed || $0.editedText != nil }
            let prefix = mergedEdit?.text ?? precedingText
            let remaining = included.filter { !(mergedEdit?.coveredIDs.contains($0.id) ?? false) }
            return ([prefix] + remaining.map(\.displayedText))
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return selected?.displayedText ?? ""
    }
    var qrCodes: [String] {
        (mergesAllText ? tasks : selected.map { [$0] } ?? []).flatMap { $0.document?.qrCodes ?? [] }
    }

    mutating func add(_ urls: [URL], append: Bool, existingText: String = "") {
        guard !urls.isEmpty else { return }
        if !append { tasks = []; precedingText = ""; mergedEdit = nil }
        else if tasks.isEmpty { precedingText = existingText }
        let additions = urls.map(OCRImageTask.init)
        tasks.append(contentsOf: additions)
        selectedID = additions.first?.id
        mergesAllText = true
    }
    mutating func select(_ id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        selectedID = id
        mergesAllText = false
    }
    mutating func merge() { mergesAllText = true }
    /// An edited combined document is independent of individual page edits.
    /// New pages append after it; switching previews never rewrites it. A retry
    /// of a page represented in the edited document explicitly rebuilds it.
    mutating func editText(_ value: String) {
        if mergesAllText, tasks.count > 1 || !precedingText.isEmpty {
            mergedEdit = (value, Set(tasks.filter { $0.status == .completed || $0.editedText != nil }.map(\.id)))
        } else if let index = tasks.firstIndex(where: { $0.id == selected?.id }) {
            tasks[index].editedText = value
        }
    }
    mutating func markRecognizing(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .recognizing
        tasks[index].error = nil
    }
    mutating func complete(_ id: UUID, document: OCRDocument, text: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .completed
        tasks[index].document = document
        tasks[index].text = text
        tasks[index].error = nil
    }
    mutating func fail(_ id: UUID, message: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .failed
        tasks[index].error = message
    }
    mutating func interrupt() {
        for index in tasks.indices where tasks[index].status == .recognizing { tasks[index].status = .waiting }
    }
    mutating func retry(_ id: UUID? = nil) {
        if id == nil || id.map({ mergedEdit?.coveredIDs.contains($0) ?? false }) == true { mergedEdit = nil }
        for index in tasks.indices where id == nil || tasks[index].id == id {
            tasks[index].status = .waiting
            tasks[index].document = nil
            tasks[index].text = ""
            tasks[index].editedText = nil
            tasks[index].error = nil
        }
    }

    func outcome(for ids: Set<UUID>) -> OCRImageBatchOutcome {
        OCRImageBatchOutcome(tasks: tasks.filter { ids.contains($0.id) })
    }
}

/// Completion feedback is scoped to the submitted batch, never earlier pages.
struct OCRImageBatchOutcome {
    let completedCount: Int
    let failedCount: Int
    let hasNewContent: Bool
    let failureNotice: String?

    init(tasks: [OCRImageTask]) {
        completedCount = tasks.filter { $0.status == .completed }.count
        let failures = tasks.filter { $0.status == .failed }
        failedCount = failures.count
        hasNewContent = tasks.contains {
            $0.status == .completed && (!$0.text.isEmpty || !($0.document?.qrCodes.isEmpty ?? true))
        }
        failureNotice = failures.isEmpty ? nil : failures.map {
            "\($0.url.lastPathComponent)：\($0.error ?? "识别失败")"
        }.joined(separator: "\n")
    }

    var succeeded: Bool { hasNewContent && failedCount == 0 }
    var notice: String? { failureNotice ?? (completedCount > 0 && !hasNewContent ? "没有识别到文字或二维码。" : nil) }
    func shouldCopy(autoCopy: Bool, silent: Bool, text: String) -> Bool {
        hasNewContent && (autoCopy || silent) && !text.isEmpty
    }
}

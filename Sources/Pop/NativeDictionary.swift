import CoreServices
import Foundation
import SQLite3

/// Independent, bundled ECDICT data is the primary source. macOS DictionaryServices
/// is a fallback for words outside that database, using the user's installed dictionaries.
enum NativeDictionary {
    static func lookup(_ term: String) -> String? {
        OfflineDictionaryStore.shared.lookup(term)?.plainText ?? systemDefinition(term)
    }

    static func lookupResult(_ term: String) async -> DictionaryResult? {
        let worker = Task.detached(priority: .userInitiated) { () -> DictionaryResult? in
            guard !Task.isCancelled else { return nil }
            if let result = OfflineDictionaryStore.shared.lookup(term) { return result }
            guard !Task.isCancelled, let definition = systemDefinition(term) else { return nil }
            return DictionaryResult(word: term.trimmingCharacters(in: .whitespacesAndNewlines),
                                    parts: [.init(part: nil, means: [definition])],
                                    additions: [.init(name: "来源", value: "macOS 已安装词典")])
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// Explicitly tests the bundled data, never substituting system dictionaries.
    static func lookupBundledResult(_ term: String) async -> DictionaryResult? {
        await Task.detached(priority: .userInitiated) { OfflineDictionaryStore.shared.lookup(term) }.value
    }
    static var bundledEntryCount: Int { OfflineDictionaryStore.shared.entryCount }
    static var bundledDatabaseURL: URL? { OfflineDictionaryStore.databaseURL }

    private static func systemDefinition(_ term: String) -> String? {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 160, !word.contains("\n") else { return nil }
        guard let result = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: word.utf16.count))?.takeRetainedValue() as String? else { return nil }
        let definition = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return definition.isEmpty ? nil : definition
    }
}

private final class OfflineDictionaryStore: @unchecked Sendable {
    static let shared = OfflineDictionaryStore()
    private let lock = NSLock()
    private var database: OpaquePointer?
    private var openedPath: String?
    private var storedEntryCount = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var databaseURL: URL? {
        var candidates: [URL] = []
        if let root = Bundle.main.resourceURL {
            candidates += [root.appendingPathComponent("Dictionaries/ECDICT.sqlite"), root.appendingPathComponent("ECDICT.sqlite")]
        }
        #if DEBUG
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Dictionaries/ECDICT.sqlite"))
        #endif
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return open() ? storedEntryCount : 0
    }

    func lookup(_ term: String) -> DictionaryResult? {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 160, !word.contains("\n"), !word.contains("\r") else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard open() else { return nil }
        var record = entry(word)
        if record == nil {
            for lemma in lemmas(word) {
                if let match = entry(lemma) { record = match; break }
            }
        }
        guard let record else { return nil }
        var result = Self.result(record)
        if record.word.caseInsensitiveCompare(word) != .orderedSame {
            result.additions.append(.init(name: "查询词", value: word))
        }
        if let root = result.exchanges.first(where: { $0.name == "原形" })?.words.first,
           root.caseInsensitiveCompare(record.word) != .orderedSame,
           let base = entry(root) {
            let meanings = Self.parts(base.translation.isEmpty ? base.definition : base.translation).flatMap(\.means)
            if !meanings.isEmpty {
                result.relatedWordParts = [.init(part: "原形释义", words: [.init(word: base.word, means: meanings)])]
            }
        }
        return result
    }

    private func open() -> Bool {
        guard let url = Self.databaseURL else { return false }
        if database != nil, openedPath == url.path { return true }
        if let database { sqlite3_close(database) }
        database = nil; storedEntryCount = 0
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }; self.database = nil
            return false
        }
        sqlite3_busy_timeout(database, 100)
        sqlite3_exec(database, "PRAGMA query_only=ON; PRAGMA mmap_size=33554432;", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE key='entries'", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_close(database); self.database = nil; return false
        }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) {
            storedEntryCount = Int(String(cString: bytes)) ?? 0
        }
        openedPath = url.path
        return storedEntryCount > 0
    }

    private struct Entry {
        let word: String; let phonetic: String; let translation: String
        let definition: String; let exchange: String; let tags: String
    }
    private func entry(_ word: String) -> Entry? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT word,phonetic,translation,definition,exchange,tags FROM entries WHERE word=? COLLATE NOCASE LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, word, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func string(_ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }
        return Entry(word: string(0), phonetic: string(1), translation: string(2), definition: string(3), exchange: string(4), tags: string(5))
    }
    private func lemmas(_ form: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT lemma FROM aliases WHERE form=? COLLATE NOCASE ORDER BY (kind='0') DESC,length(lemma),lemma LIMIT 8", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, form, -1, Self.transient)
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { result.append(String(cString: value)) }
        }
        return result
    }

    private static func result(_ entry: Entry) -> DictionaryResult {
        var result = DictionaryResult(word: entry.word)
        if !entry.phonetic.isEmpty {
            result.phonetics = [.init(type: "英", value: entry.phonetic, tts: nil)]
        }
        result.parts = parts(entry.translation.isEmpty ? entry.definition : entry.translation)
        let names = ["p": "过去式", "d": "过去分词", "i": "现在分词", "3": "第三人称单数", "r": "比较级", "t": "最高级", "s": "复数", "0": "原形"]
        result.exchanges = entry.exchange.split(separator: "/").compactMap { component in
            let pair = component.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, let name = names[pair[0]] else { return nil }
            let words = pair[1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return words.isEmpty ? nil : .init(name: name, words: words)
        }
        if !entry.tags.isEmpty {
            let tags = ["zk": "中考", "gk": "高考", "cet4": "四级", "cet6": "六级", "ky": "考研", "ielts": "雅思", "toefl": "托福", "gre": "GRE"]
            let values = entry.tags.split(separator: " ").map { tags[String($0)] ?? String($0) }
            result.additions.append(.init(name: "词汇标记", value: values.joined(separator: " · ")))
        }
        if !entry.translation.isEmpty, !entry.definition.isEmpty {
            result.additions.append(.init(name: "英文释义", value: entry.definition))
        }
        result.additions.append(.init(name: "来源", value: "ECDICT · 离线英汉词典"))
        return result
    }
    private static let partExpression = try! NSRegularExpression(pattern: "^(n|v|vt|vi|adj|adv|a|ad|prep|pron|conj|interj|int|num|art|aux|abbr|pl)\\.\\s*(.*)$", options: [.caseInsensitive])
    private static func parts(_ value: String) -> [DictionaryResult.Part] {
        value.components(separatedBy: .newlines).compactMap { source in
            let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let string = line as NSString
            if let match = partExpression.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) {
                return .init(part: string.substring(with: match.range(at: 1)) + ".", means: [string.substring(with: match.range(at: 2))])
            }
            return .init(part: nil, means: [line])
        }
    }
    deinit { if let database { sqlite3_close(database) } }
}

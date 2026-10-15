import Foundation

struct PluginValidationResult: Equatable {
    var supported: Bool
    var isValid: Bool
    var message: String?
    var troubleshootingLink: URL?
}

/// Lossless fields from Bob's public `toDict` schema, without provider raw responses.
struct DictionaryResult: Codable, Equatable {
    struct Audio: Codable, Equatable { var type: String; var value: String }
    struct Phonetic: Codable, Equatable { var type: String; var value: String?; var tts: Audio? }
    struct Part: Codable, Equatable { var part: String?; var means: [String] }
    struct Exchange: Codable, Equatable { var name: String; var words: [String] }
    struct RelatedWord: Codable, Equatable { var word: String; var means: [String] }
    struct RelatedWordPart: Codable, Equatable { var part: String?; var words: [RelatedWord] }
    struct Addition: Codable, Equatable { var name: String; var value: String }
    var word: String?
    var phonetics: [Phonetic] = []
    var parts: [Part] = []
    var exchanges: [Exchange] = []
    var relatedWordParts: [RelatedWordPart] = []
    var additions: [Addition] = []

    var plainText: String {
        var lines = parts.map { [$0.part ?? "", $0.means.joined(separator: "；")].filter { !$0.isEmpty }.joined(separator: " ") }
        lines += relatedWordParts.flatMap { part in part.words.map { [$0.word, $0.means.joined(separator: "；")].filter { !$0.isEmpty }.joined(separator: " ") } }
        lines += exchanges.map { $0.name + " " + $0.words.joined(separator: "、") }
        lines += additions.map { $0.name + " " + $0.value }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func parse(_ object: [String: Any]) -> DictionaryResult {
        var result = DictionaryResult(word: object["word"] as? String)
        result.phonetics = (object["phonetics"] as? [[String: Any]] ?? []).compactMap { row in
            guard let type = row["type"] as? String else { return nil }
            var audio: Audio?
            if let tts = row["tts"] as? [String: Any], let type = tts["type"] as? String, let value = tts["value"] as? String { audio = Audio(type: type, value: value) }
            return Phonetic(type: type, value: row["value"] as? String, tts: audio)
        }
        result.parts = (object["parts"] as? [[String: Any]] ?? []).map { Part(part: $0["part"] as? String, means: $0["means"] as? [String] ?? []) }
        result.exchanges = (object["exchanges"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return Exchange(name: name, words: row["words"] as? [String] ?? [])
        }
        result.relatedWordParts = (object["relatedWordParts"] as? [[String: Any]] ?? []).map { row in
            let words = (row["words"] as? [[String: Any]] ?? []).compactMap { item -> RelatedWord? in
                guard let word = item["word"] as? String else { return nil }
                return RelatedWord(word: word, means: item["means"] as? [String] ?? [])
            }
            return RelatedWordPart(part: row["part"] as? String, words: words)
        }
        result.additions = (object["additions"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String, let value = row["value"] as? String else { return nil }
            return Addition(name: name, value: value)
        }
        return result
    }
}

/// Public plugin `content` and `thinkInfo` parsing shared by final and streaming frames.
struct PluginResultDecoder {
    private(set) var format: String?
    private(set) var reasoning: String?
    mutating func decode(_ result: [String: Any], originalText: String, streaming: Bool) throws -> TranslationOutput {
        let content = result["content"] as? [String: Any]
        let paragraphs = (result["toParagraphs"] as? [String] ?? []).filter { !$0.isEmpty }
        if let supplied = content?["format"] as? String { format = supplied }
        if format == nil { format = content == nil && paragraphs.count > 1 ? "lines" : "plain" }
        guard ["plain", "lines", "markdown"].contains(format ?? "plain") else { throw PopError.message("当前版本不支持插件返回的译文格式：\(format ?? "unknown")") }
        var text = content?["text"] as? String ?? paragraphs.joined(separator: "\n")
        let think = result["thinkInfo"] as? [String: Any]
        if let value = think?["content"] as? String { reasoning = value }
        if think?["splitThinkTag"] as? Bool == true, format != "lines" {
            var extracted: [String] = []
            while let start = text.range(of: "<think>"), let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                extracted.append(String(text[start.upperBound..<end.lowerBound]))
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
            if streaming, let start = text.range(of: "<think>") {
                extracted.append(String(text[start.upperBound...]))
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
            if !extracted.isEmpty { reasoning = extracted.joined(separator: "\n") }
        }
        if format == "lines" {
            let source = originalText.components(separatedBy: "\n")
            let translated = text.components(separatedBy: "\n")
            if source.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count == translated.count {
                var index = 0
                text = source.map { row in
                    guard !row.trimmingCharacters(in: .whitespaces).isEmpty else { return row }
                    defer { index += 1 }; return translated[index]
                }.joined(separator: "\n")
            }
        }
        let dictionary = (result["toDict"] as? [String: Any]).map(DictionaryResult.parse)
        if text.isEmpty, !streaming { text = dictionary?.plainText ?? "" }
        if !streaming, text.isEmpty, dictionary == nil { throw PopError.message("插件未返回译文或词典结果。") }
        var output = TranslationOutput(text: text, detectedSource: result["from"] as? String,
                                       pronunciation: dictionary?.phonetics.compactMap(\.value).first,
                                       details: dictionary?.parts.map { [$0.part ?? "", $0.means.joined(separator: "；")].filter { !$0.isEmpty }.joined(separator: " ") } ?? [])
        output.format = format; output.reasoning = reasoning; output.dictionary = streaming ? nil : dictionary
        return output
    }
}

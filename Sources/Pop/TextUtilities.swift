import Foundation
import NaturalLanguage

enum TextUtilities {
    static func processedInput(_ text: String, preferences: AppPreferences) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if preferences.removeCommentMarkers {
            value = value.components(separatedBy: "\n").map { line in
                line.replacingOccurrences(of: "^\\s*(?://+|/\\*+|\\*/|\\*(?!\\*)|#(?=\\s))\\s?", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s*\\*/\\s*$", with: "", options: .regularExpression)
            }.joined(separator: "\n")
        }
        if preferences.joinHyphenatedWords {
            value = value.replacingOccurrences(of: "([\\p{L}])[-\\u00AD]\\n[ \\t]*([\\p{Ll}])", with: "$1$2", options: .regularExpression)
            value = value.replacingOccurrences(of: "([\\p{L}])[-\\u00AD][ \\t]+([\\p{Ll}])", with: "$1$2", options: .regularExpression)
        }
        if preferences.mergeLineBreaks {
            value = value.replacingOccurrences(of: "(?<!\\n)\\n(?![ \\t]*\\n)", with: " ", options: .regularExpression)
        }
        if preferences.compactBlankLines {
            value = value.replacingOccurrences(of: "\\n(?:[ \\t]*\\n){2,}", with: "\n\n", options: .regularExpression)
        }
        return normalizedInput(value, splitIdentifiers: preferences.normalizeIdentifiers)
    }

    static func targetLanguage(for text: String, preferences: AppPreferences) -> String {
        let primary = resolvedPrimaryLanguage(preferences)
        guard preferences.autoTargetLanguage else {
            return resolvedLanguage(preferences.targetLanguage, fallback: primary)
        }
        let detected = preferences.sourceLanguage == "auto" ? detectLanguage(text) : preferences.sourceLanguage
        let source = Locale.Language(identifier: detected).languageCode
        let primaryCode = Locale.Language(identifier: primary).languageCode
        return source == primaryCode ? resolvedSecondaryLanguage(preferences) : primary
    }

    /// "Automatic" is a UI preference, never a provider's target-language code.
    static func resolvedPrimaryLanguage(_ preferences: AppPreferences, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let system = preferredLanguages.lazy.map { resolvedLanguage($0, fallback: "") }.first { !$0.isEmpty } ?? "en"
        return resolvedLanguage(preferences.primaryLanguage, fallback: system)
    }

    static func resolvedSecondaryLanguage(_ preferences: AppPreferences, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let primary = resolvedPrimaryLanguage(preferences, preferredLanguages: preferredLanguages)
        let fallback = Locale.Language(identifier: primary).languageCode?.identifier == "en" ? "zh-Hans" : "en"
        return resolvedLanguage(preferences.secondaryLanguage, fallback: fallback)
    }

    private static func resolvedLanguage(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        guard !value.isEmpty, value != "auto", value != "und" else { return fallback }
        if let exact = LanguageCatalog.choices.first(where: { $0.0.caseInsensitiveCompare(value) == .orderedSame && $0.0 != "auto" }) { return exact.0 }
        let language = Locale.Language(identifier: value)
        if language.languageCode?.identifier == "zh" {
            return language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "") ? "zh-Hant" : "zh-Hans"
        }
        if let code = language.languageCode?.identifier, LanguageCatalog.choices.contains(where: { $0.0 == code }) { return code }
        return fallback
    }
    /// Only a selection consisting of one identifier is split. Prose, paragraph
    /// breaks, links, email addresses, and punctuation remain intact.
    static func normalizedInput(_ text: String, splitIdentifiers: Bool) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard splitIdentifiers,
              value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            return value
        }
        let split = value
            .replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return split.isEmpty ? value : split
    }

    /// A local heuristic, not a translation provider's detected source language.
    static func detectLanguage(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return "auto" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "auto"
    }

    static func readingLanguageCode(_ code: String) -> String {
        let value = code.replacingOccurrences(of: "_", with: "-").lowercased()
        let voices: [String: String] = [
            "zh": "zh-CN", "zh-hans": "zh-CN", "zh-cn": "zh-CN", "zh-sg": "zh-CN",
            "zh-hant": "zh-TW", "zh-tw": "zh-TW", "zh-hk": "zh-HK",
            "en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "fr": "fr-FR",
            "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-BR",
            "ru": "ru-RU", "ar": "ar-SA", "vi": "vi-VN"
        ]
        return voices[value] ?? code.replacingOccurrences(of: "_", with: "-")
    }

    static func readingLanguageCode(_ code: String, text: String) -> String {
        readingLanguageCode(code == "auto" ? detectLanguage(text) : code)
    }

    /// Decode entity references once, without treating the response as HTML or
    /// invoking a web renderer. Unknown references are retained unchanged.
    static func decodeHTMLEntities(_ text: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}",
            "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
            "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "copy": "©",
            "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥",
            "cent": "¢", "times": "×", "divide": "÷", "bull": "•", "middot": "·",
            "eacute": "é", "Eacute": "É", "egrave": "è", "agrave": "à", "aacute": "á",
            "ouml": "ö", "uuml": "ü", "auml": "ä", "szlig": "ß", "ntilde": "ñ"
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);") else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let token = source.substring(with: match.range(at: 1))
            var replacement = named[token]
            if token.hasPrefix("#") {
                let hexadecimal = token.hasPrefix("#x") || token.hasPrefix("#X")
                let digits = token.dropFirst(hexadecimal ? 2 : 1)
                if let value = UInt32(digits, radix: hexadecimal ? 16 : 10),
                   value != 0, let scalar = UnicodeScalar(value) {
                    replacement = String(scalar)
                }
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}

import Foundation

enum CloudServiceResponses {
    static func decode(_ data: Data, service: ServiceConfig) throws -> TranslationOutput {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw HTTPTranslationError.invalidResponse("翻译服务没有返回有效 JSON。") }
        let json = object as? [String: Any] ?? [:]; let kind = service.kind.rawValue
        if let error = json["error"] as? [String: Any] { throw HTTPTranslationError.provider(String(describing: error["code"] ?? error["type"] ?? "error"), error["message"] as? String ?? "服务返回错误。") }
        if CloudServiceRequests.isAI(service.kind) {
            var state = CloudServiceAIAccumulator(kind: ProviderTranslationModels.accumulatorKind(service), format: service.options["format"] == "markdown" ? "markdown" : "plain")
            return try state.complete(json)
        }
        var text: String?; var source: String?; var pronunciation: String?; var details: [String] = []
        switch kind {
        case "deepL":
            let first = (json["translations"] as? [[String: Any]])?.first
            text = first?["text"] as? String; source = first?["detected_source_language"] as? String
        case "google":
            let first = ((json["data"] as? [String: Any])?["translations"] as? [[String: Any]])?.first
            text = (first?["translatedText"] as? String).map(TextUtilities.decodeHTMLEntities); source = first?["detectedSourceLanguage"] as? String
        case "baidu":
            if let code = json["error_code"], String(describing: code) != "52000" { throw HTTPTranslationError.provider(String(describing: code), json["error_msg"] as? String ?? "百度翻译失败。") }
            text = (json["trans_result"] as? [[String: Any]])?.compactMap { $0["dst"] as? String }.joined(separator: "\n"); source = json["from"] as? String
        case "youdao":
            if let code = json["errorCode"], String(describing: code) != "0" { throw HTTPTranslationError.provider(String(describing: code), "有道翻译失败，请检查密钥、语言和额度。") }
            text = (json["translation"] as? [String])?.joined(separator: "\n"); source = (json["l"] as? String)?.components(separatedBy: "2").first
            let basic = json["basic"] as? [String: Any]; pronunciation = basic?["phonetic"] as? String; details = basic?["explains"] as? [String] ?? []
        case "tencent":
            let response = json["Response"] as? [String: Any] ?? [:]
            if let error = response["Error"] as? [String: Any] { throw HTTPTranslationError.provider(error["Code"] as? String ?? "error", error["Message"] as? String ?? "腾讯翻译失败。") }
            text = response["TargetText"] as? String; source = response["Source"] as? String
        case "microsoft":
            let first = (object as? [[String: Any]])?.first
            text = (first?["translations"] as? [[String: Any]])?.first?["text"] as? String; source = (first?["detectedLanguage"] as? [String: Any])?["language"] as? String
        case "aliyun":
            if let code = json["Code"], String(describing: code) != "200" { throw HTTPTranslationError.provider(String(describing: code), json["Message"] as? String ?? "阿里云翻译失败。") }
            let body = json["Data"] as? [String: Any]; text = body?["Translated"] as? String; source = body?["DetectedLanguage"] as? String
        case "caiyun":
            if let code = json["status"], !["0", "200"].contains(String(describing: code)) { throw HTTPTranslationError.provider(String(describing: code), json["message"] as? String ?? "彩云翻译失败。") }
            text = json["target"] as? String ?? (json["target"] as? [String])?.joined(separator: "\n")
        case "niutrans":
            if let code = json["error_code"], String(describing: code) != "0" { throw HTTPTranslationError.provider(String(describing: code), json["error_msg"] as? String ?? "小牛翻译失败。") }
            text = json["tgt_text"] as? String; source = json["from"] as? String
        case "volcano":
            if let error = (json["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] { throw HTTPTranslationError.provider(String(describing: error["Code"] ?? "error"), error["Message"] as? String ?? "火山翻译失败。") }
            let list = json["TranslationList"] as? [[String: Any]]
            text = list?.compactMap { $0["Translation"] as? String }.joined(separator: "\n"); source = list?.first?["DetectedSourceLanguage"] as? String
        case "amazon":
            if let code = json["__type"] as? String { throw HTTPTranslationError.provider(code, json["message"] as? String ?? json["Message"] as? String ?? "Amazon 翻译失败。") }
            text = json["TranslatedText"] as? String; source = json["SourceLanguageCode"] as? String
        default: throw HTTPTranslationError.unsupportedService
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HTTPTranslationError.invalidResponse("\(service.kind.title) 响应缺少有效译文。") }
        return TranslationOutput(text: text, detectedSource: normalize(source), pronunciation: pronunciation, details: details, format: "lines")
    }
    static func normalize(_ source: String?) -> String? {
        guard let source else { return nil }
        switch source.lowercased() {
        case "zh", "zh-cn", "zh-hans", "zh-chs": return "zh-Hans"
        case "zh-tw", "zh-hant", "zh-cht", "cht": return "zh-Hant"
        case "jp": return "ja"
        case "kor": return "ko"
        case "fra": return "fr"
        case "spa": return "es"
        case "ara": return "ar"
        case "vie": return "vi"
        default: return source.lowercased()
        }
    }
}

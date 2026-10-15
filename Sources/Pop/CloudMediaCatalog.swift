import Foundation

/// Official cloud OCR/TTS adapters. New configurations remain disabled until the
/// user supplies credentials and explicitly enables them; local defaults stay free.
enum CloudMediaCatalog {
    static func kinds(for capability: String) -> [ServiceKind] {
        guard ["ocr", "tts"].contains(capability) else { return [] }
        return ["google", "microsoft", "baidu", "tencent", "amazon"].compactMap(ServiceKind.init(rawValue:))
    }
    static func secretFields(for kind: ServiceKind, capability: String) -> [CloudServiceField] {
        func required(_ key: String, _ title: String) -> CloudServiceField { .init(key: key, title: title, required: true) }
        switch kind.rawValue {
        case "google": return [.init(key: "apiKey", title: "API Key（与 OAuth Token 二选一）"), .init(key: "accessToken", title: "OAuth Access Token（可选，需自行更新）")]
        case "baidu": return [required("apiKey", "百度智能云 API Key"), required("secretKey", "百度智能云 Secret Key")]
        case "tencent": return [required("secretId", "SecretId"), required("secretKey", "SecretKey")]
        case "amazon": return [required("accessKeyId", "Access Key ID"), required("secretAccessKey", "Secret Access Key"), .init(key: "sessionToken", title: "临时凭据 Token（可选）")]
        default: return [required("apiKey", capability == "tts" ? "Speech 资源密钥" : "Vision 资源密钥")]
        }
    }
    static func optionFields(for kind: ServiceKind, capability: String) -> [CloudServiceField] {
        let defaults = defaultOptions(for: kind, capability: capability)
        func field(_ key: String, _ title: String, choices: [String] = []) -> CloudServiceField {
            .init(key: key, title: title, defaultValue: defaults[key] ?? "", choices: choices)
        }
        var fields: [CloudServiceField] = []
        if ["microsoft", "tencent", "amazon"].contains(kind.rawValue) { fields.append(field("region", "资源地区 / Region")) }
        if capability == "ocr" {
            switch kind.rawValue {
            case "google": fields.append(field("languageHints", "优先语言（逗号分隔，可留空自动识别）"))
            case "microsoft": fields.append(field("language", "指定识别语言（可留空自动识别）"))
            case "baidu": fields.append(field("languageType", "识别语言类型", choices: ["CHN_ENG", "ENG", "JAP", "KOR", "FRE", "SPA", "POR", "GER", "ITA", "RUS"]))
            case "tencent": fields.append(field("languageType", "LanguageType", choices: ["auto", "zh", "en", "jap", "kor", "spa", "fre", "ger", "por", "rus"]))
            default: break
            }
        } else {
            switch kind.rawValue {
            case "google": fields += [field("voice", "音色名称（留空按语言自动选择）"), field("speakingRate", "语速（0.25–4.0）")]
            case "microsoft": fields += [field("voice", "Neural 音色（留空按语言选择）")]
            case "baidu": fields += [field("voice", "发音人 per"), field("speed", "语速 spd（0–15）"), field("pitch", "音调 pit（0–15）")]
            case "tencent": fields += [field("voice", "VoiceType（留空按中英文选择）"), field("speed", "语速（-2–6）")]
            case "amazon": fields += [field("voice", "VoiceId（留空按语言选择）"), field("engine", "合成引擎", choices: ["standard", "neural", "long-form", "generative"])]
            default: break
            }
        }
        return fields
    }
    static func defaultOptions(for kind: ServiceKind, capability: String) -> [String: String] {
        switch kind.rawValue {
        case "google": return capability == "ocr" ? [:] : ["speakingRate": "1.0"]
        case "microsoft": return ["region": "eastus"]
        case "baidu": return capability == "ocr" ? ["languageType": "CHN_ENG"] : ["voice": "0", "speed": "5", "pitch": "5"]
        case "tencent": return capability == "ocr" ? ["region": "ap-guangzhou", "languageType": "auto"] : ["region": "ap-guangzhou", "speed": "0"]
        case "amazon": return capability == "ocr" ? ["region": "us-east-1"] : ["region": "us-east-1", "engine": "standard"]
        default: return [:]
        }
    }
    static func defaultEndpoint(for kind: ServiceKind, capability: String, options: [String: String] = [:]) -> String {
        let ocr = capability == "ocr"
        switch kind.rawValue {
        case "google": return ocr ? "https://vision.googleapis.com/v1/images:annotate" : "https://texttospeech.googleapis.com/v1/text:synthesize"
        case "microsoft":
            let region = effectiveRegion(for: kind, options: options)
            return ocr ? "https://\(region).api.cognitive.microsoft.com/vision/v3.2/read/analyze" : "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1"
        case "baidu": return ocr ? "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate" : "https://tsn.baidu.com/text2audio"
        case "tencent": return ocr ? "https://ocr.tencentcloudapi.com" : "https://tts.tencentcloudapi.com"
        case "amazon":
            let region = effectiveRegion(for: kind, options: options)
            let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
            return ocr ? "https://textract.\(region).\(suffix)" : "https://polly.\(region).\(suffix)/v1/speech"
        default: return ""
        }
    }

    /// Settings persist the suggested endpoint when a service is first added.
    /// Regional suggestions must follow later region edits, while resource custom
    /// domains, private endpoints, proxies and explicit query parameters stay intact.
    static func resolvedEndpoint(for kind: ServiceKind, capability: String, endpoint: String, options: [String: String]) -> String {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return defaultEndpoint(for: kind, capability: capability, options: options) }
        guard let url = URL(string: value), url.scheme == "https", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host?.lowercased() else { return value }
        let path = url.path
        let pattern: String
        switch (kind.rawValue, capability) {
        case ("microsoft", "ocr") where path == "/vision/v3.2/read/analyze":
            pattern = "^[a-z0-9-]+\\.api\\.cognitive\\.microsoft\\.com$"
        case ("microsoft", "tts") where path == "/cognitiveservices/v1":
            pattern = "^[a-z0-9-]+\\.tts\\.speech\\.microsoft\\.com$"
        case ("amazon", "ocr") where path.isEmpty || path == "/":
            pattern = "^textract\\.[a-z0-9-]+\\.amazonaws\\.com(?:\\.cn)?$"
        case ("amazon", "tts") where path == "/v1/speech":
            pattern = "^polly\\.[a-z0-9-]+\\.amazonaws\\.com(?:\\.cn)?$"
        default: return value
        }
        guard host.range(of: pattern, options: .regularExpression) != nil else { return value }
        return defaultEndpoint(for: kind, capability: capability, options: options)
    }

    static func effectiveRegion(for kind: ServiceKind, options: [String: String]) -> String {
        let value = options["region"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !value.isEmpty { return value }
        return defaultOptions(for: kind, capability: "ocr")["region"] ?? ""
    }
}

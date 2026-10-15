import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CloudMediaError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Official, opt-in media endpoints only. Credentials and transient OAuth tokens
/// stay in memory; redirect responses are never followed by the default session.
struct CloudMediaService {
    private let sessions: NetworkProxySessionProvider
    private var session: URLSession { sessions.session }
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 90
        sessions = NetworkProxySessionProvider(session: session, configuration: configuration, delegate: CloudMediaRedirectDelegate())
    }

    func recognize(imageData: Data, service: ServiceConfig, apiKey: String) async throws -> OCRDocument {
        let credentials = try CloudServiceCredentials(apiKey)
        do {
            try Task.checkCancellation()
            let image = try MediaImage(imageData)
            guard image.data.count <= (service.kind.rawValue == "baidu" ? 4 : 10) * 1024 * 1024 else {
                throw CloudMediaError(message: "图片超过当前识别接口允许的本地大小，请缩小图片后重试。")
            }
            var request = try baseRequest(service, capability: "ocr")
            let response: [String: Any]
            switch service.kind.rawValue {
            case "google":
                try googleAuthorization(&request, credentials)
                var item: [String: Any] = ["image": ["content": image.data.base64EncodedString()], "features": [["type": "DOCUMENT_TEXT_DETECTION"]]]
                let hints = (service.options["languageHints"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !hints.isEmpty { item["imageContext"] = ["languageHints": hints] }
                try json(["requests": [item]], into: &request)
                response = try await sendJSON(request, credentials: credentials)
            case "microsoft":
                request.setValue(try credentials.require("apiKey", provider: "Microsoft Vision"), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); request.httpBody = image.data
                if let language = service.options["language"], !language.isEmpty { request.url = try query(request.url!, adding: ["language": language]) }
                let (data, initial) = try await send(request, credentials: credentials)
                if initial.statusCode == 202 {
                    guard let location = initial.value(forHTTPHeaderField: "Operation-Location"),
                          let operation = URL(string: location, relativeTo: request.url)?.absoluteURL,
                          sameOrigin(operation, request.url!) else {
                        throw CloudMediaError(message: "Microsoft Read 返回了不安全或缺失的任务地址，已停止轮询。")
                    }
                    var completed: [String: Any]?
                    for attempt in 0..<40 {
                        try Task.checkCancellation()
                        if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                        var poll = URLRequest(url: operation); poll.httpMethod = "GET"; poll.timeoutInterval = 30
                        poll.setValue(try credentials.require("apiKey", provider: "Microsoft Vision"), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                        let value = try await sendJSON(poll, credentials: credentials)
                        let status = (value["status"] as? String ?? "").lowercased()
                        if status == "succeeded" { completed = value; break }
                        if status == "failed" { throw providerError(value) }
                        guard ["running", "notstarted"].contains(status) else { throw CloudMediaError(message: "Microsoft Read 返回未知任务状态。") }
                    }
                    guard let completed else { throw CloudMediaError(message: "Microsoft Read 识别等待超时，请稍后重试。") }
                    response = completed
                } else { response = try object(data) }
            case "baidu":
                let token = try await baiduToken(credentials)
                request.url = try query(request.url!, adding: ["access_token": token])
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = CloudServiceSigning.form(["image": image.data.base64EncodedString(), "language_type": service.options["languageType"] ?? "CHN_ENG", "detect_direction": "false", "probability": "true", "paragraph": "true"])
                response = try await sendJSON(request, credentials: credentials, secrets: [token])
            case "tencent":
                try json(["ImageBase64": image.data.base64EncodedString(), "LanguageType": service.options["languageType"] ?? "auto"], into: &request)
                try signTencent(&request, credentials: credentials, service: service, action: "GeneralBasicOCR", apiService: "ocr", version: "2018-11-19")
                response = try await sendJSON(request, credentials: credentials)
            case "amazon":
                request.setValue("Textract.DetectDocumentText", forHTTPHeaderField: "X-Amz-Target")
                request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["Document": ["Bytes": image.data.base64EncodedString()]], options: [.sortedKeys])
                try signAWS(&request, credentials: credentials, service: service, apiService: "textract")
                response = try await sendJSON(request, credentials: credentials)
            default: throw CloudMediaError(message: "当前服务尚未接入云端文字识别。")
            }
            try Task.checkCancellation()
            return try CloudMediaOCR.decode(response, provider: service.kind.rawValue, size: image.size)
        } catch { throw sanitized(error, credentials: credentials) }
    }

    func synthesize(text: String, language: String, service: ServiceConfig, apiKey: String) async throws -> Data {
        let credentials = try CloudServiceCredentials(apiKey)
        do {
            try Task.checkCancellation()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudMediaError(message: "请输入需要朗读的文字。") }
            guard text.utf8.count <= 5000 else { throw CloudMediaError(message: "朗读内容过长，请分段朗读。") }
            var request = try baseRequest(service, capability: "tts")
            var extraSecrets: [String] = []
            let lang = Self.language(language)
            switch service.kind.rawValue {
            case "google":
                try googleAuthorization(&request, credentials)
                var voice: [String: Any] = ["languageCode": lang == "zh-CN" ? "cmn-CN" : lang == "zh-TW" ? "cmn-TW" : lang]
                if let name = service.options["voice"], !name.isEmpty { voice["name"] = name }
                let rate = try number(service.options["speakingRate"] ?? "1", range: 0.25...4, name: "语速")
                try json(["input": ["text": text], "voice": voice, "audioConfig": ["audioEncoding": "MP3", "speakingRate": rate]], into: &request)
            case "microsoft":
                request.setValue(try credentials.require("apiKey", provider: "Microsoft Speech"), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
                request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
                request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
                request.setValue("pop", forHTTPHeaderField: "User-Agent")
                let voice = service.options["voice"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.microsoftVoice(lang)
                request.httpBody = Data("<speak version='1.0' xml:lang='\(Self.xml(lang))'><voice name='\(Self.xml(voice))'>\(Self.xml(text))</voice></speak>".utf8)
            case "baidu":
                guard text.utf8.count <= 1024 else { throw CloudMediaError(message: "百度短文本合成每次最多 1024 个 UTF-8 字节，请分段朗读。") }
                let token = try await baiduToken(credentials); extraSecrets = [token]
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                // Baidu's official demo explicitly URL-encodes tex twice; other fields once.
                request.httpBody = CloudServiceSigning.form(["tex": CloudServiceSigning.encode(text), "tok": token,
                    "cuid": "pop-desktop", "ctp": "1", "lan": "zh", "aue": "3",
                    "per": service.options["voice"] ?? "0", "spd": String(Int(try number(service.options["speed"] ?? "5", range: 0...15, name: "语速"))),
                    "pit": String(Int(try number(service.options["pitch"] ?? "5", range: 0...15, name: "音调"))), "vol": "5"])
            case "tencent":
                let english = lang.hasPrefix("en")
                guard text.count <= (english ? 500 : 150) else { throw CloudMediaError(message: "腾讯基础合成单次限 150 个中文字符或 500 个英文字母，请分段朗读。") }
                let voice = Int(service.options["voice"] ?? "") ?? (english ? 1050 : 1001)
                try json(["Text": text, "SessionId": UUID().uuidString, "ModelType": 1, "VoiceType": voice,
                          "PrimaryLanguage": english ? 2 : 1, "SampleRate": 16000, "Codec": "mp3",
                          "Speed": try number(service.options["speed"] ?? "0", range: -2...6, name: "语速")], into: &request)
                try signTencent(&request, credentials: credentials, service: service, action: "TextToVoice", apiService: "tts", version: "2019-08-23")
            case "amazon":
                guard text.count <= 3000 else { throw CloudMediaError(message: "Amazon Polly 同步合成单次最多 3000 个字符，请分段朗读。") }
                let voice = service.options["voice"].flatMap { $0.isEmpty ? nil : $0 } ?? (lang.hasPrefix("zh") ? "Zhiyu" : "Joanna")
                try json(["Text": text, "OutputFormat": "mp3", "VoiceId": voice, "Engine": service.options["engine"] ?? "standard"], into: &request)
                try signAWS(&request, credentials: credentials, service: service, apiService: "polly")
            default: throw CloudMediaError(message: "当前服务尚未接入云端语音合成。")
            }
            let (data, response) = try await send(request, credentials: credentials, secrets: extraSecrets)
            try Task.checkCancellation()
            let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if ["google", "tencent"].contains(service.kind.rawValue) {
                let value = try object(data)
                let content = service.kind.rawValue == "google" ? value : (value["Response"] as? [String: Any] ?? [:])
                if content["Error"] != nil || value["error"] != nil { throw providerError(value) }
                let encoded = content[service.kind.rawValue == "google" ? "audioContent" : "Audio"] as? String ?? ""
                guard let audio = Data(base64Encoded: encoded), !audio.isEmpty else { throw CloudMediaError(message: "语音服务未返回有效音频。") }
                return try audioData(audio)
            }
            guard !contentType.contains("json"), !contentType.contains("text/") else {
                throw providerError((try? object(data)) ?? [:], secrets: extraSecrets)
            }
            return try audioData(data)
        } catch { throw sanitized(error, credentials: credentials) }
    }

    private func baseRequest(_ service: ServiceConfig, capability: String) throws -> URLRequest {
        if ["microsoft", "amazon", "tencent"].contains(service.kind.rawValue) {
            let region = CloudMediaCatalog.effectiveRegion(for: service.kind, options: service.options)
            guard region.count <= 64, region.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
                throw CloudMediaError(message: "资源地区 / Region 无效，请填写服务控制台中的地区代码。")
            }
        }
        let endpoint = CloudMediaCatalog.resolvedEndpoint(for: service.kind, capability: capability, endpoint: service.endpoint, options: service.options)
        guard let url = URL(string: endpoint), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && HTTPTranslationService.isLoopback(host)) else {
            throw CloudMediaError(message: "媒体服务地址无效，云端地址需要 HTTPS；本机服务可使用 HTTP。")
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func googleAuthorization(_ request: inout URLRequest, _ credentials: CloudServiceCredentials) throws {
        if let token = credentials.values["accessToken"], !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        else { request.setValue(try credentials.require("apiKey", provider: "Google Cloud"), forHTTPHeaderField: "X-Goog-Api-Key") }
    }
    private func signTencent(_ request: inout URLRequest, credentials: CloudServiceCredentials, service: ServiceConfig, action: String, apiService: String, version: String) throws {
        CloudServiceSigning.signTencent(&request, secretId: try credentials.require("secretId", provider: "腾讯云"), secretKey: try credentials.require("secretKey", provider: "腾讯云"), service: apiService, action: action, version: version, region: CloudMediaCatalog.effectiveRegion(for: service.kind, options: service.options), now: Date())
    }
    private func signAWS(_ request: inout URLRequest, credentials: CloudServiceCredentials, service: ServiceConfig, apiService: String) throws {
        CloudServiceSigning.signAWS(&request, accessKeyId: try credentials.require("accessKeyId", provider: "Amazon"), secretAccessKey: try credentials.require("secretAccessKey", provider: "Amazon"), sessionToken: credentials.values["sessionToken"], region: CloudMediaCatalog.effectiveRegion(for: service.kind, options: service.options), service: apiService, now: Date())
    }
    private func baiduToken(_ credentials: CloudServiceCredentials) async throws -> String {
        var request = URLRequest(url: URL(string: "https://aip.baidubce.com/oauth/2.0/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudServiceSigning.form(["grant_type": "client_credentials", "client_id": try credentials.require("apiKey", provider: "百度智能云"), "client_secret": try credentials.require("secretKey", provider: "百度智能云")])
        let response = try await sendJSON(request, credentials: credentials)
        guard let token = response["access_token"] as? String, !token.isEmpty else { throw providerError(response) }
        return token
    }
    private func sendJSON(_ request: URLRequest, credentials: CloudServiceCredentials, secrets: [String] = []) async throws -> [String: Any] {
        let (data, _) = try await send(request, credentials: credentials, secrets: secrets)
        let value = try object(data)
        if value["error"] != nil || value["error_code"] != nil || (value["Response"] as? [String: Any])?["Error"] != nil {
            throw providerError(value, secrets: secrets)
        }
        return value
    }
    private func send(_ request: URLRequest, credentials: CloudServiceCredentials, secrets: [String] = []) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CloudMediaError(message: "媒体服务返回非 HTTP 响应。") }
        guard data.count <= 32 * 1024 * 1024 else { throw CloudMediaError(message: "媒体服务响应过大，已停止处理。") }
        guard (200..<300).contains(response.statusCode) else {
            var message = "媒体服务返回 HTTP \(response.statusCode)，请检查接口、密钥、开通状态与额度。"
            if let value = try? object(data) { message += " " + providerError(value, secrets: secrets).message }
            throw CloudMediaError(message: credentials.redact(message))
        }
        return (data, response)
    }
    private func providerError(_ value: [String: Any], secrets: [String] = []) -> CloudMediaError {
        let error = value["error"] as? [String: Any] ?? (value["Response"] as? [String: Any])?["Error"] as? [String: Any] ?? [:]
        var message = error["message"] as? String ?? error["Message"] as? String ?? value["error_msg"] as? String ?? value["error_description"] as? String ?? value["message"] as? String ?? value["Message"] as? String ?? "媒体服务处理失败，请检查配置、权限与输入。"
        for secret in secrets where !secret.isEmpty { message = message.replacingOccurrences(of: secret, with: "[已隐藏]") }
        return CloudMediaError(message: String(message.prefix(600)))
    }
    private func sanitized(_ error: Error, credentials: CloudServiceCredentials) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return CloudMediaError(message: url.code == .timedOut ? "媒体服务请求超时，请稍后重试。" : "无法连接媒体服务（\(url.code.rawValue)），请检查网络与服务地址。")
        }
        if error is CloudMediaError || error is HTTPTranslationError { return CloudMediaError(message: credentials.redact(error.localizedDescription)) }
        return CloudMediaError(message: "媒体服务响应无法解析，请检查接口版本与配置。")
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudMediaError(message: "媒体服务未返回有效 JSON。") }
        return value
    }
    private func json(_ value: [String: Any], into request: inout URLRequest) throws { request.httpBody = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func query(_ url: URL, adding values: [String: String]) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CloudMediaError(message: "服务地址无效。") }
        var items = components.queryItems ?? []
        items.removeAll { values[$0.name] != nil }
        items += values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        components.queryItems = items
        guard let result = components.url else { throw CloudMediaError(message: "服务地址无效。") }; return result
    }
    private func sameOrigin(_ a: URL, _ b: URL) -> Bool { a.scheme == b.scheme && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port && a.user == nil && a.password == nil }
    private func number(_ value: String, range: ClosedRange<Double>, name: String) throws -> Double {
        guard let number = Double(value), number.isFinite, range.contains(number) else { throw CloudMediaError(message: "\(name)必须在 \(range.lowerBound)–\(range.upperBound) 范围内。") }; return number
    }
    private func audioData(_ data: Data) throws -> Data {
        // Reject empty/error bodies without logging provider content. Container decoding
        // remains AVAudioPlayer's responsibility; MP3 may start with ID3 or a frame sync.
        guard data.count >= 4 else { throw CloudMediaError(message: "语音服务返回空音频或无效音频。") }
        return data
    }
    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private static func language(_ value: String) -> String {
        let aliases = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU", "ar": "ar-SA"]
        return aliases[value] ?? value
    }
    private static func microsoftVoice(_ language: String) -> String {
        ["zh-CN": "zh-CN-XiaoxiaoNeural", "zh-TW": "zh-TW-HsiaoChenNeural", "ja-JP": "ja-JP-NanamiNeural", "ko-KR": "ko-KR-SunHiNeural", "fr-FR": "fr-FR-DeniseNeural", "de-DE": "de-DE-KatjaNeural", "es-ES": "es-ES-ElviraNeural", "ru-RU": "ru-RU-SvetlanaNeural"][language] ?? "en-US-JennyMultilingualNeural"
    }
}

private final class CloudMediaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct MediaImage {
    let data: Data
    let size: CGSize
    init(_ input: Data) throws {
        guard !input.isEmpty, input.count <= 24 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(input as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 50_000_000 else {
            throw CloudMediaError(message: "图片无效或过大，请使用不超过 24 MB、5000 万像素的图片。")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let type = CGImageSourceGetType(source) as String? ?? ""
        if orientation == 1 && [UTType.png.identifier, UTType.jpeg.identifier].contains(type) {
            data = input; size = CGSize(width: width.doubleValue, height: height.doubleValue)
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CloudMediaError(message: "无法将图片转换为 OCR 支持的格式。") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw CloudMediaError(message: "无法编码 OCR 图片。") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CloudMediaError(message: "无法编码 OCR 图片。") }
            data = output as Data; size = CGSize(width: image.width, height: image.height)
        }
    }
}

private enum CloudMediaOCR {
    static func decode(_ object: [String: Any], provider: String, size: CGSize) throws -> OCRDocument {
        var lines: [OCRLine] = []
        var texts: [String] = []
        func add(_ text: String, rect: CGRect?, confidence: Double, imageSize: CGSize = size) {
            guard !text.isEmpty else { return }; texts.append(text)
            guard let rect, rect.width > 0, rect.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
            let normalized = CGRect(x: rect.minX / imageSize.width, y: 1 - rect.maxY / imageSize.height,
                                    width: rect.width / imageSize.width, height: rect.height / imageSize.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return }
            lines.append(OCRLine(text: text, x: normalized.minX, y: normalized.minY, width: normalized.width, height: normalized.height, confidence: Float(min(1, max(0, confidence)))))
        }
        switch provider {
        case "google":
            guard let response = (object["responses"] as? [[String: Any]])?.first else { throw CloudMediaError(message: "Google Vision 未返回识别结果。") }
            if response["error"] != nil { throw CloudMediaError(message: "Google Vision 识别失败，请检查 API 权限与图片。") }
            if let full = response["fullTextAnnotation"] as? [String: Any], let pages = full["pages"] as? [[String: Any]] {
                for page in pages {
                    let pageSize = CGSize(width: number(page["width"], fallback: size.width), height: number(page["height"], fallback: size.height))
                    for block in page["blocks"] as? [[String: Any]] ?? [] {
                        for paragraph in block["paragraphs"] as? [[String: Any]] ?? [] {
                            var words: [String] = [], bounds = CGRect.null, confidence: [Double] = []
                            func flush() {
                                if !words.isEmpty { add(words.joined(separator: " "), rect: bounds.isNull ? nil : bounds, confidence: confidence.reduce(0,+) / Double(max(1,confidence.count)), imageSize: pageSize) }
                                words = []; bounds = .null; confidence = []
                            }
                            for word in paragraph["words"] as? [[String: Any]] ?? [] {
                                let symbols = word["symbols"] as? [[String: Any]] ?? []
                                words.append(symbols.compactMap { $0["text"] as? String }.joined())
                                if let rect = polygon(word["boundingBox"]) { bounds = bounds.union(rect) }
                                if let value = word["confidence"] as? NSNumber { confidence.append(value.doubleValue) }
                                let last = symbols.last?["property"] as? [String: Any]
                                let breaks = last?["detectedBreak"] as? [String: Any]
                                if ["LINE_BREAK", "EOL_SURE_SPACE", "HYPHEN"].contains(breaks?["type"] as? String ?? "") { flush() }
                            }
                            flush()
                        }
                    }
                }
                if texts.isEmpty, let text = full["text"] as? String { texts.append(text) }
            } else if let annotations = response["textAnnotations"] as? [[String: Any]], let first = annotations.first {
                texts = [first["description"] as? String ?? ""]
                for annotation in annotations.dropFirst() { add(annotation["description"] as? String ?? "", rect: polygon(annotation["boundingPoly"]), confidence: 0) }
            }
        case "microsoft":
            guard let result = object["analyzeResult"] as? [String: Any], let pages = result["readResults"] as? [[String: Any]] else { throw CloudMediaError(message: "Microsoft Read 未返回已完成的识别结果。") }
            for page in pages {
                let pageSize = CGSize(width: number(page["width"], fallback: size.width), height: number(page["height"], fallback: size.height))
                for line in page["lines"] as? [[String: Any]] ?? [] {
                    let values = (line["words"] as? [[String: Any]] ?? []).compactMap { ($0["confidence"] as? NSNumber)?.doubleValue }
                    add(line["text"] as? String ?? "", rect: flatPolygon(line["boundingBox"]), confidence: values.reduce(0,+) / Double(max(1,values.count)), imageSize: pageSize)
                }
            }
        case "baidu":
            guard let values = object["words_result"] as? [[String: Any]] else { throw CloudMediaError(message: "百度 OCR 未返回识别结果。") }
            for line in values {
                let location = line["location"] as? [String: Any]
                let rect = location.map { CGRect(x: number($0["left"]), y: number($0["top"]), width: number($0["width"]), height: number($0["height"])) }
                add(line["words"] as? String ?? "", rect: rect, confidence: number((line["probability"] as? [String: Any])?["average"]))
            }
        case "tencent":
            guard let response = object["Response"] as? [String: Any], let values = response["TextDetections"] as? [[String: Any]] else { throw CloudMediaError(message: "腾讯 OCR 未返回识别结果。") }
            for line in values {
                // Polygon is in the original image; ItemPolygon is rotation-corrected.
                let rect = points(line["Polygon"], x: "X", y: "Y")
                add(line["DetectedText"] as? String ?? "", rect: rect, confidence: number(line["Confidence"]) / 100)
            }
        case "amazon":
            guard let blocks = object["Blocks"] as? [[String: Any]] else { throw CloudMediaError(message: "Amazon Textract 未返回识别结果。") }
            for block in blocks where block["BlockType"] as? String == "LINE" {
                let box = (block["Geometry"] as? [String: Any])?["BoundingBox"] as? [String: Any]
                let rect = box.map { CGRect(x: number($0["Left"]) * size.width, y: number($0["Top"]) * size.height, width: number($0["Width"]) * size.width, height: number($0["Height"]) * size.height) }
                add(block["Text"] as? String ?? "", rect: rect, confidence: number(block["Confidence"]) / 100)
            }
        default: throw CloudMediaError(message: "未知的云 OCR 服务。")
        }
        let sorted = OCRTextLayout.orderedLines(lines)
        // Do not invent bounding boxes when a service returns text only.
        let text = sorted.isEmpty ? texts.joined(separator: "\n") : OCRTextLayout.text(from: sorted)
        return OCRDocument(text: text, lines: sorted, qrCodes: [])
    }
    private static func number(_ value: Any?, fallback: Double = 0) -> Double { (value as? NSNumber)?.doubleValue ?? fallback }
    private static func polygon(_ value: Any?) -> CGRect? { points((value as? [String: Any])?["vertices"], x: "x", y: "y") }
    private static func points(_ value: Any?, x: String, y: String) -> CGRect? {
        guard let values = value as? [[String: Any]], values.count >= 3 else { return nil }
        let xs = values.map { number($0[x]) }, ys = values.map { number($0[y]) }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    private static func flatPolygon(_ value: Any?) -> CGRect? {
        guard let values = value as? [NSNumber], values.count >= 6, values.count % 2 == 0 else { return nil }
        let points = stride(from: 0, to: values.count, by: 2).map { ["x": values[$0], "y": values[$0+1]] }
        return self.points(points, x: "x", y: "y")
    }
}

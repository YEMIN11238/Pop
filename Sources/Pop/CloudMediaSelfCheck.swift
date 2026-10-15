import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Every URL, including OAuth and Azure polling, is intercepted by URLProtocol.
/// These tests never use real credentials or contact billable cloud services.
enum CloudMediaSelfCheck {
    static func run() async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMediaFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CloudMediaFixtureProtocol.setHandler(nil) }
        let client = CloudMediaService(session: session)
        let image = try imageFixture()
        let audio = wavFixture()
        var checks: [String] = []

        func config(_ name: String, _ capability: String) throws -> ServiceConfig {
            guard let kind = ServiceKind(rawValue: name) else { throw PopError.message("媒体自检缺少服务类型 \(name)") }
            var service = ServiceConfig(name: name, kind: kind)
            service.capability = capability; service.options = CloudMediaCatalog.defaultOptions(for: kind, capability: capability)
            return service
        }
        func assertLine(_ document: OCRDocument, _ expected: String) throws {
            guard document.text.contains(expected), let line = document.lines.first,
                  abs(line.x - 0.1) < 0.001, abs(line.y - 0.7) < 0.001,
                  abs(line.width - 0.5) < 0.001, abs(line.height - 0.2) < 0.001 else {
                throw PopError.message("云 OCR 归一化文字或框位置自检失败：\(expected)")
            }
        }

        let google = try config("google", "ocr")
        CloudMediaFixtureProtocol.setHandler { request in
            try require(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "fixture-google-key", "Google OCR API Key header")
            let json = try bodyJSON(request)
            let first = (json["requests"] as? [[String: Any]])?.first
            try require(((first?["features"] as? [[String: Any]])?.first?["type"] as? String) == "DOCUMENT_TEXT_DETECTION", "Google OCR feature")
            try require(((first?["image"] as? [String: Any])?["content"] as? String) == image.base64EncodedString(), "Google OCR image bytes")
            var symbols = "Hello".map { ["text": String($0)] as [String: Any] }
            symbols[symbols.count - 1]["property"] = ["detectedBreak": ["type": "LINE_BREAK"]]
            let word: [String: Any] = ["symbols": symbols, "confidence": 0.95, "boundingBox": ["vertices": vertices()]]
            return .json(["responses": [["fullTextAnnotation": ["text": "Hello\n", "pages": [["width": 200, "height": 100, "blocks": [["paragraphs": [["words": [word]]]]]]]]]]])
        }
        try assertLine(try await client.recognize(imageData: image, service: google, apiKey: "fixture-google-key"), "Hello")
        checks.append("Google Vision：本地拦截验证鉴权、图片 base64、DOCUMENT_TEXT_DETECTION、段落符号解析与实际尺寸归一化框")

        let microsoft = try config("microsoft", "ocr")
        let readCounter = MediaFixtureCounter()
        CloudMediaFixtureProtocol.setHandler { request in
            let count = readCounter.increment()
            try require(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "fixture-ms-key", "Azure OCR key")
            if count == 1 {
                try require(request.httpMethod == "POST" && body(request) == image, "Azure Read image body")
                return .init(status: 202, headers: ["Operation-Location": "https://eastus.api.cognitive.microsoft.com/vision/v3.2/read/analyzeResults/test"], data: Data())
            }
            try require(request.httpMethod == "GET", "Azure Read poll method")
            if count == 2 { return .json(["status": "running"]) }
            return .json(["status": "succeeded", "analyzeResult": ["readResults": [["width": 200, "height": 100, "lines": [["text": "Azure fixture", "boundingBox": [20,10,120,10,120,30,20,30], "words": [["confidence": 0.9]]]]]]]])
        }
        try assertLine(try await client.recognize(imageData: image, service: microsoft, apiKey: "fixture-ms-key"), "Azure")
        try require(readCounter.value == 3, "Azure Read async POST + running + succeeded")
        checks.append("Microsoft Read：本地验证 POST→202→running→succeeded 异步轮询、资源密钥与四点坐标归一化")

        let baidu = try config("baidu", "ocr")
        let baiduCredentials = "{\"apiKey\":\"fixture-baidu-api\",\"secretKey\":\"fixture-baidu-secret\"}"
        CloudMediaFixtureProtocol.setHandler { request in
            if request.url?.path.contains("oauth") == true {
                let values = form(request)
                try require(values["client_id"] == "fixture-baidu-api" && values["client_secret"] == "fixture-baidu-secret" && request.httpMethod == "POST", "Baidu media OAuth fields")
                try require(request.url?.query == nil, "Baidu secret not in URL")
                return .json(["access_token": "fixture-baidu-token", "expires_in": 3600])
            }
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "access_token" })?.value
            try require(token == "fixture-baidu-token" && form(request)["image"] == image.base64EncodedString(), "Baidu OCR token and image")
            return .json(["words_result": [["words": "Baidu fixture", "location": ["left": 20, "top": 10, "width": 100, "height": 20], "probability": ["average": 0.98]]]])
        }
        try assertLine(try await client.recognize(imageData: image, service: baidu, apiKey: baiduCredentials), "Baidu")
        checks.append("百度 OCR：智能云 API Key/Secret Key 独立 OAuth、POST 密钥、短期 token、表单图片和置信度/位置解析通过")

        let tencent = try config("tencent", "ocr")
        let tencentCredentials = "{\"secretId\":\"fixture-tencent-id\",\"secretKey\":\"fixture-tencent-secret\"}"
        CloudMediaFixtureProtocol.setHandler { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            try require(authorization.hasPrefix("TC3-HMAC-SHA256") && authorization.contains("/ocr/tc3_request"), "Tencent OCR signing scope")
            try require(request.value(forHTTPHeaderField: "X-TC-Action") == "GeneralBasicOCR" && request.value(forHTTPHeaderField: "X-TC-Version") == "2018-11-19", "Tencent OCR API action/version")
            return .json(["Response": ["TextDetections": [["DetectedText": "Tencent fixture", "Confidence": 99, "Polygon": vertices(uppercase: true), "ItemPolygon": ["X": 999, "Y": 999, "Width": 1, "Height": 1]]]]])
        }
        try assertLine(try await client.recognize(imageData: image, service: tencent, apiKey: tencentCredentials), "Tencent")
        checks.append("腾讯 OCR：TC3 OCR 签名域/版本与原图 Polygon 坐标验证；不误用旋转纠正后的 ItemPolygon")

        let amazon = try config("amazon", "ocr")
        let amazonCredentials = "{\"accessKeyId\":\"fixture-aws-id\",\"secretAccessKey\":\"fixture-aws-secret\",\"sessionToken\":\"fixture-aws-token\"}"
        CloudMediaFixtureProtocol.setHandler { request in
            try require((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("/textract/aws4_request"), "Textract AWS signing scope")
            try require(request.value(forHTTPHeaderField: "X-Amz-Target") == "Textract.DetectDocumentText" && request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "fixture-aws-token", "Textract target/session token")
            return .json(["Blocks": [["BlockType": "LINE", "Text": "Textract fixture", "Confidence": 98, "Geometry": ["BoundingBox": ["Left": 0.1, "Top": 0.1, "Width": 0.5, "Height": 0.2]]]]])
        }
        try assertLine(try await client.recognize(imageData: image, service: amazon, apiKey: amazonCredentials), "Textract")
        checks.append("Amazon Textract：AWS SigV4 服务域/临时 Token、DetectDocumentText 与标准化文字框验证通过")

        for name in ["google", "microsoft", "baidu", "tencent", "amazon"] {
            var service = try config(name, "tts")
            if name == "microsoft" { service.options["voice"] = "en-US-JennyNeural" }
            let key = name == "baidu" ? baiduCredentials : name == "tencent" ? tencentCredentials : name == "amazon" ? amazonCredentials : "fixture-tts-key"
            CloudMediaFixtureProtocol.setHandler { request in
                if request.url?.path.contains("oauth") == true { return .json(["access_token": "fixture-baidu-token"]) }
                switch name {
                case "google":
                    let value = try bodyJSON(request)
                    try require((value["audioConfig"] as? [String: Any])?["audioEncoding"] as? String == "MP3", "Google TTS output encoding")
                    try require((value["voice"] as? [String: Any])?["languageCode"] as? String == "cmn-CN", "Google Chinese locale")
                    return .json(["audioContent": audio.base64EncodedString()])
                case "microsoft":
                    let text = String(data: body(request), encoding: .utf8) ?? ""
                    try require(text.contains("&lt;pop&gt;") && text.contains("&amp;"), "Microsoft TTS SSML escape")
                    try require(request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat") == "audio-24khz-48kbitrate-mono-mp3", "Microsoft TTS output header")
                case "baidu":
                    let values = form(request)
                    try require(values["tex"]?.removingPercentEncoding == "你好 <pop> &", "Baidu TTS double encoding")
                    try require(values["lan"] == "zh" && values["ctp"] == "1" && values["tok"] == "fixture-baidu-token", "Baidu TTS fixed fields/token")
                case "tencent":
                    try require(request.value(forHTTPHeaderField: "X-TC-Action") == "TextToVoice" && request.value(forHTTPHeaderField: "X-TC-Version") == "2019-08-23", "Tencent TTS action/version")
                    try require((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("/tts/tc3_request"), "Tencent TTS signing scope")
                    return .json(["Response": ["Audio": audio.base64EncodedString()]])
                default:
                    try require(request.url?.path == "/v1/speech" && (request.value(forHTTPHeaderField: "Authorization") ?? "").contains("/polly/aws4_request"), "Amazon Polly route/signing scope")
                }
                return .init(status: 200, headers: ["Content-Type": "audio/mpeg"], data: audio)
            }
            let value = try await client.synthesize(text: "你好 <pop> &", language: "zh-Hans", service: service, apiKey: key)
            try require(value == audio, "\(name) TTS binary/base64 audio bytes")
        }
        checks.append("5 家云 TTS：Google JSON/base64、Microsoft SSML 转义、百度 tex 双编码、腾讯 TC3、Polly AWS 签名与音频字节本地验证通过")

        for (name, capability, region, expected) in [
            ("microsoft", "ocr", "westus2", "https://westus2.api.cognitive.microsoft.com/vision/v3.2/read/analyze"),
            ("microsoft", "tts", "westus2", "https://westus2.tts.speech.microsoft.com/cognitiveservices/v1"),
            ("amazon", "ocr", "cn-north-1", "https://textract.cn-north-1.amazonaws.com.cn"),
            ("amazon", "tts", "cn-north-1", "https://polly.cn-north-1.amazonaws.com.cn/v1/speech")
        ] {
            var regional = try config(name, capability)
            regional.endpoint = CloudMediaCatalog.defaultEndpoint(for: regional.kind, capability: capability)
            regional.options["region"] = " \(region.uppercased()) "
            CloudMediaFixtureProtocol.setHandler { request in
                try require(request.url?.absoluteString == expected, "\(name) \(capability) regional endpoint refresh")
                if name == "amazon" {
                    try require((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("/cn-north-1/"), "AWS signing region matches endpoint")
                }
                if capability == "tts" { return .init(status: 200, headers: ["Content-Type": "audio/mpeg"], data: audio) }
                if name == "amazon" {
                    return .json(["Blocks": [["BlockType": "LINE", "Text": "Region fixture", "Geometry": ["BoundingBox": ["Left": 0.1, "Top": 0.1, "Width": 0.5, "Height": 0.2]]]]])
                }
                return .json(["status": "succeeded", "analyzeResult": ["readResults": [["width": 200, "height": 100, "lines": [["text": "Region fixture", "boundingBox": [20,10,120,10,120,30,20,30]]]]]]])
            }
            if capability == "ocr" {
                try assertLine(try await client.recognize(imageData: image, service: regional, apiKey: name == "amazon" ? amazonCredentials : "fixture-ms-key"), "Region")
            } else {
                let result = try await client.synthesize(text: "fixture", language: "en", service: regional, apiKey: name == "amazon" ? amazonCredentials : "fixture-ms-key")
                try require(result == audio, "regional TTS audio")
            }
        }
        for (name, capability, custom) in [
            ("microsoft", "ocr", "https://my-resource.cognitiveservices.azure.com/vision/v3.2/read/analyze"),
            ("amazon", "tts", "https://private.example/v1/speech"),
            ("microsoft", "tts", "https://eastus.tts.speech.microsoft.com/cognitiveservices/v1?custom=true")
        ] {
            let service = try config(name, capability)
            try require(CloudMediaCatalog.resolvedEndpoint(for: service.kind, capability: capability, endpoint: custom, options: ["region": "westus2"]) == custom, "explicit custom endpoint preserved")
        }
        var invalidRegion = try config("amazon", "tts"); invalidRegion.options["region"] = "us-east-1/path"
        let invalidCounter = MediaFixtureCounter()
        CloudMediaFixtureProtocol.setHandler { _ in _ = invalidCounter.increment(); return .init(data: audio) }
        do { _ = try await client.synthesize(text: "fixture", language: "en", service: invalidRegion, apiKey: amazonCredentials); throw PopError.message("无效 Region 未被拒绝") }
        catch let error as CloudMediaError { try require(error.message.contains("Region") && invalidCounter.value == 0, "invalid region rejected before network") }
        let msKind = try config("microsoft", "tts").kind
        try require(CloudMediaCatalog.defaultEndpoint(for: msKind, capability: "tts", options: ["region": " "]) == "https://eastus.tts.speech.microsoft.com/cognitiveservices/v1", "blank region falls back to catalog default")
        checks.append("地区一致性：Azure OCR/TTS 与 AWS Textract/Polly 的预填地址随地区更新、AWS 中国域名/签名一致；自定义端点保留，空地区回退与非法地区提前拒绝通过")

        let blocked = MediaFixtureCounter()
        CloudMediaFixtureProtocol.setHandler { _ in
            _ = blocked.increment()
            return .init(status: 202, headers: ["Operation-Location": "https://untrusted.example/read/1"], data: Data())
        }
        do { _ = try await client.recognize(imageData: image, service: microsoft, apiKey: "private-media-key"); throw PopError.message("Azure 不安全轮询未被拒绝") }
        catch let error as CloudMediaError { try require(error.message.contains("不安全") && blocked.value == 1, "Azure cross-origin poll blocked") }

        CloudMediaFixtureProtocol.setHandler { request in
            if request.url?.path.contains("oauth") == true { return .json(["access_token": "private-generated-token"]) }
            return .json(["error_code": 110, "error_msg": "denied private-generated-token fixture-baidu-api fixture-baidu-secret"])
        }
        do { _ = try await client.synthesize(text: "fixture", language: "zh-Hans", service: try config("baidu", "tts"), apiKey: baiduCredentials); throw PopError.message("百度 TTS JSON 错误未被拒绝") }
        catch let error as CloudMediaError {
            try require(!error.message.contains("private-generated-token") && !error.message.contains("fixture-baidu-api") && !error.message.contains("fixture-baidu-secret"), "Baidu derived token and credentials redaction")
        }
        CloudMediaFixtureProtocol.setHandler { _ in .json(["audioContent": "invalid-base64!"]) }
        do { _ = try await client.synthesize(text: "fixture", language: "en", service: try config("google", "tts"), apiKey: "key"); throw PopError.message("无效 base64 音频未被拒绝") }
        catch is CloudMediaError { }
        checks.append("云媒体错误保护：跨域 Azure 轮询不转发密钥、HTTP200 JSON 错误、衍生 token/多字段密钥隐藏、无效 base64 音频拒绝通过")

        let delayed = MediaFixtureCounter()
        CloudMediaFixtureProtocol.setHandler { _ in _ = delayed.increment(); return .init(status: 200, headers: ["Content-Type": "application/json"], data: Data("{}".utf8), delay: 0.3) }
        let task = Task { try await client.synthesize(text: "fixture", language: "en", service: try config("google", "tts"), apiKey: "key") }
        try await Task.sleep(nanoseconds: 30_000_000); task.cancel()
        do { _ = try await task.value; throw PopError.message("云媒体任务取消未传播") }
        catch is CancellationError { }
        checks.append("云媒体取消：URLProtocol 延迟请求取消传播成功；全部测试请求在本机拦截，真实云 API 与费用未触发")
        return checks
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PopError.message("CloudMedia self-check: " + message) }
    }
    private static func body(_ request: URLRequest) -> Data {
        if let value = request.httpBody { return value }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    private static func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: body(request)) as? [String: Any] else { throw PopError.message("Fixture body is not JSON") }; return value
    }
    private static func form(_ request: URLRequest) -> [String: String] {
        let text = String(data: body(request), encoding: .utf8) ?? ""
        return Dictionary(text.split(separator: "&").compactMap { pair -> (String, String)? in
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, let key = String(pieces[0]).removingPercentEncoding,
                  let value = String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
            return (key, value)
        }, uniquingKeysWith: { _, next in next })
    }
    private static func vertices(uppercase: Bool = false) -> [[String: Int]] {
        [(20,10),(120,10),(120,30),(20,30)].map { [uppercase ? "X" : "x": $0.0, uppercase ? "Y" : "y": $0.1] }
    }
    private static func imageFixture() throws -> Data {
        guard let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PopError.message("Cannot create media fixture") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        guard let image = context.makeImage() else { throw PopError.message("Cannot render media fixture") }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PopError.message("Cannot encode media fixture") }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw PopError.message("Cannot finalize media fixture") }
        return data as Data
    }
    private static func wavFixture() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(356); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        text("data"); u32(320); data.append(Data(repeating: 0, count: 320)); return data
    }
}

private final class MediaFixtureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct CloudMediaFixtureReply {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var data: Data
    var delay: TimeInterval = 0
    static func json(_ value: [String: Any]) -> CloudMediaFixtureReply {
        .init(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }
}

private final class CloudMediaFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let handlerLock = NSLock()
    private static var handler: ((URLRequest) throws -> CloudMediaFixtureReply)?
    private let stateLock = NSLock(); private var stopped = false
    static func setHandler(_ value: ((URLRequest) throws -> CloudMediaFixtureReply)?) {
        handlerLock.lock(); handler = value; handlerLock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handlerLock.lock(); let handler = Self.handler; Self.handlerLock.unlock()
        do {
            guard let handler else { throw PopError.message("Unconfigured media fixture; network access is forbidden") }
            let reply = try handler(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
                guard let self else { return }
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                guard !self.stopped, let url = self.request.url,
                      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

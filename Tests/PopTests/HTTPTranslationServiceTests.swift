import Foundation
import XCTest
@testable import Pop

final class HTTPTranslationServiceTests: XCTestCase {
    private var session: URLSession!
    private var sut: HTTPTranslationService!
    private let input = TranslationRequest(text: "Hello\n\nWorld", source: "auto", target: "zh-Hans")

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranslationMockURLProtocol.self]
        session = URLSession(configuration: config)
        sut = HTTPTranslationService(session: session, timeout: 23)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        TranslationMockURLProtocol.setHandler(nil)
        session = nil
        sut = nil
        super.tearDown()
    }

    func testOpenAIURLConstructionAcceptsBaseAndExactEndpoints() throws {
        let cases = [
            "https://api.example.com": "https://api.example.com/v1/chat/completions",
            "https://api.example.com/v1/": "https://api.example.com/v1/chat/completions",
            "https://api.example.com/custom/v1": "https://api.example.com/custom/v1/chat/completions",
            "https://api.example.com/custom/chat/completions": "https://api.example.com/custom/chat/completions",
            "http://localhost:11434": "http://localhost:11434/v1/chat/completions",
            "http://127.0.0.1:11434/v1": "http://127.0.0.1:11434/v1/chat/completions"
        ]
        for (endpoint, expected) in cases {
            XCTAssertEqual(try sut.endpointURL(ServiceConfig(name: "Test", kind: .openAI, endpoint: endpoint)).absoluteString, expected)
        }
    }

    func testInvalidAndUnsupportedEndpointConfigurationsAreRejected() {
        for endpoint in ["file:///tmp/api", "https:///missing-host", "https://user:secret@example.com/v1", "http://192.168.1.2:11434", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "https://example.com:99999"] {
            XCTAssertThrowsError(try sut.endpointURL(ServiceConfig(name: "Test", kind: .openAI, endpoint: endpoint)), endpoint)
        }
        XCTAssertThrowsError(try sut.endpointURL(ServiceConfig(name: "DeepL", kind: .deepL, endpoint: "https://wrong.example/v2/translate")))
        XCTAssertThrowsError(try sut.endpointURL(ServiceConfig(name: "Google", kind: .google, endpoint: "https://translate.google.com")))
    }

    func testOpenAIRequestUsesNonStreamingChatAndSeparateTranslationInstructions() throws {
        let service = ServiceConfig(name: "Test", kind: .openAI, endpoint: "https://api.example.com/v1", model: "configured-model")
        let request = try sut.buildRequest(input, service: service, apiKey: "test-key")
        let body = try jsonBody(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 23)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(body["model"] as? String, "configured-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] ?? "" }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]?.contains("简体中文") == true)
        XCTAssertTrue(messages[0]["content"]?.contains("translation alone") == true)
        XCTAssertEqual(messages[1]["content"], "The passage between the ~~~ markers needs a 简体中文 translation. Return the translated passage without the markers.\n~~~\n" + input.text + "\n~~~")
    }

    func testOptionalOpenAIKeyIsNotSentForEitherRemoteOrLocalServer() throws {
        for endpoint in ["https://private.example/v1", "http://localhost:11434/v1"] {
            let service = ServiceConfig(name: "Test", kind: .openAI, endpoint: endpoint, model: "installed-model")
            XCTAssertNil(try sut.buildRequest(input, service: service, apiKey: "").value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testOpenAIRequiresAnExplicitModelForRemoteAndLocalServers() {
        for endpoint in ["", "https://private.example/v1", "http://localhost:11434"] {
            for model in ["", " \n\t"] {
                let service = ServiceConfig(name: "Missing model", kind: .openAI, endpoint: endpoint, model: model)
                XCTAssertThrowsError(try sut.buildRequest(input, service: service, apiKey: "")) { error in
                    guard case .configuration = error as? HTTPTranslationError else {
                        return XCTFail("Expected model configuration error, got \(error)")
                    }
                }
            }
        }
    }

    func testDeepLRequestMapsSourceAndTargetVariants() throws {
        let service = ServiceConfig(name: "DeepL", kind: .deepL, endpoint: "https://api.deepl.com/v2")
        let request = try sut.buildRequest(TranslationRequest(text: "Olá", source: "pt-PT", target: "zh-Hant"), service: service, apiKey: "test-key")
        let body = try jsonBody(request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepl.com/v2/translate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key test-key")
        XCTAssertEqual(body["text"] as? [String], ["Olá"])
        XCTAssertEqual(body["source_lang"] as? String, "PT")
        XCTAssertEqual(body["target_lang"] as? String, "ZH-HANT")
        let automatic = try sut.buildRequest(input, service: service, apiKey: "test-key")
        XCTAssertNil(try jsonBody(automatic)["source_lang"])
        XCTAssertEqual(HTTPTranslationService.deepLLanguage("en-GB", isTarget: true), "EN-GB")
        XCTAssertEqual(HTTPTranslationService.deepLLanguage("zh-Hans", isTarget: false), "ZH")
    }

    func testGoogleUsesOfficialV2AndKeyHeaderInsteadOfQuery() throws {
        let request = try sut.buildRequest(TranslationRequest(text: "Hello", source: "en-US", target: "zh-Hant"), service: ServiceConfig(name: "Google", kind: .google), apiKey: "test-key")
        let body = try jsonBody(request)
        XCTAssertEqual(request.url?.absoluteString, "https://translation.googleapis.com/language/translate/v2")
        XCTAssertNil(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.query })
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-API-Key"), "test-key")
        XCTAssertEqual(body["q"] as? [String], ["Hello"])
        XCTAssertEqual(body["format"] as? String, "text")
        XCTAssertEqual(body["source"] as? String, "en")
        XCTAssertEqual(body["target"] as? String, "zh-TW")
        XCTAssertThrowsError(try sut.buildRequest(input, service: ServiceConfig(name: "Google", kind: .google), apiKey: ""))
        XCTAssertThrowsError(try sut.buildRequest(input, service: ServiceConfig(name: "DeepL", kind: .deepL), apiKey: ""))
    }

    func testMockedOpenAIResponseIsDecoded() async throws {
        TranslationMockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            return (200, Data(#"{"choices":[{"message":{"content":"  你好\n\n世界  "}}]}"#.utf8))
        }
        let output = try await sut.translate(input, service: ServiceConfig(name: "Test", kind: .openAI, model: "fixture-model"), apiKey: "")
        XCTAssertEqual(output.text, "你好\n\n世界")
    }

    func testMockedDeepLResponsePreservesDetectedLanguage() async throws {
        TranslationMockURLProtocol.setHandler { _ in
            (200, Data(#"{"translations":[{"text":"你好","detected_source_language":"EN"}]}"#.utf8))
        }
        let output = try await sut.translate(input, service: ServiceConfig(name: "DeepL", kind: .deepL), apiKey: "test-key")
        XCTAssertEqual(output.text, "你好")
        XCTAssertEqual(output.detectedSource, "en")
    }

    func testMockedGoogleResponseDecodesEscapedTextAndDetectedLanguage() async throws {
        TranslationMockURLProtocol.setHandler { _ in
            (200, Data(#"{"data":{"translations":[{"translatedText":"Tom &#39;n&#39; Jerry &amp; friends &#x4E2D;","detectedSourceLanguage":"en"}]}}"#.utf8))
        }
        let output = try await sut.translate(input, service: ServiceConfig(name: "Google", kind: .google), apiKey: "test-key")
        XCTAssertEqual(output.text, "Tom 'n' Jerry & friends 中")
        XCTAssertEqual(output.detectedSource, "en")
    }

    func testServerErrorsExposeStatusAndRedactEchoedKey() async {
        TranslationMockURLProtocol.setHandler { _ in
            (401, Data(#"{"error":{"message":"Invalid token test-key"}}"#.utf8))
        }
        do {
            _ = try await sut.translate(input, service: ServiceConfig(name: "Test", kind: .openAI, model: "fixture-model"), apiKey: "test-key")
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("test-key"))
            XCTAssertTrue(error.localizedDescription.contains("[已隐藏]"))
        }
    }

    func testMalformedSuccessAndTimeoutHaveExplicitErrors() async {
        TranslationMockURLProtocol.setHandler { _ in (200, Data(#"{"choices":[]}"#.utf8)) }
        do {
            _ = try await sut.translate(input, service: ServiceConfig(name: "Test", kind: .openAI, model: "fixture-model"), apiKey: "")
            XCTFail("Expected malformed-response error")
        } catch {
            guard case .invalidResponse = error as? HTTPTranslationError else { return XCTFail("Wrong error: \(error)") }
        }
        TranslationMockURLProtocol.setHandler { _ in throw URLError(.timedOut) }
        do {
            _ = try await sut.translate(input, service: ServiceConfig(name: "Test", kind: .openAI, model: "fixture-model"), apiKey: "")
            XCTFail("Expected timeout error")
        } catch {
            XCTAssertEqual(error as? HTTPTranslationError, .timedOut)
        }
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

/// Every URL in these tests is intercepted here, including URLs bearing the
/// official providers' hostnames. No external translation request is made.
private final class TranslationMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ value: Handler?) {
        lock.lock()
        handler = value
        lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

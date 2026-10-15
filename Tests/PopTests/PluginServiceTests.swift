import XCTest
@testable import Pop

final class PluginServiceTests: XCTestCase {
    @MainActor
    private func fixture(source: String, modules: [String: String] = [:], timeout: TimeInterval = 1,
                         session: URLSession? = nil, log: @escaping (String, String) -> Void = { _, _ in }) throws -> (URL, PluginService, PluginDescriptor) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PopPluginTest-\(UUID().uuidString)", isDirectory: true)
        let incoming = base.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let info: [String: Any] = ["identifier": "test.fixture", "name": "Fixture", "version": "1.0.0", "category": "translate", "options": [["identifier": "suffix", "type": "text", "title": "Suffix", "defaultValue": "default", "textConfig": ["type": "visible"]]]]
        try JSONSerialization.data(withJSONObject: info).write(to: incoming.appendingPathComponent("info.json"))
        try Data(source.utf8).write(to: incoming.appendingPathComponent("main.js"))
        for (name, contents) in modules {
            let file = incoming.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        let host = PluginService(rootURL: base.appendingPathComponent("installed", isDirectory: true), timeout: timeout, session: session, executionMode: .inProcess, logHandler: log)
        return (base, host, try host.importPlugin(from: incoming))
    }

    private func config(_ plugin: PluginDescriptor, options: [String: String] = [:]) -> ServiceConfig {
        var service = ServiceConfig(name: "Fixture", kind: .plugin)
        service.pluginID = plugin.id; service.options = options
        return service
    }

    @MainActor
    func testImportListAndRemoveDoNotExecuteMainScript() throws {
        let (base, host, plugin) = try fixture(source: "throw new Error('import must not execute');")
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(host.listPlugins().map(\.id), ["test.fixture"])
        XCTAssertEqual(plugin.options.first?.identifier, "suffix")
        XCTAssertEqual(plugin.options.first?.defaultValue, "default")
        XCTAssertFalse(plugin.options.first?.isSecure ?? true)
        XCTAssertEqual(try String(contentsOf: plugin.path.appendingPathComponent("main.js"), encoding: .utf8), "throw new Error('import must not execute');")
        try host.removePlugin(id: plugin.id)
        XCTAssertTrue(host.listPlugins().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("fixture/main.js").path))
    }

    @MainActor
    func testSynchronousCallbackAndCommonJSUseIsolatedVirtualPaths() async throws {
        let source = """
        const helper = require('./lib/helper');
        const defaults = require('/defaults.json');
        function supportLanguages() { return ['auto', 'en', 'zh-Hans']; }
        function translate(query, completion) {
          $log.info('fixture');
          completion({result: {from: 'en', to: 'zh-Hans', toParagraphs: [helper.prefix(query.text, $option.suffix), defaults.value + ':' + $info.name + ':' + $env.appName]}});
        }
        """
        var callbackOnMain = false
        let (base, host, plugin) = try fixture(source: source, modules: ["lib/helper.js": "const p = require('../prefix.json'); exports.prefix = (text, suffix) => p.value + text + ':' + suffix;", "prefix.json": "{\"value\":\"translated:\"}", "defaults.json": "{\"value\":\"json\"}"], log: { _, _ in callbackOnMain = Thread.isMainThread })
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try await host.translate(TranslationRequest(text: "hello", source: "auto", target: "zh-Hans"), service: config(plugin, options: ["suffix": "override"]))
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pop"
        XCTAssertEqual(output.text, "translated:hello:override\njson:Fixture:" + appName)
        XCTAssertEqual(output.detectedSource, "en")
        XCTAssertTrue(callbackOnMain)
    }

    @MainActor
    func testAsyncTimerCompletionAndDuplicateCallbackResumeOnce() async throws {
        let source = """
        exports.supportLanguages = () => ['en', 'zh-Hans'];
        exports.translate = function(query, completion) {
          $timer.schedule({interval: 0.01, repeats: false, handler: function() {
            query.onCompletion({result: {content: {format: 'plain', text: 'asynchronous'}}});
            completion({result: {toParagraphs: ['duplicate']}});
          }});
        };
        """
        let (base, host, plugin) = try fixture(source: source)
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try await host.translate(TranslationRequest(text: "hello", source: "en", target: "zh-Hans"), service: config(plugin))
        XCTAssertEqual(output.text, "asynchronous")
    }

    @MainActor
    func testMissingCallbackTimesOut() async throws {
        let source = "function supportLanguages(){return ['en','zh-Hans'];} function translate(query,completion){}"
        let (base, host, plugin) = try fixture(source: source, timeout: 0.04)
        defer { try? FileManager.default.removeItem(at: base) }
        let began = Date()
        do {
            _ = try await host.translate(TranslationRequest(text: "hello", source: "en", target: "zh-Hans"), service: config(plugin))
            XCTFail("Missing callbacks must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    }

    @MainActor
    func testThrowingScriptAndLanguageRejectionAreExplicit() async throws {
        let source = "function supportLanguages(){return ['en','zh-Hans'];} function translate(){throw new Error('fixture failure');}"
        let (base, host, plugin) = try fixture(source: source)
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            _ = try await host.translate(TranslationRequest(text: "hello", source: "en", target: "zh-Hans"), service: config(plugin))
            XCTFail("JavaScript exceptions must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture failure")) }
        do {
            _ = try await host.translate(TranslationRequest(text: "hello", source: "en", target: "ja"), service: config(plugin))
            XCTFail("Unsupported languages must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不支持所选语言")) }
    }

    @MainActor
    func testCommonJSCannotReadOutsideTheInstalledPlugin() async throws {
        let source = "const secret = require('../secret'); function supportLanguages(){return ['en','zh-Hans'];} function translate(){}"
        let (base, host, plugin) = try fixture(source: source)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("module.exports='fixture only'".utf8).write(to: host.rootURL.appendingPathComponent("secret.js"))
        do {
            _ = try await host.translate(TranslationRequest(text: "hello", source: "en", target: "zh-Hans"), service: config(plugin))
            XCTFail("Outside paths must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("越出插件目录")) }
    }

    @MainActor
    func testCancellationReleasesAnOutstandingTranslation() async throws {
        let started = expectation(description: "JavaScript translation is awaiting completion")
        let source = "function supportLanguages(){return ['en','zh-Hans'];} function translate(){$log.info('translation started');}"
        let (base, host, plugin) = try fixture(source: source, timeout: 2, log: { _, message in
            if message == "translation started" { started.fulfill() }
        })
        defer { try? FileManager.default.removeItem(at: base) }
        let task = Task { try await host.translate(TranslationRequest(text: "hello", source: "en", target: "zh-Hans"), service: config(plugin)) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled translations must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testHTTPCallbackAndPromiseParseJSONOnMainActor() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let source = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query, completion) {
          $http.get({url:'https://fixture.invalid/callback', body:{word:query.text}, handler:function(resp){
            if (resp.error) {completion({error:resp.error}); return;}
            $http.post({url:'https://fixture.invalid/promise', header:{'Content-Type':'application/json'}, body:{word:query.text}}).then(function(second){
              $log.info('http callback');
              query.onCompletion({result:{toParagraphs:[resp.data.translation,second.data.translation,String(second.response.statusCode)]}});
            }).catch(function(error){completion({error:{message:JSON.stringify(error)}});});
          }});
        }
        """
        var onMain = false
        let (base, host, plugin) = try fixture(source: source, session: session, log: { _, _ in onMain = Thread.isMainThread })
        defer { try? FileManager.default.removeItem(at: base) }
        let output = try await host.translate(TranslationRequest(text: "hello world", source: "en", target: "zh-Hans"), service: self.config(plugin))
        XCTAssertEqual(output.text, "callback JSON\npromise JSON\n200")
        XCTAssertTrue(onMain)
    }

    @MainActor
    func testZIPImportAndUnsafePathsOrSymlinksAreRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PopZIPTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let host = PluginService(rootURL: base.appendingPathComponent("installed", isDirectory: true))
        let info = Data(#"{"identifier":"test.zip","name":"ZIP Fixture","version":"1.0.0","category":"translate"}"#.utf8)
        let archive = base.appendingPathComponent("fixture.bobplugin")
        try makeZIP(entries: [("info.json", info, 0x81a4), ("main.js", Data("function translate(){}".utf8), 0x81a4)]).write(to: archive)
        let descriptor = try host.importPlugin(from: archive)
        XCTAssertEqual(descriptor.id, "test.zip")
        XCTAssertEqual(host.listPlugins().count, 1)
        for name in ["../outside.js", "/absolute.js", "folder/../../outside.js", "C:\\outside.js"] {
            try makeZIP(entries: [(name, Data("bad".utf8), 0x81a4)]).write(to: archive)
            XCTAssertThrowsError(try host.importPlugin(from: archive))
        }
        try makeZIP(entries: [("link.js", Data("../outside.js".utf8), 0xa1ff)]).write(to: archive)
        XCTAssertThrowsError(try host.importPlugin(from: archive))
        XCTAssertEqual(host.listPlugins().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("outside.js").path))
    }

    @MainActor
    func testDirectorySymlinkIsRejectedWithoutFollowingIt() throws {
        let (base, host, _) = try fixture(source: "function translate(){}")
        defer { try? FileManager.default.removeItem(at: base) }
        let incoming = base.appendingPathComponent("fixture", isDirectory: true)
        let target = base.appendingPathComponent("outside.js")
        try Data("fixture secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: incoming.appendingPathComponent("linked.js"), withDestinationURL: target)
        XCTAssertThrowsError(try host.importPlugin(from: incoming))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testExpandedPublicInterfacesUsingRealJavaScriptCoreFixtures() async throws {
        let results = try await PluginSelfCheck.runInProcess()
        XCTAssertGreaterThanOrEqual(results.count, 21)
        XCTAssertTrue(results.contains { $0.contains("AES 已知向量") && $0.contains("安全随机盐") })
        XCTAssertTrue(results.contains { $0.contains("OCR 图片 query") && $0.contains("坐标转换") })
        XCTAssertTrue(results.contains { $0.contains("TTS text/lang query") && $0.contains("URL 音频下载") })
        XCTAssertTrue(results.contains { $0.contains("HTTP 二进制 body") && $0.contains("rawData") })
        XCTAssertTrue(results.contains { $0.contains("真实流式 HTTP") && $0.contains("跨块 UTF8") })
        XCTAssertTrue(results.contains { $0.contains("multipart") && $0.contains("二进制文件") })
        XCTAssertTrue(results.contains { $0.contains("$file 基础接口") && $0.contains("卸载清理") })
        XCTAssertTrue(results.contains { $0.contains("完整词典") && $0.contains("think 标签") })
        XCTAssertTrue(results.contains { $0.contains("originalText") && $0.contains("原文空行") })
        XCTAssertTrue(results.contains { $0.contains("pluginValidate") && $0.contains("异步验证") })
        XCTAssertTrue(results.contains { $0.contains("localhost WebSocket") && $0.contains("正常关闭") })
        XCTAssertTrue(results.contains { $0.contains("appcast") && $0.contains("SHA256/ID 拒绝") })
    }

    /// Small uncompressed ZIP fixture writer; no external archives or user files are used.
    private func makeZIP(entries: [(String, Data, UInt32)]) -> Data {
        func append16(_ number: UInt16, to data: inout Data) { data.append(UInt8(number & 255)); data.append(UInt8(number >> 8)) }
        func append32(_ number: UInt32, to data: inout Data) { append16(UInt16(number & 65535), to: &data); append16(UInt16(number >> 16), to: &data) }
        func crc(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xffff_ffff
            for byte in data {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
            }
            return value ^ 0xffff_ffff
        }
        var data = Data(), central = Data()
        for (name, body, mode) in entries {
            let nameData = Data(name.utf8), offset = UInt32(data.count), checksum = crc(body)
            append32(0x04034b50, to: &data)
            for value: UInt16 in [20, 0, 0, 0, 0] { append16(value, to: &data) }
            append32(checksum, to: &data); append32(UInt32(body.count), to: &data); append32(UInt32(body.count), to: &data)
            append16(UInt16(nameData.count), to: &data); append16(0, to: &data); data.append(nameData); data.append(body)
            append32(0x02014b50, to: &central)
            for value: UInt16 in [0x0314, 20, 0, 0, 0, 0] { append16(value, to: &central) }
            append32(checksum, to: &central); append32(UInt32(body.count), to: &central); append32(UInt32(body.count), to: &central)
            for value: UInt16 in [UInt16(nameData.count), 0, 0, 0, 0] { append16(value, to: &central) }
            append32(mode << 16, to: &central); append32(offset, to: &central); central.append(nameData)
        }
        let centralStart = UInt32(data.count); data.append(central)
        append32(0x06054b50, to: &data)
        for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { append16(value, to: &data) }
        append32(UInt32(central.count), to: &data); append32(centralStart, to: &data); append16(0, to: &data)
        return data
    }
}

private final class PluginFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isPost = request.httpMethod == "POST"
        let json = isPost ? #"{"translation":"promise JSON"}"# : #"{"translation":"callback JSON"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

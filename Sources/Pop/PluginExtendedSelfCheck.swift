import Foundation
import Network
import CryptoKit

@MainActor
enum PluginExtendedSelfCheck {
    static func run(base: URL) async throws -> [String] {
        let manager = FileManager.default
        let root = base.appendingPathComponent("extended", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PopError.message("插件扩展自检失败：\(message)") }
        }
        func package(_ id: String, version: String = "1.2.0", source: String, appcast: String? = nil) throws -> URL {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            var info: [String: Any] = ["identifier": id, "name": "Extended Fixture", "version": version, "category": "translate"]
            if let appcast { info["appcast"] = appcast }
            try JSONSerialization.data(withJSONObject: info).write(to: folder.appendingPathComponent("info.json"))
            try Data(source.utf8).write(to: folder.appendingPathComponent("main.js"))
            return folder
        }
        let languages = "function supportLanguages(){return ['en','zh-Hans'];}\n"
        let request = TranslationRequest(text: "first\n\nsecond", source: "en", target: "zh-Hans")
        let host = PluginService(rootURL: root.appendingPathComponent("installed", isDirectory: true), timeout: 2, executionMode: .inProcess)
        let resultSource = languages + """
        function translate(query,completion){
          query.onStream({thinkInfo:{content:'initial reasoning'}});
          query.onStream({content:{format:'markdown',text:'# Partial'}});
          query.onStream({content:{text:'# Partial updated'}});
          completion({result:{from:'en',content:{text:'<think>private reasoning</think># Final'},thinkInfo:{splitThinkTag:true},toDict:{word:'good',phonetics:[{type:'us',value:'ɡʊd',tts:{type:'base64',value:'YXVkaW8='}}],parts:[{part:'adj.',means:['好','优良']}],exchanges:[{name:'比较级',words:['better']}],relatedWordParts:[{part:'名词',words:[{word:'goodness',means:['善良']}]}],additions:[{name:'例句',value:'A good day.'}]}}});
        }
        """
        let resultPlugin = try host.importPlugin(from: package("selfcheck.results", source: resultSource))
        var service = ServiceConfig(name: "Results", kind: .plugin); service.pluginID = resultPlugin.id
        var frames: [TranslationOutput] = []
        let output = try await host.translate(request, service: service, onStream: { frames.append($0) })
        try expect(output.text == "# Final" && output.reasoning == "private reasoning" && output.format == "markdown", "content/format/thinkInfo")
        try expect(frames.count == 3 && frames[0].text.isEmpty && frames[0].reasoning == "initial reasoning" && frames[2].format == "markdown", "纯思考帧与格式保留")
        try expect(output.dictionary?.phonetics.first?.tts?.value == "YXVkaW8=" && output.dictionary?.parts.first?.means.count == 2 && output.dictionary?.exchanges.first?.words == ["better"] && output.dictionary?.relatedWordParts.first?.words.first?.word == "goodness" && output.dictionary?.additions.first?.value == "A good day.", "完整词典字段")
        var decoder = PluginResultDecoder()
        let lines = try decoder.decode(["toParagraphs": ["一", "二"]], originalText: request.text, streaming: false)
        try expect(lines.text == "一\n\n二" && lines.format == "lines", "逐行译文映射原文空行")
        var rejected = false
        do { _ = try decoder.decode(["content": ["format": "unknown", "text": "invalid"]], originalText: "", streaming: false) } catch { rejected = true }
        try expect(rejected, "未知译文格式明确报错")

        let originalQueryPlugin = try host.importPlugin(from: package("selfcheck.originalquery", source: languages + """
        function translate(q,c){
          if(q.text!=='first second'||q.originalText!=='// first\\n\\n// second'){c({error:{message:'original text was normalized'}});return;}
          q.onStream({toParagraphs:['一','二']});c({result:{toParagraphs:['一','二']}});
        }
        """))
        service.pluginID = originalQueryPlugin.id
        var originalFrames: [TranslationOutput] = []
        let originalQuery = TranslationRequest(text: "first second", source: "en", target: "zh-Hans", originalText: "// first\n\n// second")
        let originalResult = try await host.translate(originalQuery, service: service, onStream: { originalFrames.append($0) })
        try expect(originalResult.text == "一\n\n二" && originalFrames.first?.text == "一\n\n二", "插件收到处理前原文，流式与最终逐行结果保留原始空行")

        let validationSource = """
        async function pluginValidate(completion){await new Promise(resolve=>setTimeout(resolve,5));completion($option.token==='fixture' ? {result:true} : {result:false,error:{type:'secretKey',message:'fixture key missing',troubleshootingLink:'https://example.invalid/help'}});}
        """
        let validationPlugin = try host.importPlugin(from: package("selfcheck.validate", source: validationSource))
        service.pluginID = validationPlugin.id
        let invalid = try await host.validate(service: service)
        try expect(invalid.supported && !invalid.isValid && invalid.message == "fixture key missing" && invalid.troubleshootingLink?.host == "example.invalid", "验证失败详情")
        service.options = ["token": "fixture"]
        let valid = try await host.validate(service: service)
        try expect(valid.supported && valid.isValid, "异步验证成功")
        service.pluginID = resultPlugin.id
        let unsupported = try await host.validate(service: service)
        try expect(!unsupported.supported, "缺失可选验证接口")

        let socketServer = try PluginLocalWebSocketFixture()
        defer { socketServer.stop() }
        let port = try await socketServer.start()
        let wsSource = languages + """
        function translate(query,completion){
          let flags={text:false,data:false,ping:false,pong:false,clientPong:false,server:false};let closing=false;
          const s=$websocket.new({url:'ws://127.0.0.1:\(port)/fixture',timeoutInterval:1,header:{'X-Fixture':'fixture'}});
          function done(){if(!closing&&Object.keys(flags).every(k=>flags[k])){closing=true;s.close({code:1000});}}
          s.listenOpen(function(socket){if(socket.readyState!==1)throw new Error('readyState open');socket.sendString('hello');socket.sendData($data.fromByteArray([0,255,65]));socket.ping($data.fromUTF8('client ping'));socket.pong($data.fromUTF8('client pong'));});
          s.listenReceiveString(function(socket,text){if(text==='echo:hello')flags.text=true;if(text==='server-complete')flags.server=true;done();});
          s.listenReceiveData(function(socket,data){flags.data=data.toHex()==='00ff41';done();});
          s.listenReceivePing(function(socket,data){flags.ping=data.toUTF8()==='server ping';done();});
          s.listenReceivePong(function(socket,data){if(data.toUTF8()==='server pong')flags.pong=true;if(data.toUTF8()==='client ping')flags.clientPong=true;done();});
          s.listenError(function(socket,error){completion({error:{message:error.message}});});
          s.listenClose(function(socket,code,reason){if(!closing||code!==1000||socket.readyState!==3){completion({error:{message:'Unexpected close '+code}});return;}completion({result:{toParagraphs:['WebSocket fixture passed']}});});s.open();
        }
        """
        let wsPlugin = try host.importPlugin(from: package("selfcheck.websocket", source: wsSource))
        service.pluginID = wsPlugin.id
        let websocket = try await host.translate(request, service: service)
        try expect(websocket.text == "WebSocket fixture passed" && socketServer.headerSeen, "localhost WebSocket 文本/二进制/ping/pong/关闭")

        let registry = PluginUpdateFixtureRegistry.shared
        registry.reset()
        defer { registry.reset() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PluginUpdateFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let updateHost = PluginService(rootURL: root.appendingPathComponent("updates", isDirectory: true), timeout: 2, session: session, executionMode: .inProcess)
        let appcastURL = "https://pop-plugin-update-fixture.invalid/appcast.json"
        let first = try package("selfcheck.update", source: languages + "function translate(q,c){c({result:{toParagraphs:['old']}});}", appcast: appcastURL)
        _ = try updateHost.importPlugin(from: first)
        let cache = updateHost.rootURL.appendingPathComponent(".sandboxes/selfcheck.update", isDirectory: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("preserved fixture cache".utf8).write(to: cache.appendingPathComponent("keep.txt"))
        let updated = try package("selfcheck.update", version: "1.10.0", source: "throw new Error('Import must never execute updates');", appcast: appcastURL)
        func zipPackage(_ folder: URL) throws -> Data {
            let archive = root.appendingPathComponent(UUID().uuidString + ".bobplugin")
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = folder
            zip.arguments = ["-q", archive.path, "info.json", "main.js"]; zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice; zip.standardInput = FileHandle.nullDevice
            try zip.run(); zip.waitUntilExit()
            guard zip.terminationStatus == 0 else { throw PopError.message("自检 ZIP 生成失败。") }
            return try Data(contentsOf: archive)
        }
        let archive = try zipPackage(updated)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["identifier": "selfcheck.update", "versions": [
            ["version": "1.3.0", "desc": "Earlier", "sha256": digest, "url": "https://pop-plugin-update-fixture.invalid/package.bobplugin"],
            ["version": "1.10.0", "desc": "Fixture update", "sha256": digest, "url": "https://pop-plugin-update-fixture.invalid/package.bobplugin", "timestamp": 1_700_000_000_000]
        ]]
        registry.set("/appcast.json", data: try JSONSerialization.data(withJSONObject: manifest))
        registry.set("/package.bobplugin", data: archive)
        guard let update = try await updateHost.checkForUpdate(id: "selfcheck.update") else { throw PopError.message("自检找不到更新。") }
        try expect(update.version == "1.10.0" && updateHost.listPlugins().first?.version == "1.2.0" && registry.count("/package.bobplugin") == 0, "检查更新不自动下载或安装，且按数值比较版本")
        let corrupt = PluginUpdate(pluginID: update.pluginID, name: update.name, currentVersion: update.currentVersion, version: update.version, notes: update.notes, downloadURL: update.downloadURL, sha256: String(repeating: "0", count: 64), minBobVersion: nil, publishedAt: nil, appcastURL: update.appcastURL)
        var checksumRejected = false
        do { _ = try await updateHost.installUpdate(corrupt) } catch { checksumRejected = error.localizedDescription.contains("SHA256") }
        try expect(checksumRejected && updateHost.listPlugins().first?.version == "1.2.0", "损坏更新不修改原插件")
        let wrongPackage = try package("selfcheck.unrelated", version: "1.10.0", source: "throw new Error('must never execute');", appcast: appcastURL)
        let wrongArchive = try zipPackage(wrongPackage)
        let wrongDigest = SHA256.hash(data: wrongArchive).map { String(format: "%02x", $0) }.joined()
        registry.set("/package.bobplugin", data: wrongArchive)
        let wrongIdentity = PluginUpdate(pluginID: update.pluginID, name: update.name, currentVersion: update.currentVersion, version: update.version, notes: update.notes, downloadURL: update.downloadURL, sha256: wrongDigest, minBobVersion: nil, publishedAt: nil, appcastURL: update.appcastURL)
        var identityRejected = false
        do { _ = try await updateHost.installUpdate(wrongIdentity) } catch { identityRejected = error.localizedDescription.contains("标识符或版本") }
        try expect(identityRejected && updateHost.listPlugins().map(\.id) == ["selfcheck.update"] && updateHost.listPlugins().first?.version == "1.2.0", "匹配 SHA256 但 identifier 错误的更新被拒绝且保留原版本")
        registry.set("/package.bobplugin", data: archive)
        let installed = try await updateHost.installUpdate(update)
        let retained = try String(contentsOf: cache.appendingPathComponent("keep.txt"), encoding: .utf8)
        try expect(retained == "preserved fixture cache", "成功更新保留插件 sandbox 缓存")
        try expect(installed.id == "selfcheck.update" && installed.version == "1.10.0", "显式更新成功且导入不执行 JavaScript")
        try expect(PluginVersions.compare("1.0.0beta1", "1.0.0") == .orderedAscending && PluginVersions.compare("1.9", "1.10") == .orderedAscending, "版本比较预发布与数字排序")
        return ["插件：完整词典、格式保留、思考过程、think 标签与原文空行映射通过", "插件：处理前 originalText 与处理后 text 分离，流式和最终结果按原文空行映射通过", "插件：pluginValidate 异步验证、失败帮助链接及缺失接口通过", "插件：localhost WebSocket 文本/二进制/ping/pong/headers/正常关闭通过", "插件：appcast 只读检查、数值版本、SHA256/ID 拒绝、缓存保留与显式更新通过"]
    }
}

@MainActor
private final class PluginLocalWebSocketFixture {
    private let queue: DispatchQueue
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let headerStatus: PluginHeaderFlag
    var headerSeen: Bool { headerStatus.get() }
    private var textSeen = false, dataSeen = false, pingSeen = false, pongSeen = false, automaticPongSeen = false, announced = false
    init() throws {
        let queue = DispatchQueue(label: "pop.plugin.websocket.fixture")
        self.queue = queue
        let marker = PluginHeaderFlag(); headerStatus = marker
        let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { _, headers in
            let valid = headers.contains { $0.name.lowercased() == "x-fixture" && $0.value == "fixture" }
            marker.set(valid)
            return NWProtocolWebSocket.Response(status: valid ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !resumed else { return }
                    switch state {
                    case .ready: resumed = true; continuation.resume(returning: self.listener.port!.rawValue)
                    case .failed(let error): resumed = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [connection] in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        if case .ready = state {
                            Task { @MainActor in
                                guard let self, let connection else { return }
                                self.send(connection, data: Data("server ping".utf8), opcode: .ping)
                                self.send(connection, data: Data("server pong".utf8), opcode: .pong)
                                self.receive(connection)
                            }
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
            listener.start(queue: queue)
        }
    }
    private func send(_ connection: NWConnection, data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        if opcode == .close { metadata.closeCode = .protocolCode(.normalClosure) }
        let context = NWConnection.ContentContext(identifier: "fixture", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            Task { @MainActor in
                guard let self, let connection, error == nil else { return }
                let data = data ?? Data()
                switch opcode {
                case .text: self.textSeen = String(data: data, encoding: .utf8) == "hello"; self.send(connection, data: Data("echo:hello".utf8), opcode: .text)
                case .binary: self.dataSeen = data == Data([0, 255, 65]); self.send(connection, data: data, opcode: .binary)
                case .ping: self.pingSeen = String(data: data, encoding: .utf8) == "client ping"
                case .pong:
                    if String(data: data, encoding: .utf8) == "client pong" { self.pongSeen = true }
                    if String(data: data, encoding: .utf8) == "server ping" { self.automaticPongSeen = true }
                case .close: self.send(connection, data: Data(), opcode: .close); return
                default: break
                }
                if self.textSeen && self.dataSeen && self.pingSeen && self.pongSeen && self.automaticPongSeen && !self.announced {
                    self.announced = true; self.send(connection, data: Data("server-complete".utf8), opcode: .text)
                }
                self.receive(connection)
            }
        }
    }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
}

private final class PluginHeaderFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    func get() -> Bool { lock.withLock { value } }
}

private final class PluginUpdateFixtureRegistry: @unchecked Sendable {
    static let shared = PluginUpdateFixtureRegistry()
    private let lock = NSLock()
    private var data: [String: Data] = [:], counts: [String: Int] = [:]
    func set(_ path: String, data: Data) { lock.withLock { self.data[path] = data } }
    func get(_ path: String) -> Data? { lock.withLock { counts[path, default: 0] += 1; return data[path] } }
    func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    func reset() { lock.withLock { data.removeAll(); counts.removeAll() } }
}
private final class PluginUpdateFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "pop-plugin-update-fixture.invalid", let data = PluginUpdateFixtureRegistry.shared.get(request.url?.path ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import Foundation
import Darwin

/// Exercises only generated fixture plugins in a temporary directory.
/// HTTP responses are supplied by a private URLProtocol, never by the network.
@MainActor
enum PluginSelfCheck {
    static func run() async throws -> [String] {
        try await runFixtures(includeProcessIsolation: true)
    }

    /// XCTest does not have Pop's --plugin-worker entry point. Exercise the same
    /// JavaScriptCore fixtures here; the packaged executable runs the worker
    /// fixtures through --plugin-self-check on each native CI architecture.
    static func runInProcess() async throws -> [String] {
        try await runFixtures(includeProcessIsolation: false)
    }

    private static func runFixtures(includeProcessIsolation: Bool) async throws -> [String] {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("Pop-Plugin-SelfCheck-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        var checks: [String] = []
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pop"
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PopError.message("插件自检失败：\(message)") }
        }
        func install(_ id: String, source: String, modules: [String: String] = [:], timeout: TimeInterval = 1, session: URLSession? = nil, category: String = "translate") throws -> (PluginService, ServiceConfig) {
            let folder = base.appendingPathComponent(id, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let info: [String: Any] = ["identifier": id, "version": "1.0.0", "name": "Self Check Fixture", "category": category, "options": [["identifier": "suffix", "title": "Suffix", "type": "text", "defaultValue": "default"]]]
            try JSONSerialization.data(withJSONObject: info).write(to: folder.appendingPathComponent("info.json"))
            try Data(source.utf8).write(to: folder.appendingPathComponent("main.js"))
            for (name, contents) in modules {
                let file = folder.appendingPathComponent(name)
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: file)
            }
            let host = PluginService(rootURL: base.appendingPathComponent("installed-" + id, isDirectory: true), timeout: timeout, session: session, executionMode: .inProcess)
            let descriptor = try host.importPlugin(from: folder)
            try expect(host.listPlugins().map(\.id) == [id], "导入与插件列表")
            try expect(descriptor.options.first?.defaultValue == "default", "选项默认值")
            var service = ServiceConfig(name: "Self Check", kind: .plugin)
            service.pluginID = id
            return (host, service)
        }
        let request = TranslationRequest(text: "hello", source: "en", target: "zh-Hans")
        let synchronous = """
        const helper = require('./lib/helper');
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){completion({result:{from:'en',toParagraphs:[helper.translate(query.text,$option.suffix),$env.appName]}});}
        """
        let (syncHost, syncConfig) = try install("selfcheck.sync", source: synchronous, modules: ["lib/helper.js": "const prefix=require('../prefix.json'); module.exports.translate=(text,suffix)=>prefix.text+text+':'+suffix;", "prefix.json": "{\"text\":\"translated:\"}"])
        var configured = syncConfig; configured.options = ["suffix": "override"]
        let syncResult = try await syncHost.translate(request, service: configured)
        try expect(syncResult.text == "translated:hello:override\n" + appName && syncResult.detectedSource == "en", "同步 completion、CommonJS/JSON 与选项")
        checks.append("插件：同步 completion、CommonJS/JSON 模块、虚拟目录和选项通过")

        let asynchronous = """
        exports.supportLanguages=()=>['en','zh-Hans'];
        exports.translate=function(query,completion){$timer.schedule({interval:0.005,repeats:false,handler:function(){query.onCompletion({result:{content:{text:'async timer',format:'plain'}}});completion({result:{toParagraphs:['duplicate']}});}});};
        """
        let (asyncHost, asyncConfig) = try install("selfcheck.async", source: asynchronous)
        let asyncResult = try await asyncHost.translate(request, service: asyncConfig)
        try expect(asyncResult.text == "async timer", "异步定时器与重复回调")
        checks.append("插件：异步定时器、query.onCompletion 与重复回调保护通过")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PluginSelfCheckURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let networking = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){
          $http.get({url:'https://pop-fixture.invalid/get',handler:function(resp){
            if(resp.error){completion({error:resp.error});return;}
            $http.post({url:'https://pop-fixture.invalid/post',header:{'Content-Type':'application/json'},body:{text:query.text}}).then(function(second){query.onCompletion({result:{toParagraphs:[resp.data.translation,second.data.translation,String(second.response.statusCode)]}});}).catch(function(error){completion({error:{message:JSON.stringify(error)}});});
          }});
        }
        """
        let (httpHost, httpConfig) = try install("selfcheck.http", source: networking, session: session)
        let httpResult = try await httpHost.translate(request, service: httpConfig)
        try expect(httpResult.text == "GET fixture\nPOST fixture\n200", "HTTP 回调与 Promise")
        checks.append("插件：无网络 HTTP fixture、JSON 解析、HTTP Promise 与主 actor 回调通过")

        let binaryHTTP = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){$http.post({url:'https://pop-fixture.invalid/binary',body:$data.fromUTF8('binary request'),handler:function(resp){
          if(resp.error){completion({error:resp.error});return;}
          if(!$data.isData(resp.data)||!$data.isData(resp.rawData))throw new Error('Missing binary HTTP data');
          completion({result:{toParagraphs:[resp.data.toHex(),resp.rawData.toBase64()]}});
        }});}
        """
        let (binaryHost, binaryConfig) = try install("selfcheck.binary", source: binaryHTTP, session: session)
        let binaryResult = try await binaryHost.translate(request, service: binaryConfig)
        try expect(binaryResult.text == "ff0041\n/wBB", "HTTP 二进制 body、data 与 rawData")
        checks.append("插件：HTTP 二进制 body、data 与 rawData 通过")

        let rejecting = "function supportLanguages(){return ['en','zh-Hans'];} async function translate(){throw new Error('fixture Promise rejection');}"
        let (rejectionHost, rejectionConfig) = try install("selfcheck.rejection", source: rejecting)
        var rejectionReported = false
        do { _ = try await rejectionHost.translate(request, service: rejectionConfig) }
        catch { rejectionReported = error.localizedDescription.contains("fixture Promise rejection") }
        try expect(rejectionReported, "async translate Promise 错误回传")
        checks.append("插件：async translate 的 Promise 拒绝转为明确错误通过")

        let validArchive = base.appendingPathComponent("valid.bobplugin")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = base.appendingPathComponent("selfcheck.http", isDirectory: true)
        zip.arguments = ["-q", validArchive.path, "info.json", "main.js"]
        zip.standardInput = FileHandle.nullDevice; zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try zip.run(); zip.waitUntilExit()
        try expect(zip.terminationStatus == 0, "生成仅自建文件的 ZIP fixture")
        let zipHost = PluginService(rootURL: base.appendingPathComponent("installed-zip", isDirectory: true))
        let importedZIP = try zipHost.importPlugin(from: validArchive)
        try expect(importedZIP.id == "selfcheck.http" && zipHost.listPlugins().count == 1, "合法 bobplugin ZIP 导入")
        checks.append("插件：仅自建文件的 bobplugin ZIP 正常导入通过")

        let stalled = "function supportLanguages(){return ['en','zh-Hans'];} function translate(){}"
        let (timeoutHost, timeoutConfig) = try install("selfcheck.timeout", source: stalled, timeout: 0.04)
        var timedOut = false
        do { _ = try await timeoutHost.translate(request, service: timeoutConfig) }
        catch { timedOut = error.localizedDescription.contains("超时") }
        try expect(timedOut, "缺失 completion 的超时")
        checks.append("插件：缺失 completion 时的明确超时通过")

        let escaping = "require('../outside'); function supportLanguages(){return ['en','zh-Hans'];} function translate(){}"
        let (escapeHost, escapeConfig) = try install("selfcheck.escape", source: escaping)
        var escapeRejected = false
        do { _ = try await escapeHost.translate(request, service: escapeConfig) }
        catch { escapeRejected = error.localizedDescription.contains("越出插件目录") }
        try expect(escapeRejected, "CommonJS 根目录越界拒绝")
        checks.append("插件：CommonJS 越界读取拒绝通过")

        let importedSource = base.appendingPathComponent("selfcheck.sync", isDirectory: true)
        let outside = base.appendingPathComponent("fixture-outside.js")
        try Data("self check only".utf8).write(to: outside)
        try manager.createSymbolicLink(at: importedSource.appendingPathComponent("linked.js"), withDestinationURL: outside)
        var linkRejected = false
        do { _ = try syncHost.importPlugin(from: importedSource) }
        catch { linkRejected = error.localizedDescription.contains("符号链接") }
        try expect(linkRejected, "目录符号链接拒绝")
        try expect(syncHost.listPlugins().count == 1, "失败导入不破坏已安装插件")

        let badArchive = base.appendingPathComponent("traversal.bobplugin")
        try traversalZIP().write(to: badArchive)
        var zipRejected = false
        do { _ = try syncHost.importPlugin(from: badArchive) }
        catch { zipRejected = error.localizedDescription.contains("不安全路径") }
        try expect(zipRejected, "ZIP 路径越界拒绝")
        for origin in [syncHost.rootURL, base] {
            var recursiveRejected = false
            do { _ = try syncHost.importPlugin(from: origin) }
            catch { recursiveRejected = error.localizedDescription.contains("插件存储目录") }
            try expect(recursiveRejected, "拒绝来源目录包含插件存储目录")
        }
        let specialSource = base.appendingPathComponent("selfcheck.http", isDirectory: true)
        let fifo = specialSource.appendingPathComponent("fixture-pipe")
        try expect(mkfifo(fifo.path, 0o600) == 0, "创建仅自建的 FIFO fixture")
        var fifoRejected = false
        do { _ = try syncHost.importPlugin(from: specialSource) }
        catch { fifoRejected = error.localizedDescription.contains("特殊文件") }
        try expect(fifoRejected, "拒绝管道特殊文件，避免阻塞复制")
        try manager.removeItem(at: fifo)
        for index in 0..<2001 {
            try manager.createDirectory(at: specialSource.appendingPathComponent("empty-\(index)", isDirectory: true), withIntermediateDirectories: false)
        }
        var excessiveDirectoriesRejected = false
        do { _ = try syncHost.importPlugin(from: specialSource) }
        catch { excessiveDirectoriesRejected = error.localizedDescription.contains("2000") }
        try expect(excessiveDirectoriesRejected, "空目录也计入插件条目上限")
        try syncHost.removePlugin(id: "selfcheck.sync")
        try expect(syncHost.listPlugins().isEmpty, "卸载插件")
        checks.append("插件：符号链接、ZIP 路径遍历、递归复制、特殊文件、超量空目录拒绝及卸载通过")

        let ocr = """
        function supportLanguages(){return ['auto','en'];}
        function supportBoundingBox(){return true;}
        function ocr(query,completion){
          if (!$data.isData(query.image) || query.image.length < 8 || query.pixelWidth !== 1 || query.pixelHeight !== 1) throw new Error('Invalid image data query');
          const bytes=$data.fromByteArray([65,66,67]);
          const copy=$data.fromData(bytes);
          bytes.writeUInt8(68,1);
          if(bytes.readUInt8(1)!==68 || bytes.toHex(true)!=='414443' || copy.toUTF8()!=='ABC') throw new Error('Invalid $data byte operations');
          const sub=bytes.subData(0,2); sub.appendData($data.fromBase64('QQ=='));
          if(sub.toUTF8()!=='ADA' || $data.fromHex('ff00').toByteArray()[0]!==255 || $data.fromUTF8('你好').toUTF8()!=='你好') throw new Error('Invalid $data conversion');
          completion({result:{regionInfos:[{paragraphInfos:[{texts:[{text:'Fixture OCR',boundingBox:{points:[{x:0.1,y:0.2},{x:0.9,y:0.2},{x:0.1,y:0.4},{x:0.9,y:0.4}]}}]}]}]}});
        }
        """
        let (ocrHost, ocrConfig) = try install("selfcheck.ocr", source: ocr, category: "ocr")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aT+EAAAAASUVORK5CYII=")!
        let document = try await ocrHost.recognize(imageData: png, service: ocrConfig)
        try expect(document.text == "Fixture OCR" && document.lines.count == 1, "公开 OCR 结构化结果")
        try expect(abs(document.lines[0].y - 0.6) < 0.0001 && abs(document.lines[0].width - 0.8) < 0.0001, "OCR 左上坐标转换为左下坐标")
        checks.append("插件：$data 编码/复制/读写、OCR 图片 query、结构化结果与坐标转换通过")

        let ttsBase64 = "function supportLanguages(){return ['en'];} function tts(query,completion){if(query.lang!=='en'||query.text!=='hello')throw new Error('Invalid TTS query'); completion({result:{type:'base64',value:$data.fromUTF8('fixture audio').toBase64()}});}"
        let (ttsHost, ttsConfig) = try install("selfcheck.tts", source: ttsBase64, category: "tts")
        let ttsData = try await ttsHost.synthesize(text: "hello", language: "en", service: ttsConfig)
        try expect(String(data: ttsData, encoding: .utf8) == "fixture audio", "公开 TTS base64 结果")
        let ttsURL = "function supportLanguages(){return ['en'];} function tts(query,completion){completion({result:{type:'url',value:'https://pop-fixture.invalid/audio'}});}"
        let (urlHost, urlConfig) = try install("selfcheck.ttsurl", source: ttsURL, session: session, category: "tts")
        let urlData = try await urlHost.synthesize(text: "hello", language: "en", service: urlConfig)
        try expect(String(data: urlData, encoding: .utf8) == "fixture downloaded audio", "TTS URL 下载使用隔离 HTTP fixture")
        checks.append("插件：TTS text/lang query、base64 与无网络 URL 音频下载通过")

        let cryptography = """
        const C=require('crypto-js');
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){
          const key=C.enc.Hex.parse('2b7e151628aed2a6abf7158809cf4f3c');
          const iv=C.enc.Hex.parse('000102030405060708090a0b0c0d0e0f');
          const encrypted=C.AES.encrypt(C.enc.Hex.parse('6bc1bee22e409f96e93d7e117393172a'),key,{iv:iv,mode:C.mode.CBC,padding:C.pad.NoPadding}).ciphertext.toString(C.enc.Hex);
          const salted=C.AES.encrypt('secure random fixture','fixture password').toString();
          if(C.AES.decrypt(salted,'fixture password').toString(C.enc.Utf8)!=='secure random fixture')throw new Error('AES random salt round trip');
          completion({result:{toParagraphs:[C.SHA256('abc').toString(),encrypted]}});
        }
        """
        let (cryptoHost, cryptoConfig) = try install("selfcheck.crypto", source: cryptography)
        let cryptoResult = try await cryptoHost.translate(request, service: cryptoConfig)
        try expect(cryptoResult.text == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n7649abac8119b246cee98e9b12e9197d", "CryptoJS SHA256/AES-CBC 已知向量")
        checks.append("插件：官方 CryptoJS 4.2.0 SHA256、AES 已知向量与安全随机盐通过")

        let fileSource = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){
          if($file.read('/../outside') || $file.read('$sandbox/../outside') || $file.read('$sandbox/evil'))throw new Error('File escaped virtual root');
          if($file.write({path:'/reference.txt',data:$data.fromUTF8('changed')}) || $file.delete('/reference.txt') || $file.move({src:'/reference.txt',dst:'$sandbox/moved-package'}))throw new Error('Package mutation allowed');
          const old=$file.read('$sandbox/counter.txt');
          if(old){completion({result:{toParagraphs:[old.toUTF8(),'persisted']}});return;}
          if(!$file.mkdir('$sandbox/cache') || !$file.isDirectory('$sandbox/cache'))throw new Error('mkdir failed');
          if(!$file.write({path:'$sandbox/counter.txt',data:$data.fromUTF8('first operation')}))throw new Error('write failed');
          if(!$file.copy({src:'/reference.txt',dst:'$sandbox/cache/copy.txt'}) || !$file.move({src:'$sandbox/cache/copy.txt',dst:'$sandbox/cache/moved.txt'}))throw new Error('copy/move failed');
          if($file.read('$sandbox/cache/moved.txt').toUTF8()!=='package fixture' || $file.list('$sandbox/cache')[0]!=='moved.txt' || !$file.exists('$sandbox/counter.txt'))throw new Error('file result mismatch');
          if(!$file.delete('$sandbox/cache/moved.txt') || $file.exists('$sandbox/cache/moved.txt'))throw new Error('delete failed');
          completion({result:{toParagraphs:['first operation','created']}});
        }
        """
        let (fileHost, fileConfig) = try install("selfcheck.files", source: fileSource, modules: ["reference.txt": "package fixture"])
        let firstFileResult = try await fileHost.translate(request, service: fileConfig)
        try expect(firstFileResult.text == "first operation\ncreated", "$file 的完整公开基础接口")
        let fileSandbox = fileHost.rootURL.appendingPathComponent(".sandboxes/selfcheck.files", isDirectory: true)
        try manager.createSymbolicLink(at: fileSandbox.appendingPathComponent("evil"), withDestinationURL: outside)
        let secondFileResult = try await fileHost.translate(request, service: fileConfig)
        try expect(secondFileResult.text == "first operation\npersisted", "插件沙盒跨调用持久化且拒绝链接")
        try fileHost.removePlugin(id: fileConfig.pluginID)
        try expect(!manager.fileExists(atPath: fileSandbox.path), "卸载时清理插件独立沙盒")
        checks.append("插件：$file 基础接口、只读包目录、独立持久化沙盒、越界/链接拒绝与卸载清理通过")

        let multipart = """
        function supportLanguages(){return ['en','zh-Hans'];}
        async function translate(query,completion){const resp=await $http.post({url:'https://pop-fixture.invalid/multipart',header:{'Content-Type':'application/json'},body:{field:'fixture value'},files:[{name:'upload',filename:'fixture.bin','content-type':'application/octet-stream',data:$data.fromByteArray([0,255,65])}]});completion({result:{toParagraphs:[String(resp.data.multipart)]}});}
        """
        let (multipartHost, multipartConfig) = try install("selfcheck.multipart", source: multipart, session: session)
        let multipartResult = try await multipartHost.translate(request, service: multipartConfig)
        try expect(multipartResult.text == "true", "multipart 边界、字段、文件元信息和二进制 bytes")
        checks.append("插件：multipart 表单字段/二进制文件与强制 Content-Type 通过")

        let streaming = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){let text='',raw=0,frames=0;$http.streamRequest({url:'https://pop-fixture.invalid/stream',streamHandler:function(chunk){if(!$data.isData(chunk.rawData)||!chunk.rawData.length)throw new Error('Missing stream rawData');raw+=chunk.rawData.length;frames++;text+=chunk.text;query.onStream({content:{text:text,format:'plain'}});},handler:function(resp){if(resp.error){completion({error:resp.error});return;}if('data' in resp || 'rawData' in resp || frames<2 || raw!==13)throw new Error('Invalid streaming final response');query.onCompletion({result:{content:{text:text,format:'plain'}}});}});}
        """
        let (streamHost, streamConfig) = try install("selfcheck.stream", source: streaming, session: session)
        var partial: [String] = []
        let streamResult = try await streamHost.translate(request, service: streamConfig, onStream: { partial.append($0.text) })
        try expect(streamResult.text == "start:中:end" && partial.count >= 2 && partial.first == "start:", "真实分块、跨块 UTF8 与 query.onStream")
        checks.append("插件：真实流式 HTTP 分块、跨块 UTF8、流式译文回调和最终响应结构通过")

        let signals = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){let n=0;const s=$signal.new();s.subscribe(()=>n++);const d=s.subscribe(()=>n+=100);d.dispose();s.send();s.removeAllSubscriber();s.send();if(n!==1||!query.cancelSignal)throw new Error('Signal interface');const cancel=$signal.new();$http.streamRequest({url:'https://pop-fixture.invalid/cancel-stream',cancelSignal:cancel,streamHandler:function(){},handler:function(resp){if(!resp.error)throw new Error('Expected cancellation');completion({result:{toParagraphs:['cancelled']}});}});$timer.schedule({interval:0.025,repeats:false,handler:()=>cancel.send()});}
        """
        let (signalHost, signalConfig) = try install("selfcheck.signal", source: signals, session: session)
        let signalResult = try await signalHost.translate(request, service: signalConfig)
        try expect(signalResult.text == "cancelled", "$signal 接口与流式 HTTP 取消")
        checks.append("插件：$signal 订阅/解除/发送、query.cancelSignal 与流式请求取消通过")
        checks += try await PluginExtendedSelfCheck.run(base: base)
        if includeProcessIsolation { checks += try await PluginIsolationSelfCheck.run(base: base) }
        return checks
    }

    private static func traversalZIP() -> Data {
        let name = Data("../outside.js".utf8)
        var local = Data(), central = Data()
        func append16(_ n: UInt16, _ data: inout Data) { data.append(UInt8(n & 255)); data.append(UInt8(n >> 8)) }
        func append32(_ n: UInt32, _ data: inout Data) { append16(UInt16(n & 65535), &data); append16(UInt16(n >> 16), &data) }
        append32(0x04034b50, &local)
        [20, 0, 0, 0, 0].forEach { append16(UInt16($0), &local) }
        [0, 0, 0].forEach { append32(UInt32($0), &local) }
        append16(UInt16(name.count), &local); append16(0, &local); local.append(name)
        append32(0x02014b50, &central)
        [0x0314, 20, 0, 0, 0, 0].forEach { append16(UInt16($0), &central) }
        [0, 0, 0].forEach { append32(UInt32($0), &central) }
        [name.count, 0, 0, 0, 0].forEach { append16(UInt16($0), &central) }
        append32(0x81a4_0000, &central); append32(0, &central); central.append(name)
        let start = local.count; local.append(central)
        append32(0x06054b50, &local)
        [0, 0, 1, 1].forEach { append16(UInt16($0), &local) }
        append32(UInt32(central.count), &local); append32(UInt32(start), &local); append16(0, &local)
        return local
    }
}

private final class PluginSelfCheckURLProtocol: URLProtocol {
    private let fixtureLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "pop-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if request.url?.path == "/stream" || request.url?.path == "/cancel-stream" {
            let chunks = request.url?.path == "/stream" ? [Data("start:".utf8), Data([0xe4]), Data([0xb8, 0xad]), Data(":end".utf8)] : [Data](repeating: Data("chunk".utf8), count: 100)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Task { [weak self] in
                guard let self else { return }
                for chunk in chunks {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    guard !self.fixtureLock.withLock({ self.stopped }) else { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if request.url?.path == "/multipart" {
            let body = bodyData()
            let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            let valid = type.hasPrefix("multipart/form-data; boundary=") && body?.range(of: Data("name=\"field\"\r\n\r\nfixture value\r\n".utf8)) != nil && body?.range(of: Data("name=\"upload\"; filename=\"fixture.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)) != nil && body?.range(of: Data([0, 255, 65])) != nil
            guard valid else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"multipart":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url?.path == "/binary" {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            guard body == Data("binary request".utf8) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0xff, 0x00, 0x41]))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let json = request.url?.path == "/audio" ? "fixture downloaded audio" : (request.httpMethod == "POST" ? #"{"translation":"POST fixture"}"# : #"{"translation":"GET fixture"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func bodyData() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    override func stopLoading() { fixtureLock.withLock { stopped = true } }
}

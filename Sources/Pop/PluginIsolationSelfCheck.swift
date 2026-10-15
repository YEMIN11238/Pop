import Foundation

@MainActor
enum PluginIsolationSelfCheck {
    static func run(base: URL) async throws -> [String] {
        let manager = FileManager.default
        let storage = base.appendingPathComponent("isolated-installed", isDirectory: true)
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw PopError.message("插件进程自检失败：" + message) }
        }
        func install(_ id: String, category: String = "translate", source: String, timeout: TimeInterval = 3) throws -> (PluginService, ServiceConfig) {
            let incoming = base.appendingPathComponent("isolated-fixture-" + id, isDirectory: true)
            try manager.createDirectory(at: incoming, withIntermediateDirectories: false)
            let info = ["identifier": id, "name": "Isolated fixture", "version": "1.0.0", "category": category]
            try JSONSerialization.data(withJSONObject: info).write(to: incoming.appendingPathComponent("info.json"))
            try Data(source.utf8).write(to: incoming.appendingPathComponent("main.js"))
            let host = PluginService(rootURL: storage, timeout: timeout)
            let plugin = try host.importPlugin(from: incoming)
            var service = ServiceConfig(name: "Isolation fixture", kind: .plugin); service.pluginID = plugin.id
            return (host, service)
        }
        let languages = "function supportLanguages(){return ['en','zh-Hans'];}\n"
        let request = TranslationRequest(text: "hello", source: "en", target: "zh-Hans")
        let (host, service) = try install("selfcheck.isolated", source: languages + """
        function translate(q,c){q.onStream({content:{format:'markdown',text:'# First'},thinkInfo:{content:'reason'}});setTimeout(()=>{q.onStream({content:{text:'# Second'}});c({result:{content:{text:'# Final'},toDict:{word:'hello',parts:[{part:'n.',means:['fixture']}]}}});},10);}
        """)
        var frames: [TranslationOutput] = []
        let value = try await host.translate(request, service: service, onStream: { frames.append($0) })
        try expect(frames.map(\.text) == ["# First", "# Second"] && value.text == "# Final" && value.format == "markdown" && value.reasoning == "reason" && value.dictionary?.word == "hello", "worker 管道保留异步、流式顺序、格式/思考/词典")
        let (originalHost, originalConfig) = try install("selfcheck.isolatedoriginal", source: languages + """
        function translate(q,c){
          if(q.text!=='first second'||q.originalText!=='// first\\n\\n// second'){c({error:{message:'worker lost original text'}});return;}
          q.onStream({toParagraphs:['一','二']});c({result:{toParagraphs:['一','二']}});
        }
        """)
        var originalFrames: [TranslationOutput] = []
        let originalOutput = try await originalHost.translate(TranslationRequest(text: "first second", source: "en", target: "zh-Hans", originalText: "// first\n\n// second"), service: originalConfig, onStream: { originalFrames.append($0) })
        try expect(originalOutput.text == "一\n\n二" && originalFrames.first?.text == "一\n\n二", "独立worker保留处理前原文与空行映射")
        let (validationHost, validationConfig) = try install("selfcheck.isolatedvalidate", source: "function pluginValidate(c){setTimeout(()=>c({result:true}),5);}")
        let validation = try await validationHost.validate(service: validationConfig)
        try expect(validation.supported && validation.isValid, "worker 验证结果")
        let (speechHost, speechConfig) = try install("selfcheck.isolatedspeech", category: "tts", source: languages + "function tts(q,c){c({result:{type:'base64',value:'YXVkaW8='}});}")
        let audio = try await speechHost.synthesize(text: "fixture", language: "en", service: speechConfig)
        try expect(audio == Data("audio".utf8), "worker 二进制音频结果")

        let (loopHost, loopConfig) = try install("selfcheck.isolatedloop", source: languages + "function translate(){while(true){}}", timeout: 0.35)
        var mainActorTicked = false
        let tick = Task { @MainActor in try await Task.sleep(nanoseconds: 30_000_000); mainActorTicked = true }
        let began = Date()
        var timeoutRejected = false
        do { _ = try await loopHost.translate(request, service: loopConfig) } catch { timeoutRejected = error.localizedDescription.contains("超时") }
        _ = try await tick.value
        try expect(timeoutRejected && mainActorTicked && Date().timeIntervalSince(began) < 2, "死循环被硬超时终止且父进程主 actor 保持响应")
        let (bootstrapHost, bootstrapConfig) = try install("selfcheck.isolatedbootstrap", source: "while(true){}", timeout: 0.35)
        var bootstrapRejected = false
        do { _ = try await bootstrapHost.translate(request, service: bootstrapConfig) } catch { bootstrapRejected = error.localizedDescription.contains("超时") }
        try expect(bootstrapRejected, "main.js 初始化阶段死循环也能强制终止")
        let task = Task { try await PluginService(rootURL: storage, timeout: 5).translate(request, service: loopConfig) }
        try await Task.sleep(nanoseconds: 80_000_000); task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch { cancelled = error is CancellationError }
        try expect(cancelled, "取消可立即终止运行中的工作进程")
        // A previous hung invocation must not poison a later context.
        let again = try await host.translate(request, service: service)
        try expect(again.text == "# Final", "终止之后新插件调用仍正常")
        let (removalHost, removalConfig) = try install("selfcheck.isolatedremoval", source: languages + """
        function translate(q,c){function write(){if(!$file.write({path:'$sandbox/active.txt',data:$data.fromUTF8('fixture')}))throw new Error('cache write failed');}write();q.onStream({content:{text:'ready'}});$timer.schedule({interval:0.005,repeats:true,handler:write});}
        """)
        var ready = false, earlyError: String?
        let removalTask = Task {
            do { return try await removalHost.translate(request, service: removalConfig, onStream: { _ in ready = true }) }
            catch { earlyError = error.localizedDescription; throw error }
        }
        let waitUntil = Date().addingTimeInterval(2)
        while !ready && Date() < waitUntil { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(ready, "卸载 fixture 进程已运行（\(earlyError ?? "no error")）")
        try removalHost.removePlugin(id: removalConfig.pluginID)
        var removalCancelled = false, removalError = "no error"
        do { _ = try await removalTask.value } catch { removalCancelled = error is CancellationError; removalError = String(describing: type(of: error)) + ": " + error.localizedDescription }
        try await Task.sleep(nanoseconds: 30_000_000)
        let cacheExists = manager.fileExists(atPath: storage.appendingPathComponent(".sandboxes/" + removalConfig.pluginID).path)
        try expect(removalCancelled && !cacheExists, "卸载先终止进程再删除缓存，后续不能继续写入（cancelled=\(removalCancelled), cacheExists=\(cacheExists), error=\(removalError)）")
        return ["插件：真实子进程异步/有序流式/完整结果、验证和音频传输通过", "插件：真实子进程保留 originalText，与处理后的 text 分离并保留原文空行通过", "插件：执行及初始化死循环硬超时、父主线程响应、取消/卸载及后续调用恢复通过"]
    }
}

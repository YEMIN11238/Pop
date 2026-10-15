import Foundation

@MainActor
enum NetworkProxyPluginSelfCheck {
    static func run() async throws -> [String] {
        let saved = NetworkProxy.current
        defer { NetworkProxy.install(saved) }
        var prefs = AppPreferences()
        prefs.proxyEnabled = false
        _ = NetworkProxy.configure(preferences: prefs)
        prefs.proxyEnabled = true; prefs.proxyHost = "127.0.0.1"; prefs.proxyPort = 7890
        _ = NetworkProxy.configure(preferences: prefs, passwordOverride: "private-fixture")
        _ = NetworkProxy.configure(preferences: prefs)
        guard NetworkProxy.current.password == "private-fixture" else {
            throw PopError.message("代理自检失败：重复配置未复用密码缓存。")
        }
        prefs.proxyEnabled = false
        _ = NetworkProxy.configure(preferences: prefs)
        guard NetworkProxy.current.password.isEmpty else {
            throw PopError.message("代理自检失败：关闭代理未清理密码缓存。")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("pop-proxy-worker-fixture-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: false)
        let info = ["identifier": "selfcheck.proxyworker", "name": "Proxy worker fixture", "version": "1.0.0", "category": "translate"]
        try JSONSerialization.data(withJSONObject: info).write(to: incoming.appendingPathComponent("info.json"))
        let source = """
        function supportLanguages(){return ['en','zh-Hans'];}
        function translate(query,completion){
          $http.get({url:'\(LocalHTTPConnectProxyFixture.originURL.absoluteString)',handler:function(resp){
            if(resp.error){completion({error:resp.error});return;}
            completion({result:{toParagraphs:[String(resp.data)]}});
          }});
        }
        """
        try Data(source.utf8).write(to: incoming.appendingPathComponent("main.js"))
        let proxy = try LocalHTTPConnectProxyFixture()
        defer { proxy.stop() }
        let port = try await proxy.start()
        let host = PluginService(rootURL: root.appendingPathComponent("installed", isDirectory: true), timeout: 5)
        let plugin = try host.importPlugin(from: incoming)
        var config = ServiceConfig(name: "Proxy fixture", kind: .plugin); config.pluginID = plugin.id
        NetworkProxy.install(NetworkProxySnapshot(enabled: true, host: "127.0.0.1", port: Int(port), username: "fixture", password: "private-fixture"))
        let result = try await host.translate(TranslationRequest(text: "fixture", source: "en", target: "zh-Hans"), service: config)
        let observation = proxy.observations
        guard result.text == "proxy fixture passed", observation.connectSeen, observation.authorizationSeen, observation.originSeen else {
            throw PopError.message("代理自检失败：插件子进程未使用匿名管道携带的代理认证配置。")
        }
        return ["代理：禁用配置不读Keychain、重复启用复用密码缓存、禁用清理内存密码通过。", "代理：真实插件worker通过匿名管道获取代理快照，回环代理 CONNECT认证与$http请求通过；未读真实Keychain或外呼。"]
    }
}

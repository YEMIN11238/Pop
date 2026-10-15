import Foundation
import Network

enum NetworkProxySelfCheck {
    static func run() async throws -> [String] {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "NetworkProxySelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "代理自检失败：" + message]) }
        }
        let original = NetworkProxy.current
        defer { NetworkProxy.install(original) }
        var passed: [String] = []
        for host in ["127.0.0.1", "proxy.example.invalid", "::1", "[::1]"] {
            _ = try NetworkProxySnapshot(enabled: true, host: host, port: 7890).validated()
        }
        for host in ["", "http://127.0.0.1", "user:password@localhost", "host/path", "host\nvalue", "host:7890"] {
            var rejected = false
            do { _ = try NetworkProxySnapshot(enabled: true, host: host, port: 7890).validated() } catch { rejected = true }
            try require(rejected, "拒绝无效代理主机")
        }
        let credentials = NetworkProxySnapshot(enabled: true, host: "127.0.0.1", port: 7890, username: "fixture", password: "private-fixture")
        let encoded = try JSONEncoder().encode(credentials)
        let decoded = try JSONDecoder().decode(NetworkProxySnapshot.self, from: encoded)
        try require(decoded == credentials, "worker快照编码往返")
        passed.append("代理：主机/IP/IPv6校验及worker快照编码往返通过，未读钥匙串。")

        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 4; base.timeoutIntervalForResource = 6
        base.urlCache = nil; base.httpCookieStorage = nil; base.urlCredentialStorage = nil
        let provider = NetworkProxySessionProvider(configuration: base)
        NetworkProxy.install(NetworkProxySnapshot())
        let first = provider.session
        NetworkProxy.install(credentials)
        let second = provider.session
        try require(first !== second && second.configuration.proxyConfigurations.count == 1, "保存后更换会话")
        try require(second.configuration.proxyConfigurations[0].allowFailover == false, "禁止代理失败后直连")
        let injected = URLSession(configuration: base)
        defer { injected.invalidateAndCancel() }
        let provided = NetworkProxySessionProvider(session: injected, configuration: base)
        try require(provided.session === injected, "测试注入会话保持不变")
        NetworkProxy.install(NetworkProxySnapshot())
        try require(provider.session !== second && provider.session.configuration.proxyConfigurations.isEmpty, "关闭代理创建跟随系统会话")
        passed.append("代理：长寿命服务会话随配置更换、禁用回系统配置、注入会话隔离、禁止直连回退通过。")

        NetworkProxy.install(NetworkProxySnapshot(enabled: true, host: "https://invalid", port: 7890))
        let blocked = NetworkProxy.makeSession(configuration: base)
        defer { blocked.invalidateAndCancel() }
        var rejected = false
        do { _ = try await blocked.data(from: URL(string: "https://no-network.invalid/blocked")!) }
        catch {
            let failure = error as NSError
            rejected = failure.domain == "PopNetworkProxy" && failure.code == 1
        }
        try require(rejected, "错误的已启用代理必须阻止请求")
        passed.append("代理：错误配置由本地URLProtocol阻止请求，没有静默直连。")

        let proxy = try LocalHTTPConnectProxyFixture()
        defer { proxy.stop() }
        let port = try await proxy.start()
        NetworkProxy.install(NetworkProxySnapshot(enabled: true, host: "127.0.0.1", port: Int(port), username: "fixture", password: "private-fixture"))
        let session = NetworkProxy.makeSession(configuration: base)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: LocalHTTPConnectProxyFixture.originURL)
        try require((response as? HTTPURLResponse)?.statusCode == 200 && String(data: data, encoding: .utf8) == "proxy fixture passed", "本地CONNECT隧道响应")
        let log = proxy.observations
        try require(log.connectSeen && log.authorizationSeen && log.originSeen, "CONNECT及代理认证未到本地监听器")
        passed.append("代理：真实回环代理 HTTP CONNECT、代理账号密码认证、隧道内HTTP响应通过；未连接真实目标。")

        let (bytes, streamedResponse) = try await session.bytes(from: LocalHTTPConnectProxyFixture.originURL)
        var streamed = Data()
        for try await byte in bytes { streamed.append(byte) }
        try require((streamedResponse as? HTTPURLResponse)?.statusCode == 200 && String(data: streamed, encoding: .utf8) == "proxy fixture passed", "代理流式读取")
        passed.append("代理：真实回环代理 CONNECT中的URLSession AsyncBytes流式读取通过。")

        let badProxy = try LocalHTTPConnectProxyFixture()
        defer { badProxy.stop() }
        let badPort = try await badProxy.start()
        NetworkProxy.install(NetworkProxySnapshot(enabled: true, host: "127.0.0.1", port: Int(badPort), username: "fixture", password: "wrong-fixture"))
        let badSession = NetworkProxy.makeSession(configuration: base)
        defer { badSession.invalidateAndCancel() }
        var authFailed = false
        do {
            let (_, response) = try await badSession.data(from: LocalHTTPConnectProxyFixture.originURL)
            authFailed = (response as? HTTPURLResponse)?.statusCode == 407
        } catch { authFailed = true }
        let badLog = badProxy.observations
        try require(authFailed && badLog.connectSeen && !badLog.authorizationSeen && !badLog.originSeen, "错误代理密码不可直连/不可进入目标请求")
        passed.append("代理：真实回环代理拒绝错误密码，目标请求未进入隧道，未回退直连。")
        return passed
    }
}

/// A CONNECT proxy fixture that terminates the tunnel itself. It never resolves
/// or connects to the requested origin; all bytes stay on loopback.
final class LocalHTTPConnectProxyFixture: @unchecked Sendable {
    // A single-label local-network name is permitted by the app's existing
    // NSAllowsLocalNetworking policy. Unlike localhost it does not trigger the
    // system's mandatory loopback proxy bypass. The fixture never resolves it.
    static let originHost = "pop-proxy-fixture"
    static let originURL = URL(string: "http://" + originHost + "/fixture")!
    struct Observations { var connectSeen = false; var authorizationSeen = false; var originSeen = false }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pop.fixture.http-connect")
    private let lock = NSLock()
    private var log = Observations()
    private var connections: [NWConnection] = []
    private var startResumed = false
    var observations: Observations { lock.lock(); defer { lock.unlock() }; return log }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startResumed else { return }
                switch state {
                case .ready:
                    self.startResumed = true
                    if let port = self.listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                case .failed(let error): self.startResumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue: self.queue)
                self.receive(connection, buffered: Data(), tunneled: false)
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() } }
    private func receive(_ connection: NWConnection, buffered: Data, tunneled: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffered; if let data { bytes.append(data) }
            guard bytes.count <= 65536 else { connection.cancel(); return }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil && !complete { self.receive(connection, buffered: bytes, tunneled: tunneled) }
                else { connection.cancel() }; return
            }
            let header = String(data: bytes[..<end.upperBound], encoding: .utf8) ?? ""
            if !tunneled {
                self.lock.lock(); self.log.connectSeen = header.hasPrefix("CONNECT " + Self.originHost + ":80 "); self.lock.unlock()
                let token = Data("fixture:private-fixture".utf8).base64EncodedString()
                let authorized = header.lowercased().contains("proxy-authorization: basic " + token.lowercased())
                if !authorized {
                    let response = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"fixture\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                self.lock.lock(); self.log.authorizationSeen = true; self.lock.unlock()
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { error in
                    if error == nil { self.receive(connection, buffered: Data(bytes[end.upperBound...]), tunneled: true) }
                    else { connection.cancel() }
                })
            } else {
                self.lock.lock(); self.log.originSeen = header.hasPrefix("GET /fixture ") && header.lowercased().contains("host: " + Self.originHost); self.lock.unlock()
                let body = "proxy fixture passed"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

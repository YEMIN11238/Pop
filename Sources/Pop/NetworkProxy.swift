import Foundation
import Network

/// An invocation snapshot. Worker copies travel through anonymous pipes only;
/// passwords never enter preferences, command-line arguments or environment.
struct NetworkProxySnapshot: Codable, Equatable, Sendable {
    var enabled = false
    var host = ""
    var port = 7890
    var username = ""
    var password = ""

    func validated() throws -> NetworkProxySnapshot {
        guard enabled else { return self }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 253,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              !trimmed.contains(where: { "/\\@?#".contains($0) }),
              (1...65535).contains(port) else { throw NetworkProxyError.invalidConfiguration }
        // Accept a hostname, IPv4, or IPv6 literal. URL credentials/paths must
        // never be silently interpreted as part of the proxy endpoint.
        let bare = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard !bare.contains(":") || IPv6Address(bare) != nil else { throw NetworkProxyError.invalidConfiguration }
        guard username.utf8.count <= 4096, password.utf8.count <= 16384,
              !username.contains(where: { $0 == "\r" || $0 == "\n" }),
              !password.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw NetworkProxyError.invalidConfiguration }
        var value = self; value.host = bare
        return value
    }
}

enum NetworkProxyError: LocalizedError {
    case invalidConfiguration
    var errorDescription: String? { "代理配置无效。请填写服务器主机名或 IP，端口为 1–65535；不要在服务器中加入协议、账号或路径。" }
}

enum NetworkProxy {
    static let passwordAccount = "network.proxy.password"
    private static let lock = NSLock()
    private static var stored = NetworkProxySnapshot()
    private static var revision: UInt64 = 0

    static var current: NetworkProxySnapshot { state().snapshot }
    static func state() -> (snapshot: NetworkProxySnapshot, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }; return (stored, revision)
    }

    /// Startup/preferences bridge used only by the normal app process. Repeated
    /// unrelated preferences changes reuse the in-memory password. Disabled
    /// proxies do not read Keychain and do not retain the password in memory.
    @MainActor @discardableResult
    static func configure(preferences: AppPreferences, passwordOverride: String? = nil) -> String? {
        let previous = current
        var value = NetworkProxySnapshot(enabled: preferences.proxyEnabled, host: preferences.proxyHost,
                                         port: preferences.proxyPort, username: preferences.proxyUsername)
        if value.enabled {
            value.password = passwordOverride ?? (previous.enabled ? previous.password : SecretStore.read(passwordAccount))
        }
        install(value)
        do { _ = try value.validated(); return nil } catch { return error.localizedDescription }
    }

    /// Workers/tests install a supplied snapshot and never consult user files or
    /// Keychain. An invalid enabled proxy fails closed through a URLProtocol.
    static func install(_ value: NetworkProxySnapshot) {
        var clean = value
        if !clean.enabled { clean.password = "" }
        lock.lock(); defer { lock.unlock() }
        guard clean != stored else { return }; stored = clean; revision &+= 1
    }

    static func apply(to configuration: URLSessionConfiguration, snapshot: NetworkProxySnapshot? = nil) {
        let raw = snapshot ?? current
        guard raw.enabled else { return } // System proxy settings remain in effect.
        do {
            let value = try raw.validated()
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(value.host), port: NWEndpoint.Port(rawValue: UInt16(value.port))!)
            var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
            proxy.allowFailover = false
            if !value.username.isEmpty || !value.password.isEmpty { proxy.applyCredential(username: value.username, password: value.password) }
            configuration.proxyConfigurations = [proxy]
        } catch {
            configuration.protocolClasses = [InvalidProxyURLProtocol.self]
        }
    }

    static func makeSession(configuration: URLSessionConfiguration = .ephemeral,
                            delegate: URLSessionDelegate? = nil, delegateQueue: OperationQueue? = nil) -> URLSession {
        let copy = configuration.copy() as! URLSessionConfiguration
        apply(to: copy)
        return URLSession(configuration: copy, delegate: delegate, delegateQueue: delegateQueue)
    }
}

/// Long-lived service objects must observe settings saved AFTER their init.
/// Old sessions finish already-running tasks; subsequent requests get a session
/// with the new snapshot. An explicitly injected fixture session stays intact.
final class NetworkProxySessionProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let injected: URLSession?
    private let configuration: URLSessionConfiguration
    private let delegate: URLSessionDelegate?
    private var owned: URLSession?
    private var appliedRevision: UInt64?

    init(session: URLSession? = nil, configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil) {
        injected = session; self.configuration = configuration.copy() as! URLSessionConfiguration; self.delegate = delegate
    }
    var session: URLSession {
        if let injected { return injected }
        let state = NetworkProxy.state()
        lock.lock(); defer { lock.unlock() }
        if let owned, appliedRevision == state.revision { return owned }
        owned?.finishTasksAndInvalidate()
        let config = configuration.copy() as! URLSessionConfiguration
        NetworkProxy.apply(to: config, snapshot: state.snapshot)
        let next = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        owned = next; appliedRevision = state.revision
        return next
    }
    deinit { owned?.finishTasksAndInvalidate() }
}

private final class InvalidProxyURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "PopNetworkProxy", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: NetworkProxyError.invalidConfiguration.localizedDescription]))
    }
    override func stopLoading() {}
}

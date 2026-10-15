import Foundation
import JavaScriptCore
import Network
import Security

@objc protocol PluginWebSocketExports: JSExport {
    var readyState: Int { get }
    func open()
    func close(_ parameters: JSValue?)
    func sendString(_ string: String)
    func sendData(_ data: PluginBinaryData)
    func ping(_ data: JSValue?)
    func pong(_ data: JSValue?)
    func listenOpen(_ callback: JSValue)
    func listenClose(_ callback: JSValue)
    func listenError(_ callback: JSValue)
    func listenReceiveString(_ callback: JSValue)
    func listenReceiveData(_ callback: JSValue)
    func listenReceivePing(_ callback: JSValue)
    func listenReceivePong(_ callback: JSValue)
}

/// Network.framework implements RFC 6455 framing, masking, TLS and control frames.
/// JSExport entrypoints and JSValue listeners are accessed exclusively on the main queue.
final class PluginWebSocket: NSObject, PluginWebSocketExports, @unchecked Sendable {
    private(set) var readyState = 0
    private let url: URL
    private let headers: [(name: String, value: String)]
    private let allowSelfSigned: Bool
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "pop.plugin.websocket")
    private var connection: NWConnection?
    private var deadline: DispatchWorkItem?
    private var closeDeadline: DispatchWorkItem?
    private var listeners: [String: [JSValue]] = [:]
    private var didClose = false

    init(options: [String: Any]) throws {
        guard let string = options["url"] as? String, let parts = URLComponents(string: string),
              ["ws", "wss"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true, let url = parts.url else { throw PopError.message("WebSocket 需要有效的 ws:// 或 wss:// 地址。") }
        self.url = url
        var headers: [(name: String, value: String)] = []
        if let raw = options["header"] as? [String: Any] {
            for (key, value) in raw {
                guard let text = value as? String, key.range(of: #"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$"#, options: .regularExpression) != nil,
                      !text.contains("\r"), !text.contains("\n"), !text.contains("\0") else { throw PopError.message("WebSocket header 必须是有效的字符串，且不能包含换行。") }
                headers.append((key, text))
            }
        }
        self.headers = headers
        allowSelfSigned = options["allowSelfSignedSSLCertificates"] as? Bool ?? false
        let seconds = options["timeoutInterval"] as? Double ?? 60
        timeout = seconds.isFinite ? max(0.1, min(seconds, 300)) : 60
        super.init()
    }

    func open() {
        guard connection == nil else { return }
        readyState = 0; didClose = false
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 20 * 1024 * 1024
        websocket.setAdditionalHeaders(headers.filter { $0.name.lowercased() != "sec-websocket-protocol" })
        if let protocols = headers.first(where: { $0.name.lowercased() == "sec-websocket-protocol" })?.value {
            websocket.setSubprotocols(protocols.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let tls = url.scheme?.lowercased() == "wss" ? NWProtocolTLS.Options() : nil
        if allowSelfSigned, let tls {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                if SecTrustEvaluateWithError(reference, nil) { complete(true); return }
                guard let certificate = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first,
                      let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
                      let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate), subject == issuer else { complete(false); return }
                SecTrustSetAnchorCertificates(reference, [certificate] as CFArray)
                SecTrustSetAnchorCertificatesOnly(reference, false)
                complete(SecTrustEvaluateWithError(reference, nil))
            }, queue)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let newConnection = NWConnection(to: .url(url), using: parameters)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            DispatchQueue.main.async {
                guard let self, let newConnection, self.connection === newConnection else { return }
                switch state {
                case .ready:
                    self.deadline?.cancel(); self.deadline = nil
                    self.readyState = 1
                    self.emit("open", arguments: [self])
                    self.receive(newConnection)
                case .failed(let error): self.fail(error)
                case .cancelled: self.finishClose(code: 1006, reason: nil)
                default: break
                }
            }
        }
        let work = DispatchWorkItem { [weak self, weak newConnection] in
            guard let self, let newConnection, self.connection === newConnection, self.readyState == 0 else { return }
            self.fail(PopError.message("WebSocket 连接超时。"))
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        newConnection.start(queue: queue)
    }

    func close(_ parameters: JSValue?) {
        let requested = parameters?.objectForKeyedSubscript("code")
        let number = requested == nil || requested!.isUndefined || requested!.isNull ? 1000 : Int(requested!.toInt32())
        guard (0...65535).contains(number), let code = try? NWProtocolWebSocket.CloseCode(rawValue: UInt16(number)) else { emitError("WebSocket 关闭代码无效。", code: 1002); return }
        guard let connection, readyState == 1 else { finishClose(code: number, reason: nil); return }
        readyState = 2
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close); metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "pop.websocket.close", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { DispatchQueue.main.async { self?.fail(error) } }
        })
        let work = DispatchWorkItem { [weak self] in self?.finishClose(code: number, reason: nil) }
        closeDeadline = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func sendString(_ string: String) { send(Data(string.utf8), opcode: .text) }
    func sendData(_ data: PluginBinaryData) { send(data.bytes, opcode: .binary) }
    func ping(_ data: JSValue?) { send((data?.toObject() as? PluginBinaryData)?.bytes ?? Data(), opcode: .ping) }
    func pong(_ data: JSValue?) { send((data?.toObject() as? PluginBinaryData)?.bytes ?? Data(), opcode: .pong) }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        guard let connection, readyState == 1 else { emitError("WebSocket 尚未打开。", code: 1006); return }
        guard data.count <= ((opcode == .ping || opcode == .pong) ? 125 : 20 * 1024 * 1024) else { emitError("WebSocket 消息超过大小限制。", code: 1009); return }
        let context = NWConnection.ContentContext(identifier: "pop.websocket.\(opcode.rawValue)", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { DispatchQueue.main.async { self?.fail(error) } }
        })
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, complete, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let opcode = metadata?.opcode
            let closeCode = metadata.map { Self.number($0.closeCode) }
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection, !self.didClose else { return }
                if let error { self.fail(error); return }
                let data = data ?? Data()
                switch opcode {
                case .text:
                    guard let text = String(data: data, encoding: .utf8) else { self.fail(PopError.message("WebSocket 文本不是 UTF-8。")); return }
                    self.emit("string", arguments: [self, text])
                case .binary: self.emit("data", arguments: [self, PluginBinaryData(data)])
                case .ping: self.emit("ping", arguments: [self, PluginBinaryData(data)])
                case .pong: self.emit("pong", arguments: [self, PluginBinaryData(data)])
                case .close: self.finishClose(code: closeCode ?? 1000, reason: String(data: data, encoding: .utf8)); return
                default: break
                }
                if !self.didClose { self.receive(connection) }
            }
        }
    }

    private static func number(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code { case .protocolCode(let code): return Int(code.rawValue); case .applicationCode(let value), .privateCode(let value): return Int(value) @unknown default: return 1006 }
    }
    private func emit(_ event: String, arguments: [Any]) { for callback in listeners[event] ?? [] { _ = callback.call(withArguments: arguments) } }
    private func emitError(_ message: String, code: Int) { emit("error", arguments: [self, ["type": "websocket", "code": code, "message": message]]) }
    private func fail(_ error: Error) { emitError(error.localizedDescription, code: (error as NSError).code); finishClose(code: 1006, reason: error.localizedDescription) }
    private func finishClose(code: Int, reason: String?) {
        guard !didClose else { return }
        didClose = true; readyState = 3
        deadline?.cancel(); deadline = nil; closeDeadline?.cancel(); closeDeadline = nil
        let previous = connection; connection = nil; previous?.cancel()
        emit("close", arguments: [self, code, reason as Any? ?? NSNull()])
    }
    func shutdown() {
        listeners.removeAll(); deadline?.cancel(); deadline = nil; closeDeadline?.cancel(); closeDeadline = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil; readyState = 3; didClose = true
    }
    func listenOpen(_ callback: JSValue) { listeners["open", default: []].append(callback) }
    func listenClose(_ callback: JSValue) { listeners["close", default: []].append(callback) }
    func listenError(_ callback: JSValue) { listeners["error", default: []].append(callback) }
    func listenReceiveString(_ callback: JSValue) { listeners["string", default: []].append(callback) }
    func listenReceiveData(_ callback: JSValue) { listeners["data", default: []].append(callback) }
    func listenReceivePing(_ callback: JSValue) { listeners["ping", default: []].append(callback) }
    func listenReceivePong(_ callback: JSValue) { listeners["pong", default: []].append(callback) }
}

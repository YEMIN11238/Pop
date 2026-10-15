import AppKit
import SwiftUI
import WebKit

struct ResultContentView: View {
    let text: String
    var format: String? = nil
    let fontSize: Double
    var markdownEnabled = true
    var remoteImages = false
    var linkConfirmation = "suspicious"
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var height = 24.0

    var body: some View {
        if markdownEnabled && format == "markdown" {
            MarkdownWebView(text: text, fontSize: fontSize, dark: colorScheme == .dark, remoteImages: remoteImages, linkConfirmation: linkConfirmation, height: $height)
                .frame(height: max(24, min(24000, height)))
        } else {
            Text(text).font(.system(size: fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let dark: Bool
    let remoteImages: Bool
    var linkConfirmation = "suspicious"
    @Binding var height: Double

    static var resourceDirectory: URL? {
        let bundle = Bundle.main.resourceURL?.appendingPathComponent("Renderer")
        if let bundle, FileManager.default.fileExists(atPath: bundle.appendingPathComponent("index.html").path) { return bundle }
        #if DEBUG
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Renderer")
        return FileManager.default.fileExists(atPath: source.appendingPathComponent("index.html").path) ? source : nil
        #else
        return nil
        #endif
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "height")
        config.userContentController.add(context.coordinator, name: "link")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        if let directory = Self.resourceDirectory { view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory) }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "link")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebView
        private var ready = false
        private var last = ""
        init(_ parent: MarkdownWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ view: WKWebView) {
            guard ready else { return }
            let signature = parent.text + "\u{0}" + String(parent.fontSize) + String(parent.dark) + String(parent.remoteImages)
            guard signature != last else { return }; last = signature
            view.callAsyncJavaScript("return window.renderResult(text, 'markdown', fontSize, dark, remoteImages)",
                                     arguments: ["text": parent.text, "fontSize": parent.fontSize, "dark": parent.dark, "remoteImages": parent.remoteImages],
                                     in: nil, in: .page, completionHandler: { _ in })
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "height", let number = message.body as? NSNumber {
                let value = max(24, min(24000, number.doubleValue))
                if abs(parent.height - value) > 1 { DispatchQueue.main.async { self.parent.height = value } }
            } else if message.name == "link" {
                let value = message.body as? [String: Any]
                guard let string = value?["url"] as? String ?? message.body as? String,
                      string.utf8.count <= 16384, let url = URL(string: string), ResultLinkPolicy.allows(url) else { return }
                let text = value?["text"] as? String
                guard ResultLinkPolicy.requiresConfirmation(url: url, displayedText: text, mode: parent.linkConfirmation) else {
                    NSWorkspace.shared.open(url); return
                }
                let alert = NSAlert()
                alert.messageText = "打开此链接？"
                alert.informativeText = "实际目标：\n" + url.absoluteString
                if let text, !text.isEmpty, text != url.absoluteString {
                    alert.informativeText = "显示文字：" + String(text.prefix(500)) + "\n\n" + alert.informativeText
                }
                alert.addButton(withTitle: "打开链接")
                alert.addButton(withTitle: "取消")
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                if let window = message.webView?.window {
                    guard window.attachedSheet == nil else { return }
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                    }
                } else if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated { decisionHandler(.cancel) }
            else { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
        }
    }
}

/// The native side decides whether a renderer-provided link needs confirmation.
/// Legacy string messages have no displayed label, so only URL credentials can be
/// classified as suspicious; the always policy still asks for every allowed link.
enum ResultLinkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return false }
        if scheme == "mailto" { return true }
        return ["http", "https"].contains(scheme) && !(components.host ?? "").isEmpty
    }

    static func requiresConfirmation(url: URL, displayedText: String?, mode: String) -> Bool {
        guard allows(url) else { return false }
        if mode == "always" { return true }
        if mode == "never" { return false }
        guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if target.user != nil || target.password != nil { return true }
        guard let text = displayedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf16.count <= 16384, let labelHost = displayedURLHost(text),
              let actualHost = target.host else { return false }
        return normalizedHost(labelHost) != normalizedHost(actualHost)
    }

    private static func displayedURLHost(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return URLComponents(string: text)?.host
        }
        // Detector dictionaries omit reserved/new TLDs; parse a bare host first so
        // labels such as example.invalid are still compared rather than trusted.
        if !text.contains(where: { $0.isWhitespace }), !text.contains("@"),
           let host = URLComponents(string: "https://" + text)?.host {
            let domainPattern = #"^(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+[\p{L}][\p{L}\p{N}-]*\.?$"#
            let ipv4 = host.split(separator: ".", omittingEmptySubsequences: false)
            let isIPv4 = ipv4.count == 4 && ipv4.allSatisfy { part in Int(part).map { (0...255).contains($0) } ?? false }
            if host.range(of: domainPattern, options: .regularExpression) != nil || isIPv4 || text.hasPrefix("[") {
                return host
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range), match.range == range else { return nil }
        return match.url?.host
    }

    private static func normalizedHost(_ host: String) -> String {
        // A final dot is the DNS absolute-name form of the same host.
        var value = host.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        // Reparse to normalize Unicode/IDNA spellings consistently with Foundation.
        return URL(string: "https://" + value)?.host?.lowercased() ?? value
    }
}

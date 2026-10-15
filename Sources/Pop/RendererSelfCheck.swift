import AppKit
import WebKit

@MainActor enum RendererSelfCheck {
    static func run() async throws -> [String] {
        guard let directory = MarkdownWebView.resourceDirectory else { throw PopError.message("缺少本地富文本渲染资源。") }
        let harness = RendererHarness()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 800), configuration: config)
        web.navigationDelegate = harness
        try await harness.load(web, file: directory.appendingPathComponent("index.html"), directory: directory)
        let sample = """
        # 结果展示
        **粗体**与中文。

        | 服务 | 结果 |
        |---|---|
        | 系统 | 你好 |

        ```swift
        let message = "Hello"
        print(message)
        ```

        $$E=mc^2$$

        ```mermaid
        graph LR
        A[输入] --> B[翻译] --> C[结果]
        ```

        <img src="https://example.com/tracker.png" onerror="window.testExecuted=true"><script>window.testExecuted=true</script>
        """
        _ = try await web.callAsyncJavaScript("return window.renderResult(text, 'markdown', 14, false, false)", arguments: ["text": sample], in: nil, contentWorld: .page)
        let checks = try await web.evaluateJavaScript("JSON.stringify({table:document.querySelectorAll('table').length,code:document.querySelectorAll('code.hljs').length,math:document.querySelectorAll('.katex').length,diagram:document.querySelectorAll('.mermaid-render svg').length,labels:[...document.querySelectorAll('.mermaid-render text')].map(x=>x.textContent),scripts:document.querySelectorAll('#content script').length,images:document.querySelectorAll('#content img').length,executed:window.testExecuted===true})") as? String ?? ""
        guard let data = checks.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["table"] as? Int == 1, result["code"] as? Int == 1,
              result["math"] as? Int == 1, result["diagram"] as? Int == 1,
              result["labels"] as? [String] == ["输入", "翻译", "结果"],
              result["scripts"] as? Int == 0, result["images"] as? Int == 0,
              result["executed"] as? Bool == false else { throw PopError.message("富文本渲染断言失败：\(checks)") }
        if let path = ProcessInfo.processInfo.environment["POP_RENDERER_SNAPSHOT"] {
            let image = try await web.takeSnapshot(configuration: nil)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
        _ = try await web.callAsyncJavaScript("return window.renderResult(text, 'plain', 14, true, false)", arguments: ["text": "<b>literal</b>\nsecond line"], in: nil, contentWorld: .page)
        let plain = try await web.evaluateJavaScript("document.getElementById('content').textContent") as? String
        guard plain == "<b>literal</b>\nsecond line" else { throw PopError.message("纯文本被错误当成 HTML。") }
        web.stopLoading(); web.navigationDelegate = nil
        return ["WebKit：Markdown表格/代码高亮/公式/Mermaid中文标签实际渲染通过。", "WebKit：脚本与事件属性被清除，默认不加载远程图片，纯文本保留尖括号与换行。"]
    }
}

@MainActor private final class RendererHarness: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView, file: URL, directory: URL) async throws {
        try await withCheckedThrowingContinuation { callback in
            continuation = callback
            web.loadFileURL(file, allowingReadAccessTo: directory)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.complete(.failure(PopError.message("富文本资源加载超时。")))
            }
        }
    }
    private func complete(_ result: Result<Void, Error>) {
        guard let continuation else { return }; self.continuation = nil
        continuation.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { complete(.failure(error)) }
}

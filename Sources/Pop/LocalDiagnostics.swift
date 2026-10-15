import AppKit
import Foundation

/// Operational events contain no source text, translations, URLs or credentials.
/// There is no upload endpoint; exporting is an explicit user operation.
@MainActor
enum LocalDiagnostics {
    private static let file = AppStorage.directory.appendingPathComponent("Logs/events.jsonl")
    static func record(_ event: String, error: Error? = nil) {
        guard ConfigurationRepository.shared.preferences.localLoggingEnabled else { return }
        var entry = ["timestamp": ISO8601DateFormatter().string(from: Date()), "event": event]
        if let error { entry["errorType"] = String(describing: type(of: error)) }
        guard let json = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = (try? Data(contentsOf: file)) ?? Data()
            if data.count > 512 * 1024 {
                let suffix = data.suffix(256 * 1024)
                data = suffix.firstIndex(of: 10).map { Data(suffix.suffix(from: suffix.index(after: $0))) } ?? Data()
            }
            data.append(json); data.append(10)
            try data.write(to: file, options: .atomic)
        } catch { /* Diagnostic failure must not interrupt translation. */ }
    }

    static func export() {
        let panel = NSSavePanel()
        panel.title = "导出日志"; panel.nameFieldStringValue = "Pop-logs.jsonl"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let environment = ["event": "diagnostic_export", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                               "system": ProcessInfo.processInfo.operatingSystemVersionString]
            var data = try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
            data.append(10); data.append((try? Data(contentsOf: file)) ?? Data())
            try data.write(to: destination, options: .atomic)
        } catch {
            let alert = NSAlert(); alert.messageText = "导出日志失败"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
}

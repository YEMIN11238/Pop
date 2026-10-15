import AppKit

/// Bob's two integration rows open documentation through NSWorkspace
/// (REA: 0x1000ebb68 / 0x1000ebbc4 -> 0x100537be0).
/// pop ships its own instructions so application names and extension payloads match.
@MainActor
enum PopIntegrationActions {
    static func showPopClip() { openGuide("popclip") }
    static func showAppleScript() { openGuide("applescript") }
    private static func openGuide(_ name: String) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Guides/\(name).html")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { NSWorkspace.shared.open(bundled); return }
        #if DEBUG
        do {
            let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Guides/\(name).html")
            if FileManager.default.fileExists(atPath: source.path) { NSWorkspace.shared.open(source) }
        }
        #endif
    }
}

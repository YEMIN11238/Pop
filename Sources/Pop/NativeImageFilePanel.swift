import AppKit
import UniformTypeIdentifiers

/// Bob's “访达选图 OCR” is an asynchronous file panel, not Finder automation.
/// REA/Ghidra 0x1000a637c configures NSOpenPanel; 0x1000a67ac only submits
/// nonempty selections after the user accepts the panel.
@MainActor
final class NativeImageFilePanel {
    private var activePanel: NSOpenPanel?

    static func suppressesAutoHide(of window: NSWindow) -> Bool {
        ImageFilePanelAutoHideGuard.contains(window)
    }

    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.prompt = "开始识别"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Match the formats AppKit can actually decode, including supported
        // non-raster formats, instead of accepting every public.image subtype.
        panel.allowedContentTypes = NSImage.imageTypes.compactMap { UTType($0) }
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return panel
    }

    func present(onSelection: @escaping ([URL]) -> Void) {
        if let activePanel {
            activePanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = Self.makePanel()
        // A standalone asynchronous panel is neither an attached sheet nor
        // NSApp.modalWindow. Protect only the window that launched this panel.
        let autoHideGuard = ImageFilePanelAutoHideGuard(sourceWindow: NSApp.keyWindow)
        activePanel = panel
        panel.begin { [weak self, weak panel] response in
            guard let self, let panel, self.activePanel === panel else {
                autoHideGuard.finish()
                return
            }
            self.activePanel = nil
            let urls = panel.urls
            // Let AppKit finish dismissing the file panel and restoring its
            // previous key window before presenting OCR. Otherwise that restore
            // immediately resigns (and auto-hides) the newly opened OCR window.
            DispatchQueue.main.async {
                // Resume ordinary blur handling before OCR takes focus. Cancel
                // follows the same cleanup path without changing OCR state.
                autoHideGuard.finish()
                guard response == .OK, !urls.isEmpty else { return }
                onSelection(urls)
            }
        }
    }
}

@MainActor
private final class ImageFilePanelAutoHideGuard {
    private static let presentations = NSHashTable<ImageFilePanelAutoHideGuard>(options: [.weakMemory, .objectPointerPersonality])
    private weak var sourceWindow: NSWindow?

    init(sourceWindow: NSWindow?) {
        self.sourceWindow = sourceWindow
        Self.presentations.add(self)
    }

    static func contains(_ window: NSWindow) -> Bool {
        presentations.allObjects.contains { $0.sourceWindow === window }
    }

    func finish() {
        Self.presentations.remove(self)
    }
}

@MainActor
enum ImageFilePanelLifecycleSelfCheck {
    static func run() throws -> [String] {
        let source = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let unrelated = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        source.isReleasedWhenClosed = false
        unrelated.isReleasedWhenClosed = false
        let first = ImageFilePanelAutoHideGuard(sourceWindow: source)
        let second = ImageFilePanelAutoHideGuard(sourceWindow: source)
        defer { first.finish(); second.finish() }
        guard NativeImageFilePanel.suppressesAutoHide(of: source),
              !NativeImageFilePanel.suppressesAutoHide(of: unrelated) else {
            throw PopError.message("选图面板生命周期自检：应仅保护来源窗口。")
        }
        first.finish()
        guard NativeImageFilePanel.suppressesAutoHide(of: source) else {
            throw PopError.message("选图面板生命周期自检：关闭一个面板不应清掉另一面板的保护。")
        }
        second.finish()
        guard !NativeImageFilePanel.suppressesAutoHide(of: source) else {
            throw PopError.message("选图面板生命周期自检：结束后必须恢复失焦隐藏。")
        }
        try autoreleasepool {
            let abandoned = ImageFilePanelAutoHideGuard(sourceWindow: source)
            guard NativeImageFilePanel.suppressesAutoHide(of: source) else {
                throw PopError.message("选图面板生命周期自检：未保护来源窗口。")
            }
            withExtendedLifetime(abandoned) {}
        }
        guard !NativeImageFilePanel.suppressesAutoHide(of: source) else {
            throw PopError.message("选图面板生命周期自检：废弃的面板不能永久阻止失焦隐藏。")
        }
        return ["选图面板生命周期：仅保护来源窗，多个面板分别释放，完成或取消共用释放路径，废弃后无残留保护；未显示测试窗口。"]
    }
}

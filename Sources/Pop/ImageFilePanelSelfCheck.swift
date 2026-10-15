import AppKit
import UniformTypeIdentifiers

@MainActor
enum ImageFilePanelSelfCheck {
    static func run() throws -> [String] {
        let panel = NativeImageFilePanel.makePanel()
        guard panel.canChooseFiles, !panel.canChooseDirectories, panel.allowsMultipleSelection,
              panel.prompt == "开始识别",
              panel.directoryURL?.standardizedFileURL == FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL else {
            throw PopError.message("访达选图自检：文件面板的多选、目录或确认按钮不符合原版配置。")
        }
        let expected = Set(NSImage.imageTypes.compactMap { UTType($0)?.identifier })
        guard !expected.isEmpty, Set(panel.allowedContentTypes.map(\.identifier)) == expected else {
            throw PopError.message("访达选图自检：未使用 NSImage 支持的文件类型。")
        }
        return ["访达选图 OCR：原版使用文件面板；默认桌面、文件多选、禁止目录、开始识别按钮、NSImage 可解码类型已核对。未弹出面板、读取访达选中项或用户图片。"]
    }
}

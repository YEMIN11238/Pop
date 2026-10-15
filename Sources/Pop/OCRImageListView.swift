import AppKit
import SwiftUI

/// The original image container uses a 109-point image list (97-point rows),
/// hidden for a single image, and keeps its merge button below the scrolling list.
struct OCRImageListView: View {
    @ObservedObject var state: AppState
    @ViewState private var boxMode = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            if state.ocrImages.tasks.count > 1 {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.ocrImages.tasks) { task in
                                Button { state.selectOCRImage(task.id) } label: {
                                    VStack(spacing: 8) {
                                        Group {
                                            if let image = NSImage(contentsOf: task.url) {
                                                Image(nsImage: image).resizable().scaledToFit()
                                            } else { Image(systemName: "photo").font(.system(size: 25)).foregroundStyle(.secondary) }
                                        }.frame(width: 90, height: 55).background(Color(nsColor: .textBackgroundColor))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                                        Text(task.url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                    }.frame(width: 109, height: 97)
                                        .background(state.ocrImages.selectedID == task.id ? Color.accentColor.opacity(0.18) : .clear)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(task.url.lastPathComponent)
                                    .contextMenu {
                                        Button("重新识别") { state.retryOCRImages(task.id) }
                                        Button("合并所有文字", action: state.mergeOCRImageText)
                                    }
                            }
                        }
                    }
                    Divider()
                    Button("合并文字", action: state.mergeOCRImageText)
                        .buttonStyle(.borderless).font(.system(size: 13))
                        .foregroundStyle(state.ocrImages.mergesAllText ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity).frame(height: 36)
                }.frame(width: 109)
                Divider()
            }
            VStack(spacing: 0) {
                ZStack {
                    if let selected = state.ocrImages.selected, let image = NSImage(contentsOf: selected.url) {
                        OCRImageView(image: image, document: previewDocument(selected.document),
                                     showBoxes: boxMode != 4, translations: [:], onTextClick: state.copy)
                            .padding(10)
                    } else { Text("无法读取图片").font(.system(size: 13)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Picker("文本边框显示规则", selection: $boxMode) {
                    boxIcon("ow_box_text", fallback: "text.viewfinder").tag(0).help("显示文本块边框")
                    boxIcon("ow_box_paragraph", fallback: "rectangle.split.3x1").tag(2).help("显示段落边框")
                    boxIcon("ow_box_none", fallback: "rectangle").tag(4).help("不显示边框")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 126).padding(.vertical, 7)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func boxIcon(_ name: String, fallback: String) -> Image {
        let source = UIReferenceAssets.image(name, dark: colorScheme == .dark)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
        guard let source, let image = source.copy() as? NSImage,
              source.size.width > 0, source.size.height > 0 else { return Image(systemName: fallback) }
        // NSSegmentedControl reads the NSImage's intrinsic point size; a SwiftUI
        // frame on the label does not constrain the exported raster dimensions.
        let scale = min(15 / source.size.width, 15 / source.size.height)
        image.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        return Image(nsImage: image)
    }

    private func previewDocument(_ document: OCRDocument?) -> OCRDocument {
        guard let document else { return OCRDocument(text: "", lines: [], qrCodes: []) }
        guard boxMode == 2 else { return document }
        return OCRDocument(text: document.text, lines: OCRTextLayout.paragraphBoxes(from: document.lines), qrCodes: document.qrCodes)
    }
}

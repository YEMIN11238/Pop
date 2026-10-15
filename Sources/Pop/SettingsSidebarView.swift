import AppKit
import SwiftUI

struct SettingsSidebarItem: Equatable {
    let id: String
    let title: String
    let image: String
    let fallback: String
}

struct SettingsSidebarSection: Equatable {
    let title: String
    let items: [SettingsSidebarItem]
}

/// The reference sidebar is an NSOutlineView. Keeping a native list preserves
/// its arrow-key selection and accessibility instead of treating every page as
/// an unrelated SwiftUI button. See settings-experience-refinement-20261015.json.
@MainActor
struct SettingsSidebarView: NSViewRepresentable {
    let sections: [SettingsSidebarSection]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    fileprivate func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        let clip = SettingsSidebarClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.contentInsets = NSEdgeInsets(top: 50, left: 10, bottom: 24, right: 10)

        let outline = SettingsSidebarOutlineView()
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.indentationPerLevel = 0
        outline.intercellSpacing = .zero
        outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = false
        outline.focusRingType = .none
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.setAccessibilityLabel("设置分类")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        column.width = 160
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        scroll.documentView = outline
        coordinator.outline = outline
        coordinator.update(self)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        final class Row: NSObject {
            enum Content { case section(String), page(SettingsSidebarItem), spacer }
            let content: Content
            init(_ content: Content) { self.content = content }
            var page: SettingsSidebarItem? { if case .page(let page) = content { return page }; return nil }
        }

        var parent: SettingsSidebarView
        weak var outline: NSOutlineView?
        private var sections: [SettingsSidebarSection] = []
        private var rows: [Row] = []
        private var updating = false

        init(_ parent: SettingsSidebarView) { self.parent = parent }

        func update(_ parent: SettingsSidebarView) {
            self.parent = parent
            guard let outline else { return }
            updating = true
            defer { updating = false }
            if sections != parent.sections {
                sections = parent.sections
                rows = []
                for (index, section) in sections.enumerated() {
                    if index != 0 { rows.append(Row(.spacer)) }
                    rows.append(Row(.section(section.title)))
                    rows += section.items.map { Row(.page($0)) }
                }
                outline.reloadData()
            }
            if let index = rows.firstIndex(where: { $0.page?.id == parent.selection }), outline.selectedRow != index {
                outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                outline.scrollRowToVisible(index)
            }
            updateVisibleCells()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? rows.count : 0 }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { rows[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let row = item as? Row else { return false }
            if case .section = row.content { return true }
            return false
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Row)?.page != nil }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let row = item as? Row else { return 20 }
            switch row.content { case .section: return 20; case .page: return 32; case .spacer: return 16 }
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let row = item as? Row else { return nil }
            switch row.content {
            case .page(let page):
                let cell = SettingsSidebarCellView()
                cell.configure(page, selected: page.id == parent.selection)
                return cell
            case .section(let title):
                let cell = NSTableCellView()
                let label = NSTextField(labelWithString: title.uppercased())
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label); cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4)
                ])
                return cell
            case .spacer:
                let view = NSView()
                view.setAccessibilityElement(false)
                return view
            }
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SettingsSidebarRowView() }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline, rows.indices.contains(outline.selectedRow), let page = rows[outline.selectedRow].page else { return }
            if !updating { parent.selection = page.id }
            updateVisibleCells()
        }
        private func updateVisibleCells() {
            guard let outline else { return }
            for row in 0..<outline.numberOfRows {
                if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SettingsSidebarCellView,
                   let page = rows[row].page {
                    cell.configure(page, selected: outline.selectedRow == row)
                }
            }
        }
    }
}

@MainActor
enum SettingsSidebarSelfCheck {
    static func run() throws -> [String] {
        var selected = "translate"
        var writes = 0
        let items = [
            SettingsSidebarItem(id: "translate", title: "翻译设置", image: "pw_sidebar_setting", fallback: "hexagon"),
            SettingsSidebarItem(id: "service", title: "服务", image: "pw_sidebar_service", fallback: "cube"),
            SettingsSidebarItem(id: "ocr", title: "OCR 设置", image: "pw_sidebar_setting", fallback: "hexagon")
        ]
        let sidebar = SettingsSidebarView(sections: [
            SettingsSidebarSection(title: "翻译", items: Array(items.prefix(2))),
            SettingsSidebarSection(title: "OCR", items: [items[2]])
        ], selection: Binding(get: { selected }, set: { selected = $0; writes += 1 }))
        let coordinator = sidebar.makeCoordinator()
        let scroll = sidebar.makeScrollView(coordinator: coordinator)
        guard let outline = scroll.documentView as? NSOutlineView,
              outline.numberOfRows == 6, outline.selectedRow == 1, writes == 0 else {
            throw PopError.message("设置侧栏初始化或页面选择错误")
        }
        for index in [0, 3, 4] {
            guard let item = outline.item(atRow: index), !coordinator.outlineView(outline, shouldSelectItem: item) else {
                throw PopError.message("设置侧栏分组或空白行被当作页面")
            }
        }
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        guard selected == "service", writes == 1 else { throw PopError.message("原生侧栏选择未同步设置页面") }
        selected = "ocr"
        coordinator.update(sidebar)
        guard outline.selectedRow == 5, writes == 1 else { throw PopError.message("外部跳转侧栏时错误重复提交页面") }
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        guard selected == "translate", writes == 2 else { throw PopError.message("侧栏往返选择丢失页面状态") }
        return ["原生设置侧栏页面选择与外部跳转双向同步，分组与空白行不作为页面"]
    }
}

private final class SettingsSidebarOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func mouseDown(with event: NSEvent) {
        if row(at: convert(event.locationInWindow, from: nil)) < 0 {
            window?.performDrag(with: event)
        } else { super.mouseDown(with: event) }
    }
}

private final class SettingsSidebarClipView: NSClipView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private final class SettingsSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

private final class SettingsSidebarCellView: NSTableCellView {
    private let pageImage = NSImageView()
    private let pageTitle = NSTextField(labelWithString: "")
    private var item: SettingsSidebarItem?
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pageTitle.font = .systemFont(ofSize: 13)
        pageTitle.lineBreakMode = .byTruncatingTail
        pageImage.imageScaling = .scaleProportionallyUpOrDown
        for view in [pageImage, pageTitle] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        imageView = pageImage; textField = pageTitle
        NSLayoutConstraint.activate([
            pageImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pageImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            pageImage.widthAnchor.constraint(equalToConstant: 18),
            pageImage.heightAnchor.constraint(equalToConstant: 18),
            pageTitle.leadingAnchor.constraint(equalTo: pageImage.trailingAnchor, constant: 6),
            pageTitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            pageTitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ item: SettingsSidebarItem, selected: Bool) {
        self.item = item; self.selected = selected
        pageTitle.stringValue = item.title
        updateAppearance()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        guard let item else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = UIReferenceAssets.image(item.image, dark: dark) ?? NSImage(systemSymbolName: item.fallback, accessibilityDescription: nil)
        image?.isTemplate = true
        pageImage.image = image
        pageImage.contentTintColor = selected ? .white : NSColor(srgbRed: 128.0/255, green: 129.0/255, blue: 133.0/255, alpha: 1)
        pageTitle.textColor = selected ? .white : .labelColor
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BobHistorySettingsView: View {
    @ObservedObject var state: AppState
    let favoritesOnly: Bool
    @ViewState private var query = ""
    @ViewState private var showSearch = false
    @ViewState private var selection: UUID?
    @ViewState private var pendingRemoval: HistoryRemovalRequest?

    private var canvas: Color { Color(nsColor: .textBackgroundColor) }
    private var items: [HistoryItem] {
        state.history.filter { item in
            (!favoritesOnly || item.favorite) && (query.isEmpty || item.source.localizedCaseInsensitiveContains(query) || item.results.values.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    private var selected: HistoryItem? { items.first { $0.id == selection } ?? items.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                listHeader
                Divider()
                if showSearch {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索原文和译文", text: $query).textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).help("清除搜索")
                        }
                    }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 36)
                    Divider()
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in historyRow(item) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                detailHeader
                Divider()
                if let selected { detail(selected) }
                else { canvas.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(canvas)
        .alert(item: $pendingRemoval) { request in
            Alert(title: Text(request.title), message: Text(request.message),
                  primaryButton: .destructive(Text(request.buttonTitle)) { remove(request) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(favoritesOnly ? "收藏夹" : "历史记录").font(.system(size: 16, weight: .bold))
                Text("\(items.count) 项").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button(showSearch ? "关闭搜索" : "搜索…") {
                    showSearch.toggle()
                    if !showSearch { query = "" }
                }
                Divider()
                Button("导入历史与收藏…") { state.importHistory() }
                Button("导出当前列表…", action: exportItems).disabled(items.isEmpty)
                Divider()
                Button(favoritesOnly ? "清空收藏夹…" : "清空历史记录…", action: requestClear)
                    .disabled(favoritesOnly ? !state.history.contains(where: \.favorite) : state.history.isEmpty)
            } label: {
                UIReferenceIcon(name: "pw_more", fallback: "ellipsis")
                    .frame(width: 18, height: 19).frame(width: 26, height: 26)
                    .background(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("更多操作").accessibilityLabel("更多历史与收藏操作")
        }.padding(.horizontal, 20).frame(height: 52)
    }

    private var detailHeader: some View {
        HStack(spacing: 15) {
            Spacer()
            if !favoritesOnly {
                Button {
                    if let selected { setFavorite(!selected.favorite, id: selected.id) }
                } label: {
                    UIReferenceIcon(name: selected?.favorite == true ? "pw_detail_favorite_yellow" : "pw_detail_favorite", fallback: selected?.favorite == true ? "star.fill" : "star")
                        .frame(width: 16, height: 16)
                }.help(selected?.favorite == true ? "取消收藏" : "收藏")
                    .accessibilityLabel(selected?.favorite == true ? "取消收藏" : "收藏")
                    .disabled(selected == nil).opacity(selected == nil ? 0.35 : 1)
            }
            Button {
                if let selected { requestRemoval(selected) }
            } label: {
                UIReferenceIcon(name: "pw_detail_delete", fallback: "trash").frame(width: 16, height: 16)
            }.help(favoritesOnly ? "从收藏夹移除" : "删除历史记录")
                .accessibilityLabel(favoritesOnly ? "从收藏夹移除" : "删除历史记录")
                .disabled(selected == nil).opacity(selected == nil ? 0.35 : 1)
        }.buttonStyle(.plain).padding(.horizontal, 20).frame(height: 52)
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        Button { selection = item.id } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(item.source).font(.system(size: 13)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(item.date, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if item.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .background(selected?.id == item.id ? Color.accentColor.opacity(0.12) : canvas)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) }
            .contextMenu {
                Button("载入翻译窗口") { state.loadHistory(item) }
                Button(item.favorite ? "取消收藏" : "加入收藏") { setFavorite(!item.favorite, id: item.id) }
                Divider()
                Button(favoritesOnly ? "从收藏夹移除…" : "删除历史记录…") { requestRemoval(item) }
            }
    }

    private func detail(_ item: HistoryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(item.date, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("载入翻译窗口") { state.loadHistory(item) }
                        .font(.system(size: 11)).buttonStyle(.borderless)
                }
                historyCard(item.source, service: "原文")
                HStack(spacing: 10) {
                    Text(LanguageCatalog.title(item.sourceLanguage))
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(LanguageCatalog.title(item.targetLanguage))
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(item.results.keys.sorted(), id: \.self) { name in
                    historyCard(item.results[name] ?? "", service: name)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func historyCard(_ text: String, service: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: state.preferences.fontSize)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                Button { state.speak(text) } label: {
                    UIReferenceIcon(name: "tw_action_audio", fallback: "speaker.wave.2").frame(width: 12, height: 12)
                }.help("朗读")
                Button { state.copy(text) } label: {
                    UIReferenceIcon(name: "tw_action_copy", fallback: "doc.on.doc").frame(width: 12, height: 12)
                }.help("复制")
                Spacer()
                Text(service).font(.system(size: 10)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func setFavorite(_ value: Bool, id: UUID) {
        var next = state.history
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].favorite = value
        persist(next)
    }

    private func requestRemoval(_ item: HistoryItem) {
        if favoritesOnly {
            pendingRemoval = HistoryRemovalRequest(ids: [item.id], favoritesOnly: true,
                                                  title: "从收藏夹移除此项？", message: "原文和译文仍会保留在历史记录中。", buttonTitle: "移除收藏")
        } else {
            pendingRemoval = HistoryRemovalRequest(ids: [item.id], favoritesOnly: false,
                                                  title: "删除这条历史记录？", message: item.favorite ? "此内容也会从收藏夹移除。" : "这条记录中的原文和译文将被删除。", buttonTitle: "删除")
        }
    }

    private func requestClear() {
        let scope = state.history.filter { !favoritesOnly || $0.favorite }
        guard !scope.isEmpty else { return }
        pendingRemoval = HistoryRemovalRequest(ids: Set(scope.map(\.id)), favoritesOnly: favoritesOnly,
                                              title: favoritesOnly ? "清空收藏夹？" : "清空历史记录？",
                                              message: favoritesOnly ? "将移除 \(scope.count) 项收藏，原文和译文仍会保留在历史记录中。" : "将删除全部 \(scope.count) 项历史记录\(scope.contains(where: \.favorite) ? "，包括其中已收藏的内容" : "")。",
                                              buttonTitle: favoritesOnly ? "清空收藏" : "清空历史")
    }

    private func remove(_ request: HistoryRemovalRequest) {
        // Operate on the IDs the user confirmed. New queries arriving while an
        // alert is open must not be swept into that earlier deletion request.
        var next = state.history
        if request.favoritesOnly {
            for index in next.indices where request.ids.contains(next[index].id) { next[index].favorite = false }
        } else { next.removeAll { request.ids.contains($0.id) } }
        persist(next)
    }

    private func persist(_ next: [HistoryItem]) {
        do {
            guard next.count <= 100000 else { throw PopError.message("历史数据超过保存上限，请先导出后再整理。") }
            // A recent preference reduction must not silently delete additional,
            // unconfirmed entries during a favorite toggle or single deletion.
            try HistoryRepository.shared.replace(next, limit: max(state.preferences.historyLimit, next.count))
        } catch { state.notice = error.localizedDescription }
    }

    private func exportItems() {
        let snapshot = items
        let panel = NSSavePanel()
        panel.nameFieldStringValue = favoritesOnly ? "Pop收藏.json" : "Pop历史.json"
        panel.allowedContentTypes = [.json]
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch { state.notice = error.localizedDescription }
    }
}

private struct HistoryRemovalRequest: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
    let favoritesOnly: Bool
    let title: String
    let message: String
    let buttonTitle: String
}

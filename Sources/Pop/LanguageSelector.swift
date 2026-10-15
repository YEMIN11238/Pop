import SwiftUI

struct LanguageSelector: View {
    let code: String
    var allowAuto = false
    var title = "语言"
    var favorites: [String] = []
    let select: (String) -> Void
    @ViewState private var presented = false
    @ViewState private var query = ""
    @ViewState private var showMore = false
    private var choices: [(String, String)] {
        LanguageCatalog.choices.filter { (allowAuto || $0.0 != "auto") && (query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) || $0.1.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 4) { Text(code == "auto" ? "自动选择" : LanguageCatalog.title(code)); Image(systemName: "chevron.down").font(.system(size: 8)) }
        }.buttonStyle(.borderless).help(title)
        .popover(isPresented: $presented) {
            VStack(spacing: 8) {
                TextField("搜索语言名称或代码", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if query.isEmpty && !favorites.isEmpty {
                            ForEach(choices.filter { $0.0 == "auto" || favorites.contains($0.0) }, id: \.0) { choice($0) }
                            Divider()
                            DisclosureGroup("更多语言", isExpanded: $showMore) {
                                ForEach(choices.filter { $0.0 != "auto" && !favorites.contains($0.0) }, id: \.0) { choice($0) }
                            }.padding(.horizontal, 8)
                        } else {
                            ForEach(choices, id: \.0) { choice($0) }
                        }
                    }
                }
            }.padding(12).frame(width: 250, height: 340)
        }
    }

    private func choice(_ value: (String, String)) -> some View {
        Button { select(value.0); presented = false; query = "" } label: {
            HStack { Text(value.0 == "auto" ? "自动选择" : value.1); Spacer(); if code == value.0 { Image(systemName: "checkmark") } }
                .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

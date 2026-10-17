import SwiftUI

enum ServicePickerChoice {
    case system, dictionary, provider(ServiceKind), preset(CloudServicePreset), plugin(PluginDescriptor), installPlugin
}

struct AddServicePicker: View {
    let capability: String
    let plugins: [PluginDescriptor]
    let onChoose: (ServicePickerChoice) -> Void
    let onCancel: () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
    private var providers: [ServiceKind] {
        CloudMediaCatalog.kinds(for: capability).filter { !(capability == "ocr" && $0 == .baidu) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("内置") {
                        if capability == "translate" {
                            ForEach(CloudServiceCatalog.builtInAIPresets) { preset in presetTile(preset) }
                        }
                        tile(capability == "ocr" ? "系统文字识别" : capability == "tts" ? "系统朗读" : "系统翻译", icon: "character.bubble", tint: .black, asset: providerAsset(.apple), service: capability == "translate" ? .system : nil) { onChoose(.system) }
                        if capability == "ocr" {
                            tile("百度 OCR", icon: "cube", tint: .blue, service: .baiduOCR(scope: "translation")) { onChoose(.provider(.baidu)) }
                        }
                        if capability == "translate" {
                            tile("简明英汉词典", icon: "character.book.closed", tint: .blue, asset: "service_dict", service: .dictionary) { onChoose(.dictionary) }
                        }
                    }
                    if capability == "translate" {
                        Text("智谱与硅基流动内置的是接口和模型配置，使用时需填写你自己的 API Key。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if capability == "ocr" {
                        Text("百度 OCR 内置的是接口配置，需填写你自己的百度智能云 API Key 与 Secret Key。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    group("自带密钥") {
                        if capability == "translate" {
                            ForEach(CloudServiceCatalog.translationPresets()) { preset in
                                tile(preset.title, icon: providerIcon(preset.kind), tint: providerColor(preset.kind), asset: UIReferenceAssets.serviceName(preset)) { onChoose(.preset(preset)) }
                            }
                        } else {
                            ForEach(providers) { kind in
                                tile(providerName(kind), icon: providerIcon(kind), tint: providerColor(kind), asset: providerAsset(kind)) { onChoose(.provider(kind)) }
                            }
                        }
                    }
                    group("插件") {
                        ForEach(plugins.filter { $0.category == capability }) { plugin in
                            tile(plugin.name, icon: "puzzlepiece.extension", tint: .purple) { onChoose(.plugin(plugin)) }
                        }
                        tile("安装插件…", icon: "plus", tint: .secondary) { onChoose(.installPlugin) }
                    }
                }.padding(20)
            }
            Divider()
            HStack { Spacer(); Button(action: onCancel) { Text("取消").font(.system(size: 12)).frame(width: 76, height: 24).background(SettingsPalette.sidebar, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }
                .padding(.horizontal, 20).frame(height: 58)
        }
        .frame(width: 784, height: 580)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12, content: content)
        }
    }
    private func presetTile(_ preset: CloudServicePreset) -> some View {
        let service = CloudServiceCatalog.applying(preset, to: ServiceConfig(name: preset.title, kind: preset.kind))
        return tile(preset.title, icon: "sparkles", tint: .indigo, service: service) { onChoose(.preset(preset)) }
    }
    private func tile(_ title: String, icon: String, tint: Color, asset: String? = nil, service: ServiceConfig? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let service { ServiceSettingsIcon(service: service) }
                    else if let asset { UIReferenceIcon(name: asset, fallback: icon) }
                    else { Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(tint) }
                }.frame(width: 24, height: 24).background(.background, in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 40).frame(maxWidth: .infinity)
                .background(Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1)
                        : NSColor(srgbRed: 237.0/255, green: 237.0/255, blue: 237.0/255, alpha: 1)
                }), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).bobTooltip(title)
    }
    private func providerAsset(_ kind: ServiceKind) -> String {
        var service = ServiceConfig(name: kind.title, kind: kind); service.capability = capability
        return UIReferenceAssets.serviceName(service)
    }
    private func providerName(_ kind: ServiceKind) -> String {
        if capability != "translate" {
            let suffix = capability == "ocr" ? " OCR" : " TTS"
            switch kind {
            case .google: return "Google" + suffix
            case .microsoft: return "Microsoft" + suffix
            case .amazon: return "Amazon" + suffix
            case .baidu: return "百度" + suffix
            case .tencent: return "腾讯云" + suffix
            default: return kind.title(for: capability)
            }
        }
        switch kind {
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .google: return "Google 翻译"
        case .microsoft: return "Microsoft 翻译"
        case .amazon: return "Amazon 翻译"
        case .deepL: return "DeepL 翻译"
        case .aliyun: return "阿里翻译"
        case .tencent: return "腾讯翻译君"
        default: return kind.title
        }
    }
    private func providerIcon(_ kind: ServiceKind) -> String {
        switch kind {
        case .openAI, .claude, .gemini: return "sparkles"
        case .amazon: return "cloud"
        case .microsoft: return "square.grid.2x2"
        case .deepL: return "character.bubble"
        default: return "character"
        }
    }
    private func providerColor(_ kind: ServiceKind) -> Color {
        switch kind {
        case .baidu, .youdao: return .red
        case .caiyun, .microsoft: return .green
        case .amazon, .niutrans, .claude: return .orange
        case .gemini, .aliyun: return .purple
        default: return .blue
        }
    }
}

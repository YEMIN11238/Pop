import AppKit
import SwiftUI

/// Semantic icons drawn by macOS at runtime. No extracted application artwork is bundled.
enum UIReferenceAssets {
    static func image(_ name: String, dark: Bool = false) -> NSImage? {
        let symbols: [String: String] = [
            "pw_sidebar_setting": "hexagon", "pw_sidebar_service": "cube",
            "pw_sidebar_favorite": "star", "pw_sidebar_history": "clock",
            "pw_sidebar_plugin": "puzzlepiece.extension", "pw_sidebar_export": "arrow.up.arrow.down",
            "pw_sidebar_enhance": "paperplane", "pw_sidebar_integration": "atom",
            "pw_sidebar_about": "info.circle", "pw_more": "ellipsis",
            "pw_detail_favorite": "star", "pw_detail_favorite_yellow": "star.fill",
            "pw_detail_delete": "trash", "pw_export_import": "square.and.arrow.down",
            "pw_export_export": "square.and.arrow.up", "pw_integration_popclip": "scissors",
            "pw_integration_applescript": "applescript",
            "tw_navigation_pin_normal": "pin", "tw_navigation_pin_selected": "pin.fill",
            "tw_navigation_favorite": "star", "tw_navigation_favorite_yellow": "star.fill",
            "tw_navigation_history": "clock", "tw_navigation_snip": "scissors",
            "tw_navigation_pasteboard": "clipboard", "tw_navigation_input": "pencil",
            "tw_navigation_service": "bubble.left", "tw_navigation_control": "switch.2",
            "tw_action_audio": "speaker.wave.2", "tw_action_copy": "doc.on.doc",
            "tw_action_insert": "rectangle.portrait.and.arrow.right",
            "tw_exchange": "arrow.left.arrow.right", "ow_navigation_file": "photo",
            "ow_navigation_image": "photo.on.rectangle", "ow_box_text": "text.viewfinder",
            "ow_box_paragraph": "rectangle.split.3x1", "ow_box_none": "rectangle",
            "hud_success": "checkmark.circle.fill", "mini_hud_success": "checkmark",
            "mini_hud_fail": "xmark", "snip_lock_close": "xmark",
            "snip_lock_drag": "arrow.up.and.down.and.arrow.left.and.right"
        ]
        let symbol: String
        if let mapped = symbols[name] { symbol = mapped }
        else if name.hasPrefix("tw_action_copy_") { symbol = "textformat" }
        else if name == "service_dict" { symbol = "character.book.closed" }
        else if name.contains("ocr") { symbol = "text.viewfinder" }
        else if name.contains("tts") { symbol = "speaker.wave.2" }
        else if name.hasPrefix("service_apple") || name.contains("translate") { symbol = "character.bubble" }
        else if name == "service_ollama" || name == "service_lmstudio" { symbol = "desktopcomputer" }
        else if name.hasPrefix("service_default") { symbol = "puzzlepiece.extension" }
        else if name.hasPrefix("service_") { symbol = "sparkles" }
        else { return nil }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
    static func serviceName(_ service: ServiceConfig) -> String {
        switch service.kind {
        case .apple: return "service_apple_" + (service.capability == "translate" ? "translate" : service.capability)
        case .dictionary: return "service_dict"
        case .openAI:
            if let asset = openAIProviderAsset(service.options["provider"]) { return asset }
            let hint = (service.name + " " + service.endpoint).lowercased()
            for (match, asset) in [("deepseek", "deepseek"), ("siliconflow", "siliconflow"), ("硅基", "siliconflow"), ("groq", "groq"), ("ollama", "ollama"), ("11434", "ollama"), ("lm studio", "lmstudio"), ("1234", "lmstudio"), ("openrouter", "openrouter"), ("grok", "grok"), ("x.ai", "xai")] {
                if hint.contains(match) { return "service_" + asset }
            }
            return "service_openai"
        case .claude: return "service_claude"
        case .gemini: return "service_gemini"
        case .deepL: return "service_deepl"
        case .google: return "service_google_translate"
        case .baidu: return "service_baidu_translate"
        case .youdao: return "service_youdao"
        case .tencent: return "service_tencent_translate"
        case .microsoft: return "service_microsoft_translate"
        case .aliyun: return "service_ali_translate"
        case .caiyun: return "service_caiyun"
        case .niutrans: return "service_niu_translate"
        case .volcano: return "service_volcengine_translate"
        case .amazon: return "service_amazon"
        case .plugin: return "service_default_" + service.capability
        }
    }

    static func serviceName(_ preset: CloudServicePreset) -> String {
        var service = ServiceConfig(name: preset.title, kind: preset.kind)
        service.endpoint = preset.endpoint; service.options = preset.options
        return serviceName(service)
    }

    private static func openAIProviderAsset(_ provider: String?) -> String? {
        switch provider {
        case "openai": return "service_openai"
        case "azure": return "service_openai"
        case "aihubmix", "sophnet", "302ai", "grok", "groq", "openrouter", "ollama", "lmstudio", "deepseek", "qwen", "ernie", "doubao", "hunyuan", "gitee", "kimi", "siliconflow": return "service_" + (provider ?? "openai")
        default: return nil
        }
    }
}

struct UIReferenceIcon: View {
    let name: String
    var fallback = "globe"
    var template = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let image = UIReferenceAssets.image(name, dark: colorScheme == .dark) {
            Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
        } else { Image(systemName: fallback).resizable().scaledToFit() }
    }
}

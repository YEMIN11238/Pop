import AppKit
import SwiftUI

extension SettingsPalette {
    private static func serviceShade(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let shade = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: shade, green: shade, blue: shade, alpha: 1)
        })
    }
    static let servicePage = serviceShade(light: 1, dark: 40.0 / 255)
    static let serviceCard = serviceShade(light: 247.0 / 255, dark: 47.0 / 255)
    static let serviceSelection = serviceShade(light: 221.0 / 255, dark: 69.0 / 255)
    static let serviceControl = serviceShade(light: 229.0 / 255, dark: 62.0 / 255)
    static let serviceField = serviceShade(light: 1, dark: 26.0 / 255)
    static let serviceFieldBorder = serviceShade(light: 216.0 / 255, dark: 64.0 / 255)
}

struct ServiceSettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.font(.system(size: 12)).textFieldStyle(.plain)
            .padding(.horizontal, 6).padding(.vertical, 3).frame(minHeight: 23)
            .background(SettingsPalette.serviceField, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(SettingsPalette.serviceFieldBorder, lineWidth: 1))
    }
}

struct ServiceSettingsSecretField: View {
    let title: String
    @Binding var value: String
    @ViewState private var revealed = false
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if revealed { TextField(title, text: $value) }
                else { SecureField(title, text: $value) }
            }
            .textFieldStyle(.plain).font(.system(size: 12))
            .padding(7).frame(minHeight: 40)
            .background(SettingsPalette.serviceField, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(SettingsPalette.serviceFieldBorder, lineWidth: 1))
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").frame(width: 40, height: 24)
                    .background(SettingsPalette.serviceControl, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).accessibilityLabel(revealed ? "隐藏" + title : "显示" + title)
        }
    }
}

/// Locally drawn service marks; no artwork extracted from another application.
struct ServiceSettingsIcon: View {
    let service: ServiceConfig
    private var provider: String { CloudServiceCatalog.configurationProvider(for: service) ?? "" }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(background)
            if provider == "zhipu" {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 12)).foregroundStyle(.blue)
            } else if provider == "siliconflow" {
                ZStack {
                    RoundedRectangle(cornerRadius: 1).fill(Color.purple).frame(width: 10, height: 5).offset(x: 2, y: -3)
                    RoundedRectangle(cornerRadius: 1).fill(Color.purple).frame(width: 10, height: 5).offset(x: -2, y: 2)
                }
            } else if service.kind == .apple && service.capability == "translate" {
                Image(systemName: "character.bubble.fill").font(.system(size: 10)).foregroundStyle(.white)
                    .overlay(alignment: .bottomTrailing) { Text("文").font(.system(size: 5, weight: .bold)).padding(1).background(.cyan, in: RoundedRectangle(cornerRadius: 1)) }
            } else {
                UIReferenceIcon(name: UIReferenceAssets.serviceName(service)).padding(2)
                    .foregroundStyle(service.kind == .dictionary ? Color.white : Color.primary)
            }
        }.accessibilityHidden(true)
    }
    private var background: Color {
        if provider == "zhipu" || provider == "siliconflow" { return .white }
        if service.kind == .dictionary { return .blue }
        if service.kind == .apple && service.capability == "translate" { return Color(white: 0.1) }
        return .clear
    }
}

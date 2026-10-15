import SwiftUI
import AppKit

struct CloudServiceEditor: View {
    @Binding var service: ServiceConfig
    @ObservedObject var state: AppState
    @ViewState private var secrets: [String: String] = [:]
    @ViewState private var testing = false
    @ViewState private var testResult: String?

    private var isTranslation: Bool { service.capability == "translate" }
    private var isAI: Bool { isTranslation && [.openAI, .claude, .gemini].contains(service.kind) }
    private var fields: [CloudServiceField] { isTranslation ? CloudServiceCatalog.secretFields(for: service.kind, options: service.options) : CloudMediaCatalog.secretFields(for: service.kind, capability: service.capability) }
    private var optionFields: [CloudServiceField] { isTranslation ? CloudServiceCatalog.optionFields(for: service.kind, options: service.options) : CloudMediaCatalog.optionFields(for: service.kind, capability: service.capability) }
    private var defaultEndpoint: String { isTranslation ? CloudServiceCatalog.defaultEndpoint(for: service.kind, options: service.options) : CloudMediaCatalog.defaultEndpoint(for: service.kind, capability: service.capability, options: service.options) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if service.kind == .openAI {
                Text(CloudServiceCatalog.configurationHint(for: service))
                    .font(.caption).foregroundStyle(.secondary)
            } else if service.kind == .gemini {
                Text("此项使用 Gemini 原生协议；如果你的中转商提供 OpenAI 兼容地址，请添加“通用 AI（OpenAI 兼容）”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isTranslation && CloudServiceCatalog.presets(for: service.kind).count > 1 {
                Menu("选择接口预设") {
                    ForEach(CloudServiceCatalog.presets(for: service.kind)) { preset in
                        Button(preset.title) {
                            service = CloudServiceCatalog.applying(preset, to: service)
                        }
                    }
                }
            }
            labeled("服务地址") {
                if CloudServiceCatalog.usesDeploymentName(service) { CloudServiceRevealField(placeholder: "Azure 资源根地址或完整部署请求 URL", text: $service.endpoint) }
                else { TextField(defaultEndpoint, text: $service.endpoint) }
            }
            if service.kind == .openAI {
                Text(OllamaProtocol.isNative(service) ? "可填写 Ollama 基础地址（默认 http://localhost:11434），或完整的 /api/chat 地址。模型名称需与本机已安装的模型一致。" : CloudServiceCatalog.usesDeploymentName(service) ? "完整 URL 的部署名称与 API 版本优先；资源根地址需填写部署名称。隐藏仅影响屏幕显示，地址与部署名仍以原文保存在配置中。" : "可填写基础地址（例如 https://api.deepseek.com），或完整的 /chat/completions 地址。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if isAI { labeled("模型名称") { TextField("填写账户可用或本地已安装的模型", text: $service.model) } }
            ForEach(fields) { field in
                labeled(field.title) { SecureField(field.placeholder, text: secret(field.key)) }
            }
            if CloudServiceCatalog.isSpecializedTranslationModel(service) {
                Text(CloudServiceCatalog.specializedModelNotice).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(optionFields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.title).font(.caption).foregroundStyle(.secondary)
                    if ["prompt", "systemPrompt", "userPrompt"].contains(field.key) {
                        TextEditor(text: option(field)).font(.system(size: 12)).frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        Text(field.placeholder).font(.caption2).foregroundStyle(.secondary)
                    } else if !field.choices.isEmpty {
                        BobSettingsPicker(field.title, selection: option(field), options: field.choices.map { (field.choiceTitle($0), $0) }).frame(height: 24)
                    } else if field.key == "deploymentName" { CloudServiceRevealField(placeholder: field.placeholder, text: option(field)) }
                    else { TextField(field.placeholder, text: option(field)) }
                }.disabled(!CloudServiceCatalog.isOptionApplicable(field.key, to: service))
            }
            HStack {
                Button("保存凭据") { saveCredentials() }
                Button(testing ? "测试中…" : "保存并测试") { testConnection() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if let testResult { Text(testResult).font(.caption).textSelection(.enabled) }
            Text("凭据保存在系统钥匙串。服务开启后，内容会发送到此接口；连接测试使用 Hello 文字或合成测试图。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform: loadCredentials)
    }
    private func labeled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func secret(_ key: String) -> Binding<String> {
        Binding(get: { secrets[key] ?? "" }, set: { secrets[key] = $0 })
    }
    private func option(_ field: CloudServiceField) -> Binding<String> {
        Binding(get: { CloudServiceCatalog.optionValue(field, in: service) }, set: {
            service = CloudServiceCatalog.settingOption(field.key, value: $0, in: service)
        })
    }
    private func credentialString() throws -> String {
        if fields.count == 1, fields.first?.key == "apiKey" { return secrets["apiKey"] ?? "" }
        let nonempty = secrets.filter { !$0.value.isEmpty }
        if nonempty.isEmpty { return "" }
        return String(data: try JSONSerialization.data(withJSONObject: nonempty, options: [.sortedKeys]), encoding: .utf8) ?? ""
    }
    private func loadCredentials() {
        let stored = SecretStore.read(SecretStore.serviceKey(service.id))
        if let data = stored.data(using: .utf8), let object = try? JSONDecoder().decode([String: String].self, from: data) { secrets = object }
        else { secrets = ["apiKey": stored] }
    }
    @discardableResult private func saveCredentials() -> Bool {
        do {
            try SecretStore.write(credentialString(), account: SecretStore.serviceKey(service.id))
            state.savePreferences(); testResult = "凭据已保存。"; return true
        } catch { testResult = error.localizedDescription; return false }
    }
    private func testConnection() {
        guard saveCredentials() else { return }
        testing = true; testResult = nil
        let config = service
        Task {
            defer { testing = false }
            do {
                let key = try credentialString()
                if config.capability == "ocr" {
                    let image = NSImage(size: NSSize(width: 600, height: 140))
                    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 140).fill()
                    ("Hello Pop 123" as NSString).draw(at: NSPoint(x: 20, y: 45), withAttributes: [.font: NSFont.systemFont(ofSize: 50), .foregroundColor: NSColor.black])
                    image.unlockFocus()
                    guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { throw PopError.message("无法生成测试图。") }
                    let result = try await CloudMediaService().recognize(imageData: png, service: config, apiKey: key)
                    testResult = "连接成功：" + result.text
                } else if config.capability == "tts" {
                    let data = try await CloudMediaService().synthesize(text: "Hello", language: "en", service: config, apiKey: key)
                    testResult = "连接成功，收到 \(data.count) 字节音频。"
                } else {
                    let result = try await HTTPTranslationService().translate(TranslationRequest(text: "Hello", source: "en", target: "zh-Hans"), service: config, apiKey: key)
                    testResult = "连接成功：" + result.text
                }
            } catch { testResult = error.localizedDescription }
        }
    }
}

/// Conceals non-secret configuration on screen without suggesting Keychain
/// storage; actual API credentials continue to use SecureField and Keychain.
struct CloudServiceRevealField: View {
    let placeholder: String
    @Binding var text: String
    @ViewState private var revealed = false
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed { TextField(placeholder, text: $text) }
                else { SecureField(placeholder, text: $text) }
            }
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye").frame(width: 18, height: 18) }
                .buttonStyle(.plain).accessibilityLabel(revealed ? "隐藏内容" : "显示内容").bobTooltip(revealed ? "隐藏内容" : "显示内容")
        }
    }
}

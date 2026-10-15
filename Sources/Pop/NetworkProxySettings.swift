import AppKit
import SwiftUI

@MainActor
struct ProxySettingsSheet: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void
    @ViewState private var draft = Draft()
    @ViewState private var passwordEdited = false
    @ViewState private var message: String?

    private struct Draft: Equatable {
        var enabled = false
        var host = ""
        var port = "7890"
        var username = ""
        var password = ""
    }
    private var password: Binding<String> {
        Binding(get: { draft.password }, set: { draft.password = $0; passwordEdited = true })
    }
    private var cardColor: Color { Color(nsColor: .controlBackgroundColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("自定义代理").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("关闭，不保存修改")
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("开启自定义代理", isOn: $draft.enabled).toggleStyle(.switch).controlSize(.small)
                Text("HTTP 请求使用此代理，插件 WebSocket 除外。关闭后跟随系统网络设置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(cardColor, in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 0) {
                field("服务器地址") { TextField("例如 127.0.0.1", text: $draft.host) }
                Divider()
                field("端口") { TextField("7890", text: $draft.port) }
                Divider()
                field("用户名") { TextField("可选", text: $draft.username) }
                Divider()
                field("密码") {
                    HStack(spacing: 6) {
                        SecureField("未修改时保留已保存密码", text: password)
                        Button("清除") { draft.password = ""; passwordEdited = true }.buttonStyle(.borderless)
                    }
                }
            }.background(cardColor, in: RoundedRectangle(cornerRadius: 8))
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 10) {
                Text("保存后用于后续请求").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("撤销", action: onClose).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
        }.padding(20).frame(width: 500)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear(perform: reset)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(width: 78, alignment: .leading)
            content().textFieldStyle(.roundedBorder).font(.system(size: 13))
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
    private func reset() {
        let prefs = state.preferences
        let cached = NetworkProxy.current
        draft = Draft(enabled: prefs.proxyEnabled, host: prefs.proxyHost, port: String(prefs.proxyPort), username: prefs.proxyUsername,
                      password: cached.enabled ? cached.password : "")
        passwordEdited = false; message = nil
    }
    private func save() {
        do {
            guard let port = Int(draft.port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
                throw NetworkProxyError.invalidConfiguration
            }
            _ = try NetworkProxySnapshot(enabled: draft.enabled, host: draft.host, port: port,
                                         username: draft.username, password: draft.password).validated()
            if passwordEdited { try SecretStore.write(draft.password, account: NetworkProxy.passwordAccount) }
            var prefs = state.preferences
            prefs.proxyEnabled = draft.enabled; prefs.proxyHost = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            prefs.proxyPort = port; prefs.proxyUsername = draft.username
            _ = NetworkProxy.configure(preferences: prefs, passwordOverride: passwordEdited ? draft.password : nil)
            state.preferences = prefs; state.savePreferences()
            passwordEdited = false; message = nil; onClose()
        } catch { message = error.localizedDescription }
    }
}

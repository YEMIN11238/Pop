import Foundation

/// Provider-specific wire protocols share the OpenAI service editor and response
/// types. This helper is deliberately independent of display names and presets.
enum ProviderProtocol {
    static func providerID(for service: ServiceConfig) -> String {
        (service.options["provider"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isAzure(_ service: ServiceConfig) -> Bool {
        service.kind == .openAI && providerID(for: service) == "azure"
    }

    /// REA0x1003c37f8: endpoint + deployment path, api-version and api-key.
    /// A complete deployment URL is self-contained and takes precedence over
    /// separate deployment/version fields; a resource root needs deploymentName.
    static func azureEndpoint(_ service: ServiceConfig) throws -> URL {
        let raw = service.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw configuration("请填写 Azure OpenAI 资源的 Endpoint。") }
        guard !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var components = URLComponents(string: raw), let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw configuration("Azure OpenAI 地址无效，不能包含账号、密码或片段。")
        }
        guard scheme == "https" || HTTPTranslationService.isLoopback(host) else {
            throw configuration("Azure OpenAI 远程地址需要 HTTPS，仅本机回环地址允许 HTTP。")
        }

        let explicitVersion: String?
        if components.percentEncodedQuery != nil {
            let items = components.queryItems ?? []
            guard items.count == 1, items[0].name == "api-version", let value = items[0].value else {
                throw configuration("Azure OpenAI 地址只允许一个 api-version 查询参数。")
            }
            explicitVersion = value
        } else { explicitVersion = nil }
        let version = explicitVersion ?? nonempty(service.options["apiVersion"]) ?? "2023-03-15-preview"
        guard validAPIVersion(version) else { throw configuration("Azure OpenAI API Version 应为 YYYY-MM-DD 或 YYYY-MM-DD-preview。") }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let prefix = "/openai/deployments/", suffix = "/chat/completions"
        let deployment: String
        if path.isEmpty {
            guard let supplied = nonempty(service.options["deploymentName"]) else {
                throw configuration("请填写 Azure OpenAI 的 Deployment Name。")
            }
            deployment = supplied
        } else {
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else {
                throw configuration("Azure OpenAI Endpoint 应为资源根地址，或完整的部署 chat/completions 地址。")
            }
            let encoded = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            guard !encoded.isEmpty, !encoded.contains("/"), let decoded = encoded.removingPercentEncoding else {
                throw configuration("Azure OpenAI 完整地址中的部署名称无效。")
            }
            deployment = decoded
        }
        guard !deployment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deployment.count <= 200, deployment != ".", deployment != "..",
              !deployment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let encoded = deployment.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw configuration("Azure OpenAI 部署名称无效。")
        }
        components.percentEncodedPath = prefix + encoded + suffix
        components.queryItems = [URLQueryItem(name: "api-version", value: version)]
        guard let url = components.url else { throw configuration("无法构造 Azure OpenAI 请求地址。") }
        return url
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
    private static func configuration(_ message: String) -> HTTPTranslationError { .configuration(message) }
    private static func validAPIVersion(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-preview)?$", options: .regularExpression) != nil else { return false }
        let date = String(value.prefix(10)).split(separator: "-").compactMap { Int($0) }
        guard date.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let wanted = DateComponents(year: date[0], month: date[1], day: date[2])
        guard let parsed = calendar.date(from: wanted) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: parsed)
        return actual.year == wanted.year && actual.month == wanted.month && actual.day == wanted.day
    }
}

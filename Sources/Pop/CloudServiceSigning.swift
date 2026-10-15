import Foundation
import CryptoKit

struct CloudServiceCredentials {
    let values: [String: String]
    init(_ text: String) throws {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("{") {
            guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw HTTPTranslationError.configuration("多字段密钥必须是包含字符串字段的 JSON 对象。")
            }
            values = object.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else { values = ["apiKey": raw] }
        guard !values.values.contains(where: { $0.contains("\r") || $0.contains("\n") || $0.contains("\0") }) else {
            throw HTTPTranslationError.configuration("密钥字段不能包含换行或空字符。")
        }
    }
    func require(_ key: String, provider: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw HTTPTranslationError.configuration("\(provider) 缺少 \(key)，请在服务设置中填写对应密钥字段。")
        }
        return value
    }
    var apiKey: String { values["apiKey"] ?? "" }
    func redact(_ message: String) -> String {
        values.values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(message) { $0.replacingOccurrences(of: $1, with: "[已隐藏]") }
    }
}

/// Reusable signing primitives for future official OCR/TTS adapters. These
/// functions mutate an in-memory request only, with no logging or persistence.
enum CloudServiceSigning {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
    static func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func hmac(_ key: Data, _ text: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func date(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format
        return formatter.string(from: date)
    }
    static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    static func form(_ values: [String: String]) -> Data {
        Data(values.keys.sorted().map { encode($0) + "=" + encode(values[$0]!) }.joined(separator: "&").utf8)
    }
    static func canonicalQuery(_ url: URL) -> String {
        let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encoded: [(String, String)] = items.map { item in (encode(item.name), encode(item.value ?? "")) }
        let ordered = encoded.sorted { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }
        return ordered.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }
    private static func canonical(_ request: URLRequest, headers: [String]) -> (String, String) {
        let names = headers.sorted()
        let lines = names.map { name in name + ":" + (request.value(forHTTPHeaderField: name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }.joined()
        let signed = names.joined(separator: ";")
        let uri = request.url?.path.isEmpty == false ? request.url!.path : "/"
        return ([request.httpMethod ?? "POST", uri, canonicalQuery(request.url!), lines, signed, sha256(request.httpBody ?? Data())].joined(separator: "\n"), signed)
    }
    // https://github.com/TencentCloud/tencentcloud-sdk-python/blob/master/tencentcloud/common/abstract_client.py
    static func signTencent(_ request: inout URLRequest, secretId: String, secretKey: String, service: String, action: String, version: String, region: String, now: Date) {
        let timestamp = String(Int(now.timeIntervalSince1970)); let day = date(now, "yyyy-MM-dd")
        request.setValue(request.url!.host!, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action"); request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(timestamp, forHTTPHeaderField: "X-TC-Timestamp"); request.setValue(region, forHTTPHeaderField: "X-TC-Region")
        let (canonicalRequest, headers) = canonical(request, headers: ["content-type", "host"])
        let scope = day + "/" + service + "/tc3_request"
        let toSign = ["TC3-HMAC-SHA256", timestamp, scope, sha256(canonicalRequest)].joined(separator: "\n")
        let dateKey = hmac(Data(("TC3" + secretKey).utf8), day)
        let key = hmac(hmac(dateKey, service), "tc3_request")
        request.setValue("TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), SignedHeaders=\(headers), Signature=\(hex(hmac(key, toSign)))", forHTTPHeaderField: "Authorization")
    }
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
    static func signAWS(_ request: inout URLRequest, accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, region: String, service: String, now: Date) {
        let timestamp = date(now, "yyyyMMdd'T'HHmmss'Z'"); let day = date(now, "yyyyMMdd")
        request.setValue(request.url!.host!, forHTTPHeaderField: "Host"); request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        var headers = ["content-type", "host", "x-amz-date"]
        if request.value(forHTTPHeaderField: "X-Amz-Target") != nil { headers.append("x-amz-target") }
        if let token = sessionToken, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token"); headers.append("x-amz-security-token") }
        let (canonicalRequest, signed) = canonical(request, headers: headers)
        let scope = [day, region, service, "aws4_request"].joined(separator: "/")
        let toSign = ["AWS4-HMAC-SHA256", timestamp, scope, sha256(canonicalRequest)].joined(separator: "\n")
        let key = hmac(hmac(hmac(hmac(Data(("AWS4" + secretAccessKey).utf8), day), region), service), "aws4_request")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signed), Signature=\(hex(hmac(key, toSign)))", forHTTPHeaderField: "Authorization")
    }
    // https://github.com/volcengine/volc-sdk-python/blob/main/volcengine/auth/SignerV4.py
    static func signVolcano(_ request: inout URLRequest, accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, region: String, service: String, now: Date) {
        let timestamp = date(now, "yyyyMMdd'T'HHmmss'Z'"); let day = date(now, "yyyyMMdd")
        request.setValue(request.url!.host!, forHTTPHeaderField: "Host"); request.setValue(timestamp, forHTTPHeaderField: "X-Date")
        request.setValue(sha256(request.httpBody ?? Data()), forHTTPHeaderField: "X-Content-Sha256")
        var headers = ["content-type", "host", "x-content-sha256", "x-date"]
        if let token = sessionToken, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Security-Token"); headers.append("x-security-token") }
        let (canonicalRequest, signed) = canonical(request, headers: headers)
        let scope = [day, region, service, "request"].joined(separator: "/")
        let toSign = ["HMAC-SHA256", timestamp, scope, sha256(canonicalRequest)].joined(separator: "\n")
        let key = hmac(hmac(hmac(hmac(Data(secretAccessKey.utf8), day), region), service), "request")
        request.setValue("HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signed), Signature=\(hex(hmac(key, toSign)))", forHTTPHeaderField: "Authorization")
    }
    // https://help.aliyun.com/en/sdk/product-overview/v3-request-structure-and-signature
    static func signAliyun(_ request: inout URLRequest, accessKeyId: String, accessKeySecret: String, action: String, version: String, now: Date, nonce: String) {
        request.setValue(request.url!.host!, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-Acs-Action"); request.setValue(version, forHTTPHeaderField: "X-Acs-Version")
        request.setValue(date(now, "yyyy-MM-dd'T'HH:mm:ss'Z'"), forHTTPHeaderField: "X-Acs-Date")
        request.setValue(nonce, forHTTPHeaderField: "X-Acs-Signature-Nonce")
        request.setValue(sha256(request.httpBody ?? Data()), forHTTPHeaderField: "X-Acs-Content-Sha256")
        let headers = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }.filter { $0 == "host" || $0 == "content-type" || $0.hasPrefix("x-acs-") }
        let (canonicalRequest, signed) = canonical(request, headers: headers)
        let signature = hex(hmac(Data(accessKeySecret.utf8), "ACS3-HMAC-SHA256\n" + sha256(canonicalRequest)))
        request.setValue("ACS3-HMAC-SHA256 Credential=\(accessKeyId),SignedHeaders=\(signed),Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }
}

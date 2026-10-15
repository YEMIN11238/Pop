import Foundation

struct ExternalRequest {
    let path: String
    let action: String
    var text = ""
    var imageData: Data?
    var isSilent = false
    var source: String?
    var target: String?
    var windowLocation: String?
    var inputBoxState: String?

    static func parse(_ string: String) throws -> ExternalRequest {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return ExternalRequest(path: "translate", action: "translateText", text: string) }
        guard let data = trimmed.data(using: .utf8), data.count <= 48 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PopError.message("请求必须是 JSON 对象。") }
        let body = json["body"] as? [String: Any] ?? json
        let path = json["path"] as? String ?? "translate"
        let action = body["action"] as? String ?? (body["text"] != nil ? "translateText" : "showWindow")
        let allowed = path == "translate" ? ["selectionTranslate", "silentSelectionTranslate", "silentInputBoxTranslate", "snipTranslate", "inputTranslate", "pasteboardTranslate", "showWindow", "translateText", "translateImage", "imageTranslate", "translate"] : path == "ocr" ? ["snipOCR", "fileOCR", "pasteboardOCR", "showWindow", "ocrImage", "continuousOCR"] : []
        guard allowed.contains(action) else { throw PopError.message("不支持的脚本动作：\(path)/\(action)。") }
        var result = ExternalRequest(path: path, action: action, text: body["text"] as? String ?? "", isSilent: body["isSilent"] as? Bool ?? false)
        result.source = body["source"] as? String
        result.target = body["target"] as? String
        for (value, allowAuto) in [(result.source, true), (result.target, false)] {
            if let value, !LanguageCatalog.choices.contains(where: { $0.0 == value && (allowAuto || value != "auto") }) { throw PopError.message("脚本请求包含未知语言代码。") }
        }
        if let location = body["windowLocation"] as? String {
            guard ["mouse", "center", "statusIconBottom", "last"].contains(location) else { throw PopError.message("未知窗口位置策略。") }
            result.windowLocation = location
        }
        if let state = body["inputBoxState"] as? String {
            guard ["last", "alwaysFold", "alwaysUnfold"].contains(state) else { throw PopError.message("未知输入框状态。") }
            result.inputBoxState = state
        }
        if ["translateText", "translate"].contains(action), result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PopError.message("translateText 缺少非空 text。") }
        if ["translateImage", "ocrImage"].contains(action) {
            guard let encoded = body["imageBase64"] as? String, encoded.utf8.count <= 45 * 1024 * 1024,
                  let decoded = Data(base64Encoded: encoded), !decoded.isEmpty, decoded.count <= 32 * 1024 * 1024 else { throw PopError.message("imageBase64 无效或图片超过 32 MB。") }
            result.imageData = decoded
        }
        return result
    }
    static func reply(status: String, message: String? = nil) -> String {
        var value = ["status": status]
        if let message { value["message"] = message }
        return String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

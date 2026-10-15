import Foundation

/// Pure protocol fixtures. They do not load preferences, keys or real providers.
enum ProviderTranslationModelsSelfCheck {
    static func run() throws -> [String] {
        var checks: [String] = []
        try require(try ProviderTranslationModels.language("zh-Hant", mode: .qwenMT) == "zh_tw", "千问繁体 wire code")
        try require(try ProviderTranslationModels.language("zh-TW", mode: .doubaoTranslation) == "zh-Hant", "豆包繁体 wire code")
        try require(try ProviderTranslationModels.language("fa", mode: .qwenMT) == "fa" && ProviderTranslationModels.language("yue", mode: .qwenMT) == "yue", "千问语言表缺项")
        for code in ["auto", "yue", "unknown-language"] { try rejected { _ = try ProviderTranslationModels.language(code, mode: .doubaoTranslation) } }
        for provider in ["", "qwen", "azure", "aihubmix"] {
            let service = ServiceConfig(name: "fixture", kind: .openAI, model: "qwen-mt-plus", options: ["provider": provider])
            try require(ProviderTranslationModels.mode(service) == .qwenMT && ProviderTranslationModels.accumulatorKind(service) == "qwenMTCumulative", "共享 qwen-mt 模型分支遗漏 \(provider)")
        }
        checks.append("专用翻译模型：千问共享分支、传统中文 wire code、明确语言表与未知/auto目标拒绝通过")

        var full = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain")
        let response = snapshot(text: "你好", second: "！", reasoning: "核对")
        let output = try full.complete(response)
        try require(output.text == "你好！" && output.reasoning == "核对", "Responses 完整 output/summary 解析")
        checks.append("Responses：完整 JSON 多段正文、reasoning summary 与 completed 状态解析通过")

        var stream = CloudServiceAIAccumulator(kind: "openAIResponses", format: "markdown")
        var framing = CloudServiceSSEDecoder()
        var events: [(String, [String: Any])] = [
            ("response.created", ["type": "response.created", "response": ["status": "in_progress"]]),
            ("response.output_text.delta", ["output_index": 2, "content_index": 1, "delta": "！"]),
            ("response.output_text.delta", ["output_index": 2, "content_index": 0, "delta": "你"]),
            ("response.output_text.delta", ["output_index": 2, "content_index": 0, "delta": "好"]),
            ("response.output_text.done", ["output_index": 2, "content_index": 0, "text": "你好"]),
            ("response.reasoning_summary_text.delta", ["output_index": 0, "summary_index": 0, "delta": "核"]),
            ("response.reasoning_summary_text.delta", ["output_index": 0, "summary_index": 0, "delta": "对"]),
            ("response.reasoning_summary_text.done", ["output_index": 0, "summary_index": 0, "text": "核对"]),
            ("response.output_item.done", ["output_index": 0, "item": ["type": "reasoning", "summary": [["type": "summary_text", "text": "核对"]]]])
        ]
        // Deliberately receive content index1 before index0; wire indexes, rather
        // than network arrival order, define the visible text order.
        for (name, json) in events {
            let line = "event: \(name)\r\ndata: \(try serialized(json))\r\n\r\n"
            for byte in line.utf8 { if let event = try framing.append(byte) { _ = try stream.event(name: event.0, data: event.1) } }
        }
        try require(stream.output().text == "你好！" && stream.output().reasoning == "核对" && !stream.terminal, "流式索引顺序、UTF8、done/summary 去重")
        events = [("response.completed", ["type": "response.completed", "response": response])]
        for (name, json) in events { _ = try stream.event(name: name, data: serialized(json)) }
        let streamed = try stream.final()
        try require(streamed.text == output.text && streamed.reasoning == output.reasoning && streamed.format == "markdown", "完成快照重复拼接或格式丢失")
        checks.append("Responses SSE：逐字节 UTF8/CRLF、多索引顺序、delta/done/summary/最终快照无重复通过")

        for status in ["in_progress", "incomplete", "failed"] {
            var value = response; value["status"] = status; value["incomplete_details"] = ["reason": "max_output_tokens"]
            try rejected { var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain"); _ = try state.complete(value) }
        }
        let invalid: [[String: Any]] = [
            ["status": "completed", "output": []],
            ["status": "completed"],
            ["output": response["output"]!],
            ["status": "completed", "output": [["type": "reasoning", "summary": [["text": "只有思考"]]]]],
            ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "refusal", "refusal": "fixture refusal"]]]]],
            ["status": "completed", "output": [], "error": ["code": "AuthError", "message": "fixture error"]]
        ]
        for value in invalid { try rejected { var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain"); _ = try state.complete(value) } }
        checks.append("Responses：失败/未完成/缺状态/空输出/只有思考/拒绝/业务错误均明确失败通过")

        for event in [
            ("response.failed", ["type": "response.failed", "response": ["error": ["code": "fixture", "message": "failed"]]] as [String: Any]),
            ("response.incomplete", ["response": ["incomplete_details": ["reason": "max_output_tokens"]]]),
            ("error", ["type": "error", "code": "fixture", "message": "failed"]),
            ("response.refusal.delta", ["delta": "refused"]),
            ("response.completed", ["response": ["status": "completed", "output": []]])
        ] {
            try rejected {
                var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain")
                _ = try state.event(name: "response.output_text.delta", data: #"{"delta":"未完成"}"#)
                _ = try state.event(name: event.0, data: serialized(event.1)); _ = try state.final()
            }
        }
        try rejected { var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain"); _ = try state.event(name: "response.output_text.delta", data: #"{"delta":"半句"}"#); _ = try state.final() }
        try rejected { var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain"); _ = try state.event(name: "", data: "[DONE]") }
        try rejected { var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain"); _ = try state.event(name: "", data: "{invalid json}") }
        checks.append("Responses SSE：部分译文后的错误/不完整/拒绝/空完成/提前断流及提前DONE均不误报成功通过")

        var cumulative = CloudServiceAIAccumulator(kind: "qwenMTCumulative", format: "plain")
        for text in ["你", "你好", "你好好"] { _ = try cumulative.event(name: "", data: chat(text)) }
        _ = try cumulative.event(name: "", data: chat("", finished: true))
        try require(try cumulative.final().text == "你好好", "千问 Plus 全量片段重复累加")
        var incremental = CloudServiceAIAccumulator(kind: "openAI", format: "plain")
        for text in ["你", "好", "好"] { _ = try incremental.event(name: "", data: chat(text)) }
        _ = try incremental.event(name: "", data: chat("", finished: true))
        try require(try incremental.final().text == "你好好", "增量模式错误吞掉重复文字")
        checks.append("千问流式：Plus 累计片段替换，Flash/普通Chat增量片段保留重复文字通过")

        let ordinary: [(String, [String: Any])] = [
            ("openAI", ["choices": [["message": ["content": "你好"], "finish_reason": "stop"]]]),
            ("claude", ["content": [["type": "text", "text": "你好"]], "stop_reason": "end_turn"]),
            ("gemini", ["candidates": [["content": ["parts": [["text": "你好"]]], "finishReason": "STOP"]]])
        ]
        for (kind, value) in ordinary { var state = CloudServiceAIAccumulator(kind: kind, format: "plain"); try require(try state.complete(value).text == "你好", "普通 \(kind) 回归") }
        checks.append("普通协议回归：OpenAI Chat、Claude 与 Gemini 非流式正文解析通过")

        try rejected {
            var state = CloudServiceAIAccumulator(kind: "openAIResponses", format: "plain")
            _ = try state.event(name: "response.output_text.delta", data: serialized(["delta": String(repeating: "x", count: 8 * 1024 * 1024 + 1)]))
        }
        try rejected {
            var framing = CloudServiceSSEDecoder()
            for byte: UInt8 in [100, 97, 116, 97, 58, 32, 0xff, 10] { _ = try framing.append(byte) }
        }
        checks.append("模型传输边界：超过8MiB正文及无效UTF8流被拒绝通过")
        return checks
    }
    private static func snapshot(text: String, second: String, reasoning: String) -> [String: Any] {
        ["status": "completed", "output": [
            ["type": "reasoning", "summary": [["type": "summary_text", "text": reasoning]]],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text], ["type": "output_text", "text": second]]]
        ]]
    }
    private static func chat(_ text: String, finished: Bool = false) throws -> String {
        var choice: [String: Any] = ["delta": ["content": text]]
        if finished { choice["finish_reason"] = "stop" }
        return try serialized(["choices": [choice]])
    }
    private static func serialized(_ json: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self) }
    private static func rejected(_ operation: () throws -> Void) throws {
        do { try operation() } catch is HTTPTranslationError { return }
        throw PopError.message("专用翻译模型验收失败：错误响应被当作成功")
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw PopError.message("专用翻译模型验收失败：" + message) }
    }
}

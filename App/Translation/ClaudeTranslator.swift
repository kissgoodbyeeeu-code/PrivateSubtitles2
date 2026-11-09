import Foundation

/// 用 Claude Messages API（原始 HTTP + SSE 流式）把英文字幕译成中文。
/// Swift 没有官方 SDK，所以直接调 REST 接口。
struct ClaudeTranslator: SubtitleTranslator {
    let apiKey: String
    let model: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func translate(_ text: String, context: [TranslationContext]) -> AsyncThrowingStream<String, Error> {
        makeTranslationStream { continuation in
            try await run(text: text, context: context, continuation: continuation)
        }
    }

    private func run(text: String,
                     context: [TranslationContext],
                     continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            // 字幕翻译要低延迟：低 effort
            "output_config": ["effort": "low"],
            "system": TranslationPrompt.system,
            "messages": [
                ["role": "user", "content": TranslationPrompt.userContent(text: text, context: context)],
            ],
        ]
        // Haiku 可以完全关闭思考；Sonnet 5.5 / Opus 5.5 不允许 disabled（会 400），只靠低 effort
        if model.contains("haiku") {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw TranslatorError.http(http.statusCode, errorBody)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                // 只取正文；思考块（thinking_delta）忽略
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String {
                    continuation.yield(piece)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let stop = delta["stop_reason"] as? String,
                   stop == "refusal" {
                    throw TranslatorError.api("模型拒绝翻译这句")
                }
            case "error":
                let msg = (event["error"] as? [String: Any])?["message"] as? String ?? payload
                throw TranslatorError.api(msg)
            case "message_stop":
                return
            default:
                continue
            }
        }
    }
}

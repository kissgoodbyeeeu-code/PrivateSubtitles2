import Foundation

/// 用 Claude Messages API（原始 HTTP + SSE 流式）把英文字幕译成中文。
/// Swift 没有官方 SDK，所以直接调 REST 接口。
struct ClaudeTranslator {
    struct ContextPair {
        let english: String
        let chinese: String
    }

    enum TranslatorError: LocalizedError {
        case http(Int, String)
        case api(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
            case .api(let msg): return "API 错误: \(msg)"
            }
        }
    }

    let apiKey: String
    let model: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    你是专业的视频同声传译。把用户给出的一句英文字幕翻译成自然、简洁的简体中文字幕。
    规则：
    - 只输出译文本身，不要解释、注释、引号或原文。
    - 口语化、符合中文表达习惯，长度尽量接近原句。
    - 人名、品牌、专有名词用常见中文译法；没有通用译法的保留英文。
    - 语音识别可能有错字，结合上下文推断原意。
    """

    /// 返回中文增量片段的流。
    func translate(_ text: String, context: [ContextPair]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(text: text, context: context, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(text: String,
                     context: [ContextPair],
                     continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var userContent = ""
        if !context.isEmpty {
            userContent += "前文（仅供理解语境，不要翻译）：\n"
            for pair in context {
                userContent += "EN: \(pair.english)\nZH: \(pair.chinese)\n"
            }
            userContent += "\n"
        }
        userContent += "需要翻译的句子：\n\(text)"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            // 字幕翻译要低延迟：关闭思考、低 effort
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": userContent],
            ],
        ]

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

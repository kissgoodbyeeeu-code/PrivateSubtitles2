import Foundation

/// DeepSeek、通义千问、豆包都提供 OpenAI 兼容的 /chat/completions 接口，
/// 共用这一个实现，只是地址、Key、模型名和少量额外参数不同。
struct OpenAICompatibleTranslator: SubtitleTranslator {
    let endpoint: URL
    let apiKey: String
    let model: String
    /// 各家特有的参数（比如关闭思考）
    let extraBody: [String: Any]

    func translate(_ text: String, language: SourceLanguage, context: [TranslationContext]) -> AsyncThrowingStream<String, Error> {
        makeTranslationStream { continuation in
            try await run(text: text, language: language, context: context, continuation: continuation)
        }
    }

    private func run(text: String,
                     language: SourceLanguage,
                     context: [TranslationContext],
                     continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": 512,
            "messages": [
                ["role": "system", "content": TranslationPrompt.system],
                ["role": "user", "content": TranslationPrompt.userContent(text: text, language: language, context: context)],
            ],
        ]
        for (k, v) in extraBody { body[k] = v }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = event["error"] as? [String: Any] {
                throw TranslatorError.api(error["message"] as? String ?? payload)
            }
            guard let choices = event["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }
            // 只取正文 content；推理模型的 reasoning_content 忽略
            if let delta = first["delta"] as? [String: Any],
               let piece = delta["content"] as? String, !piece.isEmpty {
                continuation.yield(piece)
            }
            if let reason = first["finish_reason"] as? String, reason == "content_filter" {
                throw TranslatorError.api("内容被服务商过滤")
            }
        }
    }
}

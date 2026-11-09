import Foundation

/// 所有翻译引擎的统一接口：输入一句英文 + 前文，流式返回中文片段。
protocol SubtitleTranslator {
    func translate(_ text: String, context: [TranslationContext]) -> AsyncThrowingStream<String, Error>
}

struct TranslationContext {
    let english: String
    let chinese: String
}

enum TranslatorError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let engine): return "请先在设置里填写 \(engine) 的 API Key"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .api(let msg): return "API 错误: \(msg)"
        }
    }
}

/// 可选的翻译引擎
enum TranslationEngine: String, CaseIterable, Identifiable {
    case claude
    case deepseek
    case qwen
    case doubao

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .qwen: return "通义千问"
        case .doubao: return "豆包"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-haiku-5-5"
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .doubao: return "doubao-seed-1-6-flash-250615"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .claude: return "sk-ant-…"
        case .deepseek, .qwen: return "sk-…"
        case .doubao: return "火山方舟 API Key"
        }
    }

    var consoleURL: String {
        switch self {
        case .claude: return "console.anthropic.com/settings/keys"
        case .deepseek: return "platform.deepseek.com/api_keys"
        case .qwen: return "bailian.console.aliyun.com（API-KEY 管理）"
        case .doubao: return "console.volcengine.com/ark（API Key 管理）"
        }
    }

    var note: String {
        switch self {
        case .claude: return "国内需要代理。Haiku 最快最便宜；也可填 claude-sonnet-5-5 / claude-opus-5-5。"
        case .deepseek: return "国内直连，英译中质量好。"
        case .qwen: return "国内直连（阿里云百炼）。也可填 qwen-flash、qwen-max 等。"
        case .doubao: return "国内直连（火山方舟）。模型名以控制台「模型广场」里显示的 ID 为准，需要先开通该模型。"
        }
    }

    // 存储（Claude 沿用旧的 key，升级后不用重填）
    var keychainKey: String {
        self == .claude ? SettingsKeys.anthropicKey : "apiKey.\(rawValue)"
    }

    var modelDefaultsKey: String {
        self == .claude ? SettingsKeys.model : "model.\(rawValue)"
    }

    var apiKey: String? {
        Keychain.get(keychainKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    var model: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
    }

    static let storageKey = "translationEngine"

    static var current: TranslationEngine {
        UserDefaults.standard.string(forKey: storageKey).flatMap(TranslationEngine.init) ?? .claude
    }

    func makeTranslator() throws -> SubtitleTranslator {
        guard let key = apiKey else { throw TranslatorError.missingKey(title) }
        switch self {
        case .claude:
            return ClaudeTranslator(apiKey: key, model: model)
        case .deepseek:
            return OpenAICompatibleTranslator(
                endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                apiKey: key, model: model, extraBody: [:])
        case .qwen:
            return OpenAICompatibleTranslator(
                endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
                apiKey: key, model: model,
                extraBody: ["enable_thinking": false]) // 关闭思考，降低延迟
        case .doubao:
            return OpenAICompatibleTranslator(
                endpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!,
                apiKey: key, model: model,
                extraBody: ["thinking": ["type": "disabled"]]) // 关闭深度思考，降低延迟
        }
    }
}

/// 所有引擎共用的提示词
enum TranslationPrompt {
    static let system = """
    你是专业的视频同声传译。把用户给出的一句英文字幕翻译成自然、简洁的简体中文字幕。
    规则：
    - 只输出译文本身，不要解释、注释、引号或原文。
    - 口语化、符合中文表达习惯，长度尽量接近原句。
    - 人名、品牌、专有名词用常见中文译法；没有通用译法的保留英文。
    - 语音识别可能有错字，结合上下文推断原意。
    """

    static func userContent(text: String, context: [TranslationContext]) -> String {
        var content = ""
        if !context.isEmpty {
            content += "前文（仅供理解语境，不要翻译）：\n"
            for pair in context {
                content += "EN: \(pair.english)\nZH: \(pair.chinese)\n"
            }
            content += "\n"
        }
        content += "需要翻译的句子：\n\(text)"
        return content
    }
}

/// 把一个异步任务包装成流，取消流时取消任务。
func makeTranslationStream(
    _ body: @escaping (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

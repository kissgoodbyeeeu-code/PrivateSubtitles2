import Foundation

/// 所有翻译引擎的统一接口：输入一句外语原文 + 前文，流式返回中文片段。
protocol SubtitleTranslator {
    func translate(_ text: String, language: SourceLanguage, context: [TranslationContext]) -> AsyncThrowingStream<String, Error>
}

struct TranslationContext {
    let original: String
    let chinese: String
}

enum TranslatorError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case api(String)

    var isAuthError: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .missingKey(let engine): return "请先在设置里填写 \(engine) 的 API Key"
        case .http(401, _), .http(403, _):
            return "API Key 不对或已失效。通义千问 / 豆包：打开「海外节点」要用国际站的 Key，关掉则用国内的 Key"
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
        case .doubao: return isInternational ? "seed-1-6-flash-250615" : "doubao-seed-1-6-flash-250615"
        }
    }

    /// 通义千问、豆包有海外节点（国际站账号，Key 和国内不通用）
    var hasInternationalRegion: Bool { self == .qwen || self == .doubao }

    var regionDefaultsKey: String { "international.\(rawValue)" }

    var isInternational: Bool {
        hasInternationalRegion && UserDefaults.standard.bool(forKey: regionDefaultsKey)
    }

    var endpoint: URL {
        switch self {
        case .claude:
            return URL(string: "https://api.anthropic.com/v1/messages")!
        case .deepseek:
            return URL(string: "https://api.deepseek.com/chat/completions")!
        case .qwen:
            return isInternational
                ? URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!
                : URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        case .doubao:
            return isInternational
                ? URL(string: "https://ark.ap-southeast.bytepluses.com/api/v3/chat/completions")!
                : URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
        }
    }

    /// 开始同传时先连一下服务器，把 DNS / TLS 握手提前做掉，第一句翻译更快
    func warmUp() {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let started = Date()
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                log("预连接 \(title) 失败: \(error.localizedDescription)", level: "WARN")
            } else {
                log(String(format: "预连接 %@ 完成 %.2fs", title, Date().timeIntervalSince(started)))
            }
        }.resume()
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
        case .qwen: return isInternational ? "bailian.console.alibabacloud.com（国际站）" : "bailian.console.aliyun.com（API-KEY 管理）"
        case .doubao: return isInternational ? "console.byteplus.com/ark（BytePlus 国际站）" : "console.volcengine.com/ark（API Key 管理）"
        }
    }

    var note: String {
        switch self {
        case .claude: return "在海外（欧洲、美国）直连最快；国内需要代理。Haiku 最快最便宜；也可填 claude-sonnet-5-5 / claude-opus-5-5。"
        case .deepseek: return "服务器在国内，在海外用会慢一些。翻译质量好。"
        case .qwen: return "在海外请打开「海外节点」（新加坡，需国际站 Key）。也可填 qwen-flash、qwen-max 等。"
        case .doubao: return "在海外请打开「海外节点」（BytePlus 东南亚，需国际站 Key）。模型名以控制台显示的 ID 为准，需要先开通。"
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
            return OpenAICompatibleTranslator(endpoint: endpoint, apiKey: key, model: model, extraBody: [:])
        case .qwen:
            return OpenAICompatibleTranslator(
                endpoint: endpoint, apiKey: key, model: model,
                extraBody: ["enable_thinking": false]) // 关闭思考，降低延迟
        case .doubao:
            return OpenAICompatibleTranslator(
                endpoint: endpoint, apiKey: key, model: model,
                extraBody: ["thinking": ["type": "disabled"]]) // 关闭深度思考，降低延迟
        }
    }
}

/// 所有引擎共用的提示词
enum TranslationPrompt {
    static let system = """
    你是专业的视频同声传译。把用户给出的一句外语字幕（英语、日语、韩语或西班牙语）翻译成自然、简洁的简体中文字幕。
    规则：
    - 只输出译文本身，不要解释、注释、引号或原文。
    - 口语化、符合中文表达习惯，长度尽量接近原句。
    - 人名、品牌、专有名词用常见中文译法；没有通用译法的保留原文。
    - 语音识别可能有错字或同音误识，结合上下文推断原意。
    - 原文语言是自动识别的，如果看起来不是标注的语言，按实际语言翻译。
    """

    static func userContent(text: String, language: SourceLanguage, context: [TranslationContext]) -> String {
        var content = ""
        if !context.isEmpty {
            content += "前文（仅供理解语境，不要翻译）：\n"
            for pair in context {
                content += "原文: \(pair.original)\n译文: \(pair.chinese)\n"
            }
            content += "\n"
        }
        content += "需要翻译的句子（\(language.title)）：\n\(text)"
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

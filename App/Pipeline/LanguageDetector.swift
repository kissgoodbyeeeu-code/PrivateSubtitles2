import Foundation
import NaturalLanguage

/// 自动检测语言：几个语言的识别器同时听同一段声音，
/// 说对了语言的那个识别器，识别出的内容更多、置信度更高。
/// 在最近一段时间里累计「时长 × 置信度 × 文字像不像该语言」，得分明显领先就切换过去。
final class LanguageDetector {
    struct Sample {
        let language: SourceLanguage
        let text: String
        let time: Date
        let score: Double
    }

    private(set) var active: SourceLanguage
    private var samples: [Sample] = []

    /// 统计窗口
    private let window: TimeInterval = 12
    /// 切换门槛：候选得分要比当前语言高这么多倍
    private let switchRatio = 1.4
    private let minScore = 0.8

    init(initial: SourceLanguage) {
        active = initial
    }

    /// 记录一个定稿结果；返回 true 表示切换了语言
    @discardableResult
    func add(language: SourceLanguage, text: String, confidence: Double?, duration: Double) -> Bool {
        let now = Date()
        let score = (confidence ?? 0.5) * max(duration, 0.3) * Self.plausibility(text, language)
        samples.append(Sample(language: language, text: text, time: now, score: score))
        samples.removeAll { now.timeIntervalSince($0.time) > window }

        var totals: [SourceLanguage: Double] = [:]
        var counts: [SourceLanguage: Int] = [:]
        for s in samples {
            totals[s.language, default: 0] += s.score
            counts[s.language, default: 0] += 1
        }
        guard let (best, bestScore) = totals.max(by: { $0.value < $1.value }),
              best != active else { return false }
        let activeScore = totals[active] ?? 0
        if bestScore >= minScore,
           bestScore > activeScore * switchRatio,
           (counts[best] ?? 0) >= 2 {
            log(String(format: "检测到语言切换：%@ → %@（得分 %.2f vs %.2f）",
                       active.title, best.title, bestScore, activeScore))
            active = best
            return true
        }
        return false
    }

    /// 某语言最近窗口内的定稿句子（切换语言时补上，避免丢掉开头几句）
    func recentTexts(for language: SourceLanguage, within seconds: TimeInterval) -> [String] {
        let now = Date()
        return samples
            .filter { $0.language == language && now.timeIntervalSince($0.time) <= seconds }
            .map(\.text)
    }

    func reset() {
        samples.removeAll()
    }

    /// 文字本身像不像这种语言（0.4...1）。英语和西班牙语靠它区分得更准。
    private static func plausibility(_ text: String, _ language: SourceLanguage) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = SourceLanguage.detectable.map(\.nlLanguage)
        recognizer.processString(text)
        let p = recognizer.languageHypotheses(withMaximum: 4)[language.nlLanguage] ?? 0
        return 0.4 + 0.6 * p
    }
}

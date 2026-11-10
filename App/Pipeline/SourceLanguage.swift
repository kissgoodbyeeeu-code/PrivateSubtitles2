import Foundation
import NaturalLanguage

/// 视频原声语言。`auto` 会同时跑几种语言的识别，自动挑最像的那一种。
enum SourceLanguage: String, CaseIterable, Identifiable, Codable {
    case auto
    case english
    case japanese
    case korean
    case spanish

    var id: String { rawValue }

    /// 自动检测时参与比较的语言
    static let detectable: [SourceLanguage] = [.english, .japanese, .korean, .spanish]

    var title: String {
        switch self {
        case .auto: return "自动检测"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .spanish: return "西班牙语"
        }
    }

    /// 字幕旁边的小标签
    var tag: String {
        switch self {
        case .auto: return "AUTO"
        case .english: return "EN"
        case .japanese: return "JA"
        case .korean: return "KO"
        case .spanish: return "ES"
        }
    }

    var locale: Locale {
        switch self {
        case .auto, .english: return Locale(identifier: "en-US")
        case .japanese: return Locale(identifier: "ja-JP")
        case .korean: return Locale(identifier: "ko-KR")
        case .spanish: return Locale(identifier: "es-ES")
        }
    }

    var nlLanguage: NLLanguage {
        switch self {
        case .auto, .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .spanish: return .spanish
        }
    }

    /// 这次要启动哪些识别器
    var transcriberLanguages: [SourceLanguage] {
        self == .auto ? Self.detectable : [self]
    }

    static let storageKey = "sourceLanguage"
    /// 自动检测上次判断出的语言，下次从它开始
    static let lastDetectedKey = "lastDetectedLanguage"

    static var current: SourceLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SourceLanguage.init) ?? .auto
    }

    static var lastDetected: SourceLanguage {
        get {
            UserDefaults.standard.string(forKey: lastDetectedKey)
                .flatMap(SourceLanguage.init)
                .flatMap { detectable.contains($0) ? $0 : nil } ?? .english
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastDetectedKey) }
    }
}

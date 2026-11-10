import Foundation

enum AudioSource: String, CaseIterable, Identifiable {
    /// 广播扩展抓取的系统声音（任意 App 正在播放的声音）
    case system
    /// Safari 扩展抓取的网页视频声音（字幕直接显示在网页上，不用开直播）
    case safari
    /// 麦克风（外放 / 测试用）
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统声音"
        case .safari: return "Safari"
        case .microphone: return "麦克风"
        }
    }

    static let storageKey = "audioSource"

    static var current: AudioSource {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AudioSource.init) ?? .system
    }
}

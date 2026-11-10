import Foundation

/// 音频状态检查结果：没声音时给出提醒。
enum AudioHealth: Equatable {
    case ok
    /// 系统声音模式还没开始广播 / Safari 模式还没有网页连上
    case waitingConnection(AudioSource)
    /// 完全收不到音频数据
    case noAudioData(AudioSource)
    /// 有数据但一直很安静
    case silent(AudioSource)
    /// 有声音，但识别不出语音
    case noSpeech

    /// 收不到数据多久后提醒
    static let noDataAfter: TimeInterval = 3
    /// 一直安静多久后提醒
    static let silentAfter: TimeInterval = 8
    /// 有声音但没识别出语音多久后提醒
    static let noSpeechAfter: TimeInterval = 20

    /// App 里显示的提醒
    var message: String? {
        switch self {
        case .ok, .waitingConnection:
            return nil
        case .noAudioData(.system):
            return "没收到系统声音：广播可能已停止，请重新点 ⦿ 开始直播"
        case .noAudioData(.safari):
            return "没收到 Safari 的声音：视频暂停了，或者网页被切到后台了"
        case .noAudioData(.microphone):
            return "麦克风没有数据：可能被其他 App 占用了"
        case .silent(.system):
            return "没检测到声音：视频在播放吗？有版权保护的视频（如 Netflix、会员片）会被系统静音"
        case .silent(.safari):
            return "网页视频没有声音：视频静音了，或者这个网站不允许抓取声音"
        case .silent(.microphone):
            return "没检测到声音：请把外放声音开大，或让手机靠近声源"
        case .noSpeech:
            return "有声音，但没识别到语音（可能是音乐，或不是英/日/韩/西语，或识别语言选错了）"
        }
    }

    /// 悬浮窗 / 网页里显示的短提醒（空间小）
    var shortMessage: String? {
        switch self {
        case .ok: return nil
        case .waitingConnection(.safari): return "⚠︎ 还没有网页连上"
        case .waitingConnection: return "⚠︎ 还没开始广播"
        case .noAudioData(.system): return "⚠︎ 没收到声音：广播可能已停止"
        case .noAudioData(.safari): return "⚠︎ 没收到声音：视频暂停了？"
        case .noAudioData(.microphone): return "⚠︎ 麦克风没有数据"
        case .silent(.system): return "⚠︎ 没检测到声音（受版权保护的视频会被静音）"
        case .silent(.safari): return "⚠︎ 没检测到声音"
        case .silent(.microphone): return "⚠︎ 没检测到声音，请开大外放"
        case .noSpeech: return "⚠︎ 有声音，但没识别到语音"
        }
    }
}

import Foundation

/// 音频状态检查结果：没声音时给出提醒。
enum AudioHealth: Equatable {
    case ok
    /// 系统声音模式，还没开始广播
    case waitingBroadcast
    /// 完全收不到音频数据
    case noAudioData(AudioSource)
    /// 有数据但一直很安静
    case silent(AudioSource)
    /// 有声音，但识别不出英文语音
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
        case .ok, .waitingBroadcast:
            return nil
        case .noAudioData(.system):
            return "没收到系统声音：广播可能已停止，请重新点 ⦿ 开始直播"
        case .noAudioData(.microphone):
            return "麦克风没有数据：可能被其他 App 占用了"
        case .silent(.system):
            return "没检测到声音：视频在播放吗？有版权保护的视频（如 Netflix、会员片）会被系统静音"
        case .silent(.microphone):
            return "没检测到声音：请把外放声音开大，或让手机靠近声源"
        case .noSpeech:
            return "有声音，但没识别到英文语音（可能是音乐或非英语内容）"
        }
    }

    /// 悬浮窗里显示的短提醒（空间小）
    var shortMessage: String? {
        switch self {
        case .ok: return nil
        case .waitingBroadcast: return "⚠︎ 还没开始广播"
        case .noAudioData(.system): return "⚠︎ 没收到声音：广播可能已停止"
        case .noAudioData(.microphone): return "⚠︎ 麦克风没有数据"
        case .silent(.system): return "⚠︎ 没检测到声音（受版权保护的视频会被静音）"
        case .silent(.microphone): return "⚠︎ 没检测到声音，请开大外放"
        case .noSpeech: return "⚠︎ 有声音，但没识别到英文语音"
        }
    }
}

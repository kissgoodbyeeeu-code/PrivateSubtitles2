import AVFoundation

/// 「系统声音」模式下没有在录音，App 切到后台可能被挂起。
/// 循环播放静音并与其他 App 混音（不会打断其他 App 的视频声音），让主 App 一直在后台运行。
/// 被打断（别的 App 抢占声音、来电等）后会自动恢复。
final class SilentAudioPlayer {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var running = false
    private let watcher = AudioInterruptionWatcher(name: "后台保活")

    init() {
        watcher.onShouldRestart = { [weak self] in self?.restart() }
    }

    func start() throws {
        guard !running else { return }
        try startEngine()
        running = true
        log("后台保活已启动")
    }

    func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart() {
        guard running else { return }
        teardown()
        do {
            try startEngine()
            log("后台保活已恢复")
        } catch {
            logError("后台保活恢复失败: \(error.localizedDescription)")
        }
    }

    /// 每次都新建引擎：音频服务重置后旧引擎不可再用
    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(buffer.frameLength)) // 静音
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()

        self.engine = engine
        self.player = player
        watcher.start(engine: engine)
    }

    private func teardown() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}

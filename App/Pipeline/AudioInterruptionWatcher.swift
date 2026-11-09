import AVFoundation

/// 监听音频被打断（来电、别的 App 抢占声音、Siri 等）和音频服务重置，
/// 结束后回调 `onShouldRestart`，让播放器 / 麦克风自动恢复。
final class AudioInterruptionWatcher {
    /// 外部设置的恢复动作；实际调用经过 requestRestart 防抖
    var onShouldRestart: (() -> Void)?
    private var lastRestart = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private let name: String

    init(name: String) {
        self.name = name
    }

    func start(engine: AVAudioEngine) {
        stop()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(),
                                            queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("\(self.name)：系统音频服务重置，重新启动", level: "WARN")
            self.requestRestart()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("\(self.name)：音频设备变化（耳机插拔等），重新启动")
            self.requestRestart()
        })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// 1 秒内只重启一次，防止重启本身触发的设备变化通知造成循环
    private func requestRestart() {
        let now = Date()
        guard now.timeIntervalSince(lastRestart) > 1 else { return }
        lastRestart = now
        onShouldRestart?()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log("\(name)：被其他声音打断", level: "WARN")
        case .ended:
            log("\(name)：打断结束，自动恢复")
            // 稍等一下再恢复，避免和抢占方冲突
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.requestRestart()
            }
        @unknown default:
            break
        }
    }
}

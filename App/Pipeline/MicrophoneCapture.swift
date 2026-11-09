import AVFoundation

/// 麦克风音频源（外放、测试用）。
/// 被打断（来电、别的 App 占用麦克风等）或耳机插拔后会自动恢复。
final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var running = false
    private let watcher = AudioInterruptionWatcher(name: "麦克风")

    init() {
        watcher.onShouldRestart = { [weak self] in self?.restart() }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !running else { return }
        self.onBuffer = onBuffer
        try startEngine()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        teardown()
        onBuffer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart() {
        guard running else { return }
        teardown()
        do {
            try startEngine()
            log("麦克风已恢复")
        } catch {
            logError("麦克风恢复失败: \(error.localizedDescription)")
        }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log("麦克风格式: \(format.sampleRate)Hz, \(format.channelCount)ch")
        let handler = onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler?(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        watcher.start(engine: engine)
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

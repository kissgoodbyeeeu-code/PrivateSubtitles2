import AVFoundation
import Foundation
import Observation

/// 串起整条链路：音频 → 端侧识别 → 断句 → Claude 翻译 → 字幕状态。
@MainActor
@Observable
final class SubtitlePipeline {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var english: String
        var chinese: String = ""
        var isTranslating = false
        var error: String?
    }

    private(set) var lines: [Line] = []
    /// 正在说、还没定稿的英文（灰色显示）
    private(set) var volatileText = ""
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var status = "未开始"

    private(set) var activeSource: AudioSource?
    private(set) var broadcastConnected = false

    /// 输入音量 0...1（给电平条用）
    private(set) var audioLevel: Float = 0
    /// 声音状态：没声音 / 没识别到语音时给提醒
    private(set) var health: AudioHealth = .ok

    private let levelMonitor = AudioLevelMonitor()
    @ObservationIgnored private var healthTimer: Timer?
    /// 开始计算「多久没声音」的起点（麦克风：启动时；系统声音：广播连上时）
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var lastSpeechAt: Date?

    private let mic = MicrophoneCapture()
    private let receiver = SystemAudioReceiver()
    private let silentPlayer = SilentAudioPlayer()
    private var transcriber: LiveTranscriber?
    private let maxLines = 300
    private let contextSize = 3

    var latestLine: Line? { lines.last }

    /// 字幕变化时回调（英文, 中文, 英文是否未定稿），给画中画用
    @ObservationIgnored var onSubtitleChange: ((String, String, Bool) -> Void)?
    /// 电平 / 提醒变化时回调（电平 0...1, 悬浮窗提醒），给画中画用
    @ObservationIgnored var onStatusChange: ((Float, String?) -> Void)?

    private func notifySubtitleChange() {
        if !volatileText.isEmpty {
            // 正在说新的一句：显示新英文，中文先保留上一句的译文
            onSubtitleChange?(volatileText, latestLine?.chinese ?? "", true)
        } else {
            onSubtitleChange?(latestLine?.english ?? "", latestLine?.chinese ?? "", false)
        }
    }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        let engine = TranslationEngine.current
        guard engine.apiKey != nil else {
            status = "请先在设置里填写 \(engine.title) 的 API Key"
            return
        }
        isStarting = true
        defer { isStarting = false }

        let source = AudioSource.current
        if source == .microphone {
            guard await MicrophoneCapture.requestPermission() else {
                status = "没有麦克风权限，请到系统设置里打开"
                return
            }
        }
        guard await LiveTranscriber.requestPermission() else {
            status = "没有语音识别权限，请到系统设置里打开"
            return
        }

        let transcriber = LiveTranscriber()
        do {
            status = "准备语音模型…"
            try await transcriber.start(locale: Locale(identifier: "en-US")) { [weak self] update in
                Task { @MainActor in self?.handle(update) }
            }
            let monitor = levelMonitor
            monitor.reset()
            switch source {
            case .microphone:
                try mic.start { buffer in
                    monitor.process(buffer)
                    transcriber.append(buffer)
                }
                listeningSince = Date()
                status = "正在听（麦克风）…"
            case .system:
                try silentPlayer.start()
                receiver.onBuffer = { buffer in
                    monitor.process(buffer)
                    transcriber.append(buffer)
                }
                receiver.onConnectionChange = { [weak self] connected in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.broadcastConnected = connected
                        if connected {
                            monitor.reset()
                            self.listeningSince = Date()
                            self.lastSpeechAt = nil
                        }
                        self.status = connected ? "正在听（系统声音）…" : "等待广播：点下方 ⦿ 按钮开始广播"
                    }
                }
                try receiver.start()
                status = "等待广播：点下方 ⦿ 按钮开始广播"
            }
            self.transcriber = transcriber
            activeSource = source
            isRunning = true
            lastSpeechAt = nil
            startHealthChecks()
            log("管线已启动，音源: \(source.title)")
        } catch {
            mic.stop()
            receiver.stop()
            silentPlayer.stop()
            await transcriber.stop()
            status = "启动失败：\(error.localizedDescription)"
            logError("启动失败: \(error)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        mic.stop()
        receiver.stop()
        silentPlayer.stop()
        broadcastConnected = false
        activeSource = nil
        stopHealthChecks()
        await transcriber?.stop()
        transcriber = nil
        isRunning = false
        volatileText = ""
        status = "已停止"
        log("管线已停止")
    }

    func clear() {
        lines.removeAll()
        volatileText = ""
        notifySubtitleChange()
    }

    // MARK: - 声音检测

    private func startHealthChecks() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    private func stopHealthChecks() {
        healthTimer?.invalidate()
        healthTimer = nil
        listeningSince = nil
        audioLevel = 0
        health = .ok
        onStatusChange?(0, nil)
    }

    private func checkHealth() {
        guard isRunning, let source = activeSource else { return }
        let now = Date()
        let snap = levelMonitor.snapshot()

        // 超过 0.5 秒没新数据，电平归零
        let fresh = snap.lastBufferAt.map { now.timeIntervalSince($0) < 0.5 } ?? false
        let level = fresh ? AudioLevelMonitor.normalized(snap.rms) : 0

        let newHealth: AudioHealth
        if source == .system && !broadcastConnected {
            newHealth = .waitingBroadcast
        } else if let since = listeningSince {
            let lastData = snap.lastBufferAt ?? since
            let lastSound = snap.lastSoundAt ?? since
            let lastSpeech = max(lastSpeechAt ?? since, since)
            if now.timeIntervalSince(lastData) > AudioHealth.noDataAfter {
                newHealth = .noAudioData(source)
            } else if now.timeIntervalSince(lastSound) > AudioHealth.silentAfter {
                newHealth = .silent(source)
            } else if now.timeIntervalSince(lastSpeech) > AudioHealth.noSpeechAfter
                        && now.timeIntervalSince(lastSound) < 2 {
                newHealth = .noSpeech
            } else {
                newHealth = .ok
            }
        } else {
            newHealth = .ok
        }

        if newHealth != health {
            health = newHealth
            if let msg = newHealth.message {
                log("提醒：\(msg)", level: "WARN")
            } else {
                log("声音恢复正常")
            }
        }
        // 电平量化到 5%，避免无意义的刷新
        let quantized = (level * 20).rounded() / 20
        if quantized != audioLevel {
            audioLevel = quantized
        }
        onStatusChange?(audioLevel, health.shortMessage)
    }

    // MARK: - 识别结果处理

    private func handle(_ update: LiveTranscriber.Update) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lastSpeechAt = Date() }
        if update.isFinal {
            volatileText = ""
            guard !text.isEmpty else { return }
            appendLine(text)
        } else {
            volatileText = text
        }
        notifySubtitleChange()
    }

    private func appendLine(_ english: String) {
        let line = Line(english: english, isTranslating: true)
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        translate(lineID: line.id)
    }

    // MARK: - 翻译

    private func translate(lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        let english = lines[index].english
        let context = lines[..<index]
            .filter { !$0.chinese.isEmpty && $0.error == nil }
            .suffix(contextSize)
            .map { TranslationContext(english: $0.english, chinese: $0.chinese) }

        let engine = TranslationEngine.current
        let translator: SubtitleTranslator
        do {
            translator = try engine.makeTranslator()
        } catch {
            update(lineID) {
                $0.isTranslating = false
                $0.error = error.localizedDescription
            }
            return
        }
        let engineName = "\(engine.title)/\(engine.model)"
        let started = Date()

        Task {
            do {
                for try await piece in translator.translate(english, context: Array(context)) {
                    update(lineID) { $0.chinese += piece }
                }
                update(lineID) { $0.isTranslating = false }
                log(String(format: "[%@] 翻译完成 %.2fs: %@", engineName, Date().timeIntervalSince(started), english))
            } catch {
                update(lineID) {
                    $0.isTranslating = false
                    $0.error = error.localizedDescription
                }
                logError("[\(engineName)] 翻译失败: \(error.localizedDescription)")
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Line) -> Void) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[i])
        if lines[i].id == latestLine?.id { notifySubtitleChange() }
    }
}

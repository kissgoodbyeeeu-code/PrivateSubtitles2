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

    private let mic = MicrophoneCapture()
    private let receiver = SystemAudioReceiver()
    private let silentPlayer = SilentAudioPlayer()
    private var transcriber: LiveTranscriber?
    private let maxLines = 300
    private let contextSize = 3

    var latestLine: Line? { lines.last }

    /// 字幕变化时回调（英文, 中文, 英文是否未定稿），给画中画用
    @ObservationIgnored var onSubtitleChange: ((String, String, Bool) -> Void)?

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
        guard let key = Keychain.get(SettingsKeys.anthropicKey), !key.isEmpty else {
            status = "请先在设置里填写 Anthropic API Key"
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
            switch source {
            case .microphone:
                try mic.start { buffer in
                    transcriber.append(buffer)
                }
                status = "正在听（麦克风）…"
            case .system:
                try silentPlayer.start()
                receiver.onBuffer = { buffer in
                    transcriber.append(buffer)
                }
                receiver.onConnectionChange = { [weak self] connected in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.broadcastConnected = connected
                        self.status = connected ? "正在听（系统声音）…" : "等待广播：点下方 ⦿ 按钮开始广播"
                    }
                }
                try receiver.start()
                status = "等待广播：点下方 ⦿ 按钮开始广播"
            }
            self.transcriber = transcriber
            activeSource = source
            isRunning = true
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

    // MARK: - 识别结果处理

    private func handle(_ update: LiveTranscriber.Update) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .map { ClaudeTranslator.ContextPair(english: $0.english, chinese: $0.chinese) }

        let apiKey = Keychain.get(SettingsKeys.anthropicKey) ?? ""
        let model = UserDefaults.standard.string(forKey: SettingsKeys.model)
            .flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKeys.defaultModel
        let translator = ClaudeTranslator(apiKey: apiKey, model: model)
        let started = Date()

        Task {
            do {
                for try await piece in translator.translate(english, context: Array(context)) {
                    update(lineID) { $0.chinese += piece }
                }
                update(lineID) { $0.isTranslating = false }
                log(String(format: "翻译完成 %.2fs: %@", Date().timeIntervalSince(started), english))
            } catch {
                update(lineID) {
                    $0.isTranslating = false
                    $0.error = error.localizedDescription
                }
                logError("翻译失败: \(error.localizedDescription)")
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Line) -> Void) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[i])
        if lines[i].id == latestLine?.id { notifySubtitleChange() }
    }
}

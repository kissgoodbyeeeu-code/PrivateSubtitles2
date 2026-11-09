import AVFoundation
import Speech

/// iOS 26 端侧英文语音识别（SpeechAnalyzer + SpeechTranscriber）。
/// 免费、离线；第一次使用会自动下载英文模型。
final class LiveTranscriber {
    struct Update: Sendable {
        let text: String
        let isFinal: Bool
    }

    enum TranscriberError: LocalizedError {
        case localeNotSupported(String)
        var errorDescription: String? {
            switch self {
            case .localeNotSupported(let id): return "本机不支持识别语言 \(id)"
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start(locale: Locale, onUpdate: @escaping @Sendable (Update) -> Void) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        try await ensureModel(transcriber: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        analyzerFormat = format
        log("识别模型音频格式: \(format.map { "\($0.sampleRate)Hz \($0.channelCount)ch" } ?? "未知")")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    onUpdate(Update(text: text, isFinal: result.isFinal))
                }
            } catch {
                logError("识别结果流出错: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        log("语音识别已启动 (\(locale.identifier))")
    }

    /// 在音频线程调用。
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation else { return }
        do {
            let converted = try analyzerFormat.map { try converter.convert(buffer, to: $0) } ?? buffer
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            logError("音频格式转换失败: \(error)")
        }
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            logError("结束识别出错: \(error.localizedDescription)")
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        log("语音识别已停止")
    }

    private func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw TranscriberError.localeNotSupported(wanted)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log("正在下载英文语音模型…")
            try await request.downloadAndInstall()
            log("英文语音模型下载完成")
        }
    }
}

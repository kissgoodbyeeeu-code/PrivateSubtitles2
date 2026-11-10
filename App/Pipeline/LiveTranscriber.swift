import AVFoundation
import CoreMedia
import Speech

/// iOS 26 端侧语音识别（SpeechAnalyzer + SpeechTranscriber），一个实例识别一种语言。
/// 免费、离线；第一次使用某种语言会自动下载对应模型。
final class LiveTranscriber {
    struct Update: Sendable {
        let language: SourceLanguage
        let text: String
        let isFinal: Bool
        /// 平均置信度 0...1（拿不到时为 nil）
        let confidence: Double?
        /// 这段语音的时长（秒）
        let duration: Double
    }

    enum TranscriberError: LocalizedError {
        case localeNotSupported(String)
        var errorDescription: String? {
            switch self {
            case .localeNotSupported(let id): return "本机不支持识别语言 \(id)"
            }
        }
    }

    let language: SourceLanguage
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private let converter = BufferConverter()

    init(language: SourceLanguage) {
        self.language = language
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start(onUpdate: @escaping @Sendable (Update) -> Void) async throws {
        let locale = language.locale
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence]
        )

        try await ensureModel(transcriber: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let language = self.language
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    onUpdate(Update(language: language,
                                    text: text,
                                    isFinal: result.isFinal,
                                    confidence: result.isFinal ? Self.averageConfidence(result.text) : nil,
                                    duration: result.range.duration.seconds.isFinite ? result.range.duration.seconds : 0))
                }
            } catch {
                logError("[\(language.title)] 识别结果流出错: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        log("语音识别已启动 (\(locale.identifier))，格式 \(format.map { "\($0.sampleRate)Hz" } ?? "未知")")
    }

    /// 按字数加权的平均置信度
    private static func averageConfidence(_ text: AttributedString) -> Double? {
        var total = 0.0
        var weight = 0.0
        for run in text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let n = Double(text[run.range].characters.count)
            total += c * n
            weight += n
        }
        return weight > 0 ? total / weight : nil
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
    }

    private func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw TranscriberError.localeNotSupported(wanted)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log("正在下载\(language.title)语音模型…")
            try await request.downloadAndInstall()
            log("\(language.title)语音模型下载完成")
        }
    }
}

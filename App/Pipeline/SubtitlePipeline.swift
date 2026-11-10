import AVFoundation
import Foundation
import Observation

/// 串起整条链路：音频 → 端侧识别（可自动检测语言）→ 断句 → 大模型翻译 → 字幕状态。
@MainActor
@Observable
final class SubtitlePipeline {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var original: String
        var language: SourceLanguage
        var createdAt = Date()
        var chinese: String = ""
        /// 边说边翻时的草稿译文，正式译文出来前先显示它
        var draft: String = ""
        var isTranslating = false
        var error: String?

        var displayChinese: String { chinese.isEmpty ? draft : chinese }
    }

    /// 字幕当前要显示的内容：当前一句 + 前两句（共三行译文）
    struct Snapshot: Equatable {
        var original = ""
        var chinese = ""
        var isVolatile = false
        /// 前两句的译文，旧的在前
        var previousChinese: [String] = []
    }

    private(set) var lines: [Line] = []
    /// 正在说、还没定稿的原文（灰色显示）
    private(set) var volatileText = ""
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var status = "未开始"

    private(set) var activeSource: AudioSource?
    private(set) var broadcastConnected = false
    /// 当前识别的语言（自动检测时会变化）
    private(set) var currentLanguage: SourceLanguage?
    /// 这次是否开启了自动检测
    private(set) var isAutoDetect = false

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
    private let safariServer = SafariAudioServer()
    /// 上次发给网页的提醒（变了才重发）
    @ObservationIgnored private var lastSentWarning: String?? = .none
    private let silentPlayer = SilentAudioPlayer()
    private var transcribers: [LiveTranscriber] = []
    @ObservationIgnored private var detector: LanguageDetector?
    private let maxLines = 300
    private let contextSize = 3

    var latestLine: Line? { lines.last }

    /// 字幕变化时回调，给画中画用
    @ObservationIgnored var onSubtitleChange: ((Snapshot) -> Void)?
    /// 电平 / 提醒变化时回调（电平 0...1, 悬浮窗提醒），给画中画用
    @ObservationIgnored var onStatusChange: ((Float, String?) -> Void)?

    private func notifySubtitleChange() {
        var snap = Snapshot()
        let previous: [Line]
        if !volatileText.isEmpty {
            // 正在说新的一句：当前显示正在说的原文 + 草稿译文，上一句留着
            snap.original = volatileText
            snap.chinese = draftChinese
            snap.isVolatile = true
            previous = Array(lines.suffix(2))
        } else if let latest = latestLine {
            snap.original = latest.original
            snap.chinese = latest.displayChinese
            previous = Array(lines.dropLast().suffix(2))
        } else {
            previous = []
        }
        snap.previousChinese = previous.map(\.displayChinese).filter { !$0.isEmpty }
        onSubtitleChange?(snap)
        if activeSource == .safari {
            safariServer.send(["type": "sub",
                               "original": snap.original, "chinese": snap.chinese, "volatile": snap.isVolatile,
                               "prevChinese": snap.previousChinese])
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
        engine.warmUp()

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

        let languageSetting = SourceLanguage.current
        var started: [LiveTranscriber] = []
        do {
            for language in languageSetting.transcriberLanguages {
                status = "准备\(language.title)语音模型…（第一次需要下载）"
                let t = LiveTranscriber(language: language)
                do {
                    try await t.start { [weak self] update in
                        Task { @MainActor in self?.handle(update) }
                    }
                    started.append(t)
                } catch {
                    // 自动检测时某种语言起不来就跳过，其他语言照常
                    guard languageSetting == .auto else { throw error }
                    logError("\(language.title)识别启动失败，自动检测将跳过它: \(error.localizedDescription)")
                }
            }
            guard !started.isEmpty else {
                throw LiveTranscriber.TranscriberError.localeNotSupported("全部语言")
            }
            isAutoDetect = languageSetting == .auto && started.count > 1
            let available = started.map(\.language)
            let initial = available.contains(SourceLanguage.lastDetected) && languageSetting == .auto
                ? SourceLanguage.lastDetected
                : available[0]
            currentLanguage = initial
            detector = isAutoDetect ? LanguageDetector(initial: initial) : nil
            if isAutoDetect {
                log("自动检测语言：\(available.map(\.title).joined(separator: "、"))，先按\(initial.title)显示")
            }

            let transcribers = started
            let monitor = levelMonitor
            monitor.reset()
            switch source {
            case .microphone:
                try mic.start { buffer in
                    monitor.process(buffer)
                    for t in transcribers { t.append(buffer) }
                }
                listeningSince = Date()
                status = "正在听（麦克风）…"
            case .system, .safari:
                // 主 App 在后台要一直活着才能收声音
                try silentPlayer.start()
                let waitText = source == .system
                    ? "等待广播：点下方 ⦿ 按钮开始广播"
                    : "等待 Safari：在网页视频右上角点「译」"
                let listenText = source == .system ? "正在听（系统声音）…" : "正在听（Safari 网页）…"
                let onBuffer: (AVAudioPCMBuffer) -> Void = { buffer in
                    monitor.process(buffer)
                    for t in transcribers { t.append(buffer) }
                }
                let onConnection: (Bool) -> Void = { [weak self] connected in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.broadcastConnected = connected
                        if connected {
                            monitor.reset()
                            self.listeningSince = Date()
                            self.lastSpeechAt = nil
                            // 新网页连上：把当前字幕和提醒补发一次
                            self.lastSentWarning = .none
                            self.notifySubtitleChange()
                        }
                        self.status = connected ? listenText : waitText
                    }
                }
                if source == .system {
                    receiver.onBuffer = onBuffer
                    receiver.onConnectionChange = onConnection
                    try receiver.start()
                } else {
                    safariServer.onBuffer = onBuffer
                    safariServer.onConnectionChange = onConnection
                    try safariServer.start()
                }
                status = waitText
            }
            self.transcribers = transcribers
            activeSource = source
            isRunning = true
            lastSpeechAt = nil
            startHealthChecks()
            log("管线已启动，音源: \(source.title)")
        } catch {
            mic.stop()
            receiver.stop()
            safariServer.stop()
            silentPlayer.stop()
            for t in started { await t.stop() }
            currentLanguage = nil
            isAutoDetect = false
            detector = nil
            status = "启动失败：\(error.localizedDescription)"
            logError("启动失败: \(error)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        mic.stop()
        receiver.stop()
        safariServer.stop()
        silentPlayer.stop()
        broadcastConnected = false
        activeSource = nil
        stopHealthChecks()
        for t in transcribers { await t.stop() }
        transcribers = []
        detector = nil
        currentLanguage = nil
        isAutoDetect = false
        isRunning = false
        volatileText = ""
        committedText = ""
        lastVolatileAt = nil
        resetDraft()
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
        commitOnPause(now: now)
        let snap = levelMonitor.snapshot()

        // 超过 0.5 秒没新数据，电平归零
        let fresh = snap.lastBufferAt.map { now.timeIntervalSince($0) < 0.5 } ?? false
        let level = fresh ? AudioLevelMonitor.normalized(snap.rms) : 0

        let newHealth: AudioHealth
        if source != .microphone && !broadcastConnected {
            newHealth = .waitingConnection(source)
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
        if source == .safari && broadcastConnected {
            let warning = health.shortMessage
            if lastSentWarning != .some(warning) {
                lastSentWarning = .some(warning)
                safariServer.send(["type": "status", "warning": warning ?? NSNull()])
            }
        }
    }

    // MARK: - 识别结果处理

    private func handle(_ update: LiveTranscriber.Update) {
        guard isRunning else { return }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 自动检测：所有语言的定稿结果都参与打分
        if update.isFinal, !text.isEmpty, let detector {
            let previous = detector.active
            if detector.add(language: update.language, text: text,
                            confidence: update.confidence, duration: update.duration) {
                switchLanguage(from: previous, to: detector.active, detector: detector)
                return
            }
        }

        // 只显示当前语言的识别结果
        guard update.language == currentLanguage else { return }
        if !text.isEmpty { lastSpeechAt = Date() }
        if update.isFinal {
            // 识别器定稿：只翻译还没提前送出去的那部分
            let rest = Self.remainder(of: text, after: committedText)
            // 定稿可能只覆盖了提前提交内容的前一部分，剩下的留着给下一次定稿抵扣
            committedText = Self.remainder(of: committedText, after: text)
            volatileText = ""
            lastVolatileAt = nil
            if !rest.isEmpty { appendLine(rest, language: update.language) }
        } else {
            lastVolatileAt = Date()
            var rest = Self.remainder(of: text, after: committedText)
            // 句子已经说完（出现句号、问号等，后面又开始了新内容）：不等定稿，先送去翻译
            if let cut = Self.sentenceBoundary(in: rest) {
                commitEarly(String(rest[..<cut]), language: update.language)
                rest = Self.remainder(of: text, after: committedText)
            }
            volatileText = rest
            startDraftIfNeeded()
        }
        notifySubtitleChange()
    }

    // MARK: - 提前断句（降低延迟）

    /// 本段语音里已经提前送去翻译的文字
    @ObservationIgnored private var committedText = ""
    @ObservationIgnored private var lastVolatileAt: Date?
    /// 说话停顿多久就不等识别器定稿，直接翻译
    private let pauseCommitAfter: TimeInterval = 1.2
    /// 太短的半句不单独成句（字母/汉字数），等后面的内容一起
    private static let minSentenceLength = 10

    private func commitEarly(_ text: String, language: SourceLanguage) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.contentCount(sentence) > 0 else { return }
        committedText = committedText.isEmpty ? sentence : committedText + " " + sentence
        appendLine(sentence, language: language)
    }

    /// 由 0.2 秒的定时器调用：停顿超过阈值就把正在说的内容提前翻译
    private func commitOnPause(now: Date) {
        guard !volatileText.isEmpty, let language = currentLanguage,
              Self.contentCount(volatileText) >= Self.minSentenceLength,
              let last = lastVolatileAt, now.timeIntervalSince(last) >= pauseCommitAfter else { return }
        commitEarly(volatileText, language: language)
        volatileText = ""
        lastVolatileAt = nil
        notifySubtitleChange()
    }

    /// 字母和数字的个数（忽略空格、标点，比较识别结果时更稳）
    private static func contentCount<S: StringProtocol>(_ s: S) -> Int {
        s.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }

    /// 去掉 text 开头已经提交过的部分（按字母数字个数对齐，识别器小改几个词也不会重复）
    private static func remainder(of text: String, after committed: String) -> String {
        let n = contentCount(committed)
        var idx = text.startIndex
        var seen = 0
        while idx < text.endIndex && seen < n {
            if text[idx].isLetter || text[idx].isNumber { seen += 1 }
            idx = text.index(after: idx)
        }
        var rest = text[idx...]
        while let c = rest.first, c.isWhitespace || c.isPunctuation { rest = rest.dropFirst() }
        return String(rest)
    }

    /// 最后一个「句末标点 + 后面已有新内容」的位置（返回标点之后的位置）
    private static func sentenceBoundary(in text: String) -> String.Index? {
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var result: String.Index?
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(after: idx)
            if enders.contains(text[idx]), next < text.endIndex {
                let after = text[next]
                // 英文等要求标点后有空格（避免 3.5、U.S. 被拆开）；中日文不需要
                let isCJKEnd = "。？！".contains(text[idx])
                if (isCJKEnd || after.isWhitespace),
                   contentCount(text[next...]) > 0,
                   contentCount(text[..<idx]) >= minSentenceLength {
                    result = next
                }
            }
            idx = next
        }
        return result
    }

    /// 切换语言：撤掉旧语言刚才识别出的几句（多半是乱码），补上新语言最近的几句
    private func switchLanguage(from old: SourceLanguage, to new: SourceLanguage, detector: LanguageDetector) {
        let recentWindow: TimeInterval = 10
        let now = Date()
        lines.removeAll { $0.language == old && now.timeIntervalSince($0.createdAt) < recentWindow }
        currentLanguage = new
        SourceLanguage.lastDetected = new
        volatileText = ""
        committedText = ""
        lastVolatileAt = nil
        resetDraft()
        lastSpeechAt = now
        for text in detector.recentTexts(for: new, within: recentWindow) {
            appendLine(text, language: new)
        }
        notifySubtitleChange()
    }

    private func appendLine(_ text: String, language: SourceLanguage) {
        var line = Line(original: text, language: language, isTranslating: true)
        // 草稿正好就是这句：直接用，不用再请求一次
        let draftMatches = !draftChinese.isEmpty && draftTask == nil
            && Self.contentCount(draftSource) == Self.contentCount(text)
            && Self.remainder(of: text, after: draftSource).isEmpty
        if draftMatches {
            line.chinese = draftChinese
            line.isTranslating = false
        } else {
            line.draft = draftChinese
        }
        resetDraft()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        if !draftMatches { translate(lineID: line.id) }
    }

    // MARK: - 边说边翻（草稿）

    /// 正在说的那句的草稿译文
    @ObservationIgnored private var draftChinese = ""
    /// draftChinese 对应的原文
    @ObservationIgnored private var draftSource = ""
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var draftGeneration = 0
    @ObservationIgnored private var lastDraftStart = Date.distantPast

    static let liveDraftKey = "liveDraftTranslation"
    private var liveDraftEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.liveDraftKey) as? Bool ?? true
    }

    private func resetDraft() {
        draftTask?.cancel()
        draftTask = nil
        draftGeneration += 1
        draftChinese = ""
        draftSource = ""
    }

    /// 话还没说完就先翻一版，字幕几乎和声音同时出来；说完后再用正式译文替换
    private func startDraftIfNeeded() {
        guard liveDraftEnabled, draftTask == nil, let language = currentLanguage else { return }
        let text = volatileText
        guard Self.contentCount(text) >= 6,
              Self.remainder(of: text, after: draftSource).count >= 2 || draftSource.isEmpty,
              Date().timeIntervalSince(lastDraftStart) >= 0.4,
              let translator = try? TranslationEngine.current.makeTranslator() else { return }
        let context = lines.filter { !$0.chinese.isEmpty && $0.error == nil }
            .suffix(contextSize)
            .map { TranslationContext(original: $0.original, chinese: $0.chinese) }
        lastDraftStart = Date()
        let generation = draftGeneration
        draftTask = Task { [weak self] in
            var out = ""
            do {
                for try await piece in translator.translate(text, language: language, context: Array(context)) {
                    out += piece
                    guard let self, self.draftGeneration == generation else { return }
                    // 新草稿追上旧草稿的长度再替换，避免字幕一闪一闪
                    if out.count >= self.draftChinese.count {
                        self.draftChinese = out
                        self.notifySubtitleChange()
                    }
                }
            } catch {
                // 草稿失败无所谓，等正式翻译
            }
            guard let self, self.draftGeneration == generation else { return }
            if !out.isEmpty {
                self.draftChinese = out
                self.draftSource = text
            }
            self.draftTask = nil
            self.notifySubtitleChange()
            // 期间又说了新内容：接着翻下一版
            self.startDraftIfNeeded()
        }
    }

    // MARK: - 翻译

    private func translate(lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        let original = lines[index].original
        let language = lines[index].language
        let context = lines[..<index]
            .filter { !$0.chinese.isEmpty && $0.error == nil }
            .suffix(contextSize)
            .map { TranslationContext(original: $0.original, chinese: $0.chinese) }

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
                var firstPieceAt: Date?
                for try await piece in translator.translate(original, language: language, context: Array(context)) {
                    if firstPieceAt == nil { firstPieceAt = Date() }
                    update(lineID) { $0.chinese += piece }
                }
                update(lineID) { $0.isTranslating = false }
                log(String(format: "[%@] 翻译完成：首字 %.2fs，全部 %.2fs: %@", engineName,
                           (firstPieceAt ?? Date()).timeIntervalSince(started),
                           Date().timeIntervalSince(started), original))
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

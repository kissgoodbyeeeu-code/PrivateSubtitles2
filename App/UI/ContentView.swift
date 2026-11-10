import SwiftUI

struct ContentView: View {
    @Environment(SubtitlePipeline.self) private var pipeline
    @Environment(PiPSubtitleController.self) private var pip
    @AppStorage(AudioSource.storageKey) private var source: AudioSource = .system
    @State private var showSettings = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("音源", selection: $source) {
                    ForEach(AudioSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .disabled(pipeline.isRunning || pipeline.isStarting)
                statusBar
                warningBanner
                PiPLayerView(controller: pip)
                    .aspectRatio(pip.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                pipHint
                Divider()
                historyList
                controlBar
            }
            .navigationTitle("双语字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLog = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLog) { LogView() }
            .onChange(of: pipeline.activeSource) {
                pip.setAutoStart(pipeline.activeSource != .safari)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pipeline.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(pipeline.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let lang = pipeline.currentLanguage {
                Text(pipeline.isAutoDetect ? "自动·\(lang.title)" : lang.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .animation(.default, value: lang)
            }
            if pipeline.isRunning {
                LevelMeter(level: pipeline.audioLevel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var warningBanner: some View {
        if let message = pipeline.health.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .transition(.opacity)
        }
    }

    private var pipHint: some View {
        Group {
            if !pip.isSupported {
                Text("此设备不支持画中画")
            } else if pip.isActive {
                Text("悬浮字幕已打开，可以切到其他 App 看视频了")
            } else if source == .safari && !pipeline.isRunning {
                Text("第一次用：系统设置 → App → Safari → 扩展 → 打开「双语字幕」，网站权限选「允许」。然后点「开始同传」，去 Safari 播放视频，点视频右上角的「译」")
            } else if pipeline.activeSource == .safari && !pipeline.broadcastConnected {
                Text("去 Safari 播放视频，点视频右上角的「译」。字幕会直接显示在网页视频上")
            } else if pipeline.activeSource == .safari {
                Text("字幕显示在网页视频上。视频全屏时看不到网页字幕，可以点下方按钮打开悬浮字幕")
            } else if pipeline.activeSource == .system && !pipeline.broadcastConnected {
                Text("点 ⦿ →「开始直播」，然后切到任意 App 播放视频")
            } else if pipeline.isRunning {
                Text("切到后台会自动弹出悬浮字幕，也可点下方按钮手动打开")
            } else {
                Text("开始同传后可打开悬浮字幕")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            List(pipeline.lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.language.tag)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(line.original)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let error = line.error {
                        Text("翻译失败：\(error)").font(.caption).foregroundStyle(.red)
                    } else {
                        Text(line.chinese.isEmpty && line.isTranslating ? "…" : line.chinese)
                            .font(.body)
                    }
                }
                .id(line.id)
            }
            .listStyle(.plain)
            .onChange(of: pipeline.lines.count) {
                if let last = pipeline.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                pipeline.clear()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .disabled(pipeline.lines.isEmpty)

            Button {
                pip.toggle()
            } label: {
                Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                    .frame(width: 44, height: 44)
            }
            .disabled(!pip.isPossible && !pip.isActive)

            if pipeline.activeSource == .system {
                BroadcastPickerButton()
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(pipeline.broadcastConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                            .allowsHitTesting(false)
                    }
            }

            Button {
                Task { await pipeline.toggle() }
            } label: {
                Label(pipeline.isRunning ? "停止" : (pipeline.isStarting ? "启动中…" : "开始同传"),
                      systemImage: pipeline.isRunning ? "stop.fill" : "waveform")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(pipeline.isRunning ? .red : .accentColor)
            .disabled(pipeline.isStarting)
        }
        .padding(16)
    }
}


/// 输入音量电平条：有声音时绿色跳动
struct LevelMeter: View {
    let level: Float
    private let bars = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let lit = Float(i) < level * Float(bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .frame(height: 18, alignment: .bottom)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityLabel("输入音量")
    }
}

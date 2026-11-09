import SwiftUI

struct ContentView: View {
    @Environment(SubtitlePipeline.self) private var pipeline
    @Environment(PiPSubtitleController.self) private var pip
    @State private var showSettings = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var pipHint: some View {
        Group {
            if !pip.isSupported {
                Text("此设备不支持画中画")
            } else if pip.isActive {
                Text("悬浮字幕已打开，可以切到 Safari 看视频了")
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
                    Text(line.english)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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


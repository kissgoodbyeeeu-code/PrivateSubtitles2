import SwiftUI

struct ContentView: View {
    @Environment(SubtitlePipeline.self) private var pipeline
    @AppStorage(SettingsKeys.fontSize) private var fontSize: Double = 22
    @State private var showSettings = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                CurrentSubtitleView(line: pipeline.latestLine,
                                    volatileText: pipeline.volatileText,
                                    fontSize: fontSize)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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

/// 当前字幕：上英下中。P2 会把同样的排版画进画中画悬浮窗。
struct CurrentSubtitleView: View {
    let line: SubtitlePipeline.Line?
    let volatileText: String
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !volatileText.isEmpty {
                Text(volatileText)
                    .font(.system(size: fontSize * 0.75))
                    .foregroundStyle(.white.opacity(0.6))
            } else if let line {
                Text(line.english)
                    .font(.system(size: fontSize * 0.75))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(line?.chinese.isEmpty == false ? line!.chinese : " ")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.yellow)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(16)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeOut(duration: 0.15), value: line?.chinese)
    }
}

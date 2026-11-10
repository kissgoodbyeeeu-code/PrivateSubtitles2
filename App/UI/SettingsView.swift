import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TranslationEngine.storageKey) private var engine: TranslationEngine = .claude
    @AppStorage(SettingsKeys.fontSize) private var fontSize: Double = 22
    @AppStorage(SourceLanguage.storageKey) private var sourceLanguage: SourceLanguage = .auto

    /// 每个引擎各自的 Key 和模型，切换引擎时不会互相覆盖
    @State private var keys: [TranslationEngine: String] = [:]
    @State private var models: [TranslationEngine: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("翻译引擎", selection: $engine) {
                        ForEach(TranslationEngine.allCases) { e in
                            HStack {
                                Text(e.title)
                                if !(keys[e] ?? "").isEmpty {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .tag(e)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("翻译引擎")
                } footer: {
                    Text(engine.note)
                }

                Section {
                    SecureField(engine.keyPlaceholder, text: binding(for: engine, in: $keys))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(engine.defaultModel, text: binding(for: engine, in: $models))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("\(engine.title) 的 API Key 和模型")
                } footer: {
                    Text("Key 在 \(engine.consoleURL) 创建，只保存在本机钥匙串。模型留空则用默认的 \(engine.defaultModel)。")
                }

                Section {
                    Picker("视频语言", selection: $sourceLanguage) {
                        ForEach(SourceLanguage.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("识别语言")
                } footer: {
                    Text("自动检测会同时识别英、日、韩、西四种语言，挑最像的那种，比较耗电发热；固定一种语言更省电、更准。改了之后要重新开始同传才生效。每种语言第一次使用要下载语音模型。")
                }

                Section("字幕字号：\(Int(fontSize))") {
                    Slider(value: $fontSize, in: 14...40, step: 1)
                }

                Section("关于") {
                    LabeledContent("识别", value: "iOS 端侧 SpeechTranscriber（英/日/韩/西）")
                    LabeledContent("翻译", value: "\(engine.title)（→ 中文）")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func binding(for engine: TranslationEngine,
                         in dict: Binding<[TranslationEngine: String]>) -> Binding<String> {
        Binding(
            get: { dict.wrappedValue[engine] ?? "" },
            set: { dict.wrappedValue[engine] = $0 }
        )
    }

    private func load() {
        for e in TranslationEngine.allCases {
            keys[e] = Keychain.get(e.keychainKey) ?? ""
            let stored = UserDefaults.standard.string(forKey: e.modelDefaultsKey) ?? ""
            models[e] = stored == e.defaultModel ? "" : stored
        }
    }

    private func save() {
        for e in TranslationEngine.allCases {
            let key = (keys[e] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key != (Keychain.get(e.keychainKey) ?? "") {
                Keychain.set(key, for: e.keychainKey)
            }
            let model = (models[e] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(model, forKey: e.modelDefaultsKey)
        }
    }
}

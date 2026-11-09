import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.model) private var model: String = SettingsKeys.defaultModel
    @AppStorage(SettingsKeys.fontSize) private var fontSize: Double = 22
    @State private var apiKey: String = Keychain.get(SettingsKeys.anthropicKey) ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("在 console.anthropic.com 创建，按用量付费。只保存在本机钥匙串。")
                }

                Section {
                    TextField("模型", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("翻译模型")
                } footer: {
                    Text("默认 \(SettingsKeys.defaultModel)：速度快、价格低。")
                }

                Section("字幕字号：\(Int(fontSize))") {
                    Slider(value: $fontSize, in: 14...40, step: 1)
                }

                Section("关于") {
                    LabeledContent("识别", value: "iOS 端侧 SpeechTranscriber（英文）")
                    LabeledContent("翻译", value: "Claude（英 → 中）")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                     for: SettingsKeys.anthropicKey)
                        dismiss()
                    }
                }
            }
        }
    }
}

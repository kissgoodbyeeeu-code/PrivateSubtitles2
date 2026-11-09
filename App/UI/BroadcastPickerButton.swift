import ReplayKit
import SwiftUI

/// 系统的「开始广播」按钮，点了会弹出系统面板，直接选中本 App 的广播扩展。
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        // 侧载时 Bundle ID 可能被加后缀，所以按主 App 的实际 ID 拼
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.kissgoodbye.privatesubtitles") + ".broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

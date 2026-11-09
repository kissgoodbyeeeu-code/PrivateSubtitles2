import SwiftUI

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    private var appLog = AppLog.shared

    var body: some View {
        NavigationStack {
            List(appLog.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(entry.level == "ERROR" ? .red : .primary)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .overlay {
                if appLog.entries.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text")
                }
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: appLog.exportText) { Image(systemName: "square.and.arrow.up") }
                    Button { appLog.clear() } label: { Image(systemName: "trash") }
                }
            }
        }
    }
}

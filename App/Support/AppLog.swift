import Foundation
import Observation

/// App 内日志：云 Mac 连不上真机，出问题时在「日志」页导出发给开发者。
@MainActor
@Observable
final class AppLog {
    static let shared = AppLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 1000

    func add(_ level: String, _ message: String) {
        entries.append(Entry(date: Date(), level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }

    var exportText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(f.string(from: $0.date)) [\($0.level)] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// 可在任意线程调用。
func log(_ message: String, level: String = "INFO") {
    print("[\(level)] \(message)")
    Task { @MainActor in AppLog.shared.add(level, message) }
}

func logError(_ message: String) { log(message, level: "ERROR") }

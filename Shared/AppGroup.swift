import Foundation

/// 主 App 和广播扩展共用的 App Group 容器（用来放通信用的 socket 文件）。
enum AppGroup {
    static let baseID = "group.com.kissgoodbye.privatesubtitles"
    static let baseBundleID = "com.kissgoodbye.privatesubtitles"

    /// 侧载工具（AltStore/SideStore）可能给 Bundle ID 和 App Group 加后缀，这里都试一遍。
    static var candidateIDs: [String] {
        var ids = [baseID]
        var bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID.hasSuffix(".broadcast") {
            bundleID = String(bundleID.dropLast(".broadcast".count))
        }
        if bundleID.hasPrefix(baseBundleID), bundleID.count > baseBundleID.count {
            let suffix = bundleID.dropFirst(baseBundleID.count) // 形如 ".ABCDE12345"
            ids.append(baseID + suffix)
        }
        return ids
    }

    static func containerURL() -> URL? {
        for id in candidateIDs {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return url
            }
        }
        return nil
    }
}

import Foundation

/// Safari 扩展（原生部分）⇄ 主 App 的本机回环 TCP 协议。
/// 每帧：[UInt8 类型][UInt32 大端 长度][内容]
///   audio：16kHz 单声道 Int16 小端 PCM（扩展 → App）
///   json ：字幕 / 状态 JSON（App → 扩展）
///   log  ：扩展发给 App 的日志文字，方便排查（扩展 → App）
enum SafariWire {
    static let port: UInt16 = 47_322
    static let headerSize = 5
    static let maxPayload = 1_000_000

    enum Frame: UInt8 {
        case audio = 1
        case json = 2
        case log = 3
    }

    static func frame(_ type: Frame, _ payload: Data) -> Data {
        var data = Data(capacity: headerSize + payload.count)
        data.append(type.rawValue)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// 解析帧头，返回 (类型原始值, 长度)
    static func parseHeader(_ header: Data) -> (UInt8, Int)? {
        guard header.count == headerSize else { return nil }
        let bytes = [UInt8](header)
        let len = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
        guard len <= maxPayload else { return nil }
        return (bytes[0], len)
    }
}

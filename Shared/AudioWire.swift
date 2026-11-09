import Darwin
import Foundation

/// 广播扩展 → 主 App 的音频传输协议（App Group 里的 Unix domain socket）。
///
/// 每个包：8 字节头 + 数据
///   [UInt32 LE 采样率][UInt32 LE 帧数][帧数 × Float32 LE 单声道采样]
enum AudioWire {
    static let socketFileName = "audio.sock"
    static let headerSize = 8
    /// 单包最大帧数（防止读到坏数据时分配超大内存）
    static let maxFrames: UInt32 = 96_000

    static func socketPath() -> String? {
        AppGroup.containerURL()?.appendingPathComponent(socketFileName).path
    }

    static func makeAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func disableSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

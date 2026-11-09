import Darwin
import Foundation

/// 广播扩展 → 主 App 的音频传输协议：本机回环 TCP（127.0.0.1）。
/// 不依赖 App Group，侧载重签、免费账号都能用；只监听本机，外部设备连不进来。
///
/// 连接建立后客户端先发 4 字节暗号 "PSA1"，之后每个包：
///   [UInt32 LE 采样率][UInt32 LE 帧数][帧数 × Float32 LE 单声道采样]
enum AudioWire {
    static let port: UInt16 = 47_321
    static let magic: [UInt8] = Array("PSA1".utf8)
    static let headerSize = 8
    /// 单包最大帧数（防止读到坏数据时分配超大内存）
    static let maxFrames: UInt32 = 96_000

    static func loopbackAddress() -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return addr
    }

    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, size) // 小包立即发，降低延迟
    }
}

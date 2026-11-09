import CoreMedia
import os
import ReplayKit

private let logger = Logger(subsystem: "com.kissgoodbye.privatesubtitles.broadcast", category: "broadcast")

/// 广播上传扩展：接收系统正在播放的声音（audioApp），转成单声道 Float32，
/// 通过 App Group 里的 socket 发给主 App。画面帧直接丢弃。
/// 扩展内存上限约 50MB，这里只做最轻量的处理。
final class SampleHandler: RPBroadcastSampleHandler {
    private let sender = AudioSender()
    private var mono: [Float] = []
    private var lastReconnectAttempt = Date.distantPast
    private var failingSince: Date?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        if sender.connect() {
            logger.info("已连接主 App")
        } else {
            finish("请先打开「双语字幕」，音源选「系统声音」并点「开始同传」，再开始广播。")
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        guard let sampleRate = AudioExtractor.mono(from: sampleBuffer, into: &mono), !mono.isEmpty else { return }

        if sender.send(samples: mono, sampleRate: sampleRate) {
            failingSince = nil
            return
        }

        // 主 App 停了或断开：每秒重连一次，持续 3 秒失败就结束广播
        let now = Date()
        if failingSince == nil { failingSince = now }
        if now.timeIntervalSince(lastReconnectAttempt) >= 1 {
            lastReconnectAttempt = now
            if sender.connect() {
                failingSince = nil
                return
            }
        }
        if let since = failingSince, now.timeIntervalSince(since) > 3 {
            finish("「双语字幕」已停止同传，广播结束。")
        }
    }

    override func broadcastFinished() {
        sender.close()
    }

    private func finish(_ message: String) {
        sender.close()
        let error = NSError(domain: "PrivateSubtitles.Broadcast", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message])
        finishBroadcastWithError(error)
    }
}

/// socket 客户端
final class AudioSender {
    private var fd: Int32 = -1
    private var packet: [UInt8] = []

    func connect() -> Bool {
        close()
        guard let path = AudioWire.socketPath(), var addr = AudioWire.makeAddress(path: path) else {
            logger.error("找不到 App Group 容器")
            return false
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        AudioWire.disableSigPipe(s)

        // 发送超时 200ms，主 App 卡住时不要拖住扩展
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(s)
            return false
        }
        fd = s
        return true
    }

    func send(samples: [Float], sampleRate: Double) -> Bool {
        guard fd >= 0 else { return false }
        let frames = UInt32(samples.count)
        packet.removeAll(keepingCapacity: true)
        withUnsafeBytes(of: UInt32(sampleRate.rounded()).littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: frames.littleEndian) { packet.append(contentsOf: $0) }
        samples.withUnsafeBytes { packet.append(contentsOf: $0) } // iOS 是小端

        let ok = packet.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        if !ok { close() }
        return ok
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// 把 ReplayKit 给的音频（可能是 Int16 大端、多声道交错等）统一转成单声道 Float32。
enum AudioExtractor {
    static func mono(from sampleBuffer: CMSampleBuffer, into out: inout [Float]) -> Double? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, asbd.mChannelsPerFrame > 0 else { return nil }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = Int(asbd.mChannelsPerFrame)

        guard (isFloat && bits == 32) || (!isFloat && (bits == 16 || bits == 32)) else { return nil }

        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: repeatElement(0, count: frames))

        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let raw = UnsafeRawPointer(data)
                    let chInBuffer = nonInterleaved ? 1 : max(1, Int(buffer.mNumberChannels))
                    let bytesPerSample = bits / 8
                    let available = Int(buffer.mDataByteSize) / bytesPerSample
                    let usableFrames = min(frames, available / chInBuffer)
                    for f in 0..<usableFrames {
                        var sum: Float = 0
                        for c in 0..<chInBuffer {
                            let offset = (f * chInBuffer + c) * bytesPerSample
                            sum += sample(raw, offset: offset, bits: bits, isFloat: isFloat, bigEndian: isBigEndian)
                        }
                        out[f] += sum
                    }
                }
            }
        } catch {
            return nil
        }

        let scale = 1 / Float(channels)
        for i in out.indices { out[i] *= scale }
        return asbd.mSampleRate
    }

    @inline(__always)
    private static func sample(_ raw: UnsafeRawPointer, offset: Int, bits: Int, isFloat: Bool, bigEndian: Bool) -> Float {
        if isFloat {
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Float(bitPattern: bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
        }
        if bits == 16 {
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            let s = Int16(bitPattern: bigEndian ? UInt16(bigEndian: v) : UInt16(littleEndian: v))
            return Float(s) / 32768
        }
        let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        let s = Int32(bitPattern: bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
        return Float(s) / 2_147_483_648
    }
}

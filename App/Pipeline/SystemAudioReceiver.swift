import AVFoundation
import Darwin

/// 主 App 端的 socket 服务：接收广播扩展发来的系统声音，转成 AVAudioPCMBuffer。
final class SystemAudioReceiver {
    enum ReceiverError: LocalizedError {
        case noAppGroup, socketFailed(String)
        var errorDescription: String? {
            switch self {
            case .noAppGroup: return "找不到 App Group 容器（签名时没有带上 App Group 权限）"
            case .socketFailed(let why): return "本地通信启动失败：\(why)"
            }
        }
    }

    /// 在接收线程回调
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var path: String?
    private var formats: [UInt32: AVAudioFormat] = [:]

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() throws {
        guard !isRunning else { return }
        guard let path = AudioWire.socketPath() else { throw ReceiverError.noAppGroup }
        guard var addr = AudioWire.makeAddress(path: path) else {
            throw ReceiverError.socketFailed("路径过长")
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ReceiverError.socketFailed("socket() errno \(errno)") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw ReceiverError.socketFailed("bind() errno \(errno)")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw ReceiverError.socketFailed("listen() errno \(errno)")
        }

        lock.lock()
        listenFD = fd
        self.path = path
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(listenFD: fd) }
        thread.name = "SystemAudioReceiver"
        thread.qualityOfService = .userInitiated
        thread.start()
        log("系统声音接收已启动，等待广播连接")
    }

    func stop() {
        lock.lock()
        running = false
        let l = listenFD, c = clientFD, p = path
        listenFD = -1
        clientFD = -1
        lock.unlock()

        if c >= 0 { Darwin.shutdown(c, SHUT_RDWR) }
        if l >= 0 {
            Darwin.shutdown(l, SHUT_RDWR)
            Darwin.close(l)
        }
        if let p { unlink(p) }
    }

    // MARK: - 线程

    private func acceptLoop(listenFD: Int32) {
        while isRunning {
            let c = Darwin.accept(listenFD, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                break
            }
            AudioWire.disableSigPipe(c)
            lock.lock(); clientFD = c; lock.unlock()
            log("广播已连接")
            onConnectionChange?(true)

            readLoop(fd: c)

            lock.lock(); if clientFD == c { clientFD = -1 }; lock.unlock()
            Darwin.close(c)
            log("广播已断开")
            onConnectionChange?(false)
        }
    }

    private func readLoop(fd: Int32) {
        var header = [UInt8](repeating: 0, count: AudioWire.headerSize)
        var samples: [Float] = []

        while isRunning {
            let gotHeader = header.withUnsafeMutableBytes { readExactly(fd, $0.baseAddress!, $0.count) }
            guard gotHeader else { return }

            let rate = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
            let frames = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
            guard rate >= 8000, rate <= 192_000, frames > 0, frames <= AudioWire.maxFrames else {
                logError("收到异常音频包 rate=\(rate) frames=\(frames)，断开")
                return
            }

            let count = Int(frames)
            if samples.count != count { samples = [Float](repeating: 0, count: count) }
            let gotBody = samples.withUnsafeMutableBytes { readExactly(fd, $0.baseAddress!, $0.count) }
            guard gotBody else { return }

            guard let buffer = makeBuffer(samples: samples, rate: rate) else { continue }
            onBuffer?(buffer)
        }
    }

    private func readExactly(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, ptr + offset, count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private func makeBuffer(samples: [Float], rate: UInt32) -> AVAudioPCMBuffer? {
        let format: AVAudioFormat
        if let cached = formats[rate] {
            format = cached
        } else {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                        channels: 1, interleaved: false) else { return nil }
            formats[rate] = f
            format = f
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

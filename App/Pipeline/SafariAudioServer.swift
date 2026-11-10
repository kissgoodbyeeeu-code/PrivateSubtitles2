import AVFoundation
import Network

/// 本机回环 TCP 服务（127.0.0.1:47322）：
/// Safari 扩展的原生部分把网页视频的声音（16kHz 单声道 Int16）转发过来，这里把字幕 JSON 发回去。
/// 协议见 SafariWire。
final class SafariAudioServer {
    /// 在网络线程回调
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "SafariAudioServer")
    private var listener: NWListener?
    /// 只在 queue 上访问
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyCount = 0
    private var reportedConnected = false
    private var lastSub: Data?
    private var lastStatus: Data?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback // 只接受本机连接

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: SafariWire.port)!)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("Safari 扩展服务已启动（端口 \(SafariWire.port)）")
            case .failed(let error): logError("Safari 扩展服务出错: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.readyCount = 0
            self.reportedConnected = false
            self.lastSub = nil
            self.lastStatus = nil
        }
    }

    /// 把字幕 / 状态发给扩展
    func send(_ message: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        let frame = SafariWire.frame(.json, json)
        let type = message["type"] as? String
        queue.async {
            // 记住最新的字幕和状态，新连上的扩展先补发一次
            if type == "sub" { self.lastSub = frame }
            if type == "status" { self.lastStatus = frame }
            for c in self.connections.values where c.state == .ready {
                c.send(content: frame, completion: .idempotent)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        var wasReady = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                wasReady = true
                self.readyCount += 1
                self.updateConnected()
                if let connection {
                    for frame in [self.lastSub, self.lastStatus].compactMap({ $0 }) {
                        connection.send(content: frame, completion: .idempotent)
                    }
                    self.readHeader(connection)
                }
            case .failed, .cancelled:
                self.connections[id] = nil
                if wasReady {
                    wasReady = false
                    self.readyCount -= 1
                    // 扩展进程随时可能被 Safari 回收后马上重连，晚 3 秒再判断是否真的断开
                    self.queue.asyncAfter(deadline: .now() + 3) { self.updateConnected() }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func updateConnected() {
        let connected = readyCount > 0
        guard connected != reportedConnected else { return }
        reportedConnected = connected
        log(connected ? "Safari 扩展已连接" : "Safari 扩展已断开")
        onConnectionChange?(connected)
    }

    private func readHeader(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: SafariWire.headerSize,
                           maximumLength: SafariWire.headerSize) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            guard error == nil, !isComplete, let data,
                  let (type, length) = SafariWire.parseHeader(data) else {
                connection.cancel()
                return
            }
            if length == 0 {
                self.readHeader(connection)
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak connection] payload, _, _, error in
                guard let self, let connection else { return }
                guard error == nil, let payload, payload.count == length else {
                    connection.cancel()
                    return
                }
                switch SafariWire.Frame(rawValue: type) {
                case .audio: self.handleAudio(payload)
                case .log: log("Safari 扩展：\(String(decoding: payload, as: UTF8.self))")
                default: break
                }
                self.readHeader(connection)
            }
        }
    }

    private func handleAudio(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                dst[i] = Float(v) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        onBuffer?(buffer)
    }
}

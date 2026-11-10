import AVFoundation
import Network

/// 本机 WebSocket 服务（只监听回环地址）：
/// Safari 扩展把网页视频的声音（16kHz 单声道 Int16）发过来，这里把字幕 JSON 发回去显示在网页上。
final class SafariAudioServer {
    static let port: UInt16 = 47322

    /// 在网络线程回调
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "SafariAudioServer")
    private var listener: NWListener?
    /// 只在 queue 上访问
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyCount = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback // 只接受本机连接

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("Safari 扩展服务已启动（端口 \(Self.port)）")
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
        }
    }

    /// 把字幕 / 状态发给所有连着的网页
    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        queue.async {
            for c in self.connections.values where c.state == .ready {
                c.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
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
                log("Safari 网页已连接（共 \(self.readyCount) 个）")
                if self.readyCount == 1 { self.onConnectionChange?(true) }
                if let connection { self.receive(on: connection) }
            case .failed, .cancelled:
                self.connections[id] = nil
                if wasReady {
                    wasReady = false
                    self.readyCount -= 1
                    log("Safari 网页已断开（剩 \(self.readyCount) 个）")
                    if self.readyCount == 0 { self.onConnectionChange?(false) }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            if error != nil {
                connection.cancel()
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .binary:
                    if let data { self.handleAudio(data) }
                case .close:
                    connection.cancel()
                    return
                default:
                    break
                }
            }
            self.receive(on: connection)
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

import Darwin
import Foundation

/// 运行在 Safari 扩展进程里：保持一条到主 App 的本机 TCP 连接（127.0.0.1:47322），
/// 把网页发来的声音转给 App，并缓存 App 发回来的最新字幕 / 状态，随每次回复带回网页。
/// 原生代码连本机端口不受网页安全策略限制。
final class SafariBridge {
    static let shared = SafariBridge()

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var latestSub: [String: Any]?
    private var latestStatus: [String: Any]?
    private var lastError: String?
    private var lastConnectAttempt = Date.distantPast

    /// 处理一条网页消息，返回给网页的回复
    func handle(_ message: [String: Any]) -> [String: Any] {
        let type = message["type"] as? String ?? ""
        let connected = ensureConnected()
        if connected {
            switch type {
            case "audio":
                if let b64 = message["data"] as? String, let pcm = Data(base64Encoded: b64) {
                    send(SafariWire.frame(.audio, pcm))
                }
            case "log", "hello":
                if let text = message["text"] as? String {
                    send(SafariWire.frame(.log, Data(text.utf8)))
                }
            default:
                break
            }
        }
        lock.lock()
        defer { lock.unlock() }
        var reply: [String: Any] = ["connected": fd >= 0]
        if let latestSub { reply["sub"] = latestSub }
        if let latestStatus { reply["status"] = latestStatus }
        if fd < 0, let lastError { reply["error"] = lastError }
        return reply
    }

    // MARK: - 连接

    private func ensureConnected() -> Bool {
        lock.lock()
        if fd >= 0 { lock.unlock(); return true }
        // 连不上时别每个音频块都重试
        guard Date().timeIntervalSince(lastConnectAttempt) > 0.5 else { lock.unlock(); return false }
        lastConnectAttempt = Date()
        lock.unlock()

        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { setError("socket() errno \(errno)"); return false }
        AudioWire.configure(s)
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = AudioWire.loopbackAddress(port: SafariWire.port)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(s)
            setError(err == ECONNREFUSED
                     ? "App 没在同传：请打开 App，音源选「Safari」，点「开始同传」"
                     : "连接 App 失败 errno \(err)")
            return false
        }

        lock.lock()
        fd = s
        lastError = nil
        lock.unlock()

        let thread = Thread { [weak self] in self?.readLoop(s) }
        thread.name = "SafariBridge.read"
        thread.start()
        return true
    }

    private func setError(_ text: String) {
        lock.lock()
        lastError = text
        lock.unlock()
    }

    private func disconnect(_ s: Int32) {
        lock.lock()
        if fd == s {
            close(s)
            fd = -1
        }
        lock.unlock()
    }

    private func send(_ data: Data) {
        lock.lock()
        let s = fd
        lock.unlock()
        guard s >= 0 else { return }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(s, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        if !ok {
            setError("和 App 的连接断了")
            disconnect(s)
        }
    }

    // MARK: - 读 App 发来的字幕

    private func readLoop(_ s: Int32) {
        while true {
            guard let header = readExactly(s, SafariWire.headerSize),
                  let (type, length) = SafariWire.parseHeader(header),
                  let payload = length == 0 ? Data() : readExactly(s, length) else { break }
            guard type == SafariWire.Frame.json.rawValue,
                  let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            lock.lock()
            if obj["type"] as? String == "sub" { latestSub = obj }
            if obj["type"] as? String == "status" { latestStatus = obj }
            lock.unlock()
        }
        setError("App 已停止同传")
        disconnect(s)
    }

    private func readExactly(_ s: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while offset < count {
                let n = recv(s, raw.baseAddress! + offset, count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }
}

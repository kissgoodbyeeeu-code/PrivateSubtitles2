import Accelerate
import AVFoundation

/// 统计进来的音频：音量（RMS）、最后一次收到数据、最后一次有声音的时间。
/// 在音频线程写，在主线程读，用锁保护。
final class AudioLevelMonitor {
    struct Snapshot {
        let rms: Float
        let lastBufferAt: Date?
        let lastSoundAt: Date?
    }

    /// 高于这个 RMS（约 -50 dBFS）算「有声音」
    static let soundThreshold: Float = 0.003

    private let lock = NSLock()
    private var rms: Float = 0
    private var lastBufferAt: Date?
    private var lastSoundAt: Date?

    func process(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        var value: Float = 0
        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            vDSP_rmsqv(data, 1, &value, vDSP_Length(buffer.frameLength))
        }
        lock.lock()
        // 快速上升、缓慢回落，电平条看起来更稳
        rms = max(value, rms * 0.85)
        lastBufferAt = now
        if value > Self.soundThreshold { lastSoundAt = now }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(rms: rms, lastBufferAt: lastBufferAt, lastSoundAt: lastSoundAt)
    }

    func reset() {
        lock.lock()
        rms = 0
        lastBufferAt = nil
        lastSoundAt = nil
        lock.unlock()
    }

    /// RMS → 0...1（-60 dB 到 0 dB）
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}

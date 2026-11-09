import AVFoundation

/// 把任意格式的 PCM 转成语音识别模型要求的格式（采样率/声道/位深）。
/// 非线程安全：只在同一个音频线程里调用。
final class BufferConverter {
    enum ConvertError: Error { case cannotCreateConverter, cannotCreateBuffer, failed(NSError?) }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }

        if converter == nil
            || converter!.inputFormat != buffer.format
            || converter!.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConvertError.cannotCreateConverter }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConvertError.cannotCreateBuffer
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw ConvertError.failed(error) }
        return output
    }
}

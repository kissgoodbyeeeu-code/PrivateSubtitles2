import AVKit
import CoreMedia
import Observation
import UIKit

/// 画中画悬浮字幕：把渲染好的字幕帧塞进 AVSampleBufferDisplayLayer，
/// 再交给 AVPictureInPictureController 显示成系统级悬浮窗。
@MainActor
@Observable
final class PiPSubtitleController: NSObject {
    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var isPossible = false
    private(set) var isActive = false

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private let renderer = SubtitleFrameRenderer()
    @ObservationIgnored private var content = SubtitleFrameRenderer.Content()
    @ObservationIgnored private var heartbeat: Timer?

    var aspectRatio: CGFloat { renderer.size.width / renderer.size.height }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        enqueueFrame()
    }

    /// 图层进入视图层级后调用一次。
    func setUpIfNeeded() {
        guard pip == nil else { return }
        guard isSupported else {
            log("此设备不支持画中画", level: "WARN")
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        // 切到后台（比如去 Safari 看视频）时自动弹出悬浮字幕
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.requiresLinearPlayback = true

        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        self.pip = pip

        // 心跳：定期重新送一帧，防止渲染层失效后悬浮窗变黑
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enqueueFrame() }
        }
        log("画中画已初始化")
    }

    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func update(english: String, chinese: String, isVolatile: Bool) {
        let new = SubtitleFrameRenderer.Content(english: english, chinese: chinese, isVolatile: isVolatile)
        guard new != content else { return }
        content = new
        enqueueFrame()
    }

    // MARK: - 渲染

    private func enqueueFrame() {
        let fontSize = UserDefaults.standard.object(forKey: SettingsKeys.fontSize) as? Double ?? 22
        let scale = CGFloat(fontSize / 22)
        guard let pixelBuffer = renderer.render(content, scale: scale),
              let sample = Self.makeSampleBuffer(pixelBuffer) else { return }

        let sbRenderer = displayLayer.sampleBufferRenderer
        if sbRenderer.status == .failed {
            log("字幕渲染层失效，重置: \(sbRenderer.error?.localizedDescription ?? "")", level: "WARN")
            sbRenderer.flush()
        }
        sbRenderer.enqueue(sample)
    }

    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return nil }

        // 立即显示，不按时间戳排队
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - 播放代理：字幕是"直播"，永远在播放、不能快进

extension PiPSubtitleController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - 画中画生命周期

extension PiPSubtitleController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            log("悬浮字幕已打开")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            log("悬浮字幕已关闭")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        logError("悬浮字幕打开失败: \(error.localizedDescription)")
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

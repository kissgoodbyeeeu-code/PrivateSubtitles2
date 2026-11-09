import CoreVideo
import UIKit

/// 把双语字幕画成一帧 BGRA 视频画面（CVPixelBuffer），喂给画中画。
final class SubtitleFrameRenderer {
    struct Content: Equatable {
        var english: String = ""
        var chinese: String = ""
        /// 英文还在识别中（未定稿）
        var isVolatile: Bool = false
    }

    /// 3:1 的横条，适合当字幕悬浮窗
    let size = CGSize(width: 1080, height: 360)
    private var pool: CVPixelBufferPool?

    init() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    }

    func render(_ content: Content, scale: CGFloat) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // UIKit 坐标系（原点在左上）
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))

        let pad: CGFloat = 36
        let width = size.width - pad * 2
        let enSize = 38 * scale
        let zhSize = 54 * scale

        if content.english.isEmpty && content.chinese.isEmpty {
            draw("等待语音…", font: .systemFont(ofSize: enSize), color: .gray,
                 in: CGRect(x: pad, y: size.height / 2 - enSize, width: width, height: enSize * 2))
            return buffer
        }

        // 英文：最多 2 行，长句只保留结尾
        let enRect = CGRect(x: pad, y: 28, width: width, height: enSize * 2.6)
        draw(Self.tail(content.english, max: Int(110 / scale)),
             font: .systemFont(ofSize: enSize),
             color: UIColor.white.withAlphaComponent(content.isVolatile ? 0.55 : 0.85),
             in: enRect)

        // 中文：最多 2 行，黄色加粗
        let zhTop = enRect.maxY + 12
        let zhRect = CGRect(x: pad, y: zhTop, width: width, height: size.height - zhTop - 20)
        draw(Self.tail(content.chinese, max: Int(46 / scale)),
             font: .systemFont(ofSize: zhSize, weight: .semibold),
             color: UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1),
             in: zhRect)

        return buffer
    }

    private func draw(_ text: String, font: UIFont, color: UIColor, in rect: CGRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// 字太长时只显示最后一段，保证最新的内容总能看到。
    private static func tail(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        return "…" + text.suffix(max - 1)
    }
}

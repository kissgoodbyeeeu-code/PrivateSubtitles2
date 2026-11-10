import CoreVideo
import UIKit

/// 把双语字幕画成一帧 BGRA 视频画面（CVPixelBuffer），喂给画中画。
final class SubtitleFrameRenderer {
    struct Content: Equatable {
        var english: String = ""
        var chinese: String = ""
        /// 原文还在识别中（未定稿）
        var isVolatile: Bool = false
        /// 输入音量 0...1
        var level: Float = 0
        /// 没声音等提醒（显示在英文那一行的位置）
        var warning: String?
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

        drawLevelMeter(content.level, in: ctx)

        if content.english.isEmpty && content.chinese.isEmpty && content.warning == nil {
            draw("等待语音…", font: .systemFont(ofSize: enSize), color: .gray,
                 in: CGRect(x: pad, y: size.height / 2 - enSize, width: width - 40, height: enSize * 2))
            return buffer
        }

        // 原文：最多 2 行，长句只保留结尾；有提醒时这一行改成橙色提醒
        let enRect = CGRect(x: pad, y: 28, width: width - 40, height: enSize * 2.6)
        if let warning = content.warning {
            draw(warning, font: .systemFont(ofSize: enSize * 0.9, weight: .semibold),
                 color: UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1), in: enRect)
        } else {
            draw(Self.tail(content.english, max: Int((Self.isWide(content.english) ? 55 : 110) / scale)),
                 font: .systemFont(ofSize: enSize),
                 color: UIColor.white.withAlphaComponent(content.isVolatile ? 0.55 : 0.85),
                 in: enRect)
        }

        // 中文：最多 2 行，黄色加粗
        let zhTop = enRect.maxY + 12
        let zhRect = CGRect(x: pad, y: zhTop, width: width, height: size.height - zhTop - 20)
        draw(Self.tail(content.chinese, max: Int(46 / scale)),
             font: .systemFont(ofSize: zhSize, weight: .semibold),
             color: UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1),
             in: zhRect)

        return buffer
    }

    /// 右上角竖向电平条（5 格），有声音时亮绿
    private func drawLevelMeter(_ level: Float, in ctx: CGContext) {
        let bars = 5
        let barW: CGFloat = 14, barH: CGFloat = 10, gap: CGFloat = 5
        let x = size.width - 36 - barW
        let lit = Int((level * Float(bars)).rounded(.up))
        for i in 0..<bars {
            let y = 36 + CGFloat(bars - 1 - i) * (barH + gap)
            let on = i < lit
            (on ? UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1) : UIColor(white: 0.3, alpha: 1)).setFill()
            ctx.fill(CGRect(x: x, y: y, width: barW, height: barH))
        }
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

    /// 日文、韩文、汉字一个字更宽，原文一行能放的字数少一半
    private static func isWide(_ text: String) -> Bool {
        text.unicodeScalars.contains { u in
            u.properties.isIdeographic
                || (0x3040...0x30FF).contains(u.value)   // 平假名、片假名
                || (0xAC00...0xD7AF).contains(u.value)   // 韩文音节
                || (0x1100...0x11FF).contains(u.value)   // 韩文字母
        }
    }

    /// 字太长时只显示最后一段，保证最新的内容总能看到。
    private static func tail(_ text: String, max: Int) -> String {
        guard text.count > max, max > 1 else { return text }
        return "…" + text.suffix(max - 1)
    }
}

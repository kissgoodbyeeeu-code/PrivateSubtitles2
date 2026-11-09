import AVKit
import SwiftUI

/// 把画中画用的字幕图层嵌进界面。画中画要求图层必须在屏幕上，
/// 所以它同时充当 App 内的字幕预览（看到的就是悬浮窗里的样子）。
struct PiPLayerView: UIViewRepresentable {
    let controller: PiPSubtitleController

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView(hostedLayer: controller.displayLayer)
        DispatchQueue.main.async { controller.setUpIfNeeded() }
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        private let hostedLayer: CALayer

        init(hostedLayer: CALayer) {
            self.hostedLayer = hostedLayer
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(hostedLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

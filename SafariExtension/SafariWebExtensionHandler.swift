import Foundation
import SafariServices

/// Safari 扩展的原生部分。声音和字幕走本机 WebSocket，不经过这里；
/// 只是 Safari 网页扩展必须有一个原生入口，收到消息原样回个 ok。
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

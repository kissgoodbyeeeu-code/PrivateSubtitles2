import Foundation
import SafariServices

/// Safari 扩展的原生入口：网页通过 browser.runtime.sendNativeMessage 发来声音，
/// 交给 SafariBridge 转发给主 App，回复里带上最新字幕。
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = (item?.userInfo?[SFExtensionMessageKey] as? [String: Any]) ?? [:]
        let reply = SafariBridge.shared.handle(message)

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}

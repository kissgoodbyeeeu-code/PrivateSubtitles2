// 中转：内容脚本不能直接调原生消息时，由扩展后台代为调用。
// 声音和字幕都走 sendNativeMessage → 扩展原生部分 → 本机 App。
browser.runtime.onMessage.addListener((msg) => {
  if (msg && msg.native) {
    return browser.runtime.sendNativeMessage("application.id", msg.native);
  }
});

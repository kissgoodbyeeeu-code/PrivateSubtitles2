// 中转：网页里的内容脚本 ⇄ 本机「双语字幕」App 的 WebSocket 服务。
// 内容脚本直接连 ws://127.0.0.1 可能被网页的安全策略拦住，所以由扩展后台来连。
const WS_URL = "ws://127.0.0.1:47322";

function base64ToBuffer(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

browser.runtime.onConnect.addListener((port) => {
  if (port.name !== "ps-audio") return;
  let alive = true;
  let ws = null;
  let retryTimer = null;

  const open = () => {
    if (!alive) return;
    try {
      ws = new WebSocket(WS_URL);
    } catch (e) {
      port.postMessage({ type: "conn", ok: false, error: String(e) });
      retryTimer = setTimeout(open, 2000);
      return;
    }
    ws.binaryType = "arraybuffer";
    ws.onopen = () => port.postMessage({ type: "conn", ok: true });
    ws.onmessage = (e) => {
      if (typeof e.data !== "string") return;
      try { port.postMessage(JSON.parse(e.data)); } catch (_) {}
    };
    ws.onclose = () => {
      if (!alive) return;
      port.postMessage({ type: "conn", ok: false });
      retryTimer = setTimeout(open, 2000);
    };
    ws.onerror = () => {};
  };

  port.onMessage.addListener((msg) => {
    if (msg && msg.type === "audio" && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(base64ToBuffer(msg.data));
    }
  });

  port.onDisconnect.addListener(() => {
    alive = false;
    clearTimeout(retryTimer);
    if (ws) ws.close();
  });

  open();
});

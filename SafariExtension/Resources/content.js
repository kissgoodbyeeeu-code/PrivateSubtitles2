// 双语字幕 Safari 扩展：抓网页视频的声音交给本机 App 识别翻译，再把字幕盖在视频上。
(() => {
  if (window.__psLoaded) return;
  window.__psLoaded = true;

  const TARGET_RATE = 16000;
  const MIN_VIDEO_WIDTH = 160;

  let ctx = null;                      // 全页面共用一个 AudioContext
  const sources = new WeakMap();       // video → MediaElementSourceNode（每个 video 只能建一次）
  const buttons = new Map();           // video → 按钮
  let active = null;                   // 正在翻译的 { video, proc, queue, ... }

  // ---------- 字幕层 ----------
  const sub = document.createElement("div");
  sub.className = "ps-sub";
  sub.innerHTML = '<div class="ps-box"><div class="ps-prev"></div><div class="ps-orig"></div><div class="ps-zh"></div></div>';
  const prevEl = sub.querySelector(".ps-prev");
  const origEl = sub.querySelector(".ps-orig");
  const zhEl = sub.querySelector(".ps-zh");
  let subtitle = { original: "", chinese: "", volatile: false, prevChinese: [] };
  let warning = null;

  function render() {
    if (warning) {
      origEl.textContent = warning;
      origEl.className = "ps-orig ps-warn";
    } else {
      origEl.textContent = tail(subtitle.original, 120);
      origEl.className = "ps-orig" + (subtitle.volatile ? " ps-volatile" : "");
    }
    zhEl.textContent = tail(subtitle.chinese, 60);
    prevEl.textContent = subtitle.prevChinese.slice(-2).map((t) => tail(t, 40)).join("\n");
    prevEl.style.display = subtitle.prevChinese.length ? "block" : "none";
    const empty = !origEl.textContent && !zhEl.textContent && !prevEl.textContent;
    sub.querySelector(".ps-box").style.display = empty ? "none" : "inline-block";
  }

  function tail(s, max) {
    if (!s || s.length <= max) return s || "";
    return "…" + s.slice(s.length - max + 1);
  }

  function hostFor(video) {
    // 网页自己做的全屏（整个播放器容器全屏）时，字幕要放进全屏元素里才看得见
    const fs = document.fullscreenElement || document.webkitFullscreenElement;
    return fs && fs !== video && fs.contains(video) ? fs : document.documentElement;
  }

  function positionLoop() {
    if (!active) return;
    const video = active.video;
    const host = hostFor(video);
    if (sub.parentNode !== host) host.appendChild(sub);
    const r = video.getBoundingClientRect();
    if (r.width < 10 || r.height < 10) {
      sub.style.display = "none";
    } else {
      const zhSize = Math.max(12, Math.min(24, r.width / 28));
      zhEl.style.fontSize = zhSize + "px";
      origEl.style.fontSize = Math.round(zhSize * 0.72) + "px";
      prevEl.style.fontSize = Math.round(zhSize * 0.78) + "px";
      sub.style.display = "block";
      sub.style.left = r.left + r.width * 0.04 + "px";
      sub.style.width = r.width * 0.92 + "px";
      sub.style.top = Math.max(r.top, r.bottom - sub.offsetHeight - r.height * 0.06) + "px";
    }
    requestAnimationFrame(positionLoop);
  }

  // ---------- 和 App 通信（经扩展原生部分）----------
  // 网页直接连本机端口会被 Safari 拦住，所以走 sendNativeMessage：
  // 每次带上一小段声音，回复里带回最新字幕。同一时间只有一个请求在路上。
  async function nativeCall(msg) {
    if (browser.runtime.sendNativeMessage) {
      try {
        return await browser.runtime.sendNativeMessage("application.id", msg);
      } catch (e) {
        // 内容脚本里不让直接调，就交给扩展后台转
      }
    }
    return await browser.runtime.sendMessage({ native: msg });
  }

  function pump() {
    const a = active;
    if (!a || a.inFlight) return;
    let msg;
    if (a.queue.length) {
      // 把排队的声音拼起来一次发（最多约 1 秒）
      let total = 0;
      const parts = [];
      while (a.queue.length && total < TARGET_RATE) {
        const p = a.queue.shift();
        parts.push(p);
        total += p.length;
      }
      const merged = new Int16Array(total);
      let off = 0;
      for (const p of parts) { merged.set(p, off); off += p.length; }
      msg = { type: "audio", data: bytesToBase64(new Uint8Array(merged.buffer)) };
      // 积压太多（App 处理不过来）就丢掉最旧的，保证字幕不越来越慢
      if (a.queue.length > 40) a.queue.splice(0, a.queue.length - 10);
    } else if (!a.helloSent && Date.now() - a.lastCall > 300) {
      msg = { type: "hello", text: "网页已开始翻译：" + location.host };
    } else if (Date.now() - a.lastCall > 300) {
      msg = { type: "poll" };
    } else {
      return;
    }
    a.inFlight = true;
    a.lastCall = Date.now();
    nativeCall(msg).then((reply) => {
      if (active !== a) return;
      if (msg.type === "hello" && reply && reply.connected) a.helloSent = true;
      handleReply(reply);
    }).catch((e) => {
      if (active !== a) return;
      a.connected = false;
      a.error = "扩展通信失败：" + (e && e.message ? e.message : e);
      updateWarning();
    }).finally(() => {
      a.inFlight = false;
    });
  }

  function handleReply(reply) {
    if (!active) return;
    if (!reply) {
      active.connected = false;
      active.error = "扩展没有回复";
      updateWarning();
      return;
    }
    active.connected = !!reply.connected;
    active.error = reply.error || null;
    const msg = reply.sub;
    if (msg && msg !== active.lastSubRaw) {
      subtitle = { original: msg.original || "", chinese: msg.chinese || "", volatile: !!msg.volatile,
                   prevChinese: Array.isArray(msg.prevChinese) ? msg.prevChinese : [] };
    }
    active.appWarning = reply.status ? reply.status.warning || null : null;
    updateWarning();
  }

  function updateWarning() {
    if (!active) return;
    if (!active.connected) {
      warning = "⚠︎ 连不上双语字幕 App：" + (active.error || "请打开 App，音源选「Safari」，点「开始同传」");
    } else if (active.tainted) {
      warning = "⚠︎ 这个网站不允许抓取视频声音（刷新网页可恢复声音）";
    } else {
      warning = active.appWarning;
    }
    render();
  }

  function bytesToBase64(bytes) {
    let bin = "";
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(bin);
  }

  // ---------- 抓声音 ----------
  async function start(video) {
    stop();
    if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (ctx.state !== "running") await ctx.resume();

    let source = sources.get(video);
    if (!source) {
      source = ctx.createMediaElementSource(video);
      source.connect(ctx.destination); // 保证视频声音照常播放
      sources.set(video, source);
    }

    const proc = ctx.createScriptProcessor(4096, 2, 1);
    const ratio = ctx.sampleRate / TARGET_RATE;
    let carry = 0;      // 降采样时跨块剩余的位置
    let zeroBlocks = 0; // 连续全零的块数（用来判断网站不允许抓声音）

    proc.onaudioprocess = (e) => {
      if (!active || active.proc !== proc) return;
      const input = e.inputBuffer;
      const ch0 = input.getChannelData(0);
      const ch1 = input.numberOfChannels > 1 ? input.getChannelData(1) : ch0;
      const n = ch0.length;

      let peak = 0;
      for (let i = 0; i < n; i++) {
        const v = Math.abs(ch0[i]) + Math.abs(ch1[i]);
        if (v > peak) peak = v;
      }
      const playing = !video.paused && !video.muted && video.volume > 0;
      if (playing && peak === 0) {
        zeroBlocks++;
        // 约 4 秒一直是绝对的 0：多半是跨站视频被浏览器屏蔽了声音
        if (zeroBlocks * n / ctx.sampleRate > 4 && !active.tainted) {
          active.tainted = true;
          updateWarning();
        }
      } else if (peak > 0) {
        zeroBlocks = 0;
        if (active.tainted) { active.tainted = false; updateWarning(); }
      }
      if (video.paused) return;

      // 双声道混成单声道，按块平均降采样到 16kHz，转 Int16
      const outLen = Math.floor((n - carry) / ratio);
      const out = new Int16Array(outLen);
      for (let j = 0; j < outLen; j++) {
        const startPos = carry + j * ratio;
        const a = Math.floor(startPos);
        const b = Math.min(n, Math.floor(startPos + ratio));
        let sum = 0;
        for (let i = a; i < b; i++) sum += (ch0[i] + ch1[i]) * 0.5;
        const v = Math.max(-1, Math.min(1, sum / Math.max(1, b - a)));
        out[j] = v < 0 ? v * 0x8000 : v * 0x7fff;
      }
      carry = carry + outLen * ratio - n;
      if (carry < 0) carry = 0;

      if (outLen > 0 && active.connected) active.queue.push(out);
    };
    source.connect(proc);
    proc.connect(ctx.destination); // ScriptProcessor 要接到输出才会运行（输出是静音）

    active = { video, proc, connected: false, tainted: false, appWarning: null, error: null,
               queue: [], inFlight: false, helloSent: false, lastCall: 0, timer: null };
    active.timer = setInterval(pump, 100);
    pump();
    subtitle = { original: "", chinese: "", volatile: false, prevChinese: [] };
    updateWarning();
    requestAnimationFrame(positionLoop);
    refreshButtons();
  }

  function stop() {
    if (!active) return;
    const { video, proc, timer } = active;
    active = null;
    try {
      const source = sources.get(video);
      if (source) source.disconnect(proc);
      proc.disconnect();
    } catch (_) {}
    clearInterval(timer);
    sub.remove();
    refreshButtons();
  }

  // ---------- 视频上的「译」按钮 ----------
  function refreshButtons() {
    const videos = Array.from(document.querySelectorAll("video"));
    for (const [video, btn] of buttons) {
      if (!videos.includes(video) || !video.isConnected) {
        btn.remove();
        buttons.delete(video);
        if (active && active.video === video) stop();
      }
    }
    for (const video of videos) {
      const r = video.getBoundingClientRect();
      let btn = buttons.get(video);
      const visible = r.width >= MIN_VIDEO_WIDTH && r.height >= 60 && r.bottom > 0 && r.top < innerHeight;
      if (!visible) {
        if (btn) btn.style.display = "none";
        continue;
      }
      if (!btn) {
        btn = document.createElement("button");
        btn.className = "ps-btn";
        btn.type = "button";
        btn.textContent = "译";
        btn.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          if (active && active.video === video) stop();
          else start(video).catch((err) => {
            console.error("[双语字幕]", err);
            alert("双语字幕启动失败：" + err);
          });
        }, true);
        buttons.set(video, btn);
      }
      const host = hostFor(video);
      if (btn.parentNode !== host) host.appendChild(btn);
      btn.style.display = "flex";
      btn.style.left = r.right - 48 + "px";
      btn.style.top = r.top + 8 + "px";
      btn.classList.toggle("ps-on", !!(active && active.video === video));
    }
  }

  setInterval(refreshButtons, 500);
  addEventListener("scroll", refreshButtons, { passive: true });
  addEventListener("resize", refreshButtons);
  refreshButtons();
})();

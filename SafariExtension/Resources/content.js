// 双语字幕 Safari 扩展：抓网页视频的声音交给本机 App 识别翻译，再把字幕盖在视频上。
(() => {
  if (window.__psLoaded) return;
  window.__psLoaded = true;

  const TARGET_RATE = 16000;
  const MIN_VIDEO_WIDTH = 160;

  let ctx = null;                      // 全页面共用一个 AudioContext
  const sources = new WeakMap();       // video → MediaElementSourceNode（每个 video 只能建一次）
  const buttons = new Map();           // video → 按钮
  let active = null;                   // 正在翻译的 { video, proc, port, ... }

  // ---------- 字幕层 ----------
  const sub = document.createElement("div");
  sub.className = "ps-sub";
  sub.innerHTML = '<div class="ps-box"><div class="ps-orig"></div><div class="ps-zh"></div></div>';
  const origEl = sub.querySelector(".ps-orig");
  const zhEl = sub.querySelector(".ps-zh");
  let subtitle = { original: "", chinese: "", volatile: false };
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
    const empty = !origEl.textContent && !zhEl.textContent;
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
      const zhSize = Math.max(14, Math.min(30, r.width / 22));
      zhEl.style.fontSize = zhSize + "px";
      origEl.style.fontSize = Math.round(zhSize * 0.72) + "px";
      sub.style.display = "block";
      sub.style.left = r.left + r.width * 0.04 + "px";
      sub.style.width = r.width * 0.92 + "px";
      sub.style.top = Math.max(r.top, r.bottom - sub.offsetHeight - r.height * 0.06) + "px";
    }
    requestAnimationFrame(positionLoop);
  }

  // ---------- 和扩展后台 / App 通信 ----------
  function connectPort() {
    const port = browser.runtime.connect({ name: "ps-audio" });
    port.onMessage.addListener((msg) => {
      if (!msg || !active) return;
      if (msg.type === "conn") {
        active.connected = msg.ok;
        updateWarning();
      } else if (msg.type === "sub") {
        subtitle = { original: msg.original || "", chinese: msg.chinese || "", volatile: !!msg.volatile };
        render();
      } else if (msg.type === "status") {
        active.appWarning = msg.warning || null;
        updateWarning();
      }
    });
    port.onDisconnect.addListener(() => {
      // 扩展后台被系统回收时会断开，自动重连
      if (active && active.port === port) {
        active.connected = false;
        updateWarning();
        setTimeout(() => { if (active && active.port === port) active.port = connectPort(); }, 1000);
      }
    });
    return port;
  }

  function updateWarning() {
    if (!active) return;
    if (!active.connected) {
      warning = "⚠︎ 连不上双语字幕 App：请打开 App，音源选「Safari」，点「开始同传」";
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

      if (outLen > 0 && active.connected) {
        try {
          active.port.postMessage({ type: "audio", data: bytesToBase64(new Uint8Array(out.buffer)) });
        } catch (_) {}
      }
    };
    source.connect(proc);
    proc.connect(ctx.destination); // ScriptProcessor 要接到输出才会运行（输出是静音）

    active = { video, proc, port: null, connected: false, tainted: false, appWarning: null };
    active.port = connectPort();
    subtitle = { original: "", chinese: "", volatile: false };
    updateWarning();
    requestAnimationFrame(positionLoop);
    refreshButtons();
  }

  function stop() {
    if (!active) return;
    const { video, proc, port } = active;
    active = null;
    try {
      const source = sources.get(video);
      if (source) source.disconnect(proc);
      proc.disconnect();
    } catch (_) {}
    try { port.disconnect(); } catch (_) {}
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

# PrivateSubtitles · 双语同传字幕（iOS 26，自用）

看视频时实时把英文语音翻译成中文，用画中画悬浮窗显示双语字幕。

## 架构

```
音频源 ──► 端侧语音识别 ──► 断句 ──► Claude 翻译 ──► 双语字幕
(P1 麦克风 /        (SpeechTranscriber,     (claude-haiku-5-5,   (P1 App 内 /
 P3 广播扩展)         免费离线)               按量付费, 流式)      P2 画中画悬浮窗)
```

| 目录 | 内容 |
|---|---|
| `App/Pipeline/` | 麦克风采集、音频格式转换、语音识别、Claude 翻译、管线编排 |
| `App/UI/` | 主界面（当前字幕 + 历史）、设置（API Key、模型、字号）、日志 |
| `App/Support/` | App 内日志、钥匙串 |
| `project.yml` | XcodeGen 工程描述（`.xcodeproj` 不进仓库，CI 里生成） |
| `.github/workflows/build.yml` | GitHub Actions：macOS 上编译并产出 IPA |

## 进度

- [x] **P0** 工程骨架 + CI 编译
- [x] **P1** 麦克风 → 端侧识别 → Claude 翻译 → App 内双语字幕
- [x] **P2** 画中画（PiP）悬浮字幕窗：切到后台自动弹出，也可手动开关
- [x] **P3** ReplayKit 广播扩展：抓 Safari 等其他 App 的声音（音源选「系统声音」）
- [ ] **P4** 字幕样式、导出 SRT、费用统计、TestFlight 自动上传

## 怎么拿到 IPA

1. 推送到 `main`，GitHub Actions 会自动编译。
2. 在仓库的 **Actions** 页 → 最新一次运行 → **Artifacts** 里下载 `PrivateSubtitles-unsigned-ipa`。
3. 现在是**未签名** IPA，用 SideStore / AltStore 自签安装；有开发者账号后改为 TestFlight。

## 第一次使用

1. 打开 App → 右上角齿轮 → 填 Anthropic API Key（console.anthropic.com 创建）。
2. 点「开始同传」，允许麦克风和语音识别权限。第一次会下载英文语音模型。
3. 在旁边的电脑上放一段英文视频，手机上就会出现中英双语字幕。
4. 出问题时：左上角「日志」→ 分享按钮导出日志。

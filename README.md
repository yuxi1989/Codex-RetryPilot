# Codex-RetryPilot

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

## 中文

macOS 菜单应用：监控 Codex 桌面端，遇到 **"Selected model is at capacity. Please try a different model."** 时自动点击「重试」，无人值守持续恢复会话。

### 功能特性

- **三级点击策略**（由「静默点击」开关控制）：
  1. 无障碍按压（AXPress，光标不动、不抢焦点）
  2. 原生后台点击兜底（`CGEvent.postToPid` 直接向 Codex 进程投递鼠标事件，不动光标、不切前台、窗口被遮挡也能点；**零外部依赖，无需 OCU/Node**）
  3. 坐标点击兜底（CGEvent + 光标归位 + System Events 焦点归还；**必须 AX 树当前扫到「重试」按钮才执行**，杜绝盲点）
- **空闲自动发送**：Codex 无错误行且无重试按钮持续 N 分钟（可配），把多行输入区的下一行文本经原生 AX 后台通道（kAXValue 直写 → AXConfirm / Return 键投递）发进 Codex 输入框，不抢焦点
- **配置持久化**：所有参数变更即写入 `~/Library/Application Support/CodexRetry/config.json`（保留旧目录名以兼容已保存配置和自学习模板）
- **配置导入/导出**：JSON 文件
- **权限引导**：辅助功能 / 屏幕录制 / 自动化 三项权限逐项独立引导框，含「在访达中显示」快捷导入与 tccutil 重置再触发
- 其他：运行时长（支持自定义）、检查间隔、防息屏、空闲自动停止、提示音、试运行、模板自动学习、运行日志（一次操作一行结论）

### 构建与安装

```bash
# 编译（SDK 路径必需）
cd <项目目录>
export SDKROOT=$(xcrun --show-sdk-path)
xcrun swiftc -O main.swift -o /tmp/CodexRetry-new

# 安装（bundle id 保持 com.zhuxiaoyu.codexretry 以保留 TCC 授权）
cp /tmp/CodexRetry-new ~/Applications/Codex-RetryPilot.app/Contents/MacOS/CodexRetry

# 签名（自签证书 "Codex-RetryPilot"，同一证书重签权限保持稳定）
codesign --force --sign "Codex-RetryPilot" \
  --keychain ~/Library/Keychains/codexretry-signing.keychain-db \
  ~/Applications/Codex-RetryPilot.app
codesign --verify ~/Applications/Codex-RetryPilot.app
```

> ⚠️ **注意事项**
> - 不要改 bundle id——TCC 权限按 bundle id + 签名归属，改了三项权限全部要重授。
> - **换签名证书 = 权限重置**：TCC 记录绑定证书指纹，换成其他证书（包括未来的 Developer ID 证书）后三项权限要重新授权一次。
> - 签名钥匙串：`~/Library/Keychains/codexretry-signing.keychain-db`；当前签名身份 **"Codex-RetryPilot"**（v3.3.0 起，openssl 自签 10 年，CN=Codex-RetryPilot）；旧身份 "CodexRetry Local Signing" 保留备用。密码见密码管理记录。
> - 本仓库 **`certs/` 目录包含私钥，已被 `.gitignore` 排除，永远不要提交或加入发布包**。

### 文件说明

| 文件 | 用途 |
|---|---|
| `main.swift` | 应用主体（AppKit 单文件） |
| `readlog.swift` | 经 AX 读取运行中 app 的窗口日志（窗口被遮挡时排错用） |
| `startviaax.swift` | 经 AX 点击「开始监控」 |
| `focustest.swift` | 焦点测量（验证点击前后前台变化） |
| `procinfo.swift` | 读进程 RSS/CPU |
| `diag5.swift` / `analyzetpl.swift` | 诊断与模板分析 |
| `templates/` | 早期模板素材（运行时模板在 `~/Library/Application Support/CodexRetry/template*.png`，支持自动学习收录） |
| `certs/` | 签名与公证材料（**不入库**） |

### 关键实现备忘

- **Chromium/Electron 兼容**：必须强写 `AXManualAccessibility` + `AXEnhancedUserInterface`，否则 AX 树为空
- **按压生效判定**：轮询「重试按钮短暂消失」，避免 AXPress 假成功；假成功降级只认「后台点击确实投递了但没生效」
- **焦点归还**：System Events AppleScript **必须在主线程执行**（NSAppleScript 后台线程会静默失败）；osascript 子进程探测（`probeViaOsascript`）是自动化授权弹框最可靠的触发方式——`AEDeterminePermissionToAutomateTarget` 的返回值不可信
- **原生后台点击/输入**（v3.3.0 起替代 OCU）：点击 = `CGEvent.postToPid(pid)`（鼠标 down/up 到按钮中心）；空闲发送 = `kAXValue` 直写 AXTextArea → 回读确认 → `AXConfirm`（失败投递 keyCode 36 Return）→ 读回验证已清空。Chromium 需先强写 AXManualAccessibility
- **重签会改 cdhash 但 DR 不变**：TCC 记录在 `codesign --force`（同一证书）下保持有效
- **日志精简原则**：成功只打一行结论，失败才展开

### 版本历史

| 版本 | 日期 | 说明 |
|---|---|---|
| v3.3.0 | 2026-10-23 | **移除 OCU 依赖，全部原生化**——sky_click 改为 `CGEvent.postToPid` 原生后台点击，空闲发送改为 AX 直写 + AXConfirm/Return 投递；app 零外部依赖单文件。config 结构未变，旧配置直接兼容 |
| v3.2.0 | 2026-10-23 | **UI 现代化重构**——分组卡片布局、权限状态彩色胶囊、SF Symbol 图标、NSSwitch 开关；功能与 v3.0.4 一致 |
| v3.0.4 | 2026-10-23 | 空闲自动发送、配置持久化/导入导出、三权限引导、自动化授权修复（osascript 链路）、输入框失焦保存 |

### 分发说明

- 自签 / Developer ID 签名后经 GitHub 分发均**不违反 Apple 协议**（macOS 允许 App Store 外分发）。
- 自签版本：用户首次打开需右键 →「打开」，或 `xattr -cr Codex-RetryPilot.app` 去除隔离属性。
- Developer ID + 公证版本：可直接双击打开（需 Apple Developer Program，$99/年）。
- **禁止使用 Enterprise 证书公开分发**（违反协议，证书会被吊销）。

---

<a id="english"></a>

## English

A macOS menu app that monitors the Codex desktop client and automatically clicks **"Retry"** when it shows **"Selected model is at capacity. Please try a different model."**, keeping your session alive unattended.

### Features

- **Three-tier click strategy** (controlled by the "Silent Click" toggle):
  1. Accessibility press (AXPress — no cursor movement, no focus stealing)
  2. Native background click fallback (`CGEvent.postToPid` posts mouse events directly to the Codex process — cursor stays put, frontmost app unchanged, works even when the window is occluded; **zero external dependencies, no OCU/Node needed**)
  3. Coordinate-click fallback (CGEvent + cursor restore + focus return via System Events; **only fires when the "Retry" button is actually present in the AX tree** — no blind clicks)
- **Idle auto-send**: when Codex shows no error line and no Retry button for N minutes (configurable), sends the next line from a multi-line input queue into Codex via the native AX channel (kAXValue write → AXConfirm / Return key delivery) without stealing focus
- **Config persistence**: every change is written immediately to `~/Library/Application Support/CodexRetry/config.json` (legacy directory name kept for compatibility with saved configs and self-learned templates)
- **Config import/export**: JSON files
- **Permission onboarding**: guided, per-permission dialogs for Accessibility / Screen Recording / Automation, including "Reveal in Finder" quick import and tccutil reset-and-retry
- Also: run duration (custom values supported), check interval, sleep prevention, idle auto-stop, sound alerts, dry-run mode, template auto-learning, and a one-line-per-action run log

### Build & Install

```bash
# Compile (SDK path required)
cd <project-dir>
export SDKROOT=$(xcrun --show-sdk-path)
xcrun swiftc -O main.swift -o /tmp/CodexRetry-new

# Install (keep bundle id com.zhuxiaoyu.codexretry to preserve TCC grants)
cp /tmp/CodexRetry-new ~/Applications/Codex-RetryPilot.app/Contents/MacOS/CodexRetry

# Sign (self-signed cert "Codex-RetryPilot"; re-signing with the same cert keeps TCC grants)
codesign --force --sign "Codex-RetryPilot" \
  --keychain ~/Library/Keychains/codexretry-signing.keychain-db \
  ~/Applications/Codex-RetryPilot.app
codesign --verify ~/Applications/Codex-RetryPilot.app
```

> ⚠️ **Notes**
> - Never change the bundle id — TCC permissions are tied to bundle id + signing identity; changing it requires re-granting all three permissions.
> - **Changing the signing certificate = permission reset**: TCC records are bound to the certificate fingerprint. Switching certs (including a future Developer ID cert) requires re-authorization.
> - Signing keychain: `~/Library/Keychains/codexretry-signing.keychain-db`; current identity **"Codex-RetryPilot"** (since v3.3.0, openssl self-signed, 10-year, CN=Codex-RetryPilot); legacy identity "CodexRetry Local Signing" kept as backup. Passwords are in the password manager.
> - The **`certs/` directory contains private keys** — excluded by `.gitignore`, and must never be committed or included in release archives.

### Files

| File | Purpose |
|---|---|
| `main.swift` | Main app (single-file AppKit) |
| `readlog.swift` | Read the running app's on-window log via AX (for debugging when occluded) |
| `startviaax.swift` | Click "Start Monitoring" via AX |
| `focustest.swift` | Focus measurement (verify frontmost-app changes around clicks) |
| `procinfo.swift` | Read process RSS/CPU |
| `diag5.swift` / `analyzetpl.swift` | Diagnostics and template analysis |
| `templates/` | Early template assets (runtime templates live at `~/Library/Application Support/CodexRetry/template*.png`, with auto-learning) |
| `certs/` | Signing & notarization material (**never committed**) |

### Implementation Notes

- **Chromium/Electron compatibility**: must force-set `AXManualAccessibility` + `AXEnhancedUserInterface`, otherwise the AX tree is empty
- **Press-effect verification**: polls for the Retry button's brief disappearance to avoid AXPress false positives; fallback to coordinate click only when a background click was truly delivered but had no effect
- **Focus return**: System Events AppleScript **must run on the main thread** (NSAppleScript silently fails off-main); the osascript subprocess probe (`probeViaOsascript`) is the most reliable way to trigger the Automation TCC prompt — `AEDeterminePermissionToAutomateTarget` return values are unreliable
- **Native background click/input** (replacing OCU since v3.3.0): click = `CGEvent.postToPid(pid)` (mouse down/up at button center); idle send = kAXValue write to AXTextArea → read-back verify → `AXConfirm` (fallback: Return key, keyCode 36) → verify cleared. Chromium requires the AXManualAccessibility keys first
- **Re-signing changes cdhash but not DR**: TCC records stay valid under `codesign --force` with the same certificate
- **Log discipline**: one conclusive line per successful action; details only on failure

### Version History

| Version | Date | Notes |
|---|---|---|
| v3.3.0 | 2026-10-23 | **Removed OCU dependency, fully native** — sky_click replaced by `CGEvent.postToPid` background clicks; idle send now uses AX write + AXConfirm/Return delivery; zero-dependency single binary. Config structure unchanged |
| v3.2.0 | 2026-10-23 | **Modernized UI** — grouped card layout, colored permission pills, SF Symbol icons, NSSwitch toggles; functionally identical to v3.0.4 |
| v3.0.4 | 2026-10-23 | Idle auto-send, config persistence/import/export, three-permission onboarding, Automation grant fix (osascript path), blur-save on all inputs |

### Distribution

- Distributing via GitHub after self-signing or Developer ID signing is **fully compliant** with Apple's terms (macOS allows distribution outside the App Store).
- Self-signed builds: users must right-click → "Open" on first launch, or clear quarantine with `xattr -cr Codex-RetryPilot.app`.
- Developer ID + notarized builds: open directly by double-click (requires Apple Developer Program, $99/year).
- **Never distribute publicly with an Enterprise certificate** (violates the agreement; the cert will be revoked).

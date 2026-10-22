# Codex-RetryPilot

macOS 菜单应用：监控 Codex 桌面端，遇到 "Selected model is at capacity. Please try a different model." 时自动点击「重试」，无需人工值守。

## 功能

- **三级点击策略**（由「静默点击」开关控制）：
  1. 无障碍按压（AXPress，光标不动、不抢焦点）
  2. 原生后台点击兜底（`CGEvent.postToPid` 直接向 Codex 进程投递鼠标事件，不动光标、不切前台、窗口被遮挡也能点；**零外部依赖，无需 OCU/Node**）
  3. 坐标点击兜底（CGEvent + 光标归位 + System Events 焦点归还；**必须 AX 树当前扫到「重试」按钮才执行**，杜绝盲点）
- **空闲自动发送**：Codex 无错误行且无重试按钮持续 N 分钟（可配），把多行输入区的下一行文本经原生 AX 后台通道（kAXValue 直写 → AXConfirm / Return 键投递）发进 Codex 输入框，不抢焦点
- **配置持久化**：所有参数变更即写入 `~/Library/Application Support/CodexRetry/config.json`（保留旧目录名以兼容已保存配置和自学习模板）
- **配置导入/导出**：JSON 文件
- **权限引导**：辅助功能 / 屏幕录制 / 自动化 三项必需权限逐项独立引导框，含「在访达中显示」快捷导入与 tccutil 重置再触发
- 运行时长（支持自定义）、检查间隔、防息屏、空闲自动停止、提示音、试运行、模板自动学习、运行日志（一次操作一行结论）

## 构建与安装

```bash
# 编译（SDK 路径必需）
cd /Users/zhuxiaoyu/GitGit/Codex-RetryPilot
export SDKROOT=$(xcrun --show-sdk-path)
xcrun swiftc -O main.swift -o /tmp/CodexRetry-new

# 安装（bundle id 保持 com.zhuxiaoyu.codexretry 以保留 TCC 授权）
cp /tmp/CodexRetry-new ~/Applications/Codex-RetryPilot.app/Contents/MacOS/CodexRetry

# 签名（自签证书 "Codex-RetryPilot"，权限在重签名间保持稳定）
codesign --force --sign "Codex-RetryPilot" \
  --keychain ~/Library/Keychains/codexretry-signing.keychain-db \
  ~/Applications/Codex-RetryPilot.app
codesign --verify ~/Applications/Codex-RetryPilot.app
```

> ⚠️ 不要改 bundle id——TCC 权限按 bundle id + 签名归属，改了三项权限全部要重授。
> **换签名证书 = 权限重置**：TCC 记录绑定证书指纹，换成其他证书（包括未来的 Developer ID 证书）后三项权限要重新授权一次。
> 签名钥匙串：`~/Library/Keychains/codexretry-signing.keychain-db`；当前签名身份 **"Codex-RetryPilot"**（v3.3.0 起，openssl 自签 10 年，CN=Codex-RetryPilot）；旧身份 "CodexRetry Local Signing" 保留在钥匙串中备用。密码见密码管理记录。

## 文件说明

| 文件 | 用途 |
|---|---|
| `main.swift` | 应用主体（AppKit 单文件，~1600 行） |
| `readlog.swift` | 经 AX 读取运行中 app 的窗口日志（窗口被遮挡时排错用） |
| `startviaax.swift` | 经 AX 点击「开始监控」 |
| `focustest.swift` | 焦点测量（验证点击前后前台变化） |
| `procinfo.swift` | 读进程 RSS/CPU |
| `diag5.swift` / `analyzetpl.swift` | 诊断与模板分析 |
| `templates/` | 早期模板素材（运行时实际模板在 `~/Library/Application Support/CodexRetry/template*.png`，支持自动学习收录） |

## 关键实现备忘

- **Chromium/Electron 兼容**：必须强写 `AXManualAccessibility` + `AXEnhancedUserInterface`，否则 AX 树为空
- **按压生效判定**：轮询「重试按钮短暂消失」，避免 AXPress 假成功；假成功降级只认「后台点击确实投递了但没生效」
- **焦点归还**：System Events AppleScript **必须在主线程执行**（NSAppleScript 后台线程会静默失败）；osascript 子进程探测（`probeViaOsascript`）是自动化授权弹框最可靠的触发方式——`AEDeterminePermissionToAutomateTarget` 的返回值不可信
- **日志精简原则**：成功只打一行结论，失败才展开
- **原生后台点击/输入**（v3.3.0 起替代 OCU）：点击 = `CGEvent.postToPid(pid)`（鼠标 down/up 到按钮中心）；空闲发送 = `kAXValue` 直写 AXTextArea → 回读确认 → `AXConfirm`（失败投递 keyCode 36 Return）→ 读回验证已清空。Chromium 需先强写 AXManualAccessibility
- **重签会改 cdhash 但 DR 不变**：TCC 记录在 `codesign --force`（同一证书）下保持有效

## 当前版本

v3.3.0（2026-10-23）：**移除 OCU 依赖，全部原生化**——sky_click 改为 `CGEvent.postToPid` 原生后台点击，空闲发送改为 AX 直写 + AXConfirm/Return 投递；删除「安装 OCU」按钮与 Node/ocu 路径解析；app 零外部依赖单文件。config 结构未变，旧配置直接兼容。

v3.2.0（2026-10-23）：**UI 现代化重构**——分组卡片布局（监控参数/点击方式/运行选项/空闲自动发送）、权限状态彩色胶囊（头部右侧）、SF Symbol 图标按钮、NSSwitch 开关两列排布；功能与 v3.0.4 完全一致（outlet 名与 config 结构未变，旧配置直接兼容）。

v3.0.4（2026-10-23）：空闲自动发送、配置持久化/导入导出、三权限引导、自动化授权修复（osascript 链路）、全输入框失焦保存。

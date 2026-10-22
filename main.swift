import Cocoa
import ApplicationServices
import CoreGraphics

// MARK: - 全局状态

let CODEX_BUNDLE = "com.openai.codex"
let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexRetry")
let templatePath = appSupportDir.appendingPathComponent("template.png")

func ensureSupportDir() {
    try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: templatePath.path),
       let bundled = Bundle.main.url(forResource: "tpl_check", withExtension: "png") {
        try? FileManager.default.copyItem(at: bundled, to: templatePath)
    }
}

// MARK: - AX 工具

func axAttr(_ el: AXUIElement, _ key: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
    return v
}

func axStr(_ el: AXUIElement, _ key: String) -> String {
    axAttr(el, key).map { "\($0)" } ?? ""
}

func axRect(_ el: AXUIElement) -> CGRect? {
    guard let pv = axAttr(el, kAXPositionAttribute), CFGetTypeID(pv as CFTypeRef) == AXValueGetTypeID(),
          let sv = axAttr(el, kAXSizeAttribute), CFGetTypeID(sv as CFTypeRef) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt),
          AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}

struct ErrorRow { let rect: CGRect }

struct CodexScan {
    var rows: [ErrorRow] = []
    var buttons: [(el: AXUIElement, rect: CGRect)] = []
}

/// 单次全树遍历同时收集错误行与「重试」按钮，避免一个周期内多次遍历（AX 属性读取是跨进程 IPC，开销大）
func scanCodex() -> CodexScan {
    guard let app = codexApp() else { return CodexScan() }
    var s = CodexScan()
    func walk(_ el: AXUIElement, _ depth: Int) {
        if depth > 60 { return }
        let role = axStr(el, kAXRoleAttribute)
        if role == "AXStaticText" {
            if axStr(el, kAXValueAttribute).contains("at capacity"),
               let r = axRect(el), r.height > 5 {
                s.rows.append(ErrorRow(rect: r))
            }
        } else if role == "AXButton", axStr(el, kAXTitleAttribute) == "重试",
                  let r = axRect(el), r.height > 8 {
            s.buttons.append((el, r))
        }
        if let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    walk(AXUIElementCreateApplication(app.processIdentifier), 0)
    return s
}

func codexApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "") == CODEX_BUNDLE })
}

/// 所有显示器的联合范围（CG 全局坐标 = 顶部左侧原点，与 AX 一致）
func displaysUnion() -> CGRect {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else {
        return NSScreen.screens.first?.frame ?? .zero
    }
    var union = CGRect.null
    for i in 0..<Int(count) { union = union.union(CGDisplayBounds(ids[i])) }
    return union
}

// MARK: - 截图 / 比对 / 点击

func captureRegion(_ rect: CGRect) -> CGImage? {
    let path = NSTemporaryDirectory() + "codexretry_cand.png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", "-R",
                   "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
    try? p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func grayPixels(_ img: CGImage, w: Int, h: Int) -> [UInt8]? {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let d = ctx.data else { return nil }
    return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self), count: w * h))
}

/// 自适应「笔画掩码」：取与图像自身亮度中心偏离的像素。
/// 极性无关 —— 亮底深字（浅色模式）和深底亮字（深色模式）都能正确提取笔画。
/// 阈值带下限 12，避免纯色区域的噪声被当成笔画。
func inkMask(_ g: [UInt8], k: Double) -> ([Bool], Int) {
    let n = Double(g.count)
    let mean = Double(g.reduce(0) { $0 + Int($1) }) / n
    let varr = g.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
    let std = varr.squareRoot()
    let th = max(k * std, 12.0)
    var count = 0
    let mask = g.map { v -> Bool in
        let d = abs(Double(v) - mean) > th
        if d { count += 1 }
        return d
    }
    return (mask, count)
}

/// 模板匹配：返回 nil 表示无法判断，true/false 表示匹配结果
func matchesTemplate(candidate: CGImage, template: CGImage) -> (matched: Bool, detail: String) {
    let W = 160, H = 60
    guard let tg = grayPixels(template, w: W, h: H), let cg = grayPixels(candidate, w: W, h: H) else {
        return (false, "图像解码失败")
    }
    let (tm, tCount) = inkMask(tg, k: 0.8)
    let (cm, cCount) = inkMask(cg, k: 0.8)
    guard tCount > 30, tCount < 2000 else { return (false, "模板异常(笔画像素\(tCount))") }
    var xor = 0
    for i in 0..<(W * H) where tm[i] != cm[i] { xor += 1 }
    let ok = Double(xor) < Double(tCount) * 0.9
        && cCount > tCount / 3
        && cCount < tCount * 3
    return (ok, "t=\(tCount) c=\(cCount) xor=\(xor)")
}

func loadTemplates() -> [URL] {
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(at: appSupportDir, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix("template") && $0.pathExtension == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    return files
}

func pruneTemplates(keep: Int) {
    let files = loadTemplates()
    guard files.count > keep else { return }
    for f in files.prefix(files.count - keep) {
        try? FileManager.default.removeItem(at: f)
    }
}

/// 从单次扫描结果里挑出离错误行最近（y 差 <30pt）的重试按钮（元素 + 矩形）
func retryButton(from scan: CodexScan, near row: CGRect) -> (el: AXUIElement, rect: CGRect)? {
    scan.buttons
        .filter { abs($0.rect.midY - row.midY) < 30 }
        .max(by: { $0.rect.minY < $1.rect.minY })
        .map { (el: $0.el, rect: $0.rect) }
}

/// 强制开启 Codex(Electron/Chromium) 渲染进程的无障碍支持。
/// 没有它时渲染层可能未启用 a11y，AXPress 会「假成功」（返回成功但不执行点击）。
func enableRendererAccessibility(_ app: NSRunningApplication) {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

/// 全局点击（会占用光标），点完立刻把光标挪回原位
func clickGlobally(_ pt: CGPoint) {
    let saved = CGEvent(source: nil)?.location
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        if let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
        usleep(60000)
    }
    if let saved { CGWarpMouseCursorPosition(saved) }
}

func targetPoint(for row: CGRect) -> CGPoint {
    CGPoint(x: row.minX + row.width + 295, y: row.midY)
}

// MARK: - 权限检测（辅助功能 / 屏幕录制 / 自动化 System Events）

/// System Events（焦点归还用的自动化权限）状态："granted" / "denied" / "unknown"
func systemEventsAutomationStatus() -> String {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
    let err = AEDeterminePermissionToAutomateTarget(target.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    if err == 0 { return "granted" }
    if err == errAEEventNotPermitted { return "denied" }
    return "unknown"
}

/// 主动发一个最小 Apple Event 给 System Events：
/// 未确定时会触发系统授权弹窗（并在设置里生成条目）；被拒时返回 false
@discardableResult
func probeSystemEventsPermission() -> Bool {
    guard let osa = NSAppleScript(source:
        "tell application \"System Events\" to get name of first application process whose frontmost is true") else { return false }
    var err: NSDictionary?
    _ = osa.executeAndReturnError(&err)
    let code = (err?["NSAppleScriptErrorNumber"] as? Int) ?? 0
    return code == 0
}

/// 强制触发自动化授权弹框：promptUser=true，未确定/状态卡住时系统会弹授权框并生成条目。
/// 比 NSAppleScript 探测可靠——后者在部分状态下会被系统静默吞掉不弹框。
func promptSystemEventsPermission() -> Bool {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
    let err = AEDeterminePermissionToAutomateTarget(target.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    return err == 0
}

/// 重置本应用的 Apple Events 授权记录（tccutil 只能重置自己的 bundle id）。
/// 用于「被拒/卡住后再也不弹框」的情况，重置后重新探测会弹新授权框。
@discardableResult
func resetOwnAppleEventsPermission() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    p.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "com.zhuxiaoyu.codexretry"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// osascript 子进程探测（从 v2.4.1 原样恢复——01:06 那次授权成功走的就是这条路径）：
/// 子进程发 AppleScript，TCC 把请求归因到父应用（本应用），系统弹授权框时
/// 本调用阻塞到用户点完为止（最多 60s）。
@discardableResult
func probeViaOsascript() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to get name of first application process whose frontmost is true"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return false }
    // 等待授权弹框被处理：最多 60s（用户可能要点弹框）
    let deadline = Date().addingTimeInterval(60)
    while p.isRunning && Date() < deadline { usleep(200_000) }
    if p.isRunning { p.terminate(); return false }
    return p.terminationStatus == 0
}

// MARK: - 原生后台点击 / 后台输入（sky_click 的本机替代，零外部依赖）

/// 向指定进程后台投递鼠标点击（等价 ocu sky_click 的本机实现）：
/// 不动真实光标、不切前台、不改键盘焦点，窗口被遮挡也能点。
func postClickToPid(_ pid: pid_t, at pt: CGPoint) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) else { continue }
        ev.postToPid(pid)
        usleep(60000)
    }
}

/// 向指定进程后台投递 Return 键（不切前台）。返回是否成功投递。
func postReturnKeyToPid(_ pid: pid_t) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return false }
    down.postToPid(pid)
    usleep(30000)
    up.postToPid(pid)
    return true
}

/// 查找 Codex 界面里最后一个多行文本域（输入框；深度优先取最后命中，与原 OCU 查询语义一致）
func findCodexTextArea() -> AXUIElement? {
    guard let app = codexApp() else { return nil }
    var found: AXUIElement?
    func walk(_ el: AXUIElement, _ depth: Int) {
        if depth > 60 { return }
        if axStr(el, kAXRoleAttribute) == "AXTextArea" { found = el }
        if let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    walk(AXUIElementCreateApplication(app.processIdentifier), 0)
    return found
}

/// 把一行文本写入 Codex 输入框并回车（原生实现，不抢焦点、光标不动）：
/// AX 直写 kAXValue → 回读确认 → AXConfirm（失败则向进程投递 Return 键）→ 读回验证已清空。
/// 返回 "sent" / "unclear" / "nofield" / "error: ..."。
func nativeSendLine(_ line: String) -> String {
    guard let app = codexApp() else { return "nofield" }
    enableRendererAccessibility(app)
    guard let ta = findCodexTextArea() else { return "nofield" }
    let res = AXUIElementSetAttributeValue(ta, kAXValueAttribute as CFString, line as CFString)
    guard res == .success else { return "error: AX 写入失败 code=\(res.rawValue)" }
    usleep(300_000)
    guard axStr(ta, kAXValueAttribute) == line else { return "unclear" }
    if AXUIElementPerformAction(ta, "AXConfirm" as CFString) != .success {
        _ = postReturnKeyToPid(app.processIdentifier)
    }
    usleep(800_000)
    let after = axStr(ta, kAXValueAttribute)
    return after != line ? "sent" : "unclear" // 输入框内容已变化（通常被清空）即视为发出
}

// MARK: - 控制器

final class Controller: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    var window: NSWindow!
    var durationPopup: NSPopUpButton!
    var customField: NSTextField!
    var intervalField: NSTextField!
    var idleSendField: NSTextField!
    var idleSendCheck: NSSwitch!
    var scriptView: NSTextView!
    var dryRunCheck: NSSwitch!
    var idleStopCheck: NSSwitch!
    var focusReturnCheck: NSSwitch!
    var soundCheck: NSSwitch!
    var silentClickCheck: NSSwitch!
    var autoLearnCheck: NSSwitch!
    var noSleepCheck: NSSwitch!
    var startBtn: NSButton!
    var stopBtn: NSButton!
    var calibBtn: NSButton!
    var permBtn: NSButton!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var permAxLabel: NSTextField!
    var permScLabel: NSTextField!
    var permAutoLabel: NSTextField!

    var running = false
    var clicks = 0
    var customMinutes = 45
    var deadline = Date()
    var lastErrorAt = Date()
    var failStreak = 0
    var skyNomatchAt = Date.distantPast
    var statusTimer: Timer?
    var workQueue = DispatchQueue(label: "codexretry.worker")
    var currentInterval: Double = 10
    var pmAssertion: UInt32 = 0
    var pmReleaseFn: ((UInt32) -> Int32)?

    // MARK: UI

    func applicationDidFinishLaunching(_ n: Notification) {
        ensureSupportDir()
        buildUI()
        loadConfig()
        appendLog("就绪。目标应用：Codex（com.openai.codex）")
        let missing = missingPermissions()
        if missing.isEmpty {
            appendLog("✅ 权限检查通过：辅助功能 / 屏幕录制 / 自动化 均已授权")
        } else {
            appendLog("⚠️ 缺少权限：\(missing.joined(separator: "、"))—— 即将弹出引导，逐项授权")
        }
        // 三项权限统一引导：后台探测的 TCC 弹框常被系统抑制，
        // 改为弹引导框，用户点击「逐项授权」时在前台逐项请求，弹框出现率高
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showPermissionGuide(auto: true)
        }
    }

    /// 必需权限缺失清单（三项均为必需：辅助功能 / 屏幕录制 / 自动化）
    func missingPermissions() -> [String] {
        var missing: [String] = []
        if !AXIsProcessTrusted() { missing.append("辅助功能") }
        if !CGPreflightScreenCaptureAccess() { missing.append("屏幕录制") }
        if systemEventsAutomationStatus() != "granted" { missing.append("自动化(焦点归还)") }
        return missing
    }

    /// 逐个权限独立引导框：启动 1 秒后 / 「打开授权设置」时调用
    func showPermissionGuide(auto: Bool) {
        let missing = missingPermissions()
        guard !missing.isEmpty else { refreshPermLabel(); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if missing.contains("辅助功能") {
            guideOnePermission(
                name: "辅助功能",
                why: "读取 Codex 的界面元素、无障碍按压「重试」按钮（主点击路径）。没有它完全无法工作。",
                pane: "Privacy_Accessibility",
                trigger: { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) })
        }
        if missing.contains("屏幕录制") {
            guideOnePermission(
                name: "屏幕录制",
                why: "截图做模板匹配，验证 “at capacity” 错误行是否出现。缺失时无法识别错误。",
                pane: "Privacy_ScreenCapture",
                trigger: { CGRequestScreenCaptureAccess() })
        }
        if missing.contains("自动化(焦点归还)") {
            guideOnePermission(
                name: "自动化（焦点归还需要）",
                why: "坐标点击兜底后，需要通过 System Events 把原应用调回前台。\n若 设置 › 隐私与安全性 › 自动化 列表里一直没有本应用条目：点「重置记录后再触发」清掉卡住的授权状态，系统会重新弹出授权框。",
                pane: "Privacy_Automation",
                trigger: triggerAutomationPermission,
                automation: true)
        }
        refreshPermLabel()
        let still = missingPermissions()
        if still.isEmpty {
            appendLog("✅ 三项权限全部就绪（辅助功能 / 屏幕录制 / 自动化）")
        } else {
            appendLog("⛔️ 仍未授权：\(still.joined(separator: "、"))—— 可用「在访达中显示」把应用拖进设置列表")
        }
    }

    /// 自动化授权触发：先确保 System Events 进程已运行，然后
    /// 主路：NSAppleScript 直发（未授权状态会触发系统 TCC 授权框，阻塞等待用户操作）；
    /// 兜底：强制弹框 API。全程记录原始错误码，便于诊断。
    func triggerAutomationPermission() -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-b", "com.apple.systemevents"]
            try? p.run()
            var waited = 0.0
            while waited < 6 {
                if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty { break }
                usleep(300_000)
                waited += 0.3
            }
        }
        let seRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty
        appendLog("🔎 System Events 进程：\(seRunning ? "已运行" : "未运行（拉起失败）")")

        // 1. AppleScript 直发（未确定状态时系统弹授权框，此调用阻塞到用户点完）
        if let osa = NSAppleScript(source:
            "tell application \"System Events\" to get name of first application process whose frontmost is true") {
            var err: NSDictionary?
            _ = osa.executeAndReturnError(&err)
            if err == nil {
                appendLog("✅ AppleScript 直发成功（自动化已授权）")
                return true
            }
            let code = (err?["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let brief = (err?["NSAppleScriptErrorBriefMessage"] as? String) ?? ""
            appendLog("🔎 AppleScript 直发失败 code=\(code) \(brief)")
            if code == -10004 {
                appendLog("💡 -10004 = 特权违规：通常是本进程被系统按沙盒来源归因。请完全退出本应用后，从访达/启动台直接双击打开再试")
            }
        }

        // 2. 强制弹框 API（v2.4.1 原版第一层）
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        let err2 = AEDeterminePermissionToAutomateTarget(target.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
        appendLog("🔎 强制弹框 API 返回 code=\(err2)\(err2 == 0 ? "（已授权）" : err2 == errAEEventNotPermitted ? "（被拒/未确定）" : "（未知错误）")")
        if err2 == 0 { return true }

        // 3. osascript 子进程探测（v2.4.1 原版第二层，当时成功的路径）
        appendLog("🔎 走 osascript 子进程探测（弹框后请点「好」，最多等 60 秒）…")
        let ok3 = probeViaOsascript()
        appendLog(ok3 ? "✅ osascript 探测成功（自动化已授权）" : "⚠️ osascript 探测未成功（状态：\(systemEventsAutomationStatus())）")
        return ok3
    }

    /// 单个权限的引导框
    func guideOnePermission(name: String, why: String, pane: String, trigger: @escaping () -> Bool, automation: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要授权「\(name)」"
        alert.informativeText = """
        \(why)

        • 触发授权 —— 弹出系统授权框，点「好」即可
        • 在访达中显示 —— 选中本应用，拖进设置列表或用「+」添加
        • 打开设置页 —— 直达对应设置面板
        """
        alert.addButton(withTitle: "触发授权")
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: automation ? "重置记录后再触发" : "打开设置页")
        alert.addButton(withTitle: "跳过")
        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:
            NSApp.activate(ignoringOtherApps: true)
            let ok = trigger()
            refreshPermLabel()
            appendLog(ok ? "✅ \(name) 已授权" : "⚠️ \(name) 授权未完成（状态：\(automation ? systemEventsAutomationStatus() : "-")）：弹框可能被忽略，用「在访达中显示」手动拖入，或点「重置记录后再触发」")
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
            appendLog("已在访达选中本应用：把它拖进系统设置「\(pane.replacingOccurrences(of: "Privacy_", with: ""))」列表，或点列表下的「+」选择它")
        case .alertThirdButtonReturn:
            if automation {
                let resetOk = resetOwnAppleEventsPermission()
                appendLog(resetOk ? "🔄 已重置本应用 Apple Events 记录，重新触发授权…" : "⚠️ 重置失败（tccutil），请手动到设置里勾选")
                NSApp.activate(ignoringOtherApps: true)
                let ok = resetOk ? triggerAutomationPermission() : false
                refreshPermLabel()
                appendLog(ok ? "✅ 自动化已授权" : "⚠️ 自动化授权仍未完成（状态：\(systemEventsAutomationStatus())）")
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
                appendLog("已打开「\(name)」设置页：勾选 Codex-RetryPilot")
            }
        default:
            break
        }
    }

    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 930),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Codex-RetryPilot"
        window.center()
        window.minSize = NSSize(width: 600, height: 860)

        let content = NSView()

        // ── 头部：大标题 + 权限状态胶囊 ──
        let title = NSTextField(labelWithString: "Codex-RetryPilot")
        title.font = .systemFont(ofSize: 21, weight: .bold)
        let subtitle = NSTextField(labelWithString: "监测容量错误 · 自动点击「重试」 · 空闲自动接管")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let headText = NSStackView(views: [title, subtitle])
        headText.orientation = .vertical
        headText.alignment = .leading

        permAxLabel = chipLabel("辅助功能")
        permScLabel = chipLabel("屏幕录制")
        permAutoLabel = chipLabel("自动化")
        let chipRow = NSStackView(views: [permAxLabel, permScLabel, permAutoLabel])
        chipRow.orientation = .horizontal
        chipRow.spacing = 6

        let header = NSStackView(views: [headText, headerSpacer(), chipRow])
        header.orientation = .horizontal
        header.alignment = .centerY

        // ── 卡片 1：监控参数 ──
        durationPopup = NSPopUpButton()
        durationPopup.addItems(withTitles: ["15 分钟", "30 分钟", "1 小时", "2 小时", "自定义"])
        durationPopup.selectItem(at: 1)
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)

        customField = NSTextField(string: "")
        customField.alignment = .right
        customField.isEnabled = false
        customField.isHidden = true
        customField.placeholderString = "45"
        customField.toolTip = "仅当运行时长选择「自定义」时生效，单位为分钟"
        customField.delegate = self
        customField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let durUnit = NSTextField(labelWithString: "分钟")
        durUnit.textColor = .secondaryLabelColor
        let durRow = NSStackView(views: [formLabel("运行时长"), durationPopup, customField, durUnit])
        durRow.orientation = .horizontal
        durRow.spacing = 8

        intervalField = NSTextField(string: "10")
        intervalField.alignment = .right
        intervalField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        intervalField.delegate = self
        intervalField.toolTip = "失焦即保存，运行中也可修改（默认 10 秒）"
        currentInterval = Double(intervalField.stringValue) ?? 10
        let ivUnit = NSTextField(labelWithString: "秒")
        ivUnit.textColor = .secondaryLabelColor
        let ivRow = NSStackView(views: [formLabel("检查间隔"), intervalField, ivUnit])
        ivRow.orientation = .horizontal
        ivRow.spacing = 8

        let paramsCard = card(icon: "slider.horizontal.3", title: "监控参数", views: [durRow, ivRow])

        // ── 卡片 2：点击方式 ──
        silentClickCheck = NSSwitch()
        silentClickCheck.state = .on
        silentClickCheck.toolTip = "三级策略：无障碍按压 → 原生后台点击（不动光标不抢焦点，窗口被遮挡也能点）→ 坐标点击（会短暂移动光标）。关闭后直接使用坐标点击"
        let silentRow = switchRow(silentClickCheck, "静默点击：无障碍按压 → 原生后台点击，最后才动光标", tip: silentClickCheck.toolTip)

        focusReturnCheck = NSSwitch()
        focusReturnCheck.state = .on
        let focusRow = switchRow(focusReturnCheck, "坐标点击兜底后自动归还焦点（后台点击路径不会抢焦点）")

        let clickCard = card(icon: "cursorarrow.click", title: "点击方式", views: [silentRow, focusRow])

        // ── 卡片 3：运行选项（两列开关） ──
        noSleepCheck = NSSwitch()
        noSleepCheck.state = .on
        let noSleepRow = switchRow(noSleepCheck, "运行期间禁止系统息屏", tip: "通过电源断言保持亮屏；手动合盖/锁屏不受影响")
        idleStopCheck = NSSwitch()
        idleStopCheck.state = .on
        let idleStopRow = switchRow(idleStopCheck, "连续 10 分钟无错误自动停止")
        soundCheck = NSSwitch()
        soundCheck.state = .on
        let soundRow = switchRow(soundCheck, "停止时播放提示音")
        let optCol1 = NSStackView(views: [noSleepRow, idleStopRow, soundRow])
        optCol1.orientation = .vertical
        optCol1.alignment = .leading
        optCol1.spacing = 10

        dryRunCheck = NSSwitch()
        let dryRunRow = switchRow(dryRunCheck, "仅检测不点击（试运行）")
        autoLearnCheck = NSSwitch()
        autoLearnCheck.state = .on
        let autoLearnRow = switchRow(autoLearnCheck, "自动学习新的按钮样式", tip: "匹配失败时自动收录新按钮外观为模板")
        let optCol2 = NSStackView(views: [dryRunRow, autoLearnRow])
        optCol2.orientation = .vertical
        optCol2.alignment = .leading
        optCol2.spacing = 10

        let optGrid = NSStackView(views: [optCol1, optCol2])
        optGrid.orientation = .horizontal
        optGrid.spacing = 28
        let optCard = card(icon: "gearshape", title: "运行选项", views: [optGrid])

        // ── 卡片 4：空闲自动发送 ──
        idleSendCheck = NSSwitch()
        idleSendCheck.toolTip = "判定「空闲」：界面上既无错误行也无「重试」按钮（如任务已完成在等指令）"
        let idleSendTip = idleSendCheck.toolTip
        let idleSendRow = switchRow(idleSendCheck, "空闲时自动接管：发送下一行指令", tip: idleSendTip)

        idleSendField = NSTextField(string: "10")
        idleSendField.alignment = .right
        idleSendField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        idleSendField.delegate = self
        idleSendField.toolTip = "空闲持续多少分钟后发送下一行（失焦保存）"
        let idleUnit = NSTextField(labelWithString: "分钟后发送下一行")
        idleUnit.textColor = .secondaryLabelColor
        let idleMinutesRow = NSStackView(views: [formLabel("空闲"), idleSendField, idleUnit])
        idleMinutesRow.orientation = .horizontal
        idleMinutesRow.spacing = 8

        let scriptLabel = NSTextField(labelWithString: "发送内容（每行一条，从上到下依次使用，空行跳过）：")
        scriptLabel.font = .systemFont(ofSize: 11)
        scriptLabel.textColor = .secondaryLabelColor
        let scriptScroll = NSScrollView()
        scriptScroll.hasVerticalScroller = true
        scriptScroll.borderType = .bezelBorder
        scriptScroll.translatesAutoresizingMaskIntoConstraints = false
        scriptView = NSTextView()
        scriptView.font = .systemFont(ofSize: 12)
        scriptView.isVerticallyResizable = true
        scriptView.isHorizontallyResizable = false
        scriptView.autoresizingMask = [.width]
        scriptView.textContainerInset = NSSize(width: 5, height: 5)
        scriptView.delegate = self
        scriptView.string = "继续执行\n如果有未完成的步骤，继续"
        scriptScroll.documentView = scriptView
        scriptScroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scriptScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let sendCard = card(icon: "paperplane.fill", title: "空闲自动发送", views: [idleSendRow, idleMinutesRow, scriptLabel, scriptScroll])

        // ── 操作区 ──
        startBtn = symbolButton("开始监控", symbol: "play.fill", action: #selector(startTapped), key: "\r")
        stopBtn = symbolButton("停止", symbol: "stop.fill", action: #selector(stopTapped))
        stopBtn.isEnabled = false
        calibBtn = symbolButton("校准按钮", symbol: "scope", action: #selector(calibrateTapped))
        permBtn = symbolButton("授权", symbol: "checkmark.shield", action: #selector(openPermTapped))
        permBtn.toolTip = "打开权限引导 / 授权设置"
        let exportBtn = symbolButton("导出配置", symbol: "square.and.arrow.up", action: #selector(exportConfigTapped))
        let importBtn = symbolButton("导入配置", symbol: "square.and.arrow.down", action: #selector(importConfigTapped))

        let btnRow = NSStackView(views: [startBtn, stopBtn, headerSpacer(), permBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.alignment = .centerY
        let cfgRow = NSStackView(views: [calibBtn, headerSpacer(), exportBtn, importBtn])
        cfgRow.orientation = .horizontal
        cfgRow.spacing = 8
        cfgRow.alignment = .centerY

        statusLabel = NSTextField(labelWithString: "状态：待机")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        // ── 日志 ──
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView = NSTextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = logView

        let cards = [paramsCard, clickCard, optCard, sendCard]
        let stack = NSStackView(views: [header, paramsCard, clickCard, optCard, sendCard, btnRow, cfgRow, statusLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for c in cards {
            c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshPermLabel()
    }

    // MARK: 现代 UI 组件

    /// 头部弹性占位（把右侧元素推到行尾）
    private func headerSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// 权限状态胶囊（内容由 refreshPermLabel 填充）
    private func chipLabel(_ name: String) -> NSTextField {
        let l = NSTextField(labelWithString: name)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.toolTip = "\(name)权限状态"
        return l
    }

    /// 表单行左侧固定宽度标签
    private func formLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return l
    }

    /// 开关 + 说明文字行
    private func switchRow(_ sw: NSSwitch, _ text: String, tip: String? = nil) -> NSStackView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        if let tip {
            sw.toolTip = tip
            l.toolTip = tip
        }
        let r = NSStackView(views: [sw, l])
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    /// 现代分组卡片：圆角系统底色 + SF Symbol 图标标题 + 内容列
    private func card(icon: String, title: String, views: [NSView]) -> NSBox {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        iconView.contentTintColor = .secondaryLabelColor
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        head.textColor = .secondaryLabelColor
        let headRow = NSStackView(views: [iconView, head])
        headRow.orientation = .horizontal
        headRow.spacing = 6

        let body = NSStackView(views: views)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10

        let inner = NSStackView(views: [headRow, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .quaternarySystemFill
        box.borderColor = .clear
        box.cornerRadius = 10
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: box.contentView!.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -12),
        ])
        return box
    }

    /// 带 SF Symbol 图标的按钮
    private func symbolButton(_ title: String, symbol: String, action: Selector, key: String = "") -> NSButton {
        let b: NSButton
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            b = NSButton(title: title, image: img, target: self, action: action)
        } else {
            b = NSButton(title: title, target: self, action: action)
        }
        b.bezelStyle = .rounded
        if !key.isEmpty { b.keyEquivalent = key }
        return b
    }

    /// 刷新头部权限状态胶囊（绿=正常，橙=未授权，红=缺失/被拒）
    func refreshPermLabel() {
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        let auto = systemEventsAutomationStatus()
        func chip(_ l: NSTextField, _ name: String, _ state: NSColor, _ suffix: String) {
            let dot = NSAttributedString(string: "● ", attributes: [.foregroundColor: state])
            let text = NSAttributedString(string: name + suffix, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            let combined = NSMutableAttributedString()
            combined.append(dot)
            combined.append(text)
            l.attributedStringValue = combined
        }
        chip(permAxLabel, "辅助功能", ax ? .systemGreen : .systemRed, ax ? " ✓" : " ✗")
        chip(permScLabel, "屏幕录制", sc ? .systemGreen : .systemRed, sc ? " ✓" : " ✗")
        switch auto {
        case "granted": chip(permAutoLabel, "自动化", .systemGreen, " ✓")
        case "denied": chip(permAutoLabel, "自动化", .systemRed, " ✗ 被拒")
        default: chip(permAutoLabel, "自动化", .systemOrange, " 未授权")
        }
        permAxLabel.toolTip = ax ? "辅助功能权限已授予" : "缺失：无法读取 Codex 界面元素（必需）"
        permScLabel.toolTip = sc ? "屏幕录制权限已授予" : "缺失：无法截图识别错误行（必需）"
        permAutoLabel.toolTip = auto == "granted" ? "自动化权限已授予" : "坐标点击兜底后归还焦点需要（点「授权」按钮引导）"
    }

    @objc func durationChanged() {
        let isCustom = durationPopup.indexOfSelectedItem == 4
        if isCustom {
            customField.isHidden = false
            customField.isEnabled = true
            customField.stringValue = String(customMinutes)
            window.makeFirstResponder(customField)
        } else {
            let typed = Int(customField.stringValue.trimmingCharacters(in: .whitespaces))
            if let t = typed, t > 0 { customMinutes = t }
            customField.isEnabled = false
            customField.isHidden = true
            customField.stringValue = ""
        }
        saveConfig()
    }

    func selectedDuration() -> TimeInterval {
        switch durationPopup.indexOfSelectedItem {
        case 0: return 15 * 60
        case 1: return 30 * 60
        case 2: return 60 * 60
        case 3: return 120 * 60
        default:
            let typed = Int(customField.stringValue.trimmingCharacters(in: .whitespaces))
            if let t = typed, t > 0 { customMinutes = t }
            return TimeInterval(max(1, customMinutes)) * 60
        }
    }

    // MARK: 开始 / 停止

    @objc func startTapped() {
        ensurePermissions()
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            appendLog("⛔️ 权限不足，已中止。授权后请重新点击「开始监控」")
            return
        }
        guard !loadTemplates().isEmpty else {
            appendLog("⛔️ 找不到模板图，请点「校准重试按钮」")
            return
        }
        clicks = 0
        failStreak = 0
        running = true
        deadline = Date().addingTimeInterval(selectedDuration())
        lastErrorAt = Date()
        startBtn.isEnabled = false
        stopBtn.isEnabled = true
        durationPopup.isEnabled = false
        customField.isEnabled = false
        calibBtn.isEnabled = false
        appendLog("▶️ 开始监控｜时长 \(Int(selectedDuration() / 60)) 分钟" + (dryRunCheck.state == .on ? "｜试运行（不点击）" : ""))
        if silentClickCheck.state == .on {
            appendLog("点击策略：无障碍按压 → 原生后台点击 → 坐标点击兜底")
        } else {
            appendLog("点击策略：仅坐标点击（静默点击已关闭）")
        }
        if idleSendCheck.state == .on {
            let n = scriptLines().count
            let m = Int(idleSendField.stringValue) ?? 10
            appendLog(n > 0 ? "💬 空闲发送：开｜空闲 \(m) 分钟后逐行发送（共 \(n) 行）" : "💬 空闲发送：开｜但发送内容为空，不会发送")
        } else {
            appendLog("💬 空闲发送：关")
        }
        saveConfig()
        preventSleepStart()
        startStatusTimer()
        workQueue.async { [weak self] in self?.loop() }
    }

    @objc func stopTapped() {
        stop(reason: "手动停止")
    }

    func stop(reason: String) {
        guard running else { return }
        running = false
        statusTimer?.invalidate()
        statusTimer = nil
        DispatchQueue.main.async {
            self.startBtn.isEnabled = true
            self.stopBtn.isEnabled = false
            self.durationPopup.isEnabled = true
            self.customField.isEnabled = self.durationPopup.indexOfSelectedItem == 4
            if self.durationPopup.indexOfSelectedItem == 4 {
                self.customField.stringValue = String(self.customMinutes)
            }
            self.calibBtn.isEnabled = true
            self.statusLabel.stringValue = "状态：已停止｜本次点击 \(self.clicks) 次"
        }
        preventSleepEnd()
        appendLog("⏹ \(reason)｜累计点击 \(clicks) 次")
        if soundCheck.state == .on {
            playStopSound()
        }
    }

    func playStopSound() {
        if let s = NSSound(named: NSSound.Name("Glass")) {
            s.volume = 0.6
            s.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: 电源断言（防止自动息屏）
    // Swift 未导出 IOPMLib 符号，通过 dlopen 调用 IOKit

    private static let iokitLib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    func preventSleepStart() {
        guard noSleepCheck.state == .on, pmAssertion == 0 else { return }
        guard let h = Controller.iokitLib,
              let s1 = dlsym(h, "IOPMAssertionCreateWithName"),
              let s2 = dlsym(h, "IOPMAssertionRelease") else {
            appendLog("⚠️ 无法加载 IOKit 断言接口，防息屏不可用")
            return
        }
        typealias CreateFn = @convention(c) (CFString, UInt32, CFString, UnsafeMutablePointer<UInt32>) -> Int32
        typealias ReleaseFn = @convention(c) (UInt32) -> Int32
        let create = unsafeBitCast(s1, to: CreateFn.self)
        let release = unsafeBitCast(s2, to: ReleaseFn.self)
        var id: UInt32 = 0
        let res = create("PreventUserIdleDisplaySleep" as CFString, 255,
                         "CodexRetry 运行中，保持亮屏" as CFString, &id)
        if res == 0 {
            pmAssertion = id
            pmReleaseFn = release
            appendLog("🔒 已阻止系统自动息屏（手动合盖/锁屏不受影响）")
        } else {
            appendLog("⚠️ 阻止息屏设置失败（code \(res)），不影响监控")
        }
    }

    func preventSleepEnd() {
        guard pmAssertion != 0, let release = pmReleaseFn else { return }
        _ = release(pmAssertion)
        pmAssertion = 0
        pmReleaseFn = nil
    }

    // MARK: 输入框失焦即保存

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === intervalField {
            let v = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if v >= 1, v <= 3600 {
                let old = currentInterval
                currentInterval = v
                if running, Int(old) != Int(v) {
                    appendLog("✅ 检查间隔已更新为 \(Int(v)) 秒（下一轮生效）")
                }
            } else {
                field.stringValue = String(Int(currentInterval))
                appendLog("⚠️ 检查间隔需为 1–3600 的数字，已恢复为 \(Int(currentInterval))")
            }
        } else if field === customField {
            let t = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if t > 0, t <= 24 * 60 {
                customMinutes = t
            } else {
                field.stringValue = String(customMinutes)
            }
        } else if field === idleSendField {
            let t = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if t >= 1, t <= 24 * 60 {
                if running { appendLog("✅ 空闲发送间隔已更新为 \(t) 分钟") }
            } else {
                field.stringValue = "10"
            }
        }
        saveConfig()
    }

    func startStatusTimer() {
        statusTimer?.invalidate()
        var tick = 0
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            let left = max(0, Int(self.deadline.timeIntervalSinceNow))
            let m = left / 60, s = left % 60
            self.statusLabel.stringValue = String(format: "状态：运行中｜剩余 %02d:%02d｜已点击 %d 次", m, s, self.clicks)
            tick += 1
            if tick % 16 == 0 { self.refreshPermLabel() } // 每 8 秒刷新一次权限状态
        }
    }

    // MARK: 主循环（后台线程）

    func loop() {
        let dry = dryRunCheck.state == .on
        let idleSendEnabled = idleSendCheck.state == .on
        let focusReturn = focusReturnCheck.state == .on
        var silentClick = silentClickCheck.state == .on
        let idleStop = idleStopCheck.state == .on && !idleSendEnabled // 空闲发送启用时，无错误自动停止让位
        if idleSendEnabled, idleStopCheck.state == .on {
            appendLog("ℹ️ 空闲自动发送已启用，「连续 10 分钟无错误自动停止」本轮不生效")
        }
        var noAppHintAt = Date.distantPast
        var noBtnHintAt = Date.distantPast
        var captureFails = 0
            var preferCoordinateClick = false
            var downgradedAt: Date? = nil
            var cycle = 0
        var idleSince: Date? = nil
        var idleSendIdx = 0

        while running && Date() < deadline {
            cycle += 1
            let interval = currentInterval // 每轮实时读取，失焦修改立即生效
            guard let codex = codexApp() else {
                if Date().timeIntervalSince(noAppHintAt) > 30 {
                    noAppHintAt = Date()
                    appendLog("💤 Codex 未运行，等待中…（间隔 \(Int(interval))s）")
                }
                sleepSec(interval)
                continue
            }
            _ = codex
            let scan = scanCodex()
            let rows = scan.rows
            appendLog("⏱ 第 \(cycle) 次检查｜间隔 \(Int(interval))s｜错误行 \(rows.count) 条")
            idleSince = rows.isEmpty ? idleSince : nil // 有错误行即不空闲，重置计时
            guard let last = rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }) else {
                // 无错误行：Codex 空闲（无重试按钮、无错误）
                if idleSendCheck.state == .on {
                    let idleMin = Double(idleSendField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
                    if idleMin > 0 {
                        if idleSince == nil { idleSince = Date() }
                        let idleSec = Date().timeIntervalSince(idleSince!)
                        let lines = scriptLines()
                        if idleSec >= idleMin * 60, idleSendIdx < lines.count {
                            let line = lines[idleSendIdx]
                            appendLog("💬 Codex 已空闲 \(Int(idleSec / 60)) 分钟，发送第 \(idleSendIdx + 1)/\(lines.count) 行…")
                            let r = nativeSendLine(line)
                            switch r {
                            case "sent":
                                idleSendIdx += 1
                                idleSince = Date()
                                appendLog("✅ 空闲发送完成｜第 \(idleSendIdx)/\(lines.count) 行已发（光标未动）")
                            case "nofield":
                                idleSince = Date()
                                if Date().timeIntervalSince(noBtnHintAt) > 60 {
                                    noBtnHintAt = Date()
                                    appendLog("ℹ️ 未找到 Codex 输入框，无法发送（60 秒内不重复提示）")
                                }
                            default:
                                idleSince = Date()
                                appendLog("⚠️ 空闲发送未确认成功（\(r)），下轮重试同一行")
                            }
                        }
                    }
                }
                if Date().timeIntervalSince(lastErrorAt) > 600 && idleStop {
                    stop(reason: "已连续 10 分钟无错误，自动停止")
                    return
                }
                sleepSec(interval)
                continue
            }
            lastErrorAt = Date()

            // 距上次降级超 10 分钟，重新尝试无障碍按压（按压可用性会随 Codex 状态变化）
            if preferCoordinateClick, let d = downgradedAt, Date().timeIntervalSince(d) > 600 {
                preferCoordinateClick = false
                downgradedAt = nil
                appendLog("🔄 降级超 10 分钟，重新尝试无障碍按压")
            }

            let pt = targetPoint(for: last)
            let union = displaysUnion()
            guard union.width > 0,
                  pt.x > union.minX - 10, pt.x < union.maxX + 10,
                  pt.y > union.minY - 10, pt.y < union.maxY + 10 else {
                appendLog("目标位置超出所有屏幕范围，跳过")
                sleepSec(interval)
                continue
            }
            let region = CGRect(x: pt.x - 40, y: pt.y - 15, width: 80, height: 30)
            guard let cand = captureRegion(region) else {
                captureFails += 1
                if captureFails <= 2 || captureFails % 6 == 0 {
                    appendLog("截图失败（屏幕可能已休眠/锁定），暂停观察中…")
                }
                sleepSec(15)
                continue
            }
            captureFails = 0
            let tpls = loadTemplates()
            guard !tpls.isEmpty else {
                appendLog("没有可用模板，请点「校准重试按钮」")
                sleepSec(interval)
                continue
            }
            var matched = false
            var detail = "无模板"
            for t in tpls {
                if let tpl = loadImage(t) {
                    let r = matchesTemplate(candidate: cand, template: tpl)
                    if r.matched { matched = true; break }
                    detail = r.detail
                }
            }
            guard matched else {
                if scan.buttons.isEmpty {
                    // 界面上暂时没有「重试」按钮（限额冷却/会话运行中）：按正常间隔立即重查，不退避
                    if Date().timeIntervalSince(noBtnHintAt) > 60 {
                        noBtnHintAt = Date()
                        appendLog("⏳ 有错误行但暂无「重试」按钮，按正常间隔继续观察")
                    }
                    sleepSec(interval)
                    continue
                }
                appendLog("按钮区域不匹配（\(detail)）")
                if autoLearnCheck.state == .on, let g = grayPixels(cand, w: 160, h: 60) {
                    let (_, cCount) = inkMask(g, k: 0.8)
                    if cCount > 60, cCount < 2500 {
                        let name = "template_auto_\(Int(Date().timeIntervalSince1970)).png"
                        let rep = NSBitmapImageRep(cgImage: cand)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: appSupportDir.appendingPathComponent(name))
                            pruneTemplates(keep: 8)
                            appendLog("🧠 已自动收录新按钮样式，下一轮生效")
                        }
                    }
                }
                sleepSec(interval)
                continue
            }
            if dry {
                appendLog("🧪 试运行：本应点击 (\(Int(pt.x)), \(Int(pt.y)))")
                sleepSec(interval)
                continue
            }
            let previousApp = focusReturn ? NSWorkspace.shared.frontmostApplication : nil
            var handled = false

            // 用户正在打字/移动鼠标时先等一等（最多 8 秒），避免点击打断操作
            waitForUserIdle(maxWait: 8)

            // 优先无障碍按压（不占鼠标、不切前台）：最多 3 次，每次重新扫描取最新按钮元素
            if silentClick, !preferCoordinateClick {
                enableRendererAccessibility(codex)
                var pressedAny = false
                for attempt in 1...3 {
                    let s = scanCodex()
                    guard let row = s.rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }),
                          let btn = retryButton(from: s, near: row) else { break }
                    guard AXUIElementPerformAction(btn.el, kAXPressAction as CFString) == .success else {
                        appendLog("无障碍按压返回失败，改用坐标点击")
                        break
                    }
                    pressedAny = true
                    clicks += 1
                    // 判断按压本身是否引发前台切换（Chromium 行为数据点），是则立即归还焦点
                    if focusReturn {
                        usleep(300_000)
                        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CODEX_BUNDLE {
                            restoreFocusIfStolen(previousApp)
                        }
                    }
                    // 判定按压是否真实生效：重试在途时按钮会短暂消失，轮询捕捉
                    var effective = false
                    let pollEnd = Date().addingTimeInterval(2.5)
                    while Date() < pollEnd {
                        usleep(300_000)
                        let p = scanCodex()
                        if p.rows.isEmpty || retryButton(from: p, near: row) == nil {
                            effective = true
                            break
                        }
                    }
                    if effective {
                        failStreak = 0
                        appendLog("🖱 无障碍按压#\(attempt)｜✅ 生效（光标未动）｜累计 \(clicks)")
                        handled = true
                        break
                    }
                }
                if pressedAny && !handled {
                    let r = skyRetryAndVerify()
                    if r.ok {
                        handled = true
                    } else if !r.found {
                        // 按压后按钮消失（可能在途重试），不要降级
                        appendLog("ℹ️ 按压未见效且界面上已无「重试」按钮，本轮跳过")
                    } else {
                        preferCoordinateClick = true
                        downgradedAt = Date()
                        appendLog("⚠️ 按压假成功且后台点击兜底未生效，本次运行暂改用坐标点击（10 分钟后自动重试按压）")
                    }
                }
            }

            // 兜底 1：原生后台点击（向 Codex 进程直接投递点击，不抢焦点、窗口被遮挡也可点）
            var skyFound = false
            if !handled, silentClick {
                let r = skyRetryAndVerify()
                if r.ok {
                    handled = true
                }
                skyFound = r.found
            }

            // 兜底 2：坐标点击——只在「重试」按钮确实可见时才执行，绝不盲点
            if !handled {
                let s2 = scanCodex()
                let row2 = s2.rows.map({ $0.rect }).max(by: { $0.minY < $1.minY })
                let axBtn = row2.flatMap { retryButton(from: s2, near: $0) }
                if let row2, axBtn != nil {
                    clickGlobally(targetPoint(for: row2))
                    clicks += 1
                    if focusReturn {
                        usleep(300_000)
                        restoreFocusIfStolen(previousApp)
                    }
                    sleepSec(2.0)
                    let after = scanCodex().rows.map { $0.rect }
                    if after.isEmpty {
                        failStreak = 0
                        appendLog("🖱 坐标点击#\(clicks)｜✅ 会话已恢复")
                    } else {
                        failStreak += 1
                        appendLog("🖱 坐标点击#\(clicks)｜⌛️ 未生效（连续 \(failStreak)），下轮继续")
                    }
                } else if row2 != nil {
                    // 错误行还在但 AX 树里没有「重试」按钮（后台点击兜底也没找到）：
                    // 界面当前无按钮，本轮不点击，避免盲点无效操作
                    failStreak = 0
                    if !skyFound && Date().timeIntervalSince(noBtnHintAt) > 60 {
                        noBtnHintAt = Date()
                        appendLog("ℹ️ 有错误行但界面上没有「重试」按钮，本轮不点击，按正常间隔继续观察")
                    }
                } else {
                    failStreak = 0
                    appendLog("✅ 会话已恢复运行")
                }
            }
            sleepSec(interval)
        }
        if running { stop(reason: "已到设定时长") }
    }

    func sleepSec(_ s: TimeInterval) {
        let end = Date().addingTimeInterval(s)
        while running && Date() < end {
            usleep(200_000)
        }
    }

    /// 原生后台点击兜底：向 Codex 进程直接投递点击并轮询验证。
    /// 返回 ok=已触发；found=界面上确实有「重试」按钮（false 表示当前无按钮）。
    /// 日志原则：一次操作一行结论；无动作不打印。
    func skyRetryAndVerify() -> (ok: Bool, found: Bool) {
        guard let app = codexApp() else { return (false, false) }
        enableRendererAccessibility(app)
        let s = scanCodex()
        guard let row = s.rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }),
              let btn = retryButton(from: s, near: row) else {
            if Date().timeIntervalSince(skyNomatchAt) > 60 {
                skyNomatchAt = Date()
                appendLog("ℹ️ 后台点击兜底：界面上没有「重试」按钮（60 秒内不重复提示）")
            }
            return (false, false)
        }
        postClickToPid(app.processIdentifier, at: CGPoint(x: btn.rect.midX, y: btn.rect.midY))
        clicks += 1
        var effective = false
        let pollEnd = Date().addingTimeInterval(3.0)
        while Date() < pollEnd {
            usleep(400_000)
            if scanCodex().rows.isEmpty { effective = true; break }
        }
        if effective {
            failStreak = 0
            appendLog("🖱 后台点击#\(clicks)｜✅ 会话已恢复（光标未动）")
        } else {
            appendLog("🖱 后台点击#\(clicks)｜⌛️ 已点击，下轮确认")
        }
        return (true, true)
    }

    /// 把被 Codex 抢走的键盘鼠标焦点还给 prev。
    /// 唯一路径：System Events AppleScript（**必须在主线程跑**——NSAppleScript 在后台线程
    /// 会静默失败不发送事件）。已实测授权后稳定生效（2026-10-23）。
    func restoreFocusIfStolen(_ prev: NSRunningApplication?) {
        guard let prev = prev, prev.bundleIdentifier != CODEX_BUNDLE else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CODEX_BUNDLE else { return }
        let prevPid = prev.processIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            for attempt in 1...4 {
                guard self.running else { return }
                if let osa = NSAppleScript(source:
                    "tell application \"System Events\" to set frontmost of (first application process whose unix id is \(prevPid)) to true") {
                    var err: NSDictionary?
                    osa.executeAndReturnError(&err)
                    if let brief = err?["NSAppleScriptErrorBriefMessage"] {
                        self.appendLog("焦点归还(\(attempt))失败：\(brief)")
                    }
                }
                usleep(400_000)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CODEX_BUNDLE {
                    return // 归还成功不打日志（默认行为，失败才记录）
                }
                _ = prev.activate(options: [.activateAllWindows])
            }
            self.appendLog("⚠️ 焦点归还未成功（Codex 仍在前台），可手动点回原应用")
        }
    }

    /// 用户正在打字或移动鼠标时等待，避免点击打断操作；最多等 maxWait 秒
    func waitForUserIdle(maxWait: TimeInterval) {
        let end = Date().addingTimeInterval(maxWait)
        while running && Date() < end {
            let kb = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            let mm = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            if kb > 1.2 && mm > 0.5 { return }
            usleep(200_000)
        }
    }

    // MARK: 校准

    // MARK: 配置持久化（保存 / 加载 / 导入 / 导出）

    var configURL: URL { appSupportDir.appendingPathComponent("config.json") }

    func scriptLines() -> [String] {
        scriptView.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func collectConfig() -> [String: Any] {
        return [
            "version": 3,
            "customMinutes": customMinutes,
            "intervalSeconds": Int(currentInterval),
            "silentClick": silentClickCheck.state == .on,
            "focusReturn": focusReturnCheck.state == .on,
            "noSleep": noSleepCheck.state == .on,
            "idleStop": idleStopCheck.state == .on,
            "sound": soundCheck.state == .on,
            "dryRun": dryRunCheck.state == .on,
            "autoLearn": autoLearnCheck.state == .on,
            "idleSendEnabled": idleSendCheck.state == .on,
            "idleSendMinutes": Int(idleSendField.stringValue) ?? 10,
            "scriptLines": scriptLines(),
        ]
    }

    func applyConfig(_ c: [String: Any]) {
        if let v = c["customMinutes"] as? Int, v > 0 { customMinutes = v }
        if let v = c["intervalSeconds"] as? Int, v >= 1, v <= 3600 {
            currentInterval = Double(v)
            intervalField.stringValue = String(v)
        }
        func st(_ key: String, _ check: NSSwitch?) {
            if let v = c[key] as? Bool { check?.state = v ? .on : .off }
        }
        st("silentClick", silentClickCheck)
        st("focusReturn", focusReturnCheck)
        st("noSleep", noSleepCheck)
        st("idleStop", idleStopCheck)
        st("sound", soundCheck)
        st("dryRun", dryRunCheck)
        st("autoLearn", autoLearnCheck)
        st("idleSendEnabled", idleSendCheck)
        if let v = c["idleSendMinutes"] as? Int, v >= 1, v <= 24 * 60 {
            idleSendField.stringValue = String(v)
        }
        if let lines = c["scriptLines"] as? [String] {
            scriptView.string = lines.joined(separator: "\n")
        }
    }

    func saveConfig() {
        guard let data = try? JSONSerialization.data(withJSONObject: collectConfig(), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: configURL)
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        applyConfig(obj)
        appendLog("📄 已加载上次保存的配置（\(configURL.path)）")
    }

    @objc func configDirty() {
        saveConfig()
    }

    func textViewDidChangeSelection(_ notification: Notification) {}

    func textDidEndEditing(_ notification: Notification) {
        if let tv = notification.object as? NSTextView, tv === scriptView {
            saveConfig()
        }
    }

    @objc func exportConfigTapped() {
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.json]
        sp.nameFieldStringValue = "Codex-RetryPilot-config.json"
        sp.canCreateDirectories = true
        guard sp.runModal() == .OK, let url = sp.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: collectConfig(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            appendLog("✅ 配置已导出：\(url.path)")
        } catch {
            appendLog("⛔️ 导出失败：\(error.localizedDescription)")
        }
    }

    @objc func importConfigTapped() {
        let op = NSOpenPanel()
        op.allowedContentTypes = [.json]
        op.canChooseDirectories = false
        guard op.runModal() == .OK, let url = op.url,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        applyConfig(obj)
        saveConfig()
        appendLog("✅ 配置已导入并生效：\(url.path)")
    }

    // MARK: 空闲自动发送（原生 AX 后台输入，见全局 nativeSendLine）

    @objc func openPermTapped() {
        let missing = missingPermissions()
        if missing.isEmpty {
            refreshPermLabel()
            appendLog("✅ 三项权限全部就绪")
            return
        }
        showPermissionGuide(auto: false)
    }

    @objc func calibrateTapped() {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            ensurePermissions()
            appendLog("⛔️ 需要辅助功能 + 屏幕录制权限才能校准")
            return
        }
        guard let last = scanCodex().rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }) else {
            appendLog("校准失败：当前屏幕上没有 “at capacity” 错误行，请让错误提示显示出来再校准")
            return
        }
        let pt = targetPoint(for: last)
        let region = CGRect(x: pt.x - 40, y: pt.y - 15, width: 80, height: 30)
        guard let cand = captureRegion(region) else {
            appendLog("校准失败：截图失败")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cand)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            appendLog("校准失败：编码失败")
            return
        }
        do {
            let name = "template_cal_\(Int(Date().timeIntervalSince1970)).png"
            try data.write(to: appSupportDir.appendingPathComponent(name))
            pruneTemplates(keep: 8)
            appendLog("🎯 校准完成，模板已更新（\(Int(cand.width))x\(Int(cand.height))）")
        } catch {
            appendLog("校准失败：\(error.localizedDescription)")
        }
    }

    // MARK: 权限

    func ensurePermissions() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    // MARK: 日志

    func appendLog(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(text)\n"
        DispatchQueue.main.async { [weak self] in
            guard let self, let ts = self.logView.textStorage else { return }
            ts.append(NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]))
            if ts.length > 200_000 {
                ts.deleteCharacters(in: NSRange(location: 0, length: ts.length - 150_000))
            }
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘Q 退出前收尾：停监控、释放防息屏断言
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if running {
            soundCheck.state = .off // 主动退出不再播放提示音
            stop(reason: "退出应用")
        }
        preventSleepEnd()
        return .terminateNow
    }
}

// MARK: - 启动

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)

// 主菜单：没有它 ⌘Q（以及文本框 ⌘C/⌘V/⌘A）无人响应
func makeMainMenu() {
    let menu = NSMenu()

    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(NSMenuItem(title: "关于 Codex-RetryPilot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "退出 Codex-RetryPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    let editItem = NSMenuItem()
    menu.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editItem.submenu = editMenu
    for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("拷贝", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        editMenu.addItem(mi)
    }

    let winItem = NSMenuItem()
    menu.addItem(winItem)
    let winMenu = NSMenu(title: "窗口")
    winItem.submenu = winMenu
    winMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    winMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

    app.mainMenu = menu
}
makeMainMenu()

app.run()

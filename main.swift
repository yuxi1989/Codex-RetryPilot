import Cocoa
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// MARK: - 双语支持（默认跟随系统语言；config.json 的 "language" 可显式指定 "zh"/"en"，"auto" 或缺失则跟随系统；改动重启生效）

var appLang = "en"   // "en" | "zh"，初始值在 applicationDidFinishLaunching 里按系统语言解析
var explicitLangPref: String? = nil   // config 里显式指定的语言（nil = 跟随系统）

/// 双语文案：L("English text", "中文文案")
func L(_ en: String, _ zh: String) -> String { appLang == "zh" ? zh : en }

// MARK: - 单调时钟

/// 空闲计时用的是单调时钟（systemUptime，不含系统休眠时间），
/// 而不是 Date()：合盖睡一夜后醒来，Date() 差值会瞬间超过阈值、把指令立刻发出去。
func nowTick() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - 状态胶囊（圆角浅色底 + 彩色圆点，现代 macOS 风格）

/// 圆角胶囊视图：彩色圆点 + 文字，底色随状态着色（辅助功能/屏幕录制/自动化/运行状态共用）
final class ChipView: NSView {
    let label = NSTextField(labelWithString: "")

    init(_ name: String, tip: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 11, weight: .medium)
        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let tip { toolTip = tip }
        set(color: .systemGray, dot: "●", text: name)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 更新圆点颜色与文字，底色用同色 12% 透明度
    func set(color: NSColor, dot: String, text: String) {
        label.attributedStringValue = NSAttributedString(string: "\(dot) \(text)", attributes: [
            .font: label.font!,
            .foregroundColor: color == .systemGray ? NSColor.secondaryLabelColor : color,
        ])
        layer?.backgroundColor = (color == .systemGray ? NSColor.quaternarySystemFill : color.withAlphaComponent(0.12)).cgColor
    }
}

/// 系统首选语言是否为中文（zh-Hans / zh-Hant / zh-HK 等一律视为中文）
func systemPrefersChinese() -> Bool {
    for lang in Locale.preferredLanguages {
        let l = lang.lowercased()
        if l.hasPrefix("zh") { return true }
        if l.hasPrefix("en") { return false }   // 英文优先排在中文前面时按英文
    }
    return false                              // 其他语言默认英文
}

/// 启动时解析界面语言（在 buildUI 之前调用）。返回 nil 表示跟随系统。
/// 旧配置（version < 4）没有语言选择界面，"language" 只是默认值落盘，按跟随系统处理。
func loadLanguagePref() -> String? {
    let url = appSupportDir.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let version = obj["version"] as? Int ?? 0
    guard version >= 4 else { return nil }
    let lang = obj["language"] as? String
    return (lang == "en" || lang == "zh") ? lang : nil
}

// MARK: - 全局状态

let CODEX_BUNDLE = "com.openai.codex"
let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexRetry")
let templatePath = appSupportDir.appendingPathComponent("template.png")

func ensureSupportDir() {
    try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
}

/// 「重试」按钮的多语言标题（AX title 精确匹配）
let RETRY_TITLES = ["重试", "Retry", "重試"]
/// 「任务运行中」指示按钮标题（AX 树里出现即视为 Codex 正在执行任务，不算空闲）
let BUSY_TITLES = ["停止", "Stop", "中止", "Interrupt"]
/// 错误行关键字（小写匹配；可在 config.json 的 "errorKeywords" 里覆盖）
var errorKeywords = ["at capacity"]

/// 应用版本（单一来源，必须与项目版本一致 = README「版本历史」/ git tag）：发版时只改这里，
/// release.sh 会同步写进 Info.plist，「关于」面板也显示它
let appVersion = "1.0.0"

/// 项目主页（「关于」面板展示）
let projectHomepage = URL(string: "https://github.com/yuxi1989/Codex-RetryPilot")!

// MARK: - 权限探测（带重试 + 实测，消除 TCC 瞬时假阴性）

/// 辅助功能：`AXIsProcessTrusted` 在刚启动瞬间可能返回 false（TCC 守护进程尚未就绪），重试几次再下结论
func accessibilityGranted() -> Bool {
    for i in 0..<3 {
        if AXIsProcessTrusted() { return true }
        if i < 2 { usleep(250_000) }
    }
    return false
}

/// 屏幕录制：`CGPreflightScreenCaptureAccess` 在刚启动/刚登录时常见假阴性，干脆实拍一张 8×8 验证
func screenRecordingGranted() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    return captureRegion(CGRect(x: 0, y: 0, width: 8, height: 8)) != nil
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
    var busy = false // 界面上存在「停止」类按钮 = Codex 正在运行任务
}

/// 单次全树遍历同时收集错误行、「重试」按钮与运行中信号，避免一个周期内多次遍历（AX 属性读取是跨进程 IPC，开销大）
func scanCodex() -> CodexScan {
    guard let app = codexApp() else { return CodexScan() }
    var s = CodexScan()
    func walk(_ el: AXUIElement, _ depth: Int) {
        if depth > 60 { return }
        let role = axStr(el, kAXRoleAttribute)
        if role == "AXStaticText" {
            let txt = axStr(el, kAXValueAttribute).lowercased()
            if errorKeywords.contains(where: { txt.contains($0) }),
               let r = axRect(el), r.height > 5 {
                s.rows.append(ErrorRow(rect: r))
            }
        } else if role == "AXButton", let r = axRect(el), r.height > 8 {
            let t = axStr(el, kAXTitleAttribute)
            if RETRY_TITLES.contains(t) {
                s.buttons.append((el, r))
            } else if BUSY_TITLES.contains(t) {
                s.busy = true
            }
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

/// 进程内截图（坐标与 AX 一致，顶部左侧原点）。
/// 主路：ScreenCaptureKit（macOS 14+，无子进程、无临时文件）；
/// 兜底：screencapture 子进程（旧系统）。
func captureRegion(_ rect: CGRect) -> CGImage? {
    if #available(macOS 14.0, *) {
        let sema = DispatchSemaphore(value: 0)
        var out: CGImage?
        Task {
            defer { sema.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = rect
                cfg.width = Int(rect.width) * 2   // 2x，与旧 screencapture 在 Retina 下的输出一致
                cfg.height = Int(rect.height) * 2
                cfg.showsCursor = false
                cfg.captureResolution = .best
                out = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            } catch { }
        }
        sema.wait()
        return out
    }
    // 旧系统回退：子进程截图
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
    // template.png（旧版初始模板）不参与按时间戳淘汰——文件名排序它恒在最前，会被最先删掉
    let files = loadTemplates().filter { $0.lastPathComponent != "template.png" }
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
/// 先确认输入框为空（kAXValue 直写会整体覆盖现有内容，非空说明用户可能正在输入，跳过）
/// → AX 直写 kAXValue → 回读确认 → AXConfirm（失败则向进程投递 Return 键）→ 读回验证已清空。
/// 任何一步没确认成功都会把自己写进去的内容清回空——绝不给用户留下半截文字，也不让下一轮永远撞「非空」。
/// 返回 "sent" / "busy" / "unclear" / "nofield" / "error: ..."。
func nativeSendLine(_ line: String) -> String {
    guard let app = codexApp() else { return "nofield" }
    enableRendererAccessibility(app)
    guard let ta = findCodexTextArea() else { return "nofield" }
    let current = axStr(ta, kAXValueAttribute)
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "busy" // 输入框非空，绝不覆盖
    }
    // 清场：写入前框里可能只有空白符，先归一成空，避免 kAXValue 直写后残留空格导致误判
    if !current.isEmpty {
        AXUIElementSetAttributeValue(ta, kAXValueAttribute as CFString, "" as CFString)
    }
    let res = AXUIElementSetAttributeValue(ta, kAXValueAttribute as CFString, line as CFString)
    guard res == .success else { return "error: AX 写入失败 code=\(res.rawValue)" }
    usleep(300_000)
    guard axStr(ta, kAXValueAttribute) == line else {
        // 写入没落到 AXValue 上（多为该控件不支持 AXValue 直写）：清掉可能写进去的内容再报错
        AXUIElementSetAttributeValue(ta, kAXValueAttribute as CFString, "" as CFString)
        return "error: AX 写入未生效"
    }
    if AXUIElementPerformAction(ta, "AXConfirm" as CFString) != .success {
        _ = postReturnKeyToPid(app.processIdentifier)
    }
    usleep(800_000)
    let after = axStr(ta, kAXValueAttribute)
    if after != line { return "sent" } // 输入框内容已变化（通常被清空）即视为发出
    // 800ms 后这一行仍原样留在框里 = 没送出去。清空它，否则下一轮会被判「非空」而永久卡住
    AXUIElementSetAttributeValue(ta, kAXValueAttribute as CFString, "" as CFString)
    return "unclear"
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
    var idleStopCheck: NSSwitch!
    var soundCheck: NSSwitch!
    var silentSeg: NSSegmentedControl!
    var clickModeNote: NSTextField!
    var autoLearnCheck: NSSwitch!
    var noSleepCheck: NSSwitch!
    var startBtn: NSButton!
    var stopBtn: NSButton!
    var calibBtn: NSButton!
    var permBtn: NSButton!
    var statusChip: ChipView!
    var logView: NSTextView!
    var permAxLabel: ChipView!
    var durUnitLabel: NSTextField!
    var idleExtraViews: [NSView] = []
    var permScLabel: ChipView!
    var permAutoLabel: ChipView!

    var running = false
    var permGuideDismissed = false   // 本次运行内用户已点「稍后」：启动时不再重复弹引导
    private var clicksCount = 0
    private let clicksLock = NSLock()
    private let logLock = NSLock()

    /// 点击计数：后台线程递增、主线程（状态栏/停止时）读取，加锁防数据竞争
    func clicksInc() -> Int {
        clicksLock.lock(); defer { clicksLock.unlock() }
        clicksCount += 1
        return clicksCount
    }
    func clicksValue() -> Int {
        clicksLock.lock(); defer { clicksLock.unlock() }
        return clicksCount
    }
    func clicksReset() {
        clicksLock.lock(); defer { clicksLock.unlock() }
        clicksCount = 0
    }

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

    /// 自定义「关于」面板：版本号取 main.swift 顶部的 appVersion 单一来源（不读可能过期的 Info.plist），并附作者与 GitHub 链接
    @objc func showAbout() {
        let credits = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11)
        credits.append(NSAttributedString(
            string: L("Open source on GitHub · runs fully offline · the permissions it asks for are used only to clear Codex's \"Selected model is at capacity\" error and press Retry\n\n",
                      "GitHub 开源 · 完全离线运行 · 所申请的权限仅用于解决 Codex「Selected model is at capacity」错误并点击重试\n\n"),
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        credits.append(NSAttributedString(
            string: L("Author: 朱晓宇 (yuxi1989)\n", "作者：朱晓宇（yuxi1989）\n"),
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        credits.append(NSAttributedString(
            string: projectHomepage.absoluteString
                .replacingOccurrences(of: "https://", with: ""),
            attributes: [.font: font, .link: projectHomepage]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: L("Codex-RetryPilot", "Codex 重试助手"),
            .applicationVersion: appVersion,
            .version: appVersion,
            .credits: credits,
        ])
    }

    /// 打开 GitHub Issues（菜单「这是一个小工具…」点击后跳转）
    @objc func openIssues() {
        NSWorkspace.shared.open(projectHomepage.appendingPathComponent("issues"))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        ensureSupportDir()
        // 语言：默认跟随系统，config 里显式指定 "zh"/"en" 时以配置为准（必须在 buildUI 之前）
        explicitLangPref = loadLanguagePref()
        appLang = explicitLangPref ?? (systemPrefersChinese() ? "zh" : "en")
        buildUI()
        loadConfig()
        appendLog(L("Ready. Target app: Codex (com.openai.codex)", "就绪。目标应用：Codex（com.openai.codex）"))
        // 启动后等 TCC 就绪再做判定：先记一条不带结论的状态，2 秒后复核，只有复核仍缺才引导
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let missing = self.missingPermissions()
            if missing.isEmpty {
                self.refreshPermLabel()
                appendLog(L("✅ Accessibility / Screen Recording ready", "✅ 辅助功能 / 屏幕录制 已就绪"))
            } else {
                appendLog(L("⚠️ Missing permissions: ", "⚠️ 缺少权限：")
                          + missing.joined(separator: L(", ", "、"))
                          + L(" — guide will open", "—— 即将弹出引导"))
                self.showPermissionGuide(auto: true)
            }
        }
    }

    /// 必需权限缺失清单：只含硬性阻塞项（辅助功能 + 屏幕录制）。
    /// 自动化不在此列——`AEDeterminePermissionToAutomateTarget` 返回值不可信（近半数为假阴性），
    /// 且只在坐标点击兜底后归还焦点时才用到，因此改为按需引导，开机不弹窗。
    func missingPermissions() -> [String] {
        var missing: [String] = []
        if !accessibilityGranted() { missing.append(L("Accessibility", "辅助功能")) }
        if !screenRecordingGranted() { missing.append(L("Screen Recording", "屏幕录制")) }
        return missing
    }

    /// 需要引导的项（含自动化），用于手动点「授权」按钮时
    func missingPermissionsAll() -> [String] {
        var missing = missingPermissions()
        if systemEventsAutomationStatus() != "granted" { missing.append(L("Automation (focus return)", "自动化(焦点归还)")) }
        return missing
    }

    /// 权限引导：先做带重试的复核，缺失项合成**一个**汇总框；
    /// 只有单项缺失时直接给单项引导框，避免连环弹窗。
    func showPermissionGuide(auto: Bool, includeAutomation: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let missing = includeAutomation ? missingPermissionsAll() : missingPermissions()
        guard !missing.isEmpty else {
            refreshPermLabel()
            if auto { appendLog(L("✅ Permissions already granted — no guide needed", "✅ 权限已就绪，无需引导")) }
            return
        }
        // 同一次运行里用户已经点过「稍后」，启动时不再骚扰
        if auto && permGuideDismissed { return }

        let axName = L("Accessibility", "辅助功能")
        let scName = L("Screen Recording", "屏幕录制")

        if missing.count == 1 {
            // 单项：直接给带完整选项的引导框（触发授权 / 在访达中显示 / 打开设置页）
            if missing[0] == axName {
                guideOnePermission(name: axName,
                    why: L("Read Codex UI elements and press the \"Retry\" button via Accessibility (primary click path). The app cannot work without it.",
                           "读取 Codex 的界面元素、无障碍按压「重试」按钮（主点击路径）。没有它完全无法工作。"),
                    pane: "Privacy_Accessibility",
                    trigger: { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) })
            } else if missing[0] == scName {
                guideOnePermission(name: scName,
                    why: L("Capture screenshots for template matching to verify the \"at capacity\" error line. Error detection is impossible without it.",
                           "截图做模板匹配，验证 “at capacity” 错误行是否出现。缺失时无法识别错误。"),
                    pane: "Privacy_ScreenCapture",
                    trigger: { CGRequestScreenCaptureAccess() })
            } else {
                guideAutomation()
            }
            logGuideResult()
            return
        }

        // 多项：一个汇总框，点「逐项授权」后直接触发系统弹框（不再每项各弹一个我们自己的框）
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Permissions needed: \(missing.joined(separator: ", "))",
                              "需要授权：\(missing.joined(separator: "、"))")
        alert.informativeText = L("""
        Accessibility and Screen Recording are required. Automation is only used to give focus back after the coordinate-click fallback.

        Open source on GitHub, runs fully offline: these permissions are only used to detect Codex's "Selected model is at capacity" error and press Retry. No data is collected or uploaded.

        "Grant All" triggers the system dialogs one by one — click Allow in each.
        If a dialog doesn't appear, use "Open Settings" and add the app manually.
        """, """
        辅助功能与屏幕录制为必需；自动化仅用于坐标点击兜底后归还焦点。

        本应用 GitHub 开源、完全离线运行：这些权限只用于识别 Codex「Selected model is at capacity」错误并点击重试，不采集、不上传任何数据。

        点「逐项授权」会依次触发系统授权框，每个点「好」即可。
        如果系统框没有出现，用「打开设置」手动把本应用加入列表。
        """)
        alert.addButton(withTitle: L("Grant All", "逐项授权"))
        alert.addButton(withTitle: L("Open Settings", "打开设置"))
        alert.addButton(withTitle: L("Later", "稍后"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSApp.activate(ignoringOtherApps: true)
            // 逐项复核 + 触发：已经被授权的项直接跳过，不再弹任何框
            if !accessibilityGranted() {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            if !screenRecordingGranted() { _ = CGRequestScreenCaptureAccess() }
            if includeAutomation, systemEventsAutomationStatus() != "granted" { _ = triggerAutomationPermission() }
        case .alertSecondButtonReturn:
            let pane = missing.contains(scName) && missing.contains(axName) ? "Privacy_Accessibility"
                     : (missing.contains(scName) ? "Privacy_ScreenCapture" : "Privacy_Accessibility")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            permGuideDismissed = true
        }
        logGuideResult()
    }

    /// 自动化单项引导（只在手动点「授权」按钮时进入）
    func guideAutomation() {
        guideOnePermission(
            name: L("Automation (for focus return)", "自动化（焦点归还需要）"),
            why: L("After a coordinate-click fallback, System Events is needed to bring the original app back to front.\nIf this app never appears under Settings › Privacy & Security › Automation, click \"Reset & Retrigger\" to clear the stuck state; the system will prompt again.",
                   "坐标点击兜底后，需要通过 System Events 把原应用调回前台。\n若 设置 › 隐私与安全性 › 自动化 列表里一直没有本应用条目：点「重置记录后再触发」清掉卡住的授权状态，系统会重新弹出授权框。"),
            pane: "Privacy_Automation",
            trigger: triggerAutomationPermission,
            automation: true)
    }

    /// 引导结束后统一复核一次并给出结论
    func logGuideResult() {
        refreshPermLabel()
        let still = missingPermissions()
        if still.isEmpty {
            appendLog(L("✅ Accessibility / Screen Recording ready", "✅ 辅助功能 / 屏幕录制 已就绪"))
        } else {
            appendLog(L("⛔️ Still missing: ", "⛔️ 仍缺少：")
                      + still.joined(separator: L(", ", "、"))
                      + L(" — use \"Reveal in Finder\" to drag the app into the Settings list",
                          "—— 可用「在访达中显示」把应用拖进设置列表"))
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
        appendLog(L("🔎 System Events process: \(seRunning ? "running" : "not running (launch failed)")",
                    "🔎 System Events 进程：\(seRunning ? "已运行" : "未运行（拉起失败）")"))

        // 1. AppleScript 直发（未确定状态时系统弹授权框，此调用阻塞到用户点完）
        if let osa = NSAppleScript(source:
            "tell application \"System Events\" to get name of first application process whose frontmost is true") {
            var err: NSDictionary?
            _ = osa.executeAndReturnError(&err)
            if err == nil {
                appendLog(L("✅ AppleScript direct send succeeded (Automation granted)", "✅ AppleScript 直发成功（自动化已授权）"))
                return true
            }
            let code = (err?["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let brief = (err?["NSAppleScriptErrorBriefMessage"] as? String) ?? ""
            appendLog(L("🔎 AppleScript direct send failed code=\(code) \(brief)", "🔎 AppleScript 直发失败 code=\(code) \(brief)"))
            if code == -10004 {
                appendLog(L("💡 -10004 = privilege violation: this process was likely attributed to a sandboxed origin. Fully quit the app, then relaunch it directly from Finder/Launchpad and try again",
                            "💡 -10004 = 特权违规：通常是本进程被系统按沙盒来源归因。请完全退出本应用后，从访达/启动台直接双击打开再试"))
            }
        }

        // 2. 强制弹框 API（v2.4.1 原版第一层）
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        let err2 = AEDeterminePermissionToAutomateTarget(target.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
        appendLog("🔎 \(L("force-prompt API returned", "强制弹框 API 返回")) code=\(err2)\(err2 == 0 ? L(" (granted)", "（已授权）") : err2 == errAEEventNotPermitted ? L(" (denied/undetermined)", "（被拒/未确定）") : L(" (unknown error)", "（未知错误）"))")
        if err2 == 0 { return true }

        // 3. osascript 子进程探测（v2.4.1 原版第二层，当时成功的路径）
        appendLog(L("🔎 Trying osascript subprocess probe (click Allow when the dialog appears, waiting up to 60s)…",
                    "🔎 走 osascript 子进程探测（弹框后请点「好」，最多等 60 秒）…"))
        let ok3 = probeViaOsascript()
        appendLog(ok3 ? L("✅ osascript probe succeeded (Automation granted)", "✅ osascript 探测成功（自动化已授权）")
                      : L("⚠️ osascript probe did not succeed (state: \(systemEventsAutomationStatus()))", "⚠️ osascript 探测未成功（状态：\(systemEventsAutomationStatus())）"))
        return ok3
    }

    /// 单个权限的引导框
    func guideOnePermission(name: String, why: String, pane: String, trigger: @escaping () -> Bool, automation: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Permission required: \"\(name)\"", "需要授权「\(name)」")
        alert.informativeText = """
        \(why)

        • \(L("Trigger Grant — opens the system permission dialog, click Allow", "触发授权 —— 弹出系统授权框，点「好」即可"))
        • \(L("Reveal in Finder — select this app, drag it into the Settings list or add with \"+\"", "在访达中显示 —— 选中本应用，拖进设置列表或用「+」添加"))
        • \(L("Open Settings — go directly to the corresponding pane", "打开设置页 —— 直达对应设置面板"))

        \(L("Open source on GitHub, runs fully offline. This permission is only used to clear Codex's \"Selected model is at capacity\" error and press Retry — no data is collected or uploaded.",
           "本应用 GitHub 开源、完全离线运行。该权限仅用于解决 Codex「Selected model is at capacity」错误并点击重试，不采集、不上传任何数据。"))
        """
        alert.addButton(withTitle: L("Trigger Grant", "触发授权"))
        alert.addButton(withTitle: L("Reveal in Finder", "在访达中显示"))
        alert.addButton(withTitle: automation ? L("Reset & Retrigger", "重置记录后再触发") : L("Open Settings", "打开设置页"))
        alert.addButton(withTitle: L("Skip", "跳过"))
        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:
            NSApp.activate(ignoringOtherApps: true)
            let ok = trigger()
            refreshPermLabel()
            appendLog(ok ? L("✅ \(name) granted", "✅ \(name) 已授权")
                         : L("⚠️ \(name) grant not completed (state: \(automation ? systemEventsAutomationStatus() : "-")): the dialog may have been dismissed. Use \"Reveal in Finder\" to drag it in, or click \"Reset & Retrigger\"",
                             "⚠️ \(name) 授权未完成（状态：\(automation ? systemEventsAutomationStatus() : "-")）：弹框可能被忽略，用「在访达中显示」手动拖入，或点「重置记录后再触发」"))
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
            appendLog(L("App selected in Finder: drag it into the System Settings \"\(pane.replacingOccurrences(of: "Privacy_", with: ""))\" list, or click \"+\" below the list to pick it",
                        "已在访达选中本应用：把它拖进系统设置「\(pane.replacingOccurrences(of: "Privacy_", with: ""))」列表，或点列表下的「+」选择它"))
        case .alertThirdButtonReturn:
            if automation {
                let resetOk = resetOwnAppleEventsPermission()
                appendLog(resetOk ? L("🔄 Apple Events record reset, retriggering authorization…", "🔄 已重置本应用 Apple Events 记录，重新触发授权…")
                                  : L("⚠️ Reset failed (tccutil); please toggle it manually in Settings", "⚠️ 重置失败（tccutil），请手动到设置里勾选"))
                NSApp.activate(ignoringOtherApps: true)
                let ok = resetOk ? triggerAutomationPermission() : false
                refreshPermLabel()
                appendLog(ok ? L("✅ Automation granted", "✅ 自动化已授权")
                             : L("⚠️ Automation grant still not completed (state: \(systemEventsAutomationStatus()))", "⚠️ 自动化授权仍未完成（状态：\(systemEventsAutomationStatus())）"))
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
                appendLog(L("Opened \"\(name)\" settings: check Codex-RetryPilot", "已打开「\(name)」设置页：勾选 Codex-RetryPilot"))
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
        window.minSize = NSSize(width: 600, height: 760)

        let content = NSView()

        // ── 头部：一句话说明 + 权限状态胶囊（应用名在窗口标题栏，不再重复大标题）──
        let subtitle = NSTextField(labelWithString: L("Auto-retries Codex \"at capacity\" errors · optional idle auto-send",
                                                        "自动重试 Codex「at capacity」错误 · 可选空闲自动发送"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let headText = NSStackView(views: [subtitle])
        headText.orientation = .vertical
        headText.alignment = .leading

        permAxLabel = chipLabel(L("Accessibility", "辅助功能"))
        permScLabel = chipLabel(L("Screen Recording", "屏幕录制"))
        permAutoLabel = chipLabel(L("Automation", "自动化"))
        let chipRow = NSStackView(views: [permAxLabel, permScLabel, permAutoLabel])
        chipRow.orientation = .horizontal
        chipRow.spacing = 6

        let header = NSStackView(views: [headText, headerSpacer(), chipRow])
        header.orientation = .horizontal
        header.alignment = .centerY

        // ── 卡片 1：监控参数 ──
        durationPopup = NSPopUpButton()
        durationPopup.addItems(withTitles: [L("15 min", "15 分钟"), L("30 min", "30 分钟"), L("1 hour", "1 小时"), L("2 hours", "2 小时"), L("Custom", "自定义")])
        durationPopup.selectItem(at: 1)
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)

        customField = NSTextField(string: "")
        customField.alignment = .right
        customField.isEnabled = false
        customField.isHidden = true
        customField.placeholderString = "45"
        customField.toolTip = L("Only applies when run duration is \"Custom\"; unit is minutes", "仅当运行时长选择「自定义」时生效，单位为分钟")
        customField.delegate = self
        customField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        // 「分钟」后缀只在「自定义」时显示（预设选项自带单位）
        durUnitLabel = NSTextField(labelWithString: L("min", "分钟"))
        durUnitLabel.textColor = .secondaryLabelColor
        durUnitLabel.isHidden = true
        let durRow = NSStackView(views: [formLabel(L("Run duration", "运行时长")), durationPopup, customField, durUnitLabel])
        durRow.orientation = .horizontal
        durRow.spacing = 8

        intervalField = NSTextField(string: "10")
        intervalField.alignment = .right
        intervalField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        intervalField.delegate = self
        intervalField.toolTip = L("Saved on focus loss; editable while running (default 10s)", "失焦即保存，运行中也可修改（默认 10 秒）")
        currentInterval = Double(intervalField.stringValue) ?? 10
        let ivUnit = NSTextField(labelWithString: L("sec", "秒"))
        ivUnit.textColor = .secondaryLabelColor
        let ivRow = NSStackView(views: [formLabel(L("Check interval", "检查间隔")), intervalField, ivUnit])
        ivRow.orientation = .horizontal
        ivRow.spacing = 8

        let paramsCard = card(icon: "slider.horizontal.3", title: L("Monitoring", "监控参数"), views: [durRow, ivRow])

        // ── 卡片 2：点击与运行（点击方式二选一 + 运行开关两列） ──
        silentSeg = NSSegmentedControl(labels: [L("Silent", "静默"), L("Compatible", "兼容")],
                                       trackingMode: .selectOne,
                                       target: self,
                                       action: #selector(clickModeChanged))
        silentSeg.selectedSegment = 0
        silentSeg.segmentStyle = .rounded
        silentSeg.toolTip = L("Silent: Accessibility press → native background click → coordinate click as a last resort (never touches your cursor unless everything else fails). Compatible: coordinate click only (briefly moves the cursor) — use it if pressing has no effect on your machine.",
                              "静默：无障碍按压 → 原生后台点击 → 实在不行才坐标点击（几乎不会动你的光标）。兼容：只用坐标点击（会短暂移动光标），按压在本机不起作用时选它。")
        let clickModeRow = NSStackView(views: [formLabel(L("Click mode", "点击方式")), silentSeg])
        clickModeRow.orientation = .horizontal
        clickModeRow.spacing = 8

        clickModeNote = NSTextField(labelWithString: "")
        clickModeNote.font = .systemFont(ofSize: 11)
        clickModeNote.textColor = .secondaryLabelColor

        noSleepCheck = NSSwitch()
        noSleepCheck.state = .on
        let noSleepRow = switchRow(noSleepCheck, L("Prevent display sleep", "防止系统息屏"),
                                   tip: L("Keeps the screen on via a power assertion; manual lid-close/lock is unaffected", "通过电源断言保持亮屏；手动合盖/锁屏不受影响"))

        idleStopCheck = NSSwitch()
        idleStopCheck.state = .on
        let idleStopRow = switchRow(idleStopCheck, L("Auto-stop after 10 min without errors", "连续 10 分钟无错误自动停止"))
        soundCheck = NSSwitch()
        soundCheck.state = .on
        let soundRow = switchRow(soundCheck, L("Play sound on stop", "停止时播放提示音"))
        autoLearnCheck = NSSwitch()
        autoLearnCheck.state = .on
        let autoLearnRow = switchRow(autoLearnCheck, L("Auto-learn new button styles", "自动学习新版按钮样式"),
                                     tip: L("When matching fails, capture the new button appearance as a template", "匹配失败时自动收录新按钮外观为模板"))

        let optCol1 = NSStackView(views: [noSleepRow, idleStopRow])
        optCol1.orientation = .vertical
        optCol1.alignment = .leading
        optCol1.spacing = 10
        let optCol2 = NSStackView(views: [soundRow, autoLearnRow])
        optCol2.orientation = .vertical
        optCol2.alignment = .leading
        optCol2.spacing = 10

        let optGrid = NSStackView(views: [optCol1, optCol2])
        optGrid.orientation = .horizontal
        optGrid.spacing = 28
        let optCard = card(icon: "gearshape", title: L("Click & Run", "点击与运行"),
                           views: [clickModeRow, clickModeNote, optGrid])
        updateClickModeNote()

        // ── 卡片 4：空闲自动发送 ──
        idleSendCheck = NSSwitch()
        idleSendCheck.toolTip = L("\"Idle\" means no error line, no \"Retry\" button, and no running task (Stop button) on screen — a running long task is never treated as idle",
                                  "判定「空闲」：界面上既无错误行、无「重试」按钮，也没有正在运行的任务（「停止」按钮）。长任务运行中不会被误判为空闲")
        let idleSendTip = idleSendCheck.toolTip
        let idleSendRow = switchRow(idleSendCheck,
                                    L("Idle auto-send: send the next command line",
                                      "空闲时自动发送下一行指令"),
                                    tip: idleSendTip)
        idleSendCheck.target = self
        idleSendCheck.action = #selector(idleSendToggled)

        idleSendField = NSTextField(string: "10")
        idleSendField.alignment = .right
        idleSendField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        idleSendField.delegate = self
        idleSendField.toolTip = L("Minutes of idle before sending the next line (saved on focus loss)", "空闲持续多少分钟后发送下一行（失焦保存）")
        let idleUnit = NSTextField(labelWithString: L("min before sending next line", "分钟后发送下一行"))
        idleUnit.textColor = .secondaryLabelColor
        let idleMinutesRow = NSStackView(views: [formLabel(L("Idle", "空闲")), idleSendField, idleUnit])
        idleMinutesRow.orientation = .horizontal
        idleMinutesRow.spacing = 8

        let scriptLabel = NSTextField(labelWithString: L("Commands (one per line, sent top-down, blank lines skipped):",
                                                           "指令内容（每行一条，依次发送，空行跳过）："))
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
        scriptView.string = L("Continue\nIf any steps are unfinished, continue", "继续执行\n如果有未完成的步骤，继续")
        scriptScroll.documentView = scriptView
        scriptScroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scriptScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let sendCard = card(icon: "paperplane.fill", title: L("Idle Auto-Send", "空闲自动发送"), views: [idleSendRow, idleMinutesRow, scriptLabel, scriptScroll])
        // 开关关闭时下方输入项整体置灰，视觉上明确「未启用」
        idleExtraViews = [idleSendField, idleUnit, idleMinutesRow, scriptLabel, scriptScroll]
        idleSendToggled()

        // ── 操作区（一行：开始 / 停止 / 校准 …… 授权；导入导出配置在应用菜单） ──
        startBtn = symbolButton(L("Start", "开始监控"), symbol: "play.fill", action: #selector(startTapped), key: "\r")
        stopBtn = symbolButton(L("Stop", "停止"), symbol: "stop.fill", action: #selector(stopTapped))
        stopBtn.isEnabled = false
        calibBtn = symbolButton(L("Calibrate", "校准按钮"), symbol: "scope", action: #selector(calibrateTapped))
        calibBtn.toolTip = L("Teach the app what the \"Retry\" button looks like (only needed after Codex UI updates)", "教应用认识「重试」按钮的样子（Codex 界面更新后才需要）")
        permBtn = symbolButton(L("Permissions", "授权"), symbol: "checkmark.shield", action: #selector(openPermTapped))
        permBtn.toolTip = L("Open permission guide / authorization settings", "打开权限引导 / 授权设置")

        let btnRow = NSStackView(views: [startBtn, stopBtn, calibBtn, headerSpacer(), permBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.alignment = .centerY

        statusChip = ChipView(L("Standby", "待机"))
        statusChip.label.font = .systemFont(ofSize: 12, weight: .medium)

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

        let cards = [paramsCard, optCard, sendCard]
        let stack = NSStackView(views: [header, paramsCard, optCard, sendCard, btnRow, statusChip, scroll])
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
    private func chipLabel(_ name: String) -> ChipView {
        ChipView(name, tip: L("\(name) permission status", "\(name)权限状态"))
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

    /// 刷新头部权限状态胶囊（绿=正常，橙=未授权/待确认，红=缺失/被拒）
    func refreshPermLabel() {
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        let auto = systemEventsAutomationStatus()
        let name_ax = L("Accessibility", "辅助功能")
        let name_sc = L("Screen Recording", "屏幕录制")
        let name_au = L("Automation", "自动化")
        permAxLabel.set(color: ax ? .systemGreen : .systemRed, dot: ax ? "✓" : "✗", text: name_ax)
        permScLabel.set(color: sc ? .systemGreen : .systemRed, dot: sc ? "✓" : "✗", text: name_sc)
        // AEDeterminePermissionToAutomateTarget 返回值不可信，未明确 granted 时只标「待确认」，不当作缺失
        permAutoLabel.set(color: auto == "granted" ? .systemGreen : .systemOrange,
                          dot: auto == "granted" ? "✓" : "?",
                          text: auto == "granted" ? name_au : "\(name_au) \(L("unconfirmed", "待确认"))")
        permAxLabel.toolTip = ax ? L("Accessibility permission granted", "辅助功能权限已授予")
                                 : L("Missing: cannot read Codex UI elements (required)", "缺失：无法读取 Codex 界面元素（必需）")
        permScLabel.toolTip = sc ? L("Screen Recording permission granted", "屏幕录制权限已授予")
                                 : L("Missing: cannot capture screenshots to detect the error line (required)", "缺失：无法截图识别错误行（必需）")
        permAutoLabel.toolTip = auto == "granted" ? L("Automation permission granted", "自动化权限已授予")
                                                  : L("Needed only to return focus after the coordinate-click fallback. macOS reports this state unreliably, so it is checked on demand (click \"Grant\" to verify)", "仅在坐标点击兜底后归还焦点时用到。系统对该状态回报不可靠，改为按需检测（点「授权」按钮可手动确认）")
    }

    /// 点击方式切换：更新下方说明并即时保存
    @objc func clickModeChanged() {
        updateClickModeNote()
        saveConfig()
    }

    func updateClickModeNote() {
        let silent = silentSeg.selectedSegment == 0
        clickModeNote.stringValue = silent
            ? L("Press → background click; the cursor never moves. Coordinate click is used only if both fail.",
                "按压 → 后台点击，光标全程不动；两者都失败才用坐标点击。")
            : L("Coordinate click only — the cursor briefly moves. Use this if pressing has no effect on your machine.",
                "仅用坐标点击——会短暂移动鼠标。按压在本机不起作用时选这个。")
        clickModeNote.textColor = silent ? .secondaryLabelColor : .systemOrange
    }

    /// 空闲发送开关切换：关闭时下方「空闲分钟 + 指令内容」整体置灰禁用
    @objc func idleSendToggled() {
        let on = idleSendCheck.state == .on
        for v in idleExtraViews {
            v.alphaValue = on ? 1.0 : 0.45
            (v as? NSTextField)?.isEnabled = on      // idleSendField
            ((v as? NSScrollView)?.documentView as? NSTextView)?.isEditable = on  // scriptView
        }
    }

    @objc func durationChanged() {        let isCustom = durationPopup.indexOfSelectedItem == 4
        durUnitLabel.isHidden = !isCustom
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
        // 用带重试的探测：刚授权/刚启动时 TCC 可能瞬时假阴性，别让用户白点一次
        guard accessibilityGranted(), screenRecordingGranted() else {
            appendLog(L("⛔️ Insufficient permissions, aborted. After granting, click \"Start\" again",
                        "⛔️ 权限不足，已中止。授权后请重新点击「开始监控」"))
            return
        }
        guard !loadTemplates().isEmpty else {
            appendLog(L("⛔️ No template image found; click \"Calibrate\" first", "⛔️ 找不到模板图，请点「校准重试按钮」"))
            return
        }
        clicksReset()
        failStreak = 0
        running = true
        deadline = Date().addingTimeInterval(selectedDuration())
        lastErrorAt = Date()
        startBtn.isEnabled = false
        stopBtn.isEnabled = true
        durationPopup.isEnabled = false
        customField.isEnabled = false
        calibBtn.isEnabled = false
        appendLog(L("▶️ Monitoring started | duration \(Int(selectedDuration() / 60)) min | \(silentSeg.selectedSegment == 0 ? "silent" : "compatible") clicks",
                    "▶️ 开始监控｜时长 \(Int(selectedDuration() / 60)) 分钟｜\(silentSeg.selectedSegment == 0 ? "静默" : "兼容")点击"))
        if idleSendCheck.state == .on {
            let n = scriptLines().count
            let m = Int(idleSendField.stringValue) ?? 10
            appendLog(n > 0 ? L("💬 Idle send: on | sends after \(m) min idle (\(n) lines)",
                                "💬 空闲发送：开｜空闲 \(m) 分钟后逐行发送（共 \(n) 行）")
                            : L("💬 Idle send: on | command list is empty, nothing will be sent",
                                "💬 空闲发送：开｜但发送内容为空，不会发送"))
        }
        saveConfig()
        preventSleepStart()
        startStatusTimer()
        // 参数在主线程快照一次再交给后台循环，后台不碰任何 AppKit 控件
        let cfg = snapshotRunConfig()
        workQueue.async { [weak self] in self?.loop(cfg) }
    }

    @objc func stopTapped() {
        stop(reason: L("manual stop", "手动停止"))
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
            self.statusChip.set(color: .systemGray, dot: "○",
                                text: L("Stopped · \(self.clicksValue()) clicks this session", "已停止 · 本次点击 \(self.clicksValue()) 次"))
        }
        preventSleepEnd()
        appendLog(L("⏹ \(reason) | total clicks \(clicksValue())", "⏹ \(reason)｜累计点击 \(clicksValue()) 次"))
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
            appendLog("⚠️ " + L("Failed to load IOKit assertion API; sleep prevention unavailable", "无法加载 IOKit 断言接口，防息屏不可用"))
            return
        }
        typealias CreateFn = @convention(c) (CFString, UInt32, CFString, UnsafeMutablePointer<UInt32>) -> Int32
        typealias ReleaseFn = @convention(c) (UInt32) -> Int32
        let create = unsafeBitCast(s1, to: CreateFn.self)
        let release = unsafeBitCast(s2, to: ReleaseFn.self)
        var id: UInt32 = 0
        let res = create("PreventUserIdleDisplaySleep" as CFString, 255,
                         "Codex-RetryPilot running, keeping display awake" as CFString, &id)
        if res == 0 {
            pmAssertion = id
            pmReleaseFn = release
            appendLog(L("🔒 Display auto-sleep prevented", "🔒 防息屏已启用"))
        } else {
            appendLog(L("⚠️ Failed to prevent sleep (code \(res)); monitoring continues", "⚠️ 阻止息屏设置失败（code \(res)），不影响监控"))
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
                    appendLog(L("✅ Check interval updated to \(Int(v))s (takes effect next cycle)",
                                "✅ 检查间隔已更新为 \(Int(v)) 秒（下一轮生效）"))
                }
            } else {
                field.stringValue = String(Int(currentInterval))
                appendLog(L("⚠️ Check interval must be a number between 1–3600; restored to \(Int(currentInterval))",
                            "⚠️ 检查间隔需为 1–3600 的数字，已恢复为 \(Int(currentInterval))"))
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
                if running { appendLog(L("✅ Idle-send interval updated to \(t) min", "✅ 空闲发送间隔已更新为 \(t) 分钟")) }
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
            self.statusChip.set(color: .systemGreen, dot: "●",
                                text: String(format: L("Running · %02d:%02d left · %d clicks",
                                                        "运行中 · 剩余 %02d:%02d · 已点击 %d 次"), m, s, self.clicksValue()))
            tick += 1
            if tick % 16 == 0 { self.refreshPermLabel() } // 每 8 秒刷新一次权限状态
        }
    }

    // MARK: 主循环（后台线程）

    func loop(_ cfg: RunConfig) {
        // 全部开关/文案都在主线程 startTapped 里快照好（AppKit 非线程安全），这里只读值类型。
        // 运行中修改开关/发送内容/空闲分钟数，下一轮「开始监控」才生效。
        let idleSendEnabled = cfg.idleSendEnabled
        let silentClick = cfg.silentClick
        let autoLearn = cfg.autoLearn
        let idleMin = cfg.idleMinutes
        let script = cfg.script
        let idleStop = cfg.idleStopEnabled && !idleSendEnabled // 空闲发送启用时，无错误自动停止让位
        if idleSendEnabled, cfg.idleStopEnabled {
            appendLog(L("ℹ️ Idle auto-send is enabled; \"auto-stop after 10 min without errors\" is suspended for this run",
                        "ℹ️ 空闲自动发送已启用，「连续 10 分钟无错误自动停止」本轮不生效"))
        }
        var noAppHintAt = Date.distantPast
        var noBtnHintAt = Date.distantPast
        var busyHintAt: Double = 0
        var noFieldHintAt: Double = 0
        var exhaustedLogged = false
        var captureFails = 0
            var preferCoordinateClick = false
            var downgradedAt: Date? = nil
            var lastRendererAXAt = Date.distantPast   // AXManualAccessibility 是跨进程写，不必每轮都设
            var skyDeadStreak = 0                     // 后台点击「按钮在但点了没反应」的连续次数
            var skyDeadUntil = Date.distantPast       // 该策略短期停用截止时间
            var clickCooldownUntil = Date.distantPast // 刚触发重试、服务端还没恢复时的冷却截止
            var lastLoggedRowCount = -1               // 只在错误行数变化时打检查日志
        var idleSince: Double? = nil   // 单调时钟打点（秒），见 nowTick()
        var idleSendIdx = 0

        while running && Date() < deadline {
            let interval = currentInterval // 每轮实时读取，失焦修改立即生效
            guard let codex = codexApp() else {
                if Date().timeIntervalSince(noAppHintAt) > 30 {
                    noAppHintAt = Date()
                    appendLog(L("💤 Codex not running, waiting… (interval \(Int(interval))s)",
                                "💤 Codex 未运行，等待中…（间隔 \(Int(interval))s）"))
                }
                sleepSec(interval)
                continue
            }
            _ = codex
            let scan = scanCodex()
            let rows = scan.rows
            // 日志原则：只打结论。错误行数没变就不刷屏；打印时只记「从多少变到多少」
            if rows.count != lastLoggedRowCount {
                let transition = lastLoggedRowCount >= 0 ? " \(lastLoggedRowCount)→\(rows.count) " : " \(rows.count) "
                lastLoggedRowCount = rows.count
                appendLog(L("⏱ Error lines:\(transition)", "⏱ 错误行 \(transition)条"))
            }
            // 空闲的判定：无错误行、无「重试」按钮、无运行中任务（「停止」类按钮）。
            // 少了「重试按钮」这一条会有漏洞：错误行文字没命中关键字但按钮在时，会被误判成空闲。
            let isIdle = rows.isEmpty && scan.buttons.isEmpty && !scan.busy
            if !isIdle { idleSince = nil }
            guard let last = rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }) else {
                // 无错误行：Codex 空闲（无重试按钮、无错误、无运行中任务）
                if idleSendEnabled, idleMin > 0 {
                    let now = nowTick()
                    if idleSince == nil { idleSince = now }
                    let idleSec = now - idleSince!
                    let lines = script
                    if !lines.isEmpty, idleSendIdx >= lines.count {
                        // 指令用完了：提示一次，避免用户以为还在发
                        if !exhaustedLogged {
                            exhaustedLogged = true
                            appendLog(L("✅ All \(lines.count) command lines sent; nothing left to send",
                                        "✅ \(lines.count) 行指令已全部发送完毕，不再发送"))
                        }
                    } else if idleSec >= idleMin * 60, idleSendIdx < lines.count {
                        let line = lines[idleSendIdx]
                        appendLog(L("💬 Codex idle for \(Int(idleSec / 60)) min, sending line \(idleSendIdx + 1)/\(lines.count)…",
                                    "💬 Codex 已空闲 \(Int(idleSec / 60)) 分钟，发送第 \(idleSendIdx + 1)/\(lines.count) 行…"))
                        let r = nativeSendLine(line)
                        switch r {
                        case "sent":
                            idleSendIdx += 1
                            idleSince = now        // 下一行同样要再空闲 N 分钟
                            appendLog(L("✅ Idle send done | line \(idleSendIdx)/\(lines.count) sent (cursor untouched)",
                                        "✅ 空闲发送完成｜第 \(idleSendIdx)/\(lines.count) 行已发（光标未动）"))
                        case "busy":
                            // 输入框非空（用户可能正在输入），绝不覆盖；60 秒后再看一次，不必重等满 N 分钟
                            idleSince = now - idleMin * 60 + 60
                            if now - busyHintAt > 60 {
                                busyHintAt = now
                                appendLog(L("ℹ️ Input box not empty (you may be typing); will retry in ~60s",
                                            "ℹ️ 输入框非空（可能你正在输入），约 60 秒后再试"))
                            }
                        case "nofield":
                            idleSince = now - idleMin * 60 + 60
                            if now - noFieldHintAt > 60 {
                                noFieldHintAt = now
                                appendLog(L("ℹ️ Codex input box not found, cannot send (no repeat within 60s)",
                                            "ℹ️ 未找到 Codex 输入框，无法发送（60 秒内不重复提示）"))
                            }
                        default:
                            // 写入失败/未确认：同样 60 秒后重试同一行，行号不推进（不漏发、不重发）
                            idleSince = now - idleMin * 60 + 60
                            appendLog(L("⚠️ Idle send not confirmed (\(r)); will retry the same line in ~60s",
                                        "⚠️ 空闲发送未确认成功（\(r)），约 60 秒后重试同一行"))
                        }
                    }
                }
                if Date().timeIntervalSince(lastErrorAt) > 600 && idleStop && !scan.busy {
                    stop(reason: L("no errors for 10 consecutive minutes, auto-stopped", "已连续 10 分钟无错误，自动停止"))
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
                appendLog(L("🔄 Downgraded over 10 min, retrying Accessibility press", "🔄 降级超 10 分钟，重新尝试无障碍按压"))
            }

            let pt = targetPoint(for: last)
            let union = displaysUnion()
            guard union.width > 0,
                  pt.x > union.minX - 10, pt.x < union.maxX + 10,
                  pt.y > union.minY - 10, pt.y < union.maxY + 10 else {
                appendLog(L("Target position is outside all displays, skipping", "目标位置超出所有屏幕范围，跳过"))
                sleepSec(interval)
                continue
            }
            let region = CGRect(x: pt.x - 40, y: pt.y - 15, width: 80, height: 30)
            guard let cand = captureRegion(region) else {
                captureFails += 1
                if captureFails <= 2 || captureFails % 6 == 0 {
                    appendLog(L("Screenshot failed (display may be asleep/locked), pausing…",
                                "截图失败（屏幕可能已休眠/锁定），暂停观察中…"))
                }
                sleepSec(15)
                continue
            }
            captureFails = 0
            let tpls = loadTemplates()
            guard !tpls.isEmpty else {
                appendLog(L("No template available; click \"Calibrate\" first", "没有可用模板，请点「校准重试按钮」"))
                sleepSec(interval)
                continue
            }
            var matched = false
            var detail = L("no template", "无模板")
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
                        appendLog(L("⏳ Error line present but no \"Retry\" button yet; continuing at normal interval",
                                    "⏳ 有错误行但暂无「重试」按钮，按正常间隔继续观察"))
                    }
                    sleepSec(interval)
                    continue
                }
                appendLog(L("Button area mismatch (\(detail))", "按钮区域不匹配（\(detail)）"))
                if autoLearn, let g = grayPixels(cand, w: 160, h: 60) {
                    let (_, cCount) = inkMask(g, k: 0.8)
                    if cCount > 60, cCount < 2500 {
                        let name = "template_auto_\(Int(Date().timeIntervalSince1970)).png"
                        let rep = NSBitmapImageRep(cgImage: cand)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: appSupportDir.appendingPathComponent(name))
                            pruneTemplates(keep: 8)
                            appendLog(L("🧠 New button style captured; takes effect next cycle", "🧠 已自动收录新按钮样式，下一轮生效"))
                        }
                    }
                }
                sleepSec(interval)
                continue
            }
            // 刚触发过重试、服务端还没恢复：冷却期内不重复点击（避免 10 秒一次猛按）
            if Date() < clickCooldownUntil {
                let wait = min(interval, clickCooldownUntil.timeIntervalSinceNow + 0.5)
                if wait > 0 { sleepSec(wait) }
                continue
            }
            // 坐标点击会抢焦点，所以先记下当前前台应用，点完还回去（恒开，无开关）
            let previousApp = NSWorkspace.shared.frontmostApplication
            var handled = false
            var backgroundTried = false   // 本轮是否已投递过后台点击（避免同一轮重复投递）

            // 无障碍按压与后台点击都不移动真实鼠标、不切前台，因此不必等用户空闲——
            // 只有最后一步「坐标点击」会真抢鼠标，才在它之前等待（见兜底 2）。
            // 第 1 次复用本周期开头的扫描结果，之后复用按压轮询里最新的扫描，减少全树遍历次数
            if silentClick, !preferCoordinateClick {
                if Date().timeIntervalSince(lastRendererAXAt) > 300 {
                    enableRendererAccessibility(codex)
                    lastRendererAXAt = Date()
                }
                var pressedAny = false
                var curScan = scan
                // 日志实测（2026-10-23）：11 次点击里 10 次一次即生效、1 次第二次生效，#3 从未用到
                for attempt in 1...2 {
                    guard let row = curScan.rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }),
                          let btn = retryButton(from: curScan, near: row) else { break }
                    guard AXUIElementPerformAction(btn.el, kAXPressAction as CFString) == .success else {
                        appendLog(L("Accessibility press failed, falling back to coordinate click",
                                    "无障碍按压返回失败，改用坐标点击"))
                        break
                    }
                    pressedAny = true
                    let clickNo = clicksInc()
                    // 判断按压本身是否引发前台切换（Chromium 行为数据点），是则立即归还焦点
                    usleep(300_000)
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CODEX_BUNDLE {
                        restoreFocusIfStolen(previousApp)
                    }
                    // 判定按压是否真实生效：重试在途时按钮会短暂消失，轮询捕捉
                    // 日志实测按钮几乎瞬时消失，1.5 秒窗口已够（原 2.5 秒纯等待）
                    var effective = false
                    let pollEnd = Date().addingTimeInterval(1.5)
                    while Date() < pollEnd {
                        usleep(250_000)
                        let p = scanCodex()
                        curScan = p
                        if p.rows.isEmpty || retryButton(from: p, near: row) == nil {
                            effective = true
                            break
                        }
                    }
                    if effective {
                        failStreak = 0
                        // 错误行还在、只是按钮消失 = 重试在途（服务端可能还没恢复）。
                        // 日志里出现过 12 秒内连按 3 次，给 Codex 20 秒缓冲再动手
                        if !curScan.rows.isEmpty {
                            clickCooldownUntil = Date().addingTimeInterval(20)
                        }
                        appendLog(L("🖱 Press #\(attempt) | ✅ effective | total \(clickNo)",
                                    "🖱 按压#\(attempt)｜✅ 生效｜累计 \(clickNo)"))
                        handled = true
                        break
                    }
                }
                if pressedAny && !handled {
                    let r = skyRetryAndVerify()
                    backgroundTried = true
                    if r.ok {
                        handled = true
                    } else if !r.found {
                        // 按压后按钮消失（可能在途重试），不要降级
                        appendLog(L("ℹ️ Press had no visible effect and no \"Retry\" button remains; skipping this cycle",
                                    "ℹ️ 按压未见效且界面上已无「重试」按钮，本轮跳过"))
                    } else {
                        preferCoordinateClick = true
                        downgradedAt = Date()
                        appendLog(L("⚠️ Press was a false success and background click fallback failed; using coordinate clicks for this run (will retry pressing in 10 min)",
                                    "⚠️ 按压假成功且后台点击兜底未生效，本次运行暂改用坐标点击（10 分钟后自动重试按压）"))
                    }
                }
            }

            // 兜底 1：原生后台点击（向 Codex 进程直接投递点击，不抢焦点、窗口被遮挡也可点）
            // 同一轮最多投递一次；连续 3 次「按钮在但点了没反应」则 10 分钟内跳过该策略
            var skyFound = false
            if !handled, silentClick, !backgroundTried, Date() >= skyDeadUntil {
                let r = skyRetryAndVerify()
                backgroundTried = true
                skyFound = r.found
                if r.ok {
                    handled = true
                    skyDeadStreak = 0
                } else if r.found {
                    skyDeadStreak += 1
                    if skyDeadStreak >= 3 {
                        skyDeadUntil = Date().addingTimeInterval(600)
                        appendLog(L("⚠️ Background click ineffective 3 times in a row; skipping this strategy for 10 min (coordinate click takes over)",
                                    "⚠️ 后台点击连续 3 次无效，该策略暂停 10 分钟（改由坐标点击接手）"))
                    }
                }
            }

            // 兜底 2：坐标点击——只在「重试」按钮确实可见时才执行，绝不盲点。
            // 直接点 AX 按钮矩形的中心（比 +295pt 推算位置更稳，不受字体/语言/缩放影响）。
            // 这是唯一会真抢鼠标的策略，所以只有这里需要等用户手停下来。
            if !handled {
                waitForUserIdle(maxWait: 8)
                let s2 = scanCodex()
                let row2 = s2.rows.map({ $0.rect }).max(by: { $0.minY < $1.minY })
                let axBtn = row2.flatMap { retryButton(from: s2, near: $0) }
                if let axBtn = axBtn {
                    clickGlobally(CGPoint(x: axBtn.rect.midX, y: axBtn.rect.midY))
                    let clickNo = clicksInc()
                    usleep(300_000)
                    restoreFocusIfStolen(previousApp)   // 坐标点击会抢焦点，点完立刻还回去
                    sleepSec(2.0)
                    let afterScan = scanCodex()
                    let afterRow = afterScan.rows.map { $0.rect }.max(by: { $0.minY < $1.minY })
                    let afterBtn = afterRow.flatMap { retryButton(from: afterScan, near: $0) }
                    if afterScan.rows.isEmpty {
                        failStreak = 0
                        appendLog(L("🖱 Coordinate click #\(clickNo) | ✅ session recovered", "🖱 坐标点击#\(clickNo)｜✅ 会话已恢复"))
                    } else if afterBtn == nil {
                        // 错误行还在但按钮消失 = 重试在途，不算失败（与无障碍按压的判定保持一致）
                        failStreak = 0
                        appendLog(L("🖱 Coordinate click #\(clickNo) | ⌛️ retry in flight (button gone), confirming next cycle",
                                    "🖱 坐标点击#\(clickNo)｜⌛️ 重试在途（按钮已消失），下轮确认"))
                    } else {
                        failStreak += 1
                        appendLog(L("🖱 Coordinate click #\(clickNo) | ⌛️ not effective (streak \(failStreak)), continuing",
                                    "🖱 坐标点击#\(clickNo)｜⌛️ 未生效（连续 \(failStreak)），下轮继续"))
                    }
                } else if row2 != nil {
                    // 错误行还在但 AX 树里没有「重试」按钮（后台点击兜底也没找到）：
                    // 界面当前无按钮，本轮不点击，避免盲点无效操作
                    failStreak = 0
                    if !skyFound && Date().timeIntervalSince(noBtnHintAt) > 60 {
                        noBtnHintAt = Date()
                        appendLog(L("ℹ️ Error line present but no \"Retry\" button on screen; not clicking this cycle, continuing at normal interval",
                                    "ℹ️ 有错误行但界面上没有「重试」按钮，本轮不点击，按正常间隔继续观察"))
                    }
                } else {
                    failStreak = 0
                    appendLog(L("✅ Session recovered and running", "✅ 会话已恢复运行"))
                }
            }
            sleepSec(interval)
        }
        if running { stop(reason: L("preset duration reached", "已到设定时长")) }
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
                appendLog(L("ℹ️ Background click fallback: no \"Retry\" button on screen (no repeat within 60s)",
                            "ℹ️ 后台点击兜底：界面上没有「重试」按钮（60 秒内不重复提示）"))
            }
            return (false, false)
        }
        postClickToPid(app.processIdentifier, at: CGPoint(x: btn.rect.midX, y: btn.rect.midY))
        let clickNo = clicksInc()
        var effective = false
        let pollEnd = Date().addingTimeInterval(3.0)
        while Date() < pollEnd {
            usleep(400_000)
            if scanCodex().rows.isEmpty { effective = true; break }
        }
        if effective {
            failStreak = 0
            appendLog(L("🖱 Background click #\(clickNo) | ✅ session recovered (cursor untouched)",
                        "🖱 后台点击#\(clickNo)｜✅ 会话已恢复（光标未动）"))
        } else {
            appendLog(L("🖱 Background click #\(clickNo) | ⌛️ clicked, will confirm next cycle",
                        "🖱 后台点击#\(clickNo)｜⌛️ 已点击，下轮确认"))
        }
        return (true, true)
    }

    /// 把被 Codex 抢走的键盘鼠标焦点还给 prev。
    /// 三条路径依次尝试：AX 设 frontmost（只需辅助功能）→ System Events（需自动化权限）→ NSRunningApplication.activate。
    /// **必须在主线程跑**——NSAppleScript 在后台线程会静默失败不发送事件。
    func restoreFocusIfStolen(_ prev: NSRunningApplication?) {
        guard let prev = prev, prev.bundleIdentifier != CODEX_BUNDLE else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CODEX_BUNDLE else { return }
        let prevPid = prev.processIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            var appleScriptTried = false
            for attempt in 1...4 {
                guard self.running else { return }
                // 1) AX：只需辅助功能权限，无需自动化
                let axApp = AXUIElementCreateApplication(prevPid)
                _ = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                usleep(250_000)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CODEX_BUNDLE { return }
                // 2) System Events AppleScript（失败只记一次，避免每轮刷屏）
                if !appleScriptTried {
                    appleScriptTried = true
                    if let osa = NSAppleScript(source:
                        "tell application \"System Events\" to set frontmost of (first application process whose unix id is \(prevPid)) to true") {
                        var err: NSDictionary?
                        osa.executeAndReturnError(&err)
                        if let brief = err?["NSAppleScriptErrorBriefMessage"] {
                            self.appendLog(L("Focus return (attempt \(attempt)) failed: \(brief)",
                                             "焦点归还(\(attempt))失败：\(brief)"))
                        }
                    }
                    usleep(300_000)
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CODEX_BUNDLE { return }
                }
                // 3) 兜底：常规激活
                _ = prev.activate(options: [.activateAllWindows])
                usleep(300_000)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != CODEX_BUNDLE {
                    return // 归还成功不打日志（默认行为，失败才记录）
                }
            }
            self.appendLog(L("⚠️ Focus return failed (Codex still frontmost); click back to the original app manually",
                             "⚠️ 焦点归还未成功（Codex 仍在前台），可手动点回原应用"))
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

    /// 一次运行的全部参数。必须在主线程（「开始监控」时）构建：AppKit 控件不能跨线程读，
    /// 后台 loop 只拿这份值类型快照，运行中改界面不影响本轮。
    struct RunConfig {
        var idleSendEnabled = false
        var idleMinutes: Double = 10
        var script: [String] = []
        var silentClick = true
        var autoLearn = true
        var idleStopEnabled = true   // 用户是否勾选「连续 10 分钟无错误自动停止」
    }

    func snapshotRunConfig() -> RunConfig {
        var minutes = Double(idleSendField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 10
        if minutes < 1 || minutes > 24 * 60 {
            // 0 / 负数 / 乱码都会让空闲发送静默失效，这里直接纠正并告知
            minutes = 10
            idleSendField.stringValue = "10"
            appendLog(L("⚠️ Idle minutes out of range (1–1440); reset to 10",
                        "⚠️ 空闲分钟数超出范围（1–1440），已重置为 10"))
        }
        return RunConfig(idleSendEnabled: idleSendCheck.state == .on,
                         idleMinutes: minutes,
                         script: scriptLines(),
                         silentClick: silentSeg.selectedSegment == 0,
                         autoLearn: autoLearnCheck.state == .on,
                         idleStopEnabled: idleStopCheck.state == .on)
    }

    func collectConfig() -> [String: Any] {
        return [
            "version": 4,
            "language": explicitLangPref ?? "auto",   // auto = 跟随系统
            "customMinutes": customMinutes,
            "intervalSeconds": Int(currentInterval),
            "silentClick": silentSeg.selectedSegment == 0,
            "noSleep": noSleepCheck.state == .on,
            "idleStop": idleStopCheck.state == .on,
            "sound": soundCheck.state == .on,
            "autoLearn": autoLearnCheck.state == .on,
            "idleSendEnabled": idleSendCheck.state == .on,
            "idleSendMinutes": Int(idleSendField.stringValue) ?? 10,
            "scriptLines": scriptLines(),
            "errorKeywords": errorKeywords,
        ]
    }

    func applyConfig(_ c: [String: Any]) {
        // 语言在 buildUI 之前已解析（见 applicationDidFinishLaunching）；这里只在 version>=4 且显式指定时同步，供日志等使用
        if (c["version"] as? Int ?? 0) >= 4, let v = c["language"] as? String, v == "en" || v == "zh" { appLang = v }
        if let v = c["customMinutes"] as? Int, v > 0 { customMinutes = v }
        if let v = c["intervalSeconds"] as? Int, v >= 1, v <= 3600 {
            currentInterval = Double(v)
            intervalField.stringValue = String(v)
        }
        func st(_ key: String, _ check: NSSwitch?) {
            if let v = c[key] as? Bool { check?.state = v ? .on : .off }
        }
        // 旧配置的 silentClick = false 视为「兼容模式」；focusReturn 已成为恒定行为，旧值忽略
        if let v = c["silentClick"] as? Bool {
            silentSeg.selectedSegment = v ? 0 : 1
            updateClickModeNote()
        }
        st("noSleep", noSleepCheck)
        st("idleStop", idleStopCheck)
        st("sound", soundCheck)
        st("autoLearn", autoLearnCheck)
        st("idleSendEnabled", idleSendCheck)
        if let v = c["idleSendMinutes"] as? Int, v >= 1, v <= 24 * 60 {
            idleSendField.stringValue = String(v)
        }
        if let ks = c["errorKeywords"] as? [String], !ks.isEmpty {
            errorKeywords = ks.map { $0.lowercased() } // 错误行关键字可自定义（小写匹配）
        }
        if let lines = c["scriptLines"] as? [String] {
            scriptView.string = lines.joined(separator: "\n")
        }
        idleSendToggled() // 按加载后的开关状态刷新置灰
    }

    func saveConfig() {
        guard let data = try? JSONSerialization.data(withJSONObject: collectConfig(), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: configURL)
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        applyConfig(obj)
        appendLog(L("📄 Config loaded", "📄 已加载上次保存的配置"))
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
        // 手动点击时才把自动化纳入引导（自动化只在坐标点击兜底后归还焦点时用到）
        let missing = missingPermissionsAll()
        if missing.isEmpty {
            refreshPermLabel()
            appendLog(L("✅ All permissions ready", "✅ 三项权限全部就绪"))
            return
        }
        permGuideDismissed = false
        showPermissionGuide(auto: false, includeAutomation: true)
    }

    @objc func calibrateTapped() {
        guard accessibilityGranted(), screenRecordingGranted() else {
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
        writeLogFile(line)
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

    /// 日志同时落盘到 logs/YYYY-MM-DD.log——窗口被遮挡时直接看文件即可排障
    private func writeLogFile(_ line: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(df.string(from: Date())).log")
        guard let data = line.data(using: .utf8) else { return }
        logLock.lock()
        defer { logLock.unlock() }
        if let fh = FileHandle(forWritingAtPath: url.path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
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
    appMenu.addItem(NSMenuItem(title: "关于 Codex-RetryPilot", action: #selector(Controller.showAbout), keyEquivalent: ""))
    appMenu.addItem(NSMenuItem(title: L("A small tool — issues are welcome for feature requests",
                                        "这是一个小工具，如有需要欢迎提交 issue 扩展功能"),
                               action: #selector(Controller.openIssues), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: L("Export Config…", "导出配置…"), action: #selector(Controller.exportConfigTapped), keyEquivalent: "e"))
    appMenu.addItem(NSMenuItem(title: L("Import Config…", "导入配置…"), action: #selector(Controller.importConfigTapped), keyEquivalent: "o"))
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

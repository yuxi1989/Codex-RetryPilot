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

/// 四元填充色：.quaternarySystemFill 是 macOS 14 才有的，13 上用等效半透明灰
func quaternaryFill() -> NSColor {
    if #available(macOS 14.0, *) { return .quaternarySystemFill }
    return NSColor.secondaryLabelColor.withAlphaComponent(0.08)
}

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
        layer?.backgroundColor = (color == .systemGray ? quaternaryFill() : color.withAlphaComponent(0.12)).cgColor
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
/// 「滚动到底部」下箭头按钮标题：视图未在底部时出现，此时窗口外的错误行/按钮读不全，须先滚到底再判定
let SCROLL_BOTTOM_TITLES = ["滚动到底部", "Scroll to bottom", "滾動到底部"]
/// 「重置使用量」按钮：只出现在官方额度横幅上 —— 既证明额度耗尽，也用来定位横幅文案
let RESET_USAGE_TITLES = ["重置使用量", "Reset usage", "Reset usage limit", "重設使用量"]
/// 「恢复目标」按钮：额度耗尽时 Codex 会把当前 Goal 置为「目标使用受限」，
/// 额度恢复后点它就能从原目标继续（比发「继续」更准，不会改变会话意图）
let RESUME_GOAL_TITLES = ["恢复目标", "Resume goal", "Resume Goal", "恢復目標"]
/// 「目标使用受限」状态条的文案前缀（AXButton 标题形如「目标使用受限 按开发文档持续进行开发 49m 18s」）
let GOAL_LIMITED_KEYWORDS = ["目标使用受限", "目标已暂停", "goal paused", "goal is paused", "goal paused by usage limit"]
/// 错误行关键字（小写匹配；可在 config.json 的 "errorKeywords" 里覆盖）
var errorKeywords = ["at capacity"]
/// 「用量上限」关键字（小写匹配）：命中说明套餐额度用完、点重试无效，只能等额度重置。
/// 此状态暂停点击与空闲发送，也不算空闲（和 at capacity 的瞬时错误分开处理）。
/// 注意：这些词也会出现在对话正文里（例如图片生成额度提示「您已达到使用上限」），
/// 单凭关键字判定会误判 —— 真正的判定见 STRONG_LIMIT_KEYWORDS + 主循环里的强弱两档逻辑。
let LIMIT_KEYWORDS = ["使用上限", "额度已用完", "usage limit", "codex and work usage", "rate limit resets"]
/// 「官方额度横幅」专属措辞（小写匹配）：只会出现在 Codex 自己的额度提示条上，对话正文里不会有。
/// 命中即为强信号，直接判定用量上限；其余含「使用上限」字样的文字只算弱信号，需多轮确认。
/// 中文实测文案：「Codex 和工作使用额度已用完」「你的速率限制将于 22:59 重置。立即升级，或使用一次速率限制重置机会。」
let STRONG_LIMIT_KEYWORDS = ["codex and work usage", "rate limit resets", "usage limit resets",
                             "额度将在", "上限将在", "额度重置时间",
                             "和工作使用额度已用完", "速率限制将于", "速率限制重置"]

/// 应用版本（单一来源，必须与项目版本一致 = README「版本历史」/ git tag）：发版时只改这里，
/// release.sh 会同步写进 Info.plist，「关于」面板也显示它
let appVersion = "1.0.7"

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
    /// 命中「用量上限」字样的可见文本（含坐标：用来区分官方横幅与对话正文里的历史文案）
    var limitItems: [(text: String, rect: CGRect)] = []
    /// 全部可见静态文本（含坐标）：横幅上的重置时间那句不含「使用上限」字样，
    /// 只能靠「与『重置使用量』按钮同高」这个几何关系捞出来，所以这里全量留一份
    var allTexts: [(text: String, rect: CGRect)] = []
    /// 「重置使用量 / Reset usage」按钮的位置 = 官方额度横幅存在（这个按钮只出现在额度横幅上）
    var limitAnchorRects: [CGRect] = []
    var strongLimit = false       // 命中官方横幅专属措辞 = 强信号（对话正文里不会出现）
    var buttons: [(el: AXUIElement, rect: CGRect)] = []
    var busy = false // 界面上存在「停止」类按钮 = Codex 正在运行任务
    var scrollBtn: AXUIElement? // 「滚动到底部」下箭头：出现即代表视图不在底部，读到的界面不全
    /// 「恢复目标」按钮：额度恢复后点它，被中断的目标会话从原目标继续
    var resumeGoal: (el: AXUIElement, rect: CGRect)? = nil
    /// 界面显示「目标使用受限」= 当前有个被额度打断的 Goal
    var goalLimited = false

    var limitTexts: [String] { limitItems.map { $0.text } }
    /// 官方横幅存在（界面上有「重置使用量」按钮）
    var bannerPresent: Bool { !limitAnchorRects.isEmpty }
    /// 只取与横幅按钮同高（±120px）的文案：对话正文里那条「…或在 22:59后重试」不算，
    /// 否则历史消息里的旧时间会一直参与「等多久」的计算。
    var bannerLimitTexts: [String] {
        guard bannerPresent else { return [] }
        let anchors = limitAnchorRects
        return allTexts.filter { item in
            item.text.count > 3 && anchors.contains { abs($0.midY - item.rect.midY) < 120 }
        }.map { $0.text }
    }
}

/// 单次全树遍历同时收集错误行、「重试」按钮与运行中信号，避免一个周期内多次遍历（AX 属性读取是跨进程 IPC，开销大）
func scanCodex() -> CodexScan {
    guard let app = codexApp() else { return CodexScan() }
    var s = CodexScan()
    func walk(_ el: AXUIElement, _ depth: Int) {
        if depth > 60 { return }
        let role = axStr(el, kAXRoleAttribute)
        if role == "AXStaticText" {
            let raw = axStr(el, kAXValueAttribute)
            let txt = raw.lowercased()
            if errorKeywords.contains(where: { txt.contains($0) }),
               let r = axRect(el), r.height > 5 {
                s.rows.append(ErrorRow(rect: r))
            }
            let isLimitKw = LIMIT_KEYWORDS.contains(where: { txt.contains($0) })
            // 可能含「重置时间」的文本（有数字 + 冒号，或命中上限关键字）才去读坐标：
            // 读 rect 是跨进程 IPC，对所有文本都读会让打字变卡
            let maybeReset = raw.contains(":") && raw.contains(where: { $0.isNumber })
            // 只认「可见」文案：虚拟化列表里滚出屏幕的历史行 rect 高度为 1，
            // 会把几条对话里出现过的「使用上限」永远算成当前状态（实际误判来源）。
            if !raw.isEmpty, raw.count <= 400, (maybeReset || isLimitKw),
               let r = axRect(el), r.height >= 8, r.width >= 40 {
                s.allTexts.append((raw, r))
                if isLimitKw {
                    s.limitItems.append((raw, r))
                    if STRONG_LIMIT_KEYWORDS.contains(where: { txt.contains($0) }) { s.strongLimit = true }
                }
            }
        } else if role == "AXButton", let r = axRect(el), r.height > 8 {
            let t = axStr(el, kAXTitleAttribute)
            if RETRY_TITLES.contains(t) {
                s.buttons.append((el, r))
            } else if BUSY_TITLES.contains(t) {
                s.busy = true
            } else if SCROLL_BOTTOM_TITLES.contains(t), s.scrollBtn == nil {
                s.scrollBtn = el
            }
            // 「重置使用量」只出现在官方额度横幅上：它既是「额度耗尽」的硬证据，
            // 也是定位横幅文案的锚点（横幅上的重置时间解析只认这一带的文本）
            if RESET_USAGE_TITLES.contains(t) {
                s.limitAnchorRects.append(r)
            }
            if RESUME_GOAL_TITLES.contains(t) {
                s.resumeGoal = (el, r)
            }
            let tl = t.lowercased()
            if GOAL_LIMITED_KEYWORDS.contains(where: { tl.contains($0) }) {
                s.goalLimited = true
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

/// screencapture 子进程截图（旧系统主路，也是 SCK 失败时的兜底）。
/// 子进程继承本 app 的屏幕录制授权，两者失败/成功通常同步，但 SCK 有独立故障面
/// （例如 API 变更、显示器状态、内部超时），故保留双路。
func captureViaProcess(_ rect: CGRect) -> CGImage? {
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

/// 截图（带失败原因）：先 SCK，失败自动退到 screencapture 子进程，并把原因带出去写日志。
/// 返回 nil 时 error 一定有值，方便日志说清「为什么截图失败」（以前 catch 静默吞掉，只能猜）。
func captureRegionDetailed(_ rect: CGRect) -> (image: CGImage?, error: String?) {
    if #available(macOS 14.0, *) {
        let sema = DispatchSemaphore(value: 0)
        var out: CGImage?
        var err: String?
        Task {
            defer { sema.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // 选「覆盖面积最大」的显示器：窗口跨屏时不能随便取第一个相交的
                let display = content.displays
                    .map { ($0, $0.frame.intersection(rect)) }
                    .filter { !$0.1.isNull && !$0.1.isEmpty }
                    .max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })?.0
                    ?? content.displays.first
                guard let display else {
                    err = "SCK: no display (displays=\(content.displays.count))"
                    return
                }
                // ⚠️ sourceRect 用的是「以该显示器左上角为原点」的局部坐标，必须减掉显示器原点。
                // 主显示器原点恰好是 (0,0)，全局坐标 == 局部坐标，所以单屏/主屏上一直正常；
                // 一旦 Codex 窗口被拖到副屏，传全局坐标就会越界 → SCStreamErrorDomain -3812
                // 「参数无效导致失败」→ 截图失败（2026-10-29 的故障就是它）。
                let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                // 贴边时区域可能超出一半，裁进显示器范围再截
                let clamped = local.intersection(CGRect(origin: .zero, size: display.frame.size))
                guard !clamped.isEmpty, clamped.width >= 2, clamped.height >= 2 else {
                    err = "SCK: region outside display \(display.displayID) (local=\(local))"
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = clamped
                cfg.width = Int(clamped.width) * 2   // 2x，与旧 screencapture 在 Retina 下的输出一致
                cfg.height = Int(clamped.height) * 2
                cfg.showsCursor = false
                cfg.captureResolution = .best
                out = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                if out == nil { err = "SCK: nil image" }
            } catch {
                let e = error as NSError
                err = "SCK: \(e.domain) \(e.code) \(e.localizedDescription)"
            }
        }
        // 3 秒没回来就别再等（SCK 偶发不回调，旧代码会永久卡住这一轮）
        if sema.wait(timeout: .now() + 3) == .timedOut { err = "SCK: timeout 3s" }
        if let img = out { return (img, nil) }
        if let fb = captureViaProcess(rect) { return (fb, "\(err ?? "SCK: ?") → screencapture fallback OK") }
        return (nil, "\(err ?? "SCK: ?") → screencapture fallback also failed")
    }
    // 旧系统：子进程截图
    let img = captureViaProcess(rect)
    return (img, img == nil ? "screencapture failed" : nil)
}

/// 进程内截图（坐标与 AX 一致，顶部左侧原点）：主路 ScreenCaptureKit（macOS 14+），失败退子进程。
func captureRegion(_ rect: CGRect) -> CGImage? {
    captureRegionDetailed(rect).image
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

func regexLast(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    let ms = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
    guard let m = ms.last else { return nil }
    return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
}

/// 只有时间、没有日期时判定归属日：算出来的时间点比现在早 12 小时以上 → 视为次日。
/// （23:00 看到「将于 09:00 重置」指的必然是明天 09:00，不是今天早上）
func resolveBareTime(hour: Int, minute: Int) -> Date? {
    let cal = Calendar.current
    let now = Date()
    var c = DateComponents()
    c.year = cal.component(.year, from: now)
    c.month = cal.component(.month, from: now)
    c.day = cal.component(.day, from: now)
    c.hour = hour; c.minute = minute
    guard let d = cal.date(from: c) else { return nil }
    if d.timeIntervalSince(now) < -12 * 3600 {
        return cal.date(byAdding: .day, value: 1, to: d)
    }
    return d
}

/// 从「用量上限」文案解析额度重置时间（取最后一条匹配 = 最新的提示）：
/// 中文「在 2026年10月25日 00:14后重试」「将于 10月25日 0:14 重置」；
/// 英文「will reset at 4:00 PM」。解析失败返回 nil。
func parseLimitResetText(_ raw: String) -> Date? {
    let s = raw.replacingOccurrences(of: "\n", with: " ")
    let cal = Calendar.current
    let now = Date()
    var c = DateComponents()
    if let g = regexLast("(\\d{4})\\s*年\\s*(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日\\s*(\\d{1,2}):(\\d{2})", s), g.count == 5 {
        c.year = Int(g[0]); c.month = Int(g[1]); c.day = Int(g[2])
        c.hour = Int(g[3]); c.minute = Int(g[4])
        return cal.date(from: c)
    }
    if let g = regexLast("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日\\s*(\\d{1,2}):(\\d{2})", s), g.count == 4 {
        c.year = cal.component(.year, from: now)
        c.month = Int(g[0]); c.day = Int(g[1]); c.hour = Int(g[2]); c.minute = Int(g[3])
        return cal.date(from: c)
    }
    if let g = regexLast("reset[^0-9]{0,30}(\\d{1,2}):(\\d{2})\\s*([APap])\\.?\\s?M\\.?", s), g.count == 3 {
        var h = Int(g[0]) ?? 0
        let pm = g[2].uppercased() == "P"
        if pm, h < 12 { h += 12 }
        if !pm, h == 12 { h = 0 }
        return resolveBareTime(hour: h, minute: Int(g[1]) ?? 0)
    }
    // ── 只有时间、没有日期 ──
    // 中文官方横幅：「你的速率限制将于 22:59 重置」/「或在 22:59后重试」
    if let g = regexLast("(\\d{1,2})[:：](\\d{2})\\s*(?:后)?\\s*(?:重置|重试|恢复)", s), g.count == 2,
       let h = Int(g[0]), let mi = Int(g[1]), h < 24, mi < 60 {
        return resolveBareTime(hour: h, minute: mi)
    }
    // 英文横幅：「resets at 22:59」/「reset at 3:00 (24h)」
    if let g = regexLast("reset[s]?\\s*(?:at|around)\\s*(\\d{1,2}):(\\d{2})(?!\\s*[APap])", s), g.count == 2,
       let h = Int(g[0]), let mi = Int(g[1]), h < 24, mi < 60 {
        return resolveBareTime(hour: h, minute: mi)
    }
    return nil
}

func fmtMDHM(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX") // 固定数字格式，不随系统区域漂移
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: d)
}

/// 强制开启 Codex(Electron/Chromium) 渲染进程的无障碍支持。
/// 没有它时渲染层可能未启用 a11y，AXPress 会「假成功」（返回成功但不执行点击）。
/// AXManualAccessibility / AXEnhancedUserInterface 是跨进程写，会让 Chromium 重建 AX 树，
/// 每轮都写会在用户打字时造成卡顿：节流到 60 秒一次（Codex 重启后最多 60 秒恢复扫描）。
var lastRendererAXSetAt: Date = .distantPast
func enableRendererAccessibility(_ app: NSRunningApplication) {
    if Date().timeIntervalSince(lastRendererAXSetAt) < 60 { return }
    lastRendererAXSetAt = Date()
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

/// 用户是否正在活跃操作（打字 / 按鼠标 / 滚轮）。
/// 合成点击、AXPress、Return 注入都可能让输入框失焦、打断输入法组词，
/// 滚动按压还会把正往上翻历史的视图拽回底部——一切「动手」类操作前先过这道闸：
/// 用户活跃就本轮跳过，下个周期再动手（错误行不会自己消失，晚一轮点击无代价）。
/// anyAppKeySec > 0 时额外做不限前台的全局键盘检查：用户在任何 app 里打字都算活跃——
/// AXPress 偶发抢焦点（Chromium 行为），焦点归还的瞬间弹走弹回也会打断其他 app 的输入法组词。
func userActiveInCodex(_ app: NSRunningApplication,
                       keySec: Double = 5, mouseSec: Double = 3, scrollSec: Double = 0,
                       anyAppKeySec: Double = 0) -> Bool {
    let src = CGEventSourceStateID.combinedSessionState
    if anyAppKeySec > 0, CGEventSource.secondsSinceLastEventType(src, eventType: .keyDown) < anyAppKeySec { return true }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
    if keySec > 0, CGEventSource.secondsSinceLastEventType(src, eventType: .keyDown) < keySec { return true }
    if mouseSec > 0, CGEventSource.secondsSinceLastEventType(src, eventType: .leftMouseDown) < mouseSec { return true }
    if scrollSec > 0, CGEventSource.secondsSinceLastEventType(src, eventType: .scrollWheel) < scrollSec { return true }
    return false
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

/// 读取 Codex 输入框当前内容（nil = 输入框不存在）。
/// 供空闲发送做基线比对：Codex 会把内置建议文案（如「使用 ChatGPT Work」）直接写进 AXValue，
/// 视觉上是灰色占位，但 AX 读出来是「非空」，不能只凭非空就判定用户在输入。
func codexInputValue() -> String? {
    guard let app = codexApp() else { return nil }
    enableRendererAccessibility(app)
    guard let ta = findCodexTextArea() else { return nil }
    return axStr(ta, kAXValueAttribute)
}

/// 把一行文本写入 Codex 输入框并回车（原生实现，不抢焦点、光标不动）：
/// 输入框为空 → 直写；非空但与空闲基线一致（多为 Codex 的内置建议文案，非用户输入）→ 清场后直写；
/// 非空且与基线不同（用户空闲期间放了草稿）→ 跳过，绝不覆盖。
/// → AX 直写 kAXValue → 回读确认 → AXConfirm（失败则向进程投递 Return 键）→ 读回验证已清空。
/// 任何一步没确认成功都会把自己写进去的内容清回空——绝不给用户留下半截文字，也不让下一轮永远撞「非空」。
/// 返回 "sent" / "busy" / "unclear" / "nofield" / "error: ..."。
func nativeSendLine(_ line: String, baseline: String? = nil) -> String {
    guard let app = codexApp() else { return "nofield" }
    enableRendererAccessibility(app)
    guard let ta = findCodexTextArea() else { return "nofield" }
    let current = axStr(ta, kAXValueAttribute)
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, current != baseline {
        return "busy" // 空闲期开始后内容变了：可能是用户草稿，绝不覆盖
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
    var after = axStr(ta, kAXValueAttribute)
    if after == line {
        // AXConfirm 返回 success 也不代表真的发送（Codex 的输入框对它没反应，假成功）。
        // Return 键只有输入框持有键盘焦点时才被接收：先 AXFocused=true（不切换前台 app），再向进程投递 Return。
        AXUIElementSetAttributeValue(ta, "AXFocused" as CFString, kCFBooleanTrue)
        usleep(200_000)
        _ = postReturnKeyToPid(app.processIdentifier)
        usleep(800_000)
        after = axStr(ta, kAXValueAttribute)
    }
    if after != line { return "sent" } // 输入框内容已变化（通常被清空）即视为发出
    // 800ms 后这一行仍原样留在框里 = 没送出去。清空它，否则下一轮会被判「非空」而永久卡住
    AXUIElementSetAttributeValue(ta, kAXValueAttribute as CFString, "" as CFString)
    return "unclear"
}

// MARK: - 控制器

final class Controller: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    var window: NSWindow!
    var durationPopup: NSPopUpButton!
    var customHourField: NSTextField! // 运行时长「自定义」：小时
    var customMinField: NSTextField!  // 运行时长「自定义」：分钟（0–59）
    var intervalField: NSTextField!
    var idleSendField: NSTextField!
    var idleSendCheck: NSSwitch!
    var scriptView: NSTextView!
    var idleStopCheck: NSSwitch!
    var limitPauseCheck: NSSwitch! // 「用量上限时暂停重试与空闲发送」
    var soundCheck: NSSwitch!
    var silentSeg: NSSegmentedControl!
    var langSeg: NSSegmentedControl! // 界面语言切换：AUTO=跟随系统 / 中文 / EN
    var clickModeNote: NSTextField!
    var autoLearnCheck: NSSwitch!
    var noSleepCheck: NSSwitch!
    var startBtn: NSButton!
    var stopBtn: NSButton!
    var calibBtn: NSButton!
    var updateBtn: NSButton! // 「检查更新」：仅手动触发，无后台自动检查
    var permBtn: NSButton!
    var statusChip: ChipView!
    var logView: NSTextView!
    var permAxLabel: ChipView!
    var durHourLabel: NSTextField!
    var durMinLabel: NSTextField!
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
        // 截图自检（调试用，不影响正常启动）：环境变量 CR_CAPTURE_SELFTEST=1
        // 或存在 sentinel 文件 selftest.flag 时，连拍 3 次写日志后退出，
        // 用来判断「截图失败」是权限、SCK 还是兜底链路的问题。
        if ProcessInfo.processInfo.environment["CR_CAPTURE_SELFTEST"] == "1"
            || FileManager.default.fileExists(atPath: appSupportDir.appendingPathComponent("selftest.flag").path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { exit(0) }
                var regions: [(String, CGRect)] = [("主屏左上 (0,0)", CGRect(x: 0, y: 0, width: 80, height: 30))]
                // Codex 窗口内取一块：副屏/跨屏场景也能覆盖到（2026-10-29 的 -3812 就出在这）
                if let codex = codexApp() {
                    let ax = AXUIElementCreateApplication(codex.processIdentifier)
                    if let wins = axAttr(ax, kAXWindowsAttribute) as? [AXUIElement],
                       let w = wins.compactMap({ axRect($0) }).max(by: { $0.width * $0.height < $1.width * $1.height }) {
                        regions.append(("Codex 窗口 \(Int(w.minX)),\(Int(w.minY))", CGRect(x: w.minX + 60, y: w.minY + 60, width: 80, height: 30)))
                        regions.append(("Codex 窗口右下", CGRect(x: w.maxX - 140, y: w.maxY - 45, width: 80, height: 30)))
                    }
                }
                for (label, region) in regions {
                    let r = captureRegionDetailed(region)
                    let line: String
                    if let img = r.image {
                        line = "🧪 自检 \(label)：截图 OK \(img.width)x\(img.height)" + (r.error.map { "（\($0)）" } ?? "")
                    } else {
                        line = "🧪 自检 \(label)：截图失败 \(r.error ?? "未知")"
                    }
                    self.appendLog(line)
                    print(line)
                }
                exit(0)
            }
            return
        }
        // 额度判定自检（调试用）：CR_LIMIT_SELFTEST=1 时扫一次界面，把「看到了哪些上限文案、
        // 横幅在哪、解析出的重置时间」全部写出来后退出。用户报「额度没恢复却一直点/一直发」时用它定位。
        if ProcessInfo.processInfo.environment["CR_LIMIT_SELFTEST"] == "1"
            || FileManager.default.fileExists(atPath: appSupportDir.appendingPathComponent("limit-selftest.flag").path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { exit(0) }
                let s = scanCodex()
                var out: [String] = []
                out.append("🧪 额度自检：上限文案 \(s.limitItems.count) 条｜横幅按钮 \(s.limitAnchorRects.count) 个｜强信号 \(s.strongLimit ? "是" : "否")｜重试按钮 \(s.buttons.count) 个｜错误行 \(s.rows.count) 条")
                out.append("🧪 恢复入口：目标受限 \(s.goalLimited ? "是" : "否")｜「恢复目标」按钮 \(s.resumeGoal.map { "有（x=\(Int($0.rect.midX)) y=\(Int($0.rect.midY))）" } ?? "无")｜运行中 \(s.busy ? "是" : "否")")
                for it in s.limitItems {
                    out.append("   · y=\(Int(it.rect.midY)) h=\(Int(it.rect.height)) \(it.text)")
                }
                out.append("🧪 横幅文案 \(s.bannerLimitTexts.count) 条")
                let src = s.bannerLimitTexts.isEmpty ? s.limitTexts : s.bannerLimitTexts
                let parsed = src.compactMap(parseLimitResetText)
                out.append("🧪 解析出的重置时间：\(parsed.isEmpty ? "无" : parsed.map { fmtMDHM($0) }.joined(separator: ", "))")
                if let future = parsed.filter({ $0 > Date() }).max() {
                    out.append("🧪 判定：等到 \(fmtMDHM(future)) 再试（剩余 \(Int(future.timeIntervalSinceNow / 60)) 分钟）")
                } else if let past = parsed.filter({ $0 <= Date() }).max() {
                    let gap = Int(Date().timeIntervalSince(past) / 60)
                    out.append(gap < 5 ? "🧪 判定：横幅时间刚过 \(gap) 分钟 → 试一次"
                                       : "🧪 判定：横幅时间已过 \(gap) 分钟 → 探测退避 5/10/15/30 分钟")
                } else {
                    out.append("🧪 判定：解析不到重置时间 → 探测退避 5/10/15/30 分钟")
                }
                for line in out {
                    self.appendLog(line)
                    print(line)
                }
                exit(0)
            }
            return
        }
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
        window.title = "Codex-RetryPilot v\(appVersion)"
        window.center()
        window.minSize = NSSize(width: 600, height: 760)

        // 点击空白处结束输入（触发失焦 → controlTextDidEndEditing → 自动保存配置）。
        // NSView 默认不接 first responder，点空白不会自然结束编辑，必须手动兜底。
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            guard let self, let w = ev.window, w === self.window else { return ev }
            // 正在编辑 = firstResponder 是窗口 field editor，其 delegate 是某个 NSTextField
            guard let editor = w.firstResponder as? NSTextView,
                  editor.delegate is NSTextField else { return ev }
            if let hit = w.contentView?.hitTest(ev.locationInWindow) {
                let field = editor.delegate as? NSTextField
                let inSameField = hit === editor || hit === field || (field?.isDescendant(of: hit) ?? false)
                if !inSameField { w.makeFirstResponder(nil) } // 触发 end editing → 保存
            }
            return ev
        }

        let content = NSView()

        // ── 头部：一句话说明 + 权限状态胶囊（应用名在窗口标题栏，不再重复大标题）──
        let subtitle = NSTextField(labelWithString: L("Auto-retry Codex \"at capacity\" errors — hands-free",
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

        customHourField = NSTextField(string: "")
        customHourField.alignment = .right
        customHourField.isEnabled = false
        customHourField.isHidden = true
        customHourField.placeholderString = "0"
        customHourField.toolTip = L("Only applies when run duration is \"Custom\"; hours (0–720)", "仅当运行时长选择「自定义」时生效，单位为小时（0–720）")
        customHourField.delegate = self
        customHourField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        customMinField = NSTextField(string: "")
        customMinField.alignment = .right
        customMinField.isEnabled = false
        customMinField.isHidden = true
        customMinField.placeholderString = "45"
        customMinField.toolTip = L("Only applies when run duration is \"Custom\"; minutes (0–59)", "仅当运行时长选择「自定义」时生效，单位为分钟（0–59）")
        customMinField.delegate = self
        customMinField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // 「小时/分钟」后缀只在「自定义」时显示（预设选项自带单位）
        durHourLabel = NSTextField(labelWithString: L("h", "小时"))
        durHourLabel.textColor = .secondaryLabelColor
        durHourLabel.isHidden = true
        durMinLabel = NSTextField(labelWithString: L("min", "分钟"))
        durMinLabel.textColor = .secondaryLabelColor
        durMinLabel.isHidden = true
        let durRow = NSStackView(views: [formLabel(L("Run duration", "运行时长")), durationPopup, customHourField, durHourLabel, customMinField, durMinLabel])
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

        // 界面语言切换（监控参数卡片标题行右侧）：标签本身不翻译；切换即存配置，重启后生效
        langSeg = NSSegmentedControl(labels: ["AUTO", "中文", "EN"], trackingMode: .selectOne,
                                     target: self, action: #selector(langChanged))
        langSeg.selectedSegment = explicitLangPref == "zh" ? 1 : (explicitLangPref == "en" ? 2 : 0)
        langSeg.segmentStyle = .rounded
        langSeg.controlSize = .small   // 缩小样式，与 12pt 卡片标题相称
        langSeg.font = .systemFont(ofSize: 10)
        langSeg.toolTip = L("UI language: follow system / Chinese / English. Saves the choice and offers to relaunch.",
                            "界面语言：跟随系统 / 中文 / English。保存选择后可立即重启生效。")

        let paramsCard = card(icon: "slider.horizontal.3", title: L("Monitoring", "监控参数"), views: [durRow, ivRow],
                              trailing: langSeg)

        // ── 卡片 2：点击与运行（点击方式二选一 + 运行开关两列） ──
        silentSeg = NSSegmentedControl(labels: [L("Silent", "静默"), L("Compatible", "兼容")],
                                       trackingMode: .selectOne,
                                       target: self,
                                       action: #selector(clickModeChanged))
        silentSeg.selectedSegment = 0
        silentSeg.segmentStyle = .rounded
        silentSeg.toolTip = L("Silent: Accessibility press → native background click → coordinate click as a last resort (never touches your cursor unless everything else fails). Compatible: coordinate click only (briefly moves the cursor) — use it if pressing has no effect on your machine.",
                              "静默：无障碍按压 → 原生后台点击 → 实在不行才坐标点击（几乎不会动你的光标）。兼容：只用坐标点击（会短暂移动光标），按压在本机不起作用时选它。")
        let clickModeBadge = HelpBadge(
            title: L("Click mode", "点击方式"),
            tip: silentSeg.toolTip ?? "",
            example: L("Silent = press → background click → coordinate click as a last resort, barely touches your cursor; Compatible = coordinate click only, briefly moves the cursor. Choose Compatible if pressing never works on your machine.",
                       "静默＝按压→后台点击→坐标点击三级兜底，基本不动你的鼠标；兼容＝只用坐标点击，会短暂抢光标。按压总不生效的机器选兼容。"))
        let clickModeRow = NSStackView(views: [formLabel(L("Click mode", "点击方式")), silentSeg, clickModeBadge])
        clickModeRow.orientation = .horizontal
        clickModeRow.spacing = 8

        clickModeNote = NSTextField(labelWithString: "")
        clickModeNote.font = .systemFont(ofSize: 11)
        clickModeNote.textColor = .secondaryLabelColor

        noSleepCheck = NSSwitch()
        noSleepCheck.state = .on
        let noSleepRow = switchRow(noSleepCheck, L("Keep display awake", "监控期间防止息屏"),
                                   tip: L("Keeps the screen on via a power assertion while monitoring; released on stop", "监控运行时通过电源断言保持亮屏，停止后立即解除"),
                                   example: L("Overnight unattended retry runs — without it the display sleeps, screenshots fail, and retrying only resumes after wake. Manual power-off and lock screen (⌘⌃Q) are NOT covered: monitoring pauses until the screen returns.",
                                              "挂机通宵等重试——不开的话屏幕休眠后截图失败，要等亮屏才继续点。手动关屏、锁屏（⌘+控制+Q）不受保护：监控会暂停到屏幕恢复。"))

        idleStopCheck = NSSwitch()
        idleStopCheck.state = .on
        let idleStopRow = switchRow(idleStopCheck, L("Auto-stop after 10 idle minutes", "10 分钟无错误自动停止"),
                                    tip: L("Stops monitoring when no error line is seen for 10 consecutive minutes", "连续 10 分钟看不到错误行就自动停止监控"),
                                    example: L("Session recovered while you're away — the app calls it a day by itself. Does not apply when \"Idle auto-send\" is on (it takes over).",
                                               "会话已恢复、你在忙别的——app 自己收工，不用回来手动点停止。开着「空闲自动发送」时此项自动让位（不生效）。"))
        limitPauseCheck = NSSwitch()
        limitPauseCheck.state = .on
        let limitPauseRow = switchRow(limitPauseCheck,
                                      L("Pause when usage limit is hit", "用量上限时暂停，等额度重置"),
                                      tip: L("When Codex shows \"usage limit reached\": stop clicking Retry and idle auto-send (they can't work), wait for the quota reset time parsed from the message, then resume. Never presses \"Reset usage\" — that one-time reset is yours to spend",
                                             "识别到「用量已达上限」时：暂停点重试和空闲发送（发了也无效），等从文案里解析出的额度重置时间后自动恢复。不会代点「重置使用量」（一次性机会留给你）"),
                                      example: L("Seeing \"usage limit reached… retry after 00:14\": ON = pause until 00:14 then resume; OFF = old behavior, idle auto-send may fire into the limited session. Never presses \"Reset usage\" either way.",
                                                 "看到「用量已达上限…00:14 后重试」：开启则暂停到 00:14 后自动恢复；关闭则按旧逻辑跑，可能把空闲指令白发进受限会话。无论开关与否都不代点「重置使用量」。"))
        soundCheck = NSSwitch()
        soundCheck.state = .on
        let soundRow = switchRow(soundCheck, L("Play sound on stop", "停止时播放提示音"),
                                 tip: L("Plays an alert when monitoring stops (manual or auto)", "监控停止（手动或自动）时播放一声提示"),
                                 example: L("Hear it and know it's time to check back; turn it off for meetings or at night.",
                                            "听到声音就知道该回来看了；开会/深夜可关。"))
        autoLearnCheck = NSSwitch()
        autoLearnCheck.state = .on
        let autoLearnRow = switchRow(autoLearnCheck, L("Auto-learn new button styles", "自动学习新按钮样式"),
                                     tip: L("When matching fails, capture the new button appearance as a template", "匹配失败时自动收录新按钮外观为模板"),
                                     example: L("Codex redesigns its \"Retry\" button — usually self-heals unattended. OFF: you must click \"Calibrate\" yourself.",
                                                "Codex 改版导致「重试」按钮变色——开启通常无人值守自愈；关闭则需要你手动点「校准按钮」。"))

        let optCol1 = NSStackView(views: [noSleepRow, idleStopRow, limitPauseRow])
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
        let idleSendTip = L("\"Idle\" = no error line, no \"Retry\" button, and no running task on screen", "「空闲」= 界面上既无错误行、无「重试」按钮、也无运行中任务")
        let idleSendRow = switchRow(idleSendCheck,
                                    L("Idle auto-send: next command line", "空闲时自动发送下一行指令"),
                                    tip: idleSendTip,
                                    example: L("Feeds a multi-line script to Codex one by one for long tasks; two sends are at least 5 minutes apart; your own draft in the input box is never overwritten. Won't fire while usage-limited (unless that pause switch is off).",
                                               "多行脚本指令逐条喂给 Codex 跑长任务；两次发送至少隔 5 分钟；绝不覆盖你手打的草稿。用量上限暂停期间不发送（除非关掉「用量上限时暂停」开关）。"))
        idleSendCheck.target = self
        idleSendCheck.action = #selector(idleSendToggled)

        idleSendField = NSTextField(string: "10")
        idleSendField.alignment = .right
        idleSendField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        idleSendField.delegate = self
        idleSendField.toolTip = L("Minutes of idle before sending the next line (saved on focus loss)", "空闲持续多少分钟后发送下一行（失焦保存）")
        let idleUnit = NSTextField(labelWithString: L("min idle before next send", "分钟后发送下一行"))
        idleUnit.textColor = .secondaryLabelColor
        let idleMinutesRow = NSStackView(views: [formLabel(L("Idle", "空闲")), idleSendField, idleUnit])
        idleMinutesRow.orientation = .horizontal
        idleMinutesRow.spacing = 8

        let scriptLabel = NSTextField(labelWithString: L("Commands (one per line, sent top-down):",
                                                           "指令内容（每行一条，依次发送，空行跳过）："))
        scriptLabel.font = .systemFont(ofSize: 11)
        scriptLabel.textColor = .secondaryLabelColor
        let scriptScroll = thinScroll()
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
        stopBtn.alphaValue = 0.45   // 系统禁用态与普通灰按钮区分弱，叠加降透明度让「不可用」一眼可辨
        calibBtn = symbolButton(L("Calibrate", "校准按钮"), symbol: "scope", action: #selector(calibrateTapped))
        calibBtn.toolTip = L("Teach the app what the \"Retry\" button looks like (only needed after Codex UI updates)", "教应用认识「重试」按钮的样子（Codex 界面更新后才需要）")
        permBtn = symbolButton(L("Permissions", "授权"), symbol: "checkmark.shield", action: #selector(openPermTapped))
        permBtn.toolTip = L("Open permission guide / authorization settings", "打开权限引导 / 授权设置")
        updateBtn = symbolButton(L("Updates", "检查更新"), symbol: "arrow.triangle.2.circlepath", action: #selector(checkUpdatesTapped))
        updateBtn.toolTip = L("Manually check GitHub for a newer release. No background or automatic checks — runs only when you click.",
                              "手动到 GitHub 检查是否有新版本。不做任何后台/自动检查，仅在你点击时联网一次。")

        let btnRow = NSStackView(views: [startBtn, stopBtn, headerSpacer(), calibBtn, updateBtn, permBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.alignment = .centerY

        statusChip = ChipView(L("Standby", "待机"))
        statusChip.label.font = .systemFont(ofSize: 12, weight: .medium)

        // ── 日志 ──
        let scroll = thinScroll()
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

    /// 细边框滚动容器：系统 .bezelBorder 是 2px 内凹黑边，观感偏重；
    /// 这里用 1px separator 描边 + 圆角，与卡片风格统一
    private func thinScroll() -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.borderType = .noBorder
        s.wantsLayer = true
        if s.layer == nil { s.layer = CALayer() }
        s.layer?.cornerRadius = 8
        s.layer?.cornerCurve = .continuous
        s.layer?.borderWidth = 1
        s.layer?.borderColor = NSColor.separatorColor.cgColor
        return s
    }

    /// 表单行左侧固定宽度标签（同卡片内对齐；英文比中文宽，按语言给宽度）
    private func formLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.widthAnchor.constraint(equalToConstant: appLang == "zh" ? 72 : 92).isActive = true
        return l
    }

    /// 开关 + 说明文字行
    /// 「！」帮助徽标：悬停 0.5 秒弹出 NSPopover 说明气泡，移开即收起。
    /// 不用系统 toolTip：部分 macOS 版本对 label 类视图的 tooltip 有不显示的 bug，且无法保证生效。
    final class HelpBadge: NSView {
        private let popover = NSPopover()
        private var showItem: DispatchWorkItem?

        /// 气泡排版：标题（开关名，加粗）→ 说明 → 举例（次级色），三段分层，内容宽 330
        init(title: String, tip: String, example: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
            let contentW: CGFloat = 330, padX: CGFloat = 14, padY: CGFloat = 12, gap: CGFloat = 6
            func makeLabel(_ s: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSTextField {
                let l = NSTextField(wrappingLabelWithString: s)
                l.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
                l.textColor = color
                l.isSelectable = false
                l.preferredMaxLayoutWidth = contentW
                l.widthAnchor.constraint(lessThanOrEqualToConstant: contentW).isActive = true
                return l
            }
            let segs: [(String, CGFloat, NSColor, Bool)] = [
                (title, 12, .labelColor, true),
                (tip, 11, .labelColor, false),
                (example.isEmpty ? "" : L("Examples: ", "举例：") + example, 11, .secondaryLabelColor, false),
            ].filter { !$0.0.isEmpty }
            let stack = NSStackView(views: segs.map { makeLabel($0.0, size: $0.1, color: $0.2, bold: $0.3) })
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = gap
            stack.edgeInsets = NSEdgeInsets(top: padY, left: padX, bottom: padY, right: padX)
            stack.translatesAutoresizingMaskIntoConstraints = false
            let root = NSView()
            root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: root.topAnchor),
                stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            let vc = NSViewController()
            vc.view = root
            // 高度自己按文字度量算，显式给 preferredContentSize：
            // NSPopover 首帧时 autolayout 还没跑完，靠 fittingSize 会先弹成细条、尺寸也不稳
            func textH(_ s: String, size: CGFloat, bold: Bool) -> CGFloat {
                let font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
                return ceil((s as NSString).boundingRect(
                    with: NSSize(width: contentW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]).height)
            }
            let h = segs.reduce(padY * 2) { $0 + textH($1.0, size: $1.1, bold: $1.3) } + CGFloat(segs.count - 1) * gap
            vc.preferredContentSize = NSSize(width: contentW + padX * 2, height: h)
            popover.contentViewController = vc
            popover.behavior = .transient   // 点击气泡外任意处也会收起
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var intrinsicContentSize: NSSize { NSSize(width: 15, height: 15) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let s = NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])
            let sz = s.size()
            s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for t in trackingAreas { removeTrackingArea(t) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            let item = DispatchWorkItem { [weak self] in
                guard let self, let w = self.window, !self.popover.isShown else { return }
                // 0.5 秒后鼠标仍在这枚徽标上才弹出（移走/快速划过不弹）
                let p = self.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                guard self.bounds.insetBy(dx: -4, dy: -4).contains(p) else { return }
                self.popover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxY)
            }
            showItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        override func mouseExited(with event: NSEvent) {
            showItem?.cancel()
            if popover.isShown { popover.performClose(nil) }
        }
    }

    private func switchRow(_ sw: NSSwitch, _ text: String, tip: String? = nil, example: String? = nil) -> NSStackView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        var views: [NSView] = [sw, l]
        if let example { views.append(HelpBadge(title: text, tip: tip ?? "", example: example)) }
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    /// 现代分组卡片：圆角系统底色 + SF Symbol 图标标题 + 内容列
    private func card(icon: String, title: String, views: [NSView], trailing: NSView? = nil) -> NSBox {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        iconView.contentTintColor = .secondaryLabelColor
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        head.textColor = .secondaryLabelColor
        var headViews: [NSView] = [iconView, head]
        let hasTrailing = trailing != nil
        if let trailing { headViews += [headerSpacer(), trailing] } // 卡片标题行右侧扩展位（如语言切换）
        let headRow = NSStackView(views: headViews)
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
        if hasTrailing {
            // 标题行撑满卡片内容宽度，spacer 才能把 trailing 视图推到右端
            headRow.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                headRow.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
                headRow.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            ])
        }

        let box = NSBox()
        box.boxType = .custom
        box.fillColor = quaternaryFill()
        box.borderColor = .clear
        box.cornerRadius = 10
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 14),
            // 必须等宽：lessThanOrEqual 会让 inner 随内容收缩，带 trailing 视图时 spacer 撑不开、无法右对齐
            inner.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -14),
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
        // AEDeterminePermissionToAutomateTarget 返回值不可信，未明确 granted 时不当作缺失。
        // 自动化本身是可选权限：静默模式下用中性灰标注「可选」，只有兼容模式（坐标点击归还焦点用到它）才升级为琥珀「建议授权」
        let autoWarn = silentSeg.selectedSegment == 1
        permAutoLabel.set(color: auto == "granted" ? .systemGreen : (autoWarn ? .systemOrange : .systemGray),
                          dot: auto == "granted" ? "✓" : "○",
                          text: auto == "granted" ? name_au
                              : autoWarn ? "\(name_au) \(L("recommended", "建议授权"))"
                                         : "\(name_au) \(L("optional", "可选"))")
        permAxLabel.toolTip = ax ? L("Accessibility permission granted", "辅助功能权限已授予")
                                 : L("Missing: cannot read Codex UI elements (required)", "缺失：无法读取 Codex 界面元素（必需）")
        permScLabel.toolTip = sc ? L("Screen Recording permission granted", "屏幕录制权限已授予")
                                 : L("Missing: cannot capture screenshots to detect the error line (required)", "缺失：无法截图识别错误行（必需）")
        permAutoLabel.toolTip = auto == "granted" ? L("Automation permission granted", "自动化权限已授予")
                                                  : L("Optional. Only used to return focus after the coordinate-click fallback (compatible mode). macOS reports this state unreliably, so it is checked on demand (click \"Permissions\" to verify)", "可选权限。仅兼容模式的坐标点击兜底归还焦点时用到。系统对该状态回报不可靠，改为按需检测（点「授权」按钮可手动确认）")
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
        refreshPermLabel()   // 兼容模式依赖自动化权限，切换时同步刷新头部胶囊语义
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

    /// 把 customMinutes 拆成小时/分钟刷进两个输入框
    func syncCustomFieldsFromMinutes() {
        customHourField.stringValue = String(customMinutes / 60)
        customMinField.stringValue = String(customMinutes % 60)
    }

    /// 读取两个输入框并合并为总分钟数（非法值回退为当前 customMinutes）
    func commitCustomFields() {
        let h = Int(customHourField.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
        let m = Int(customMinField.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
        if h >= 0, h <= 720, m >= 0, m <= 59, h * 60 + m > 0 {
            customMinutes = h * 60 + m
        } else {
            syncCustomFieldsFromMinutes()
        }
    }

    /// 时长的人读格式：<1 小时显示「N 分钟」，否则「N 小时 M 分」
    func fmtDur(_ mins: Int) -> String {
        mins >= 60 ? L("\(mins / 60) h \(mins % 60) min", "\(mins / 60) 小时 \(mins % 60) 分")
                   : L("\(mins) min", "\(mins) 分钟")
    }

    @objc func durationChanged() {
        let isCustom = durationPopup.indexOfSelectedItem == 4
        durHourLabel.isHidden = !isCustom
        durMinLabel.isHidden = !isCustom
        if isCustom {
            customHourField.isHidden = false
            customHourField.isEnabled = true
            customMinField.isHidden = false
            customMinField.isEnabled = true
            syncCustomFieldsFromMinutes()
            window.makeFirstResponder(customHourField)
        } else {
            commitCustomFields() // 切走前保存已输入的值
            customHourField.isEnabled = false
            customHourField.isHidden = true
            customHourField.stringValue = ""
            customMinField.isEnabled = false
            customMinField.isHidden = true
            customMinField.stringValue = ""
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
            commitCustomFields()
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
        stopBtn.alphaValue = 1.0
        durationPopup.isEnabled = false
        customHourField.isEnabled = false
        customMinField.isEnabled = false
        calibBtn.isEnabled = false
        appendLog(L("▶️ Monitoring started | duration \(fmtDur(Int(selectedDuration() / 60))) | \(silentSeg.selectedSegment == 0 ? "silent" : "compatible") clicks",
                    "▶️ 开始监控｜时长 \(fmtDur(Int(selectedDuration() / 60)))｜\(silentSeg.selectedSegment == 0 ? "静默" : "兼容")点击"))
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
            self.stopBtn.alphaValue = 0.45
            self.durationPopup.isEnabled = true
            let isCustom = self.durationPopup.indexOfSelectedItem == 4
            self.customHourField.isEnabled = isCustom
            self.customMinField.isEnabled = isCustom
            if isCustom { self.syncCustomFieldsFromMinutes() }
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
        } else if field === customHourField || field === customMinField {
            commitCustomFields() // 非法输入在 commit 内回退为当前值
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
            let h = left / 3600, m = (left % 3600) / 60, s = left % 60
            self.statusChip.set(color: .systemGreen, dot: "●",
                                text: String(format: L("Running · %d:%02d:%02d left · %d clicks",
                                                        "运行中 · 剩余 %d:%02d:%02d · 已点击 %d 次"), h, m, s, self.clicksValue()))
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
        let limitPause = cfg.limitPauseEnabled // 「用量上限时暂停」开关；关闭则照旧逻辑走（空闲发送可能白发指令，用户自担）
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
        var captureFallbackHintAt = Date.distantPast // 「已改用 screencapture 兜底」提示的节流
            var preferCoordinateClick = false
            var downgradedAt: Date? = nil
            var lastRendererAXAt = Date.distantPast   // AXManualAccessibility 是跨进程写，不必每轮都设
            var skyDeadStreak = 0                     // 后台点击「按钮在但点了没反应」的连续次数
            var skyDeadUntil = Date.distantPast       // 该策略短期停用截止时间
            var clickCooldownUntil = Date.distantPast // 刚触发重试、服务端还没恢复时的冷却截止
            var lastLoggedRowCount = -1               // 只在错误行数变化时打检查日志
        var rowsStableSince: Date? = nil          // 错误行数上次变化的时刻：数量稳定 ≥60s 视为残留提示，不再挡空闲
        var stableHintAt = Date.distantPast       // 「残留错误视为空闲」提示的节流
        var scrollHintAt = Date.distantPast       // 「滚动到底」提示的节流
        var lastScrollPressAt = Date.distantPast  // 滚动按压节流：用户可能正往上翻历史，不要太频繁拽回底部
        var userActiveHintAt = Date.distantPast   // 「用户输入中，本轮跳过点击」提示的节流
        var idleSince: Double? = nil   // 单调时钟打点（秒），见 nowTick()
        var idleBaseline: String? = nil // 空闲期开始时的输入框内容；期间没变化才允许覆盖发送（Codex 会往输入框塞建议文案，AXValue 非空但不是用户输入）
        var idleSendIdx = 0
        var postSendHoldUntil: Double? = nil // 发送间隔保护：上一行发出后，下一行至少间隔 max(空闲分钟, 5) 分钟，
                                             // 防止「运行中停止按钮未被识别为 busy」时任务没跑完就发下一条
        var limitWasActive = false           // 上一轮是否处于上限状态：「已解除」日志只打一次
        var limitHintAt = Date.distantPast   // 上限提示节流
        var limitProbeLevel = 0              // 没有明确重置时间时的探测退避档位（5/10/15/30 分钟）
        var sendFailStreak = 0               // 空闲发送连续「unclear」次数：Codex 拒收 = 额度没恢复的硬证据
        var sendProbeUntil = 0.0             // 连续发送失败后的退避截止时刻（nowTick 口径）
        var goalAutoResumeDone = false       // 本次运行内是否已尝试「恢复目标」（只试一次）
        var lastResumeAt = Date.distantPast  // 上次「恢复目标 / 发继续」的时间：5 分钟内不重复（防额度抖动时连点连发）
        var limitIgnoreHintAt = Date.distantPast // 「命中上限字样但不算限额」提示的节流

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
            var scan = scanCodex()
            // 视图未滚到底（出现「滚动到底部」下箭头）时，窗口外的错误行/按钮读不全，
            // 直接判定会漏判「重试」按钮、也可能误判空闲。先滚到底、稍等渲染、重扫一次再用新数据判定。
            if scan.scrollBtn != nil, Date().timeIntervalSince(lastScrollPressAt) > 5,
               !userActiveInCodex(codex, scrollSec: 3) {
                lastScrollPressAt = Date()
                if AXUIElementPerformAction(scan.scrollBtn!, kAXPressAction as CFString) == .success {
                    if Date().timeIntervalSince(scrollHintAt) > 120 {
                        scrollHintAt = Date()
                        appendLog(L("⬇️ View not at bottom (scroll-to-bottom shown); scrolled down and rescanning",
                                    "⬇️ 界面未滚到底（出现下箭头），已滚动到底并重新读取"))
                    }
                    usleep(700_000)
                    scan = scanCodex()
                }
            }
            let rows = scan.rows
            // 日志原则：只打结论。错误行数没变就不刷屏；打印时只记「从多少变到多少」
            if rows.count != lastLoggedRowCount {
                let transition = lastLoggedRowCount >= 0 ? " \(lastLoggedRowCount)→\(rows.count) " : " \(rows.count) "
                lastLoggedRowCount = rows.count
                rowsStableSince = Date()   // 数量变了：稳定计时重新起算
                appendLog(L("⏱ Error lines:\(transition)", "⏱ 错误行 \(transition)条"))
            }
            // 空闲的判定：无错误行、无「重试」按钮、无运行中任务（「停止」类按钮）。
            // 少了「重试按钮」这一条会有漏洞：错误行文字没命中关键字但按钮在时，会被误判成空闲。
            // 例外：错误行数量稳定 ≥60 秒且无按钮、无任务 → 是残留的历史错误文字（如已恢复的 at capacity 提示），
            // 不是「忙」。否则残留错误会让空闲计时永不开始，空闲自动发送永远不触发。
            let rowsStableSec = rowsStableSince.map { Date().timeIntervalSince($0) } ?? 0
            let residualIdle = !rows.isEmpty && scan.buttons.isEmpty && !scan.busy && rowsStableSec >= 60
            if residualIdle, Date().timeIntervalSince(stableHintAt) > 120 {
                stableHintAt = Date()
                appendLog(L("ℹ️ \(rows.count) leftover error line(s), no \"Retry\" button, stable for 60s — treating as idle",
                            "ℹ️ 错误行 \(rows.count) 条已稳定 60 秒且无「重试」按钮，视为空闲（残留提示不影响发送）"))
            }
            let isIdle = rows.isEmpty && scan.buttons.isEmpty && !scan.busy
            if !isIdle && !residualIdle { idleSince = nil; idleBaseline = nil }
            // ── 用量上限（套餐额度用完）：点重试无效，暂停点击与空闲发送，等额度重置 ──
            // 判据只认「官方横幅」这一档，不做模糊匹配：
            //   ① 界面上有「重置使用量」按钮（这个按钮只出现在额度横幅上，实测可靠）；
            //   ② 或命中横幅专属措辞（速率限制将于 / 和工作使用额度已用完 / codex and work usage…）。
            // 对话正文里的「你已达到使用上限…升级套餐或充值额度…或在 22:59后重试」是历史消息，
            // 一律不算 —— 之前按「连续 2 轮」判定，界面一滚动就读不到、文案一抖动就误报「已解除」，
            // 2026-10-31 晚上就是这么停摆的。宁可漏判（还有下面的发送退避兜底），绝不误判。
            // 重置时间：只取横幅那一带的文案（与「重置使用量」按钮同高 ±120px）。
            // 等待策略：拿到未来时间就睡到点，期间绝不尝试；没有未来时间就 5/10/15/30 分钟探测一次。
            // 开关关闭时整段跳过，恢复旧行为（可能误判空闲、白发指令）。
            let bannerTexts = scan.bannerLimitTexts
            let resetSource = bannerTexts.isEmpty ? scan.limitTexts : bannerTexts
            let parsedResets = resetSource.compactMap(parseLimitResetText)
            let limitResetFuture = parsedResets.filter { $0 > Date() }.max()
            let limitResetPast = parsedResets.filter { $0 <= Date() }.max()
            // 横幅给的重置时间刚过 5 分钟内 = 额度应该刚恢复：退出暂停，去试一次（失败会被退回退避）
            let justReset = limitResetPast.map { Date().timeIntervalSince($0) < 300 } ?? false
            let limitStrong = scan.bannerPresent || scan.strongLimit
            let limitActive = limitPause && scan.buttons.isEmpty && !justReset && limitStrong
            // 目标条消失（已恢复/已清除）→ 允许下次再自动恢复一次
            if !scan.goalLimited, goalAutoResumeDone { goalAutoResumeDone = false }
            // 会话被额度打断后停在「目标使用受限」：只要额度横幅已经不在（= 额度已恢复），
            // 就点一次「恢复目标」把它接上，不必等 15 分钟窗口慢慢确认。
            // 每次运行只试一次，且你不在操作 Codex、它没在跑任务时才动。
            if !scan.bannerPresent, !goalAutoResumeDone, !scan.busy,
               !userActiveInCodex(codex), scan.goalLimited, let btn = scan.resumeGoal,
               Date().timeIntervalSince(lastResumeAt) > 300 {
                goalAutoResumeDone = true
                lastResumeAt = Date()
                if AXUIElementPerformAction(btn.el, kAXPressAction as CFString) == .success {
                    _ = clicksInc()
                    appendLog(L("▶️ Quota looks restored; pressed \"Resume goal\" so the interrupted goal continues",
                                "▶️ 额度看起来已恢复，已点「恢复目标」让被打断的目标继续"))
                } else {
                    clickGlobally(CGPoint(x: btn.rect.midX, y: btn.rect.midY))
                    _ = clicksInc()
                    appendLog(L("▶️ Quota looks restored; clicked \"Resume goal\" by coordinate",
                                "▶️ 额度看起来已恢复，已坐标点击「恢复目标」"))
                }
                sleepSec(2)
            }
            // 命中了上限字样却没判定为限额：说清原因，免得日志看起来像「上限被忽略」
            if limitPause, !scan.limitItems.isEmpty, !limitActive, !limitWasActive,
               Date().timeIntervalSince(limitIgnoreHintAt) > 300 {
                limitIgnoreHintAt = Date()
                let why: String
                if justReset { why = L("the banner's reset time just passed → trying once", "横幅上的重置时间刚过 → 先试一次") }
                else if !scan.buttons.isEmpty { why = L("a \"Retry\" button is present → transient model capacity error",
                                                        "界面上有「重试」按钮 → 按 at capacity 瞬时错误处理") }
                else if !rows.isEmpty { why = L("an at-capacity error line is visible → transient model capacity error",
                                                "屏幕上有 at capacity 错误行 → 按瞬时错误处理") }
                else { why = L("it's just a leftover line in the chat, not the official banner",
                               "它只是对话里的一条历史文案，不是官方额度横幅") }
                appendLog(L("ℹ️ Found text containing \"usage limit\" but \(why); not pausing",
                            "ℹ️ 检测到含「使用上限」的字样，但\(why)，不按额度耗尽处理"))
            }
            if limitActive {
                if !limitWasActive {
                    limitWasActive = true
                    let until = limitResetFuture.map { "，界面显示 " + fmtMDHM($0) + " 重置" }
                        ?? limitResetPast.map { "，界面显示的重置时间 " + fmtMDHM($0) + " 已过" }
                        ?? ""
                    appendLog(L("⏸ Usage limit reached\(until); retry clicks and idle auto-send paused until the quota resets. Won't press \"Reset usage\" — that one-time reset is yours to spend",
                                "⏸ 用量已达上限\(until)，暂停重试与空闲发送，等额度重置后自动恢复。不会代点「重置使用量」（一次性机会留给你）"))
                } else if Date().timeIntervalSince(limitHintAt) > 600 {
                    let eta = limitResetFuture.map { "，界面显示 " + fmtMDHM($0) + " 重置" } ?? ""
                    appendLog(L("⏸ Still usage-limited; waiting for quota reset\(eta)", "⏸ 仍处于用量上限状态，继续等待额度重置\(eta)"))
                }
                limitHintAt = Date()
                idleSince = nil; idleBaseline = nil
                lastErrorAt = Date() // 等待重置期间不算「无错误」，避免触发「10 分钟无错误自动停止」
                if let until = limitResetFuture {
                    // 界面给了明确重置时间：睡到点。每 2 分钟醒一次重新扫描（横幅可能被刷新/时间被改写）
                    limitProbeLevel = 0
                    let remain = until.timeIntervalSinceNow
                    sleepSec(min(max(remain, 5), 120))
                } else {
                    // 没有可用的未来时间（解析不出，或横幅给的时间已过）：退避探测，别每 20 秒空转
                    let ladder: [TimeInterval] = [300, 600, 900, 1800]
                    let wait = ladder[min(limitProbeLevel, ladder.count - 1)]
                    limitProbeLevel += 1
                    if limitProbeLevel == 1 {
                        appendLog(L("⏸ No usable reset time in the banner; probing again in \(Int(wait / 60)) min (backoff up to 30 min)",
                                    "⏸ 横幅里没有可用的重置时间，\(Int(wait / 60)) 分钟后再探（退避最长 30 分钟）"))
                    }
                    sleepSec(wait)
                }
                continue
            }
            if limitWasActive {
                limitWasActive = false
                limitProbeLevel = 0
                appendLog(L("✅ Usage limit cleared; resuming normal monitoring", "✅ 额度上限已解除，恢复正常监控"))
                // 额度恢复后把被打断的会话接上（跟随「用量上限时暂停」开关）：
                //   1) 界面上有「恢复目标」→ 点它，从原目标继续（不改会话意图，最准）
                //   2) 没有目标条 → 输入框发「继续」（框里有草稿则跳过，绝不覆盖）
                // 你不操作 Codex 且它没在跑任务时才动手，避免打断你或覆盖草稿。
                if limitPause, !scan.busy, !userActiveInCodex(codex), !goalAutoResumeDone,
                   Date().timeIntervalSince(lastResumeAt) > 300 {
                    lastResumeAt = Date()
                    if let btn = scan.resumeGoal {
                        goalAutoResumeDone = true
                        if AXUIElementPerformAction(btn.el, kAXPressAction as CFString) == .success {
                            _ = clicksInc()
                            appendLog(L("▶️ Pressed \"Resume goal\" — the goal interrupted by the usage limit continues",
                                        "▶️ 已点「恢复目标」，被额度中断的目标会话继续执行"))
                        } else {
                            clickGlobally(CGPoint(x: btn.rect.midX, y: btn.rect.midY))
                            _ = clicksInc()
                            appendLog(L("▶️ Accessibility press failed; clicked \"Resume goal\" by coordinate",
                                        "▶️ 无障碍按压「恢复目标」失败，已改用坐标点击"))
                        }
                        sleepSec(2)
                    } else {
                        switch nativeSendLine("继续") {
                        case "sent":
                            // 发完 Codex 就该跑起来了；仍留 5 分钟保护，避免 busy 识别慢时立刻又发脚本下一行
                            postSendHoldUntil = nowTick() + 300
                            sendFailStreak = 0
                            sendProbeUntil = 0
                            appendLog(L("▶️ Quota is back; sent \"继续\" to resume the interrupted conversation",
                                        "▶️ 额度已恢复，已发送「继续」接上被打断的会话"))
                        case "busy":
                            appendLog(L("ℹ️ Input box has unsent content; skipped the auto \"继续\" (won't overwrite your draft)",
                                        "ℹ️ 输入框有未发送内容，跳过自动「继续」（不覆盖你的草稿）"))
                        case "nofield":
                            appendLog(L("ℹ️ Input box not found; skipped the auto \"继续\"", "ℹ️ 未找到输入框，跳过自动「继续」"))
                        default:
                            // 发不出去 = 额度其实还没恢复：按发送退避，别每轮硬试
                            sendFailStreak += 1
                            let ladder: [Double] = [60, 120, 300, 600, 1200, 1800]
                            sendProbeUntil = nowTick() + ladder[min(sendFailStreak - 1, ladder.count - 1)]
                            appendLog(L("⚠️ Auto \"继续\" not confirmed — the quota may not be back yet; backing off",
                                        "⚠️ 自动「继续」未确认成功，额度可能还没真恢复，按退避再试"))
                        }
                    }
                }
            }
            guard let last = rows.map({ $0.rect }).max(by: { $0.minY < $1.minY }), !residualIdle else {
                // 无错误行：Codex 空闲（无重试按钮、无错误、无运行中任务）
                if idleSendEnabled, idleMin > 0 {
                    let now = nowTick()
                    if idleSince == nil { idleSince = now }
                    let idleSec = now - idleSince!
                    // 维护空闲基线：空闲期间输入框内容变了（用户草稿 / Codex 换了建议文案）→
                    // 更新基线并重新计满 N 分钟，绝不覆盖空闲开始后新出现的内容
                    var baselineChanged = false
                    if let cur = codexInputValue() {
                        if let base = idleBaseline {
                            if cur != base {
                                idleBaseline = cur
                                idleSince = now
                                baselineChanged = true
                            }
                        } else {
                            idleBaseline = cur
                        }
                    }
                    let lines = script
                    if !lines.isEmpty, idleSendIdx >= lines.count {
                        // 指令用完了：提示一次，避免用户以为还在发
                        if !exhaustedLogged {
                            exhaustedLogged = true
                            appendLog(L("✅ All \(lines.count) command lines sent; nothing left to send",
                                        "✅ \(lines.count) 行指令已全部发送完毕，不再发送"))
                        }
                    } else if baselineChanged {
                        // 基线这轮刚更新：内容是新的，本轮绝不发送（重新计满 N 分钟后再看）
                    } else if idleSec >= idleMin * 60, idleSendIdx < lines.count,
                              now >= sendProbeUntil,
                              postSendHoldUntil == nil || now >= postSendHoldUntil!,
                              !userActiveInCodex(codex) {
                        let line = lines[idleSendIdx]
                        appendLog(L("💬 Codex idle for \(Int(idleSec / 60)) min, sending line \(idleSendIdx + 1)/\(lines.count)…",
                                    "💬 Codex 已空闲 \(Int(idleSec / 60)) 分钟，发送第 \(idleSendIdx + 1)/\(lines.count) 行…"))
                        let r = nativeSendLine(line, baseline: idleBaseline)
                        switch r {
                        case "sent":
                            idleSendIdx += 1
                            idleSince = now        // 下一行同样要再空闲 N 分钟
                            postSendHoldUntil = now + max(Double(idleMin) * 60, 300) // 发送间隔保护：即使 busy 识别失效，两次发送至少隔 5 分钟
                            idleBaseline = nil     // 发送后框里已是新状态（被清空/换建议），下轮重新采样
                            if sendFailStreak > 0 || sendProbeUntil > 0 {
                                sendFailStreak = 0
                                sendProbeUntil = 0
                                appendLog(L("✅ Codex accepted input again; send backoff cleared",
                                            "✅ Codex 已能正常接收输入，发送退避解除"))
                            }
                            appendLog(L("✅ Idle send done | line \(idleSendIdx)/\(lines.count) sent (cursor untouched)",
                                        "✅ 空闲发送完成｜第 \(idleSendIdx)/\(lines.count) 行已发（光标未动）"))
                        case "busy":
                            // 空闲基线比对没通过：内容确实是空闲开始后新出现的，绝不覆盖；60 秒后再看
                            idleSince = now - idleMin * 60 + 60
                            if now - busyHintAt > 60 {
                                busyHintAt = now
                                appendLog(L("ℹ️ Input box has unsent content (possibly your draft); will retry in ~60s",
                                            "ℹ️ 输入框有未发送内容（可能是草稿），不覆盖，约 60 秒后再试"))
                            }
                        case "nofield":
                            idleSince = now - idleMin * 60 + 60
                            if now - noFieldHintAt > 60 {
                                noFieldHintAt = now
                                appendLog(L("ℹ️ Codex input box not found, cannot send (no repeat within 60s)",
                                            "ℹ️ 未找到 Codex 输入框，无法发送（60 秒内不重复提示）"))
                            }
                        default:
                            // 写入失败/未确认 = Codex 没接受这次输入。额度耗尽时正是这个表现：
                            // 文字写进去、回车投递了，但内容还留在框里。连续多次就是「额度没恢复」的硬证据，
                            // 因此按 1→2→5→10→20→30 分钟退避，别每 60 秒空转一次。
                            sendFailStreak += 1
                            let ladder: [Double] = [60, 120, 300, 600, 1200, 1800]
                            let wait = ladder[min(sendFailStreak - 1, ladder.count - 1)]
                            sendProbeUntil = now + wait
                            idleSince = now - idleMin * 60 + wait
                            appendLog(L("⚠️ Idle send not confirmed (\(r)); retry the same line in \(Int(wait / 60 >= 1 ? wait / 60 : 1)) min",
                                        "⚠️ 空闲发送未确认成功（\(r)），约 \(Int(wait / 60 >= 1 ? wait / 60 : 1)) 分钟后重试同一行"))
                            if sendFailStreak == 2 {
                                appendLog(L("⚠️ Codex rejected the input twice in a row — the quota is most likely still exhausted. Backing off (up to 30 min) until it accepts input again",
                                            "⚠️ Codex 连续 2 次拒收输入，判定额度很可能仍未恢复：进入退避（最长 30 分钟），直到它能接收输入为止"))
                            }
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
            let cap = captureRegionDetailed(region)
            // SCK 失败但子进程兜底成功：不打「截图失败」，只提示一次换路成功
            if cap.image != nil, let why = cap.error, Date().timeIntervalSince(captureFallbackHintAt) > 600 {
                captureFallbackHintAt = Date()
                appendLog(L("ℹ️ Screenshot switched to the screencapture helper (\(why))",
                            "ℹ️ 截图已改用 screencapture 兜底（\(why)）"))
            }
            guard let cand = cap.image else {
                captureFails += 1
                if captureFails <= 2 || captureFails % 6 == 0 {
                    let why = cap.error ?? L("unknown", "未知原因")
                    appendLog(L("Screenshot failed (\(why)); pausing…",
                                "截图失败（\(why)），暂停观察中…"))
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
                // UI 只显示可读观察文案；t/c/xor 等模板匹配参数只落日志文件，同签名由 appendLog 合并为 ×N
                appendLog(L("Button appearance not recognized yet, watching… (auto-learns new styles if enabled)",
                            "按钮外观暂未识别，继续观察…（已开启时自动学习新样式）"),
                          fileDetail: L("Button area mismatch (\(detail))", "按钮区域不匹配（\(detail)）"))
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
            // 用户正在打字/点击：任何合成点击都可能让输入框失焦、打断输入法组词。
            // anyAppKeySec=3：不限前台——你在其他 app 打字时 AXPress 偶发抢焦点再归还，
            // 弹走弹回的瞬间同样打断组词，所以任何 app 有打字动作都跳过本轮。
            if userActiveInCodex(codex, anyAppKeySec: 3) {
                if Date().timeIntervalSince(userActiveHintAt) > 120 {
                    userActiveHintAt = Date()
                    appendLog(L("ℹ️ You're typing/clicking; skipping automated actions this cycle to protect input focus",
                                "ℹ️ 检测到你正在输入/操作，本轮暂停自动点击，避免打断输入法"))
                }
                sleepSec(interval)
                continue
            }
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
        var limitPauseEnabled = true // 用户是否勾选「用量上限时暂停，等额度重置」
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
                         idleStopEnabled: idleStopCheck.state == .on,
                         limitPauseEnabled: limitPauseCheck.state == .on)
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
            "limitPause": limitPauseCheck.state == .on,
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
        st("limitPause", limitPauseCheck)
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

    // MARK: 界面语言切换（AUTO/中文/EN）

    @objc func langChanged() {
        let pref: String? = langSeg.selectedSegment == 1 ? "zh" : (langSeg.selectedSegment == 2 ? "en" : nil)
        guard pref != explicitLangPref else { return }
        explicitLangPref = pref
        saveConfig()
        // 同步 AppleLanguages 偏好：重启后 Dock/Finder 里的 App 名称（InfoPlist.strings）也跟着切换；
        // AUTO 则移除该偏好，恢复跟随系统语言
        if let pref {
            UserDefaults.standard.set([pref == "zh" ? "zh-Hans" : "en"], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let name = pref == "zh" ? "中文" : (pref == "en" ? "English" : L("System", "跟随系统"))
        let alert = NSAlert()
        alert.messageText = L("Language set to \(name)", "语言已切换为\(name)")
        alert.informativeText = L("Restart the app now to apply the new language?",
                                  "要立即重启应用使新语言生效吗？")
        alert.addButton(withTitle: L("Restart Now", "立即重启"))
        alert.addButton(withTitle: L("Later", "稍后"))
        if alert.runModal() == .alertFirstButtonReturn {
            // 不能用 NSWorkspace.openApplication：同 bundle id 已有实例在跑时它只会激活旧实例，
            // 随后 terminate 把唯一的实例杀掉 → 新实例永远起不来（「已不能再打开」报错）。
            // 改为起一个独立的延迟进程，等当前进程退出后再 open -n 拉起新实例。
            let path = Bundle.main.bundleURL.path
            if let task = try? Process.run(URL(fileURLWithPath: "/bin/sh"),
                                           arguments: ["-c", "sleep 0.8; open -n '\(path)'"]) {
                task.terminationHandler = nil
            }
            NSApp.terminate(nil)
        } else {
            appendLog(L("🌐 Language set to \(name); takes effect on next launch", "🌐 语言已设为\(name)，下次启动生效"))
        }
    }

    // MARK: 检查更新（仅手动触发，无任何后台/自动检查）

    /// 拉取 GitHub latest release 的版本号（后台线程调用，同步阻塞可接受）。
    /// 返回 nil = 网络失败/被限流/响应异常。
    static func fetchLatestReleaseTag() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yuxi1989/Codex-RetryPilot/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sema = DispatchSemaphore(value: 0)
        var data: Data?
        let task = URLSession.shared.dataTask(with: req) { d, _, _ in data = d; sema.signal() }
        task.resume()
        sema.wait() // 后台线程同步等待，超时 8 秒
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag
    }

    /// 语义化版本比较：逐段比数字，缺段按 0（"v" 前缀可有可无）
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func checkUpdatesTapped() {
        updateBtn.isEnabled = false
        appendLog(L("🔎 Checking for updates…", "🔎 正在检查更新…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tag = Self.fetchLatestReleaseTag()
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateBtn.isEnabled = true
                guard let tag else {
                    self.appendLog(L("⚠️ Update check failed (network unreachable or API rate-limited); current version v\(appVersion)",
                                "⚠️ 检查更新失败（网络不可达或被 GitHub 限流），当前版本 v\(appVersion)"))
                    return
                }
                if Self.isNewer(tag, than: appVersion) {
                    self.appendLog(L("🆕 New version \(tag) available (current v\(appVersion)); opening the releases page",
                                "🆕 发现新版本 \(tag)（当前 v\(appVersion)），已打开下载页"))
                    if let url = URL(string: "https://github.com/yuxi1989/Codex-RetryPilot/releases/latest") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    self.appendLog(L("✅ You're on the latest version (v\(appVersion))", "✅ 已是最新版本（v\(appVersion)）"))
                }
            }
        }
    }

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
        let cap = captureRegionDetailed(region)
        guard let cand = cap.image else {
            appendLog("校准失败：截图失败（\(cap.error ?? "未知原因")）")
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

    /// 同签名去重状态（主线程专用）：与上一条相同的内容合并为「×N」，避免每 10 秒刷一条相同的观察日志
    private var lastLogPlain: String?
    private var lastLogRepeat = 0
    private var lastLogRange = NSRange(location: NSNotFound, length: 0)

    /// fileDetail 非空时：UI 只显示 text（可读文案），参数等细节只写进日志文件
    func appendLog(_ text: String, fileDetail: String? = nil) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let stamp = f.string(from: Date())
        writeLogFile("[\(stamp)] \(fileDetail ?? text)\n")
        DispatchQueue.main.async { [weak self] in
            guard let self, let ts = self.logView.textStorage else { return }
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
            if text == self.lastLogPlain, self.lastLogRange.location != NSNotFound,
               NSMaxRange(self.lastLogRange) <= ts.length {
                // 与上一条相同：原位替换为「… ×N」
                self.lastLogRepeat += 1
                let line = "[\(stamp)] \(text) ×\(self.lastLogRepeat)\n"
                ts.replaceCharacters(in: self.lastLogRange, with: NSAttributedString(string: line, attributes: attr))
                self.lastLogRange = NSRange(location: self.lastLogRange.location, length: (line as NSString).length)
            } else {
                self.lastLogPlain = text
                self.lastLogRepeat = 1
                let line = "[\(stamp)] \(text)\n"
                ts.append(NSAttributedString(string: line, attributes: attr))
                self.lastLogRange = NSRange(location: ts.length - (line as NSString).length, length: (line as NSString).length)
            }
            if ts.length > 200_000 {
                ts.deleteCharacters(in: NSRange(location: 0, length: ts.length - 150_000))
                self.lastLogPlain = nil   // 早期内容被裁掉，range 已失效，重置合并状态
                self.lastLogRange = NSRange(location: NSNotFound, length: 0)
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

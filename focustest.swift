import Cocoa
import ApplicationServices

func attr(_ el: AXUIElement, _ k: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success else { return nil }
    return v
}
func str(_ el: AXUIElement, _ k: String) -> String { attr(el, k).map { "\($0)" } ?? "" }
func rect(_ el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute), CFGetTypeID(pv as CFTypeRef) == AXValueGetTypeID(),
          let sv = attr(el, kAXSizeAttribute), CFGetTypeID(sv as CFTypeRef) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "") == "com.openai.codex" }) else { print("NO_APP"); exit(0) }
let root = AXUIElementCreateApplication(app.processIdentifier)
// 开启渲染层无障碍
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
usleep(500_000)

func findBtn() -> AXUIElement? {
    var found: AXUIElement?
    func walk(_ el: AXUIElement, _ d: Int) {
        if d > 60 || found != nil { return }
        if str(el, kAXRoleAttribute) == "AXButton", str(el, kAXTitleAttribute) == "重试", let r = rect(el), r.height > 8 { found = el; return }
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
    }
    walk(root, 0)
    return found
}
func frontName() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

guard let btn = findBtn() else { print("NO_RETRY_BUTTON"); exit(0) }
print("点击前前台: \(frontName())")
let t0 = DispatchTime.now()
let res = AXUIElementPerformAction(btn, kAXPressAction as CFString)
print("AXPress: \(res.rawValue) @\(ms(t0))ms")
for delay in [30, 100, 300, 700, 1500] {
    usleep(UInt32(delay * 1000))
    print("  +\(ms(t0))ms 前台: \(frontName())")
}
func ms(_ s: DispatchTime) -> Int {
    Int(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1_000_000)
}
// 追加：光标位置对照由外部 shell 处理

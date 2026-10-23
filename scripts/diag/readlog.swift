import Cocoa
import ApplicationServices
func attr(_ el: AXUIElement, _ k: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success else { return nil }
    return v
}
func str(_ el: AXUIElement, _ k: String) -> String { attr(el, k).map { "\($0)" } ?? "" }
guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "") == "com.zhuxiaoyu.codexretry" }) else { print("NO_APP"); exit(0) }
var texts: [String] = []
func walk(_ el: AXUIElement, _ d: Int) {
    if d > 40 { return }
    let role = str(el, kAXRoleAttribute)
    if role == "AXTextArea" || role == "AXStaticText" {
        let v = str(el, kAXValueAttribute)
        let keys = ["检查", "点击", "按压", "退避", "重试", "恢复", "监控", "息屏", "按钮", "⏳", "⌛️"]
        if keys.contains(where: { v.contains($0) }) { texts.append(v) }
    }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
}
walk(AXUIElementCreateApplication(app.processIdentifier), 0)
print(texts.suffix(25).joined(separator: "\n"))

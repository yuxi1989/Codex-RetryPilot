import Cocoa
import ApplicationServices
func attr(_ el: AXUIElement, _ k: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success else { return nil }
    return v
}
func str(_ el: AXUIElement, _ k: String) -> String { attr(el, k).map { "\($0)" } ?? "" }
guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "") == "com.zhuxiaoyu.codexretry" }) else { print("NO_APP"); exit(0) }
var pressed = false
func walk(_ el: AXUIElement, _ d: Int) {
    if d > 40 || pressed { return }
    if str(el, kAXRoleAttribute) == "AXButton", str(el, kAXTitleAttribute) == "开始监控" {
        pressed = AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        return
    }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
}
walk(AXUIElementCreateApplication(app.processIdentifier), 0)
print("start pressed:", pressed)

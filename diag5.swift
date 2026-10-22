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
if let wins = attr(root, kAXWindowsAttribute) as? [AXUIElement], let w = wins.first {
    print("window:", rect(w).map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.minX,$0.minY,$0.width,$0.height) } ?? "?")
}
var rows: [CGRect] = []
var btns: [CGRect] = []
func walk(_ el: AXUIElement, _ d: Int) {
    if d > 60 { return }
    let role = str(el, kAXRoleAttribute)
    if role == "AXStaticText", str(el, kAXValueAttribute).contains("at capacity"), let r = rect(el), r.height > 5 { rows.append(r) }
    if role == "AXButton", str(el, kAXTitleAttribute) == "重试", let r = rect(el) { btns.append(r) }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
}
walk(root, 0)
print("rows:", rows.count, "btns:", btns.count)
if let last = rows.max(by: { $0.minY < $1.minY }) {
    print(String(format: "lastRow: x=%.0f y=%.0f w=%.0f -> target=(%.0f, %.0f)", last.minX, last.minY, last.width, last.minX + last.width + 295, last.midY))
}
btns.forEach { print(String(format: "btn: x=%.0f y=%.0f w=%.0f h=%.0f", $0.minX, $0.minY, $0.width, $0.height)) }

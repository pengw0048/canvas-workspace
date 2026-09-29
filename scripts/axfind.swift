// Prints the screen center of the first element whose title/value/description equals a string: axfind <app> <text>
import AppKit
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { exit(1) }
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    for k in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] where (attr(e, k) as? String) == a[2] { return e }
    guard d < 12, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for k in kids { if let f = find(k, d + 1) { return f } }
    return nil
}
guard let e = find(AXUIElementCreateApplication(app.processIdentifier), 0) else { print("not found"); exit(1) }
var p = CGPoint.zero, s = CGSize.zero
if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
print(Int(p.x + s.width / 2), Int(p.y + s.height / 2))

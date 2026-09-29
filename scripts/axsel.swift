// Gets or sets the selected range of a window's first text area: axsel <app> <title-prefix> [loc len]
import AppKit
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { exit(1) }
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == kAXTextAreaRole as String { return e }
    guard d < 8, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for k in kids { if let f = find(k, d + 1) { return f } }
    return nil
}
let wins = attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
guard let w = wins.first(where: { (attr($0, kAXTitleAttribute) as? String)?.hasPrefix(a[2]) == true }), let t = find(w, 0) else { print("no text area"); exit(1) }
if a.count > 4 {
    var r = CFRange(location: Int(a[3])!, length: Int(a[4])!)
    AXUIElementSetAttributeValue(t, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
}
var r = CFRange()
if let v = attr(t, kAXSelectedTextRangeAttribute) { AXValueGetValue(v as! AXValue, .cfRange, &r) }
print(r.location, r.length)

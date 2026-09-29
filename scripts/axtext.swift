// Prints the text of the first text area in a window: axtext <app name> <window title>
import AppKit
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { print("no app"); exit(1) }
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
func find(_ e: AXUIElement, _ d: Int) -> String? {
    if (attr(e, kAXRoleAttribute) as? String) == kAXTextAreaRole as String { return attr(e, kAXValueAttribute) as? String }
    guard d < 8, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for k in kids { if let s = find(k, d + 1) { return s } }
    return nil
}
let wins = attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
for w in wins where (attr(w, kAXTitleAttribute) as? String)?.hasPrefix(a[2]) == true { print(find(w, 0) ?? "<no text area>"); exit(0) }
print("no window")

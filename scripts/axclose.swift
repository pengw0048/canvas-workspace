// Closes an app's windows whose title starts with a prefix, through their close buttons: axclose <app> <prefix>
import AppKit
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { exit(0) }
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
let wins = attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
var n = 0
for w in wins where (attr(w, kAXTitleAttribute) as? String)?.hasPrefix(a[2]) == true {
    if let b = attr(w, kAXCloseButtonAttribute) { AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString); n += 1 }
}
print("closed \(n)")

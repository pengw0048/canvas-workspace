// Resizes an app's windows whose title starts with a prefix, through AX: size-window <app> <prefix> <w> <h>
import AppKit
let a = CommandLine.arguments
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == a[1] }) else { exit(1) }
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
var size = CGSize(width: Double(a[3])!, height: Double(a[4])!)
for w in attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    where (attr(w, kAXTitleAttribute) as? String)?.hasPrefix(a[2]) == true {
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
}

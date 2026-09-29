// Prints "App | title" for the named apps' windows (used to guard demo resets): app-windows <app>...
import CoreGraphics
let apps = Set(CommandLine.arguments.dropFirst())
let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in info where apps.contains(w[kCGWindowOwnerName as String] as? String ?? "") && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowOwnerName as String]!, "|", w[kCGWindowName as String] as? String ?? "")
}

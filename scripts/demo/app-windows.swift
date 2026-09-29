// Prints "App | title" for TextEdit and Preview windows (used to guard demo resets).
import CoreGraphics
let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in info where ["TextEdit", "Preview"].contains(w[kCGWindowOwnerName as String] as? String ?? "") && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowOwnerName as String]!, "|", w[kCGWindowName as String] as? String ?? "")
}

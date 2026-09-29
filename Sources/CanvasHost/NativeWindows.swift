import AppKit
import ApplicationServices
import CanvasCore

/// A window reported by the window server. Coordinates are global, top-left origin.
struct NativeWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String?
    let frame: CGRect
    let layer: Int
    let onScreen: Bool
    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    var label: String {
        if let t = title, !t.isEmpty { return "\(ownerName) — \(t)" }
        return "\(ownerName) — window \(Int(frame.width))×\(Int(frame.height))"
    }
}

enum NativeWindows {
    static var axTrusted: Bool { AXIsProcessTrusted() }
    static var screenCaptureAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Ordinary document windows of other applications.
    static func list(onScreenOnly: Bool = false) -> [NativeWindow] {
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard let num = w[kCGWindowNumber as String] as? UInt32,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard frame.width >= 80, frame.height >= 60 else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "App"
            if ["Window Server", "Dock", "Control Center", "Notification Center"].contains(owner) { return nil }
            return NativeWindow(windowID: num, pid: pid, ownerName: owner, title: w[kCGWindowName as String] as? String,
                                frame: frame, layer: layer, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    static func window(_ id: CGWindowID) -> NativeWindow? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]], let w = info.first,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return NativeWindow(windowID: id, pid: pid, ownerName: w[kCGWindowOwnerName as String] as? String ?? "App",
                            title: w[kCGWindowName as String] as? String,
                            frame: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
                            layer: w[kCGWindowLayer as String] as? Int ?? 0, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }

    // MARK: Accessibility

    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// `_AXUIElementGetWindow` maps an AX window to its window-server ID. It is undocumented; when it is
    /// missing we fall back to matching by frame and title, which can be ambiguous.
    static let getWindow: GetWindowFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(s, to: GetWindowFn.self)
    }()

    static func axWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success, let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    static func axWindow(for w: NativeWindow) -> AXUIElement? {
        guard axTrusted else { return nil }
        let wins = axWindows(pid: w.pid)
        if let f = getWindow {
            for a in wins {
                var id: CGWindowID = 0
                if f(a, &id) == .success, id == w.windowID { return a }
            }
        }
        let byFrame = wins.filter { frame(of: $0).map { abs($0.minX - w.frame.minX) < 2 && abs($0.minY - w.frame.minY) < 2 && abs($0.width - w.frame.width) < 2 } ?? false }
        return byFrame.count == 1 ? byFrame.first : nil
    }

    static func frame(of a: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(a, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setOrigin(_ a: AXUIElement, _ p: CGPoint) -> AXError {
        var pt = p
        guard let v = AXValueCreate(.cgPoint, &pt) else { return .failure }
        return AXUIElementSetAttributeValue(a, kAXPositionAttribute as CFString, v)
    }

    @discardableResult
    static func setSize(_ a: AXUIElement, _ s: CGSize) -> AXError {
        var sz = s
        guard let v = AXValueCreate(.cgSize, &sz) else { return .failure }
        return AXUIElementSetAttributeValue(a, kAXSizeAttribute as CFString, v)
    }

    static func raise(_ a: AXUIElement) {
        AXUIElementPerformAction(a, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(a, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func string(_ a: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Document file the application reports for a window (document-based apps only).
    static func documentPath(_ a: AXUIElement) -> String? {
        guard let s = string(a, kAXDocumentAttribute as String), let u = URL(string: s), u.isFileURL else { return nil }
        return u.path
    }

    static func title(_ a: AXUIElement) -> String? { string(a, kAXTitleAttribute as String) }

    static func isMinimized(_ a: AXUIElement) -> Bool {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(a, kAXMinimizedAttribute as CFString, &v)
        return (v as? Bool) ?? false
    }

    /// Presses the window's close button, which runs the app's normal close/save flow.
    static func pressClose(_ a: AXUIElement) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXCloseButtonAttribute as CFString, &v) == .success, let b = v else { return false }
        return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Sheets, dialogs, and palettes owned by the same process (the window family).
    static func family(pid: pid_t) -> [NativeWindow] {
        list(onScreenOnly: true).filter { $0.pid == pid }
    }

    // MARK: Coordinates

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa screen rect (bottom-left origin) to global top-left rect.
    static func globalRect(fromCocoa r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaRect(fromGlobal r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func isOnSomeDisplay(_ global: CGRect) -> Bool {
        let c = cocoaRect(fromGlobal: global)
        return NSScreen.screens.contains { $0.visibleFrame.intersection(c).width > 80 && $0.visibleFrame.intersection(c).height > 40 }
    }
}

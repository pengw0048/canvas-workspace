// Posts real input events for acceptance runs. Requires Accessibility.
// drive click X Y | drag X1 Y1 X2 Y2 | type TEXT | key CODE [cmd,shift,opt,ctrl] | front | pos
import AppKit
let a = CommandLine.arguments
let src = CGEventSource(stateID: .hidSystemState)
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(12_000) }
func mouse(_ t: CGEventType, _ p: CGPoint) { post(CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)) }
func flags(_ s: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in s.split(separator: ",") {
        switch m { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift); case "opt": f.insert(.maskAlternate); case "ctrl": f.insert(.maskControl); default: break }
    }
    return f
}
switch a[1] {
case "click":
    let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    mouse(.mouseMoved, p); mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
    if a.count > 4 { usleep(30_000); let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left); d?.setIntegerValueField(.mouseEventClickState, value: 2); post(d); let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left); u?.setIntegerValueField(.mouseEventClickState, value: 2); post(u) }
case "drag":
    let p1 = CGPoint(x: Double(a[2])!, y: Double(a[3])!), p2 = CGPoint(x: Double(a[4])!, y: Double(a[5])!)
    mouse(.mouseMoved, p1); mouse(.leftMouseDown, p1); usleep(150_000)
    for i in 1...30 { let t = Double(i) / 30; mouse(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)); usleep(16_000) }
    // Optional hold at the target with small movements, for spring-loaded destinations.
    let hold = a.count > 6 ? Int(a[6])! : 300
    var held = 0
    while held < hold { mouse(.leftMouseDragged, CGPoint(x: p2.x + Double(held / 50 % 2), y: p2.y)); usleep(50_000); held += 50 }
    mouse(.leftMouseDragged, p2); usleep(200_000); mouse(.leftMouseUp, p2)
case "down": mouse(.leftMouseDown, CGPoint(x: Double(a[2])!, y: Double(a[3])!))
case "move": mouse(.leftMouseDragged, CGPoint(x: Double(a[2])!, y: Double(a[3])!))
case "up": mouse(.leftMouseUp, CGPoint(x: Double(a[2])!, y: Double(a[3])!))
case "type":
    // Unicode events need a non-letter key code; some apps otherwise use the key code's character.
    for ch in a[2...].joined(separator: " ").utf16 {
        var c = ch
        for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: down); e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(e) }
    }
case "key":
    let code = CGKeyCode(Int(a[2])!), f = a.count > 3 ? flags(a[3]) : []
    for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = f; post(e) }
case "front":
    print(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
case "pos":
    print(CGEvent(source: nil)?.location ?? .zero)
default: print("unknown")
}

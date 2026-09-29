// Posts real input events for acceptance runs. Requires Accessibility.
// drive click X Y | drag X1 Y1 X2 Y2 | type TEXT | keys MS TEXT | typeu MS TEXT | hover X Y | key CODE [cmd,shift,opt,ctrl] | front | pos
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
    // Optional pause after pressing, as text views start a drag only from a held press.
    let pre = a.count > 7 ? Int(a[7])! : 150
    mouse(.mouseMoved, p1); mouse(.leftMouseDown, p1); usleep(useconds_t(pre * 1000))
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
    // Release the modifiers too, or the HID state keeps them held for later clicks (a later click became a ⌃-click).
    if !f.isEmpty {
        for m: CGKeyCode in [55, 56, 58, 59] { let e = CGEvent(keyboardEventSource: src, virtualKey: m, keyDown: false); e?.type = .flagsChanged; e?.flags = []; post(e) }
    }
case "typeu":
    // Unicode text with a delay between characters (IME-free typing into Cocoa text fields).
    let ms = UInt32(a[2])!
    for ch in a[3...].joined(separator: " ").utf16 {
        var c = ch
        for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: down); e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(e) }
        usleep(ms * 1000)
    }
case "keys":
    // US key codes with a delay between keys, for apps that ignore Unicode-string events (Terminal).
    let codes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "-": 27, "=": 24, ".": 47, ",": 43, "/": 44, " ": 49]
    let ms = UInt32(a[2])!
    for ch in a[3...].joined(separator: " ") {
        guard let code = codes[ch] else { continue }
        for down in [true, false] { post(CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)) }
        usleep(ms * 1000)
    }
case "hover":
    // Moves the pointer without pressing, over about half a second.
    let p0 = CGEvent(source: nil)?.location ?? .zero, p1 = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
    for i in 1...30 { let t = Double(i) / 30, e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        mouse(.mouseMoved, CGPoint(x: p0.x + (p1.x - p0.x) * e, y: p0.y + (p1.y - p0.y) * e)); usleep(4_000) }
case "front":
    let f = NSWorkspace.shared.frontmostApplication
    print(a.count > 2 ? "\(f?.processIdentifier ?? 0)" : f?.localizedName ?? "?")
case "pos":
    print(CGEvent(source: nil)?.location ?? .zero)
default: print("unknown")
}

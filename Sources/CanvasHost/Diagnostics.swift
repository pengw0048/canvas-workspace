import AppKit
import Carbon.HIToolbox
import CanvasCore

/// Operational events for a local diagnostic export. Records reasons, never contents or URLs.
enum Diagnostics {
    struct Event: Codable { var time: Date; var area: String; var message: String }
    private(set) static var events: [Event] = []

    static func record(_ area: String, _ message: String) {
        events.append(Event(time: Date(), area: area, message: message))
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
        NSLog("[%@] %@", area, message)
    }

    static func export(app: AppController) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Canvas Workspace diagnostics.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        let ws = app.workspace
        let summary: [String: Any] = [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "objects": ws.live.count,
            "objectKinds": Dictionary(grouping: ws.live, by: { $0.kind.rawValue }).mapValues(\.count),
            "scopes": ws.scopes.count,
            "save": ws.saveState.label,
            "pendingChanges": ws.pendingChanges.count,
            "screenRecording": NativeWindows.screenCaptureAllowed,
            "accessibility": NativeWindows.axTrusted,
            "connectedWindows": app.runtime.bindings.count,
            "liveSurfaces": app.runtime.liveObjects.count,
            "displays": NSScreen.screens.count,
        ]
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let evs = (try? JSONSerialization.jsonObject(with: enc.encode(events))) ?? []
        if let d = try? JSONSerialization.data(withJSONObject: ["summary": summary, "events": evs], options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }
}

/// A user-configurable global shortcut such as "ctrl+opt+space" (UserDefaults key per command).
struct Shortcut {
    var keyCode: UInt32
    var modifiers: UInt32

    static let keys: [String: Int] = [
        "space": kVK_Space, "c": kVK_ANSI_C, "r": kVK_ANSI_R, "k": kVK_ANSI_K, "return": kVK_Return, "escape": kVK_Escape,
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "0": kVK_ANSI_0, "9": kVK_ANSI_9,
    ]

    static func parse(_ s: String) -> Shortcut? {
        var mods: UInt32 = 0
        var key: UInt32?
        for part in s.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            default: key = keys[part].map(UInt32.init)
            }
        }
        return key.map { Shortcut(keyCode: $0, modifiers: mods) }
    }

    /// Reads `defaults write io.github.pengw0048.canvasworkspace <name> "ctrl+opt+space"`, else the default.
    static func configured(_ name: String, default d: String) -> Shortcut {
        parse(UserDefaults.standard.string(forKey: name) ?? d) ?? parse(d)!
    }
}

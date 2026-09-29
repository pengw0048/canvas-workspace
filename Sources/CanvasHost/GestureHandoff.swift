import AppKit
import CanvasCore

/// While an application owns input, ⌃⌥-scroll or ⌃⌥-pinch hands input back to the canvas.
/// The initiating gesture is consumed so the application never receives it (§5.2).
final class GestureHandoff {
    unowned let app: AppController
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(app: AppController) { self.app = app }

    /// NSEventTypeGesture (29) and NSEventTypeMagnify (30) have no named CGEventType cases.
    static let gestureTypes: Set<UInt32> = [29, 30]

    func start() {
        guard tap == nil, NativeWindows.axTrusted else { return }
        let mask = (UInt64(1) << UInt64(CGEventType.scrollWheel.rawValue)) | (UInt64(1) << 29) | (UInt64(1) << 30)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            guard let ctx else { return Unmanaged.passUnretained(event) }
            let h = Unmanaged<GestureHandoff>.fromOpaque(ctx).takeUnretainedValue()
            return h.handle(type, event)
        }, userInfo: me)
        guard let tap else { Diagnostics.record("input", "gesture tap unavailable"); return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let f = event.flags
        guard type == .scrollWheel || Self.gestureTypes.contains(type.rawValue),
              f.contains(.maskControl), f.contains(.maskAlternate),
              let id = app.runtime.activeObject, app.workspace.object(id)?.kind == .app,
              let c = app.runtime.activeCanvas ?? app.activeCanvas else { return Unmanaged.passUnretained(event) }
        let nsLoc = NSEvent.mouseLocation
        let dy = type == .scrollWheel ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : 0
        let dx = type == .scrollWheel ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : 0
        DispatchQueue.main.async {
            self.app.runtime.deactivate(capture: true)
            // Continue the gesture on the canvas at the pointer.
            guard let w = c.window else { return }
            let vp = c.convert(w.convertPoint(fromScreen: nsLoc), from: nil)
            if type == .scrollWheel { c.camera.pan(dx: dx, dy: dy) } else { c.camera.zoom(by: 1.1, anchor: vp) }
            c.applyCamera()
            c.hud.flash("Input returned to the canvas")
        }
        return nil  // consumed: the application never sees the initiating gesture
    }
}

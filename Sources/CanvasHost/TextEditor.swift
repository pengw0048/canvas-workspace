import AppKit
import CanvasCore

/// An AppKit text view placed over a native text object; IME and selection come from AppKit.
final class TextEditor: NSObject, NSTextViewDelegate {
    let objectID: ObjectID
    unowned let canvas: CanvasView
    let container = NSView()
    let textView: NSTextView
    var commitTimer: Timer?
    var lastCommitted: String

    init(objectID: ObjectID, canvas: CanvasView) {
        self.objectID = objectID
        self.canvas = canvas
        let o = canvas.ws.object(objectID)!
        lastCommitted = o.text
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: o.geom.w, height: o.geom.h))
        super.init()
        textView.string = o.text
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.focusRingType = .none
        let size: Double
        let inset: NSSize
        switch o.kind {
        case .sticky: size = o.props.fontSize ?? 18; inset = NSSize(width: 9, height: 12)
        case .shape: size = o.props.fontSize ?? 18; inset = NSSize(width: 5, height: 8)
        case .connector: size = 13; inset = .zero
        default: size = o.props.fontSize ?? 20; inset = .zero
        }
        textView.font = .systemFont(ofSize: size)
        textView.textColor = o.kind == .sticky ? NSColor(white: 0.1, alpha: 1) : (NSColor(hex: o.props.color) ?? .labelColor)
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = inset
        textView.textContainer?.lineFragmentPadding = 5
        if o.kind == .shape { textView.alignment = .center }
        container.addSubview(textView)
        canvas.addSubview(container, positioned: .below, relativeTo: canvas.hud)
        reposition()
        canvas.window?.makeFirstResponder(textView)
    }

    /// Frame = projected rect; bounds = logical size, so AppKit scales text to the zoom.
    func reposition() {
        guard let o = canvas.ws.object(objectID) else { return }
        var g = o.geom
        if o.kind == .connector {
            let a = canvas.ws.connectorEndpoint(o.props.start).point, b = canvas.ws.connectorEndpoint(o.props.end).point
            g = Geometry(x: (a.x + b.x) / 2 - 80, y: (a.y + b.y) / 2 - 14, w: 160, h: 28)
        }
        let z = canvas.camera.zoom
        let c = canvas.camera.toView(g.center)
        container.frameCenterRotation = 0
        container.frame = NSRect(x: c.x - g.w * z / 2, y: c.y - g.h * z / 2, width: g.w * z, height: g.h * z)
        container.bounds = NSRect(x: 0, y: 0, width: g.w, height: g.h)
        if o.kind.rotates && g.rotation != 0 { container.frameCenterRotation = -g.rotation * 180 / .pi }
        textView.frame = NSRect(x: 0, y: 0, width: g.w, height: max(g.h, textView.frame.height))
    }

    func textDidChange(_ notification: Notification) {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.commit() }
        growIfNeeded()
    }

    /// Text objects grow downward to fit; notes keep their size.
    func growIfNeeded() {
        guard let o = canvas.ws.object(objectID), o.kind == .text,
              let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let needed = lm.usedRect(for: tc).height + 12
        if needed > o.geom.h + 1 {
            var g = o.geom
            g.h = needed
            try? canvas.ws.perform("Edit text", recordUndo: false) { $0.update(objectID) { $0.geom = g } }
            reposition()
        }
    }

    func commit() {
        commitTimer?.invalidate()
        let s = textView.string
        guard s != lastCommitted, canvas.ws.object(objectID) != nil else { return }
        lastCommitted = s
        do { try canvas.ws.perform("Edit text") { $0.update(objectID) { $0.text = s } } }
        catch { canvas.app.report(error) }
    }

    /// Merges a remote text change while preserving the local caret where possible.
    func remoteUpdate() {
        guard let o = canvas.ws.objects[objectID] else { return }
        if o.deleted { canvas.endEditing(); return }
        guard o.text != lastCommitted, textView.string == lastCommitted, !textView.hasMarkedText() else { return }
        let sel = textView.selectedRange()
        lastCommitted = o.text
        textView.string = o.text
        textView.setSelectedRange(NSRange(location: min(sel.location, (o.text as NSString).length), length: 0))
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            canvas.endEditing()
            return true
        }
        return false
    }

    func finish() {
        commit()
        container.removeFromSuperview()
    }
}

extension CanvasView {
    func beginEditing(_ id: ObjectID, creating: Bool = false) {
        endEditing()
        editor = TextEditor(objectID: id, canvas: self)
        renderer.sync(ws)
        updateOverlay()
        _ = creating
    }

    func endEditing() {
        guard let ed = editor else { return }
        ed.finish()
        editor = nil
        // A text object left empty after editing is removed, as in other canvas tools.
        if let o = ws.object(ed.objectID), o.kind == .text, o.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? ws.removeFromCanvas([o.id])
        }
        renderer.sync(ws)
        window?.makeFirstResponder(self)
        updateOverlay()
    }
}

import AppKit
import Automerge
import CanvasCore

extension String {
    /// Unicode-scalar offset for a UTF-16 offset, as Automerge text positions count scalars.
    func scalarOffset(utf16 n: Int) -> Int {
        let i = String.Index(utf16Offset: min(n, utf16.count), in: self)
        return unicodeScalars.distance(from: unicodeScalars.startIndex, to: i)
    }

    func utf16Offset(scalar n: Int) -> Int {
        let i = unicodeScalars.index(unicodeScalars.startIndex, offsetBy: min(n, unicodeScalars.count))
        return utf16.distance(from: utf16.startIndex, to: i)
    }

    /// Minimal single splice turning `self` into `other`, in Unicode scalars.
    func spliceDiff(to other: String) -> (start: Int, delete: Int, insert: String) {
        let a = Array(unicodeScalars), b = Array(other.unicodeScalars)
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var q = 0
        while q < a.count - p && q < b.count - p && a[a.count - 1 - q] == b[b.count - 1 - q] { q += 1 }
        var ins = String.UnicodeScalarView()
        ins.append(contentsOf: b[p..<(b.count - q)])
        return (p, a.count - p - q, String(ins))
    }
}

/// An AppKit text view placed over a native text object; IME and selection come from AppKit.
final class TextEditor: NSObject, NSTextViewDelegate {
    let objectID: ObjectID
    unowned let canvas: CanvasView
    let container = NSView()
    let textView: NSTextView
    var commitTimer: Timer?
    /// The text and document heads the editor last synchronized with.
    var lastCommitted: String
    var baseHeads: Set<ChangeHash>

    init(objectID: ObjectID, canvas: CanvasView) {
        self.objectID = objectID
        self.canvas = canvas
        let o = canvas.ws.object(objectID)!
        lastCommitted = o.text
        baseHeads = canvas.ws.heads(o.scope)
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
        let mine = textView.string
        guard mine != lastCommitted, let o = canvas.ws.object(objectID), !textView.hasMarkedText() else { return }
        let d = lastCommitted.spliceDiff(to: mine)
        let caret = mine.scalarOffset(utf16: textView.selectedRange().location)
        do {
            try canvas.ws.spliceText(objectID, baseHeads: baseHeads, start: d.start, delete: d.delete, insert: d.insert)
        } catch { canvas.app.report(error); return }
        // Express the caret in base coordinates so the cursor mapping covers own and remote edits.
        let insLen = d.insert.unicodeScalars.count
        var basePos = caret, back = 0
        if caret > d.start {
            if caret >= d.start + insLen { basePos = caret - insLen + d.delete }
            else { basePos = d.start + d.delete; back = d.start + insLen - caret }
        }
        adopt(o.scope, basePosition: basePos, back: back)
    }

    /// Takes the merged document text, keeping the caret at the same logical place.
    func adopt(_ scope: ScopeID, basePosition: Int? = nil, back: Int = 0) {
        guard let o = canvas.ws.objects[objectID], let doc = canvas.ws.scopes[scope] else { return }
        let basePos = basePosition ?? textView.string.scalarOffset(utf16: textView.selectedRange().location)
        let newHeads = canvas.ws.heads(scope)
        let merged = o.text
        if merged != textView.string {
            let target = max(0, (doc.mapPosition(objectID, baseHeads: baseHeads, position: basePos) ?? basePos) - back)
            textView.string = merged
            let u = merged.utf16Offset(scalar: target)
            textView.setSelectedRange(NSRange(location: min(u, (merged as NSString).length), length: 0))
        }
        lastCommitted = merged
        baseHeads = newHeads
    }

    /// Merges a remote text change into the open editor without discarding local typing.
    func remoteUpdate() {
        guard let o = canvas.ws.objects[objectID] else { return }
        if o.deleted { canvas.endEditing(); return }
        guard !textView.hasMarkedText() else { return }
        if textView.string != lastCommitted { commit(); return }
        guard o.text != lastCommitted else { baseHeads = canvas.ws.heads(o.scope); return }
        adopt(o.scope)
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

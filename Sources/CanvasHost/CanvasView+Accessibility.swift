import AppKit
import CanvasCore

/// One canvas object exposed to assistive technology.
final class ObjectAccessibilityElement: NSAccessibilityElement {
    weak var canvas: CanvasView?
    let objectID: ObjectID

    init(canvas: CanvasView, objectID: ObjectID) {
        self.canvas = canvas
        self.objectID = objectID
        super.init()
    }

    override func accessibilityFrame() -> NSRect {
        guard let c = canvas, let o = c.ws.object(objectID), let w = c.window else { return .zero }
        let r = c.camera.toView(o.geom.bounds)
        return w.convertToScreen(c.convert(r, to: nil))
    }

    override func accessibilityParent() -> Any? { canvas }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        guard let c = canvas, let o = c.ws.object(objectID) else { return nil }
        var parts = [c.kindName(o), o.title]
        if let st = c.status(for: o) { parts.append(st.text) }
        if o.scope != Scope.privateID { parts.append("shared") }
        if c.selection.contains(objectID) { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    override func accessibilityPerformPress() -> Bool {
        canvas?.selection = [objectID]
        canvas?.activateOrEdit(objectID)
        return true
    }

    override func isAccessibilitySelected() -> Bool { canvas?.selection.contains(objectID) ?? false }
}

extension CanvasView {
    func kindName(_ o: CanvasObject) -> String {
        switch o.kind {
        case .app: return "\(o.props.appName ?? "Application") window"
        case .browser: return o.props.browserMode?.label ?? "Web page"
        case .sticky: return "Sticky note"
        case .file: return "File"
        case .image: return o.props.liveOf != nil ? "Live view" : "Image"
        default: return o.kind.rawValue.capitalized
        }
    }

    /// Objects in reading order: frames by position, then their members, then loose objects.
    func readingOrder() -> [ObjectID] {
        let objs = ws.live.filter { $0.kind != .group }
        return objs.sorted {
            let a = $0.geom.bounds, b = $1.geom.bounds
            return abs(a.minY - b.minY) > 40 ? a.minY < b.minY : a.minX < b.minX
        }.map(\.id)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Canvas, \(ws.live.count) objects. \(app.runtime.inputOwnerText)" }

    override func accessibilityChildren() -> [Any]? {
        let vis = camera.visibleWorld
        let ids = readingOrder().filter { id in ws.object(id).map { vis.intersects($0.geom.bounds) } ?? false }
        let objects: [Any] = ids.prefix(400).map { id in
            if let e = accessibilityCache[id] { return e }
            let e = ObjectAccessibilityElement(canvas: self, objectID: id)
            accessibilityCache[id] = e
            return e
        }
        // Toolbar, status, and editor subviews stay reachable alongside the objects.
        return objects + subviews.filter { !$0.isHidden }
    }

    /// Tab / ⇧Tab: select the next object in reading order and reveal it.
    func selectNext(backward: Bool) {
        let order = readingOrder()
        guard !order.isEmpty else { return }
        let cur = selection.first.flatMap { order.firstIndex(of: $0) }
        let next = cur.map { (backward ? $0 - 1 + order.count : $0 + 1) % order.count } ?? (backward ? order.count - 1 : 0)
        selection = [order[next]]
        if let o = ws.object(order[next]), !camera.visibleWorld.contains(o.geom.bounds) { reveal(o.id, highlight: false) }
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
}

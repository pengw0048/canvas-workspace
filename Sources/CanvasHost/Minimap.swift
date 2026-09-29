import AppKit
import CanvasCore

/// Overview of the whole workspace with the current view and collaborators' pointers; click or drag to move there.
final class MinimapView: NSView {
    weak var canvas: CanvasView?
    private let objects = CALayer()
    private let viewport = CAShapeLayer()
    private let cursors = CALayer()
    private var world = WRect(x: -1000, y: -1000, w: 2000, h: 2000)
    static let size = CGSize(width: 208, height: 132)

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = Theme.cardBackground.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = Theme.cardBorder.cgColor
        layer?.masksToBounds = true
        for l in [objects, cursors] { l.actions = ObjectLayer.noActions; layer?.addSublayer(l) }
        viewport.actions = ObjectLayer.noActions
        viewport.fillColor = Theme.focus.withAlphaComponent(0.1).cgColor
        viewport.strokeColor = Theme.focus.cgColor
        viewport.lineWidth = 1.5
        layer?.addSublayer(viewport)
        toolTip = "Minimap: click or drag to move the view"
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var inner: CGRect { bounds.insetBy(dx: 8, dy: 8) }

    private func toMap(_ r: WRect) -> CGRect {
        let s = min(inner.width / world.w, inner.height / world.h)
        let ox = inner.midX - world.w * s / 2, oy = inner.midY - world.h * s / 2
        return CGRect(x: ox + (r.x - world.x) * s, y: oy + (r.y - world.y) * s, width: r.w * s, height: r.h * s)
    }

    private func toWorld(_ p: CGPoint) -> WPoint {
        let s = min(inner.width / world.w, inner.height / world.h)
        let ox = inner.midX - world.w * s / 2, oy = inner.midY - world.h * s / 2
        return WPoint(x: world.x + (p.x - ox) / s, y: world.y + (p.y - oy) / s)
    }

    /// Redraws object shapes; call when the workspace changes.
    func refreshObjects() {
        guard let c = canvas else { return }
        let live = c.ws.live.filter { $0.kind != .connector && $0.kind != .group }
        let content = WRect.union(live.map(\.geom.bounds)) ?? c.camera.visibleWorld
        world = content.insetBy(-max(content.w, content.h) * 0.08)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        objects.frame = bounds
        objects.sublayers?.forEach { $0.removeFromSuperlayer() }
        for o in live.sorted(by: { ($0.kind == .frame ? 0 : 1) < ($1.kind == .frame ? 0 : 1) }) {
            let l = CALayer()
            l.frame = toMap(o.geom.bounds)
            l.cornerRadius = 1.5
            switch o.kind {
            case .frame:
                l.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
                l.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor
                l.borderWidth = 0.5
            case .app, .browser: l.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
            case .sticky: l.backgroundColor = (NSColor(hex: o.props.color) ?? .systemYellow).cgColor
            default: l.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor
            }
            objects.addSublayer(l)
        }
        CATransaction.commit()
        refreshViewport()
        refreshCursors()
    }

    func refreshViewport() {
        guard let c = canvas else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewport.frame = bounds
        viewport.path = CGPath(roundedRect: toMap(c.camera.visibleWorld).intersection(bounds.insetBy(dx: 1, dy: 1)), cornerWidth: 2, cornerHeight: 2, transform: nil)
        CATransaction.commit()
    }

    func refreshCursors() {
        guard let c = canvas else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursors.frame = bounds
        cursors.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (_, rc) in c.remoteCursors {
            let r = toMap(WRect(x: rc.point.x, y: rc.point.y, w: 0, h: 0))
            let dot = CALayer()
            dot.frame = CGRect(x: r.minX - 3.5, y: r.minY - 3.5, width: 7, height: 7)
            dot.cornerRadius = 3.5
            dot.backgroundColor = rc.color.cgColor
            dot.borderColor = NSColor.white.cgColor
            dot.borderWidth = 1
            cursors.addSublayer(dot)
        }
        CATransaction.commit()
    }

    override func mouseDown(with e: NSEvent) { jump(e) }
    override func mouseDragged(with e: NSEvent) { jump(e) }

    private func jump(_ e: NSEvent) {
        guard let c = canvas else { return }
        var cam = c.camera
        cam.center = toWorld(convert(e.locationInWindow, from: nil))
        c.setCamera(cam, animated: e.type == .leftMouseDown, record: e.type == .leftMouseDown, duration: 0.25)
    }
}

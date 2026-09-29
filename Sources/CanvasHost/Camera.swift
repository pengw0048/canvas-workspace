import AppKit
import CanvasCore

/// A personal viewport: world center and zoom. View coordinates are flipped (y down).
struct Camera: Equatable {
    var center: WPoint
    var zoom: Double
    var viewSize: CGSize

    static let minZoom = 0.02
    static let maxZoom = 16.0

    func toView(_ p: WPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x) * zoom + viewSize.width / 2, y: (p.y - center.y) * zoom + viewSize.height / 2)
    }

    func toWorld(_ p: CGPoint) -> WPoint {
        WPoint(x: (Double(p.x) - viewSize.width / 2) / zoom + center.x, y: (Double(p.y) - viewSize.height / 2) / zoom + center.y)
    }

    func toView(_ r: WRect) -> CGRect {
        let o = toView(WPoint(x: r.x, y: r.y))
        return CGRect(x: o.x, y: o.y, width: r.w * zoom, height: r.h * zoom)
    }

    var visibleWorld: WRect {
        let tl = toWorld(.zero), br = toWorld(CGPoint(x: viewSize.width, y: viewSize.height))
        return WRect(x: tl.x, y: tl.y, w: br.x - tl.x, h: br.y - tl.y)
    }

    /// Zooms by `factor` keeping the world point under `anchor` fixed.
    mutating func zoom(by factor: Double, anchor: CGPoint) {
        let before = toWorld(anchor)
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        let after = toWorld(anchor)
        center = WPoint(x: center.x + before.x - after.x, y: center.y + before.y - after.y)
    }

    mutating func pan(dx: Double, dy: Double) {
        center = WPoint(x: center.x - dx / zoom, y: center.y - dy / zoom)
    }

    /// Fits a world rect with a margin in view points.
    mutating func fit(_ r: WRect, margin: Double = 80, maxZoom: Double = 2) {
        let w = max(r.w, 1), h = max(r.h, 1)
        let z = min((viewSize.width - 2 * margin) / w, (viewSize.height - 2 * margin) / h)
        zoom = min(maxZoom, max(Self.minZoom, z))
        center = r.center
    }
}

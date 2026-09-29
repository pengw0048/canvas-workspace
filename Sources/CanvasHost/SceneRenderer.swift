import AppKit
import CanvasCore
import QuartzCore

/// What the renderer needs from the rest of the host.
protocol SceneContext: AnyObject {
    var sceneAppearance: NSAppearance { get }
    func image(for asset: AssetID?, pixels: Double) -> CGImage?
    /// Current visual for a runtime-backed object (live frame or stored preview).
    func surfaceImage(for o: CanvasObject, pixels: Double) -> CGImage?
    /// Live IOSurface or still image for a runtime-backed object.
    func surfaceContents(for o: CanvasObject, pixels: Double) -> Any?
    func thumbnail(for o: CanvasObject) -> CGImage?
    func icon(for o: CanvasObject) -> NSImage?
    /// Short consequential status such as "Live", "Last captured 5 min ago", "Source missing".
    func status(for o: CanvasObject) -> SurfaceStatus?
    var editingID: ObjectID? { get }
    var activeID: ObjectID? { get }
}

struct SurfaceStatus: Equatable {
    enum Tone { case normal, live, warning, error }
    var text: String
    var tone: Tone
}

/// Level of detail chosen from projected width, with hysteresis.
enum Detail: Int { case icon, thumbnail, full }

final class TextLayer: CALayer {
    var attributed = NSAttributedString()
    var inset = CGSize(width: 0, height: 0)
    var verticallyCentered = false

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        var r = bounds.insetBy(dx: inset.width, dy: inset.height)
        if verticallyCentered {
            let h = attributed.boundingRect(with: CGSize(width: r.width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if h < r.height { r.origin.y += (r.height - h) / 2; r.size.height = h + 1 }
        }
        attributed.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Layer subtree for one canvas object, positioned in rebased world coordinates.
final class ObjectLayer: CALayer {
    var objectID: ObjectID = ""
    var kind: ObjectKind = .sticky
    var detail: Detail = .full
    var lastObject: CanvasObject?
    var evicted = false
    var bucket = 0
    let body = CALayer()
    let shape = CAShapeLayer()
    let text = TextLayer()
    let label = TextLayer()
    let badge = TextLayer()
    let image = CALayer()
    let titleBar = CALayer()
    let icon = CALayer()

    override init() {
        super.init()
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        for l in [body, shape, image, titleBar, icon, text, label, badge] as [CALayer] {
            l.anchorPoint = .zero
            addSublayer(l)
        }
        image.contentsGravity = .resizeAspect
        image.masksToBounds = true
        icon.contentsGravity = .resizeAspect
        actions = ObjectLayer.noActions
        for l in sublayers ?? [] { l.actions = ObjectLayer.noActions }
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "path": NSNull(), "frame": NSNull(), "sublayers": NSNull(), "zPosition": NSNull(),
        "backgroundColor": NSNull(), "borderColor": NSNull(), "opacity": NSNull(), "contentsScale": NSNull(),
    ]
}

final class SceneRenderer {
    let worldLayer = CALayer()
    private(set) var layers: [ObjectID: ObjectLayer] = [:]
    private(set) var rebase = WPoint(x: 0, y: 0)
    weak var context: SceneContext?
    var camera: Camera
    var backingScale: CGFloat = 2
    /// Ephemeral drag offsets, not yet committed.
    var transientOffset: [ObjectID: (Double, Double)] = [:]
    /// Ephemeral geometry during resize/rotate.
    var transientGeom: [ObjectID: Geometry] = [:]
    var dropTargetFrame: ObjectID?
    var highlighted: Set<ObjectID> = []

    init(camera: Camera) {
        self.camera = camera
        worldLayer.anchorPoint = .zero
        worldLayer.actions = ObjectLayer.noActions
        worldLayer.isGeometryFlipped = false
    }

    // MARK: Camera

    func applyCamera(_ c: Camera) {
        camera = c
        // Rebase when the camera drifts far from the origin used for layer positions.
        if abs(c.center.x - rebase.x) > 200_000 || abs(c.center.y - rebase.y) > 200_000 {
            rebase = WPoint(x: c.center.x.rounded(), y: c.center.y.rounded())
            for l in layers.values { if let o = l.lastObject { position(l, o) } }
        }
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, c.viewSize.width / 2, c.viewSize.height / 2, 0)
        t = CATransform3DScale(t, c.zoom, c.zoom, 1)
        t = CATransform3DTranslate(t, -(c.center.x - rebase.x), -(c.center.y - rebase.y), 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldLayer.sublayerTransform = t
        CATransaction.commit()
    }

    /// Re-rasterizes text and swaps level of detail for visible objects after zoom settles.
    func refreshDetail(_ ws: Workspace) {
        let vis = camera.visibleWorld
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layers.values {
            guard let o = l.lastObject else { continue }
            let onScreen = vis.intersects(o.geom.bounds.insetBy(-o.geom.w))
            l.isHidden = !onScreen && !(o.kind == .connector)
            guard onScreen else {
                // Offscreen surfaces release their decoded pixels; the stored asset stays on disk.
                if !l.evicted {
                    l.image.contents = nil
                    for t in [l.text, l.label, l.badge] { t.contents = nil }
                    l.evicted = true
                }
                continue
            }
            if l.evicted || ([.image, .app, .browser].contains(o.kind) && l.bucket != ImageCache.bucket(for: pixelsNeeded(o))) {
                l.evicted = false
                configure(l, o, ws)
            }
            let newDetail = detail(for: o, current: l.detail)
            if newDetail != l.detail { l.detail = newDetail; configure(l, o, ws) }
            rescaleText(l, o)
            if o.kind == .frame { layoutFrameLabel(l, o) }
        }
        CATransaction.commit()
    }

    func detail(for o: CanvasObject, current: Detail) -> Detail {
        let w = o.geom.w * camera.zoom
        switch current {
        case .icon: return w > 132 ? (w > 528 ? .full : .thumbnail) : .icon
        case .thumbnail: return w < 108 ? .icon : (w > 528 ? .full : .thumbnail)
        case .full: return w < 432 ? (w < 108 ? .icon : .thumbnail) : .full
        }
    }

    /// Longest side in device pixels that an image of this object needs at the current zoom.
    func pixelsNeeded(_ o: CanvasObject) -> Double {
        max(o.geom.w, o.geom.h) * camera.zoom * Double(backingScale)
    }

    /// Swaps only the pixels of live surfaces; no other layer work happens per frame.
    func setLiveContents(_ surface: IOSurface?, for ids: [ObjectID]) {
        guard let surface else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in ids { if let l = layers[id], !l.evicted, !l.image.isHidden { l.image.contents = surface } }
        CATransaction.commit()
    }

    func textScale(_ o: CanvasObject) -> CGFloat {
        let want = backingScale * CGFloat(camera.zoom)
        let pixels = max(1, o.geom.w * o.geom.h)
        let cap = CGFloat(sqrt(12_000_000 / pixels))
        // Text is rasterized at its on-screen size, down to a quarter point per pixel when zoomed out.
        return max(0.25, min(want, cap, 32))
    }

    func rescaleText(_ l: ObjectLayer, _ o: CanvasObject) {
        let s = textScale(o)
        for t in [l.text, l.label, l.badge] where !t.isHidden && abs(t.contentsScale - s) > max(0.1, s * 0.2) {
            t.contentsScale = s
            t.setNeedsDisplay()
        }
    }

    // MARK: Sync

    func sync(_ ws: Workspace) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let order = ws.renderOrder().filter { $0.kind != .group }
        var seen = Set<ObjectID>()
        var sub: [CALayer] = []
        for o in order {
            seen.insert(o.id)
            let l = layers[o.id] ?? makeLayer(o)
            if l.lastObject != o || needsRefresh(l, o) {
                l.detail = detail(for: o, current: l.detail)
                configure(l, o, ws)
            }
            sub.append(l)
        }
        for (id, l) in layers where !seen.contains(id) { l.removeFromSuperlayer(); layers[id] = nil }
        worldLayer.sublayers = sub
        // Connectors depend on their endpoints' current positions.
        for o in order where o.kind == .connector { if let l = layers[o.id] { configureConnector(l, o, ws) } }
        CATransaction.commit()
    }

    /// Updates only transient geometry during a drag.
    func syncTransient(_ ws: Workspace) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, l) in layers {
            guard let o = ws.object(id) else { continue }
            if o.kind == .connector { configureConnector(l, o, ws); continue }
            position(l, effective(o))
            if transientGeom[id] != nil { configure(l, effective(o), ws, recordLast: false) }
        }
        for (id, l) in layers {
            guard let o = ws.object(id), o.kind == .frame else { continue }
            let isTarget = dropTargetFrame == id
            l.body.borderWidth = isTarget ? 3 : 1
            l.body.borderColor = (isTarget ? Theme.selection : Theme.cardBorder).cg(appearance)
        }
        CATransaction.commit()
    }

    func effective(_ o: CanvasObject) -> CanvasObject {
        var e = o
        if let g = transientGeom[o.id] { e.geom = g }
        if let d = transientOffset[o.id] { e.geom = e.geom.offset(d.0, d.1) }
        return e
    }

    private var surfaceStamp: [ObjectID: String] = [:]

    func needsRefresh(_ l: ObjectLayer, _ o: CanvasObject) -> Bool {
        guard [.app, .browser, .file, .image].contains(o.kind), let ctx = context else { return false }
        let st = ctx.status(for: o)
        let stamp = "\(st?.text ?? "")|\(ctx.activeID == o.id)|\(ctx.editingID == o.id)"
        if surfaceStamp[o.id] != stamp { surfaceStamp[o.id] = stamp; return true }
        return false
    }

    /// Forces a redraw of runtime-backed objects (new frames, status changes).
    func refreshSurface(_ id: ObjectID, _ ws: Workspace) {
        guard let l = layers[id], let o = ws.object(id) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configure(l, o, ws)
        CATransaction.commit()
    }

    var appearance: NSAppearance { context?.sceneAppearance ?? NSAppearance(named: .aqua)! }

    func makeLayer(_ o: CanvasObject) -> ObjectLayer {
        let l = ObjectLayer()
        l.objectID = o.id
        l.kind = o.kind
        l.contentsScale = backingScale
        for s in l.sublayers ?? [] { s.contentsScale = backingScale }
        layers[o.id] = l
        return l
    }

    func position(_ l: ObjectLayer, _ o: CanvasObject) {
        if o.kind == .connector { return }
        l.bounds = CGRect(x: 0, y: 0, width: o.geom.w, height: o.geom.h)
        l.position = CGPoint(x: o.geom.center.x - rebase.x, y: o.geom.center.y - rebase.y)
        l.setAffineTransform(o.kind.rotates ? CGAffineTransform(rotationAngle: o.geom.rotation) : .identity)
    }

    func configure(_ l: ObjectLayer, _ o0: CanvasObject, _ ws: Workspace, recordLast: Bool = true) {
        let o = effective(o0)
        if recordLast { l.lastObject = o0 }
        position(l, o)
        // Offscreen objects get their pixels only when they come into view (refreshDetail).
        if o.kind != .connector && o.kind != .frame && !camera.visibleWorld.intersects(o.geom.bounds.insetBy(-o.geom.w)) {
            l.isHidden = true
            if !l.evicted {
                l.image.contents = nil
                for t in [l.text, l.label, l.badge] { t.contents = nil }
            }
            l.evicted = true
            return
        }
        l.isHidden = false
        let ap = appearance
        let size = CGSize(width: o.geom.w, height: o.geom.h)
        let full = CGRect(origin: .zero, size: size)
        // Reset shared sublayers.
        for s in [l.body, l.shape, l.text, l.label, l.badge, l.image, l.titleBar, l.icon] as [CALayer] { s.isHidden = true }
        l.body.shadowOpacity = 0
        l.body.borderWidth = 0
        l.body.cornerRadius = 0
        l.shape.lineDashPattern = nil
        let editing = context?.editingID == o.id
        switch o.kind {
        case .sticky:
            l.body.isHidden = false
            l.body.frame = full
            l.body.backgroundColor = (NSColor(hex: o.props.color) ?? NSColor(hex: "#FFE58A")!).cgColor
            l.body.cornerRadius = 4
            l.body.shadowOpacity = 0.18
            l.body.shadowRadius = 6
            l.body.shadowOffset = CGSize(width: 0, height: 2)
            l.body.shadowColor = NSColor.black.cgColor
            l.body.shadowPath = CGPath(roundedRect: full, cornerWidth: 4, cornerHeight: 4, transform: nil)
            setText(l.text, o, frame: full, inset: CGSize(width: 14, height: 12), color: NSColor(white: 0.1, alpha: 1), size: o.props.fontSize ?? 18, hidden: editing)
        case .text:
            setText(l.text, o, frame: full, inset: .zero, color: NSColor(hex: o.props.color) ?? Theme.text, size: o.props.fontSize ?? 20, hidden: editing)
        case .shape:
            l.shape.isHidden = false
            l.shape.frame = full
            let path = CGMutablePath()
            let st = o.props.shape ?? .rect
            switch st {
            case .rect: path.addRoundedRect(in: full, cornerWidth: 6, cornerHeight: 6)
            case .ellipse: path.addEllipse(in: full)
            case .line, .arrow:
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                if st == .arrow { addArrowHead(path, from: .zero, to: CGPoint(x: size.width, y: size.height), width: o.props.strokeWidth ?? 2) }
            }
            l.shape.path = path
            l.shape.lineWidth = o.props.strokeWidth ?? 2
            l.shape.strokeColor = (NSColor(hex: o.props.color) ?? Theme.text).cg(ap)
            l.shape.fillColor = (st == .line || st == .arrow) ? nil : (NSColor(hex: o.props.fill) ?? .clear).cg(ap)
            l.shape.lineJoin = .round
            l.shape.lineCap = .round
            if st == .rect || st == .ellipse {
                setText(l.text, o, frame: full, inset: CGSize(width: 10, height: 8), color: Theme.text, size: o.props.fontSize ?? 18, hidden: editing, centered: true)
            }
        case .ink:
            l.shape.isHidden = false
            l.shape.frame = full
            let path = CGMutablePath()
            if let p = o.props.inkPoints, p.count >= 2 {
                path.move(to: CGPoint(x: p[0], y: p[1]))
                var i = 2
                while i + 1 < p.count { path.addLine(to: CGPoint(x: p[i], y: p[i + 1])); i += 2 }
                if p.count == 2 { path.addLine(to: CGPoint(x: p[0] + 0.01, y: p[1])) }
            }
            // Ink points are stored in the object's original size; scale to its current box.
            if let base = o.props.logicalSize, base.count == 2, base[0] > 0, base[1] > 0 {
                var t = CGAffineTransform(scaleX: size.width / base[0], y: size.height / base[1])
                l.shape.path = path.copy(using: &t)
            } else { l.shape.path = path }
            let highlighter = o.props.inkTool == "highlighter"
            l.shape.lineWidth = o.props.strokeWidth ?? (highlighter ? 16 : 3)
            l.shape.strokeColor = (NSColor(hex: o.props.color) ?? Theme.text).withAlphaComponent(highlighter ? 0.38 : 1).cg(ap)
            l.shape.fillColor = nil
            l.shape.lineCap = .round
            l.shape.lineJoin = .round
        case .image:
            l.image.isHidden = false
            l.image.frame = full
            l.image.contentsGravity = .resize
            l.bucket = ImageCache.bucket(for: pixelsNeeded(o))
            l.image.contents = o.props.liveOf != nil ? context?.surfaceContents(for: o, pixels: pixelsNeeded(o)) : context?.image(for: o.props.assetID, pixels: pixelsNeeded(o))
            l.image.backgroundColor = l.image.contents == nil ? NSColor.quaternaryLabelColor.cg(ap) : nil
            if l.image.contents == nil {
                setLabel(l.label, "Image bytes unavailable", frame: full.insetBy(dx: 8, dy: 8), size: 12, color: Theme.secondaryText)
            }
            if let st = context?.status(for: o) { setBadge(l, st, width: size.width) }
        case .frame:
            l.body.isHidden = false
            l.body.frame = full
            l.body.backgroundColor = (NSColor(hex: o.props.fill) ?? NSColor(white: 0.5, alpha: 0.06)).cg(ap)
            l.body.borderWidth = dropTargetFrame == o.id ? 3 : 1
            l.body.borderColor = (dropTargetFrame == o.id ? Theme.selection : Theme.cardBorder).cg(ap)
            l.body.cornerRadius = 2
            layoutFrameLabel(l, o)
        case .connector:
            configureConnector(l, o, ws)
        case .file, .app, .browser:
            configureSurface(l, o, size: size)
        case .group:
            break
        }
        rescaleText(l, o)
    }

    func layoutFrameLabel(_ l: ObjectLayer, _ o: CanvasObject) {
        let s = 1 / camera.zoom
        let name = o.props.name ?? "Frame"
        let shared = o.scope != Scope.privateID
        let title = shared ? "\(name)  · Shared" : name
        l.label.isHidden = false
        l.label.attributed = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.secondaryText,
        ])
        l.label.frame = CGRect(x: 0, y: -20 * s, width: max(40, o.geom.w), height: 18 * s)
        l.label.bounds = CGRect(x: 0, y: 0, width: max(40, o.geom.w) / s, height: 18)
        l.label.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        l.label.position = CGPoint(x: 0, y: -20 * s)
        l.label.contentsScale = backingScale
        l.label.setNeedsDisplay()
    }

    func configureConnector(_ l: ObjectLayer, _ o0: CanvasObject, _ ws: Workspace) {
        let o = effective(o0)
        l.lastObject = o0
        let (a0, ma) = endpoint(o.props.start, ws)
        let (b0, mb) = endpoint(o.props.end, ws)
        let a = CGPoint(x: a0.x - rebase.x, y: a0.y - rebase.y), b = CGPoint(x: b0.x - rebase.x, y: b0.y - rebase.y)
        l.bounds = .zero
        l.position = .zero
        l.setAffineTransform(.identity)
        l.shape.isHidden = false
        l.shape.frame = .zero
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        addArrowHead(path, from: a, to: b, width: o.props.strokeWidth ?? 2)
        for (p, missing) in [(a, ma), (b, mb)] where missing {
            path.addEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
        }
        l.shape.path = path
        l.shape.lineWidth = o.props.strokeWidth ?? 2
        l.shape.strokeColor = ((ma || mb) ? Theme.danger : (NSColor(hex: o.props.color) ?? Theme.secondaryText)).cg(appearance)
        l.shape.lineDashPattern = (ma || mb) ? [6, 4] : nil
        l.shape.fillColor = nil
        if !o.text.isEmpty {
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            setLabel(l.text, o.text, frame: CGRect(x: mid.x - 80, y: mid.y - 12, width: 160, height: 24), size: 13, color: Theme.text, centered: true)
            l.text.backgroundColor = Theme.canvasBackground.cg(appearance)
        } else { l.text.isHidden = true }
        l.text.isHidden = o.text.isEmpty || context?.editingID == o.id
    }

    func endpoint(_ e: Endpoint?, _ ws: Workspace) -> (WPoint, Bool) {
        guard let e else { return (WPoint(x: 0, y: 0), true) }
        if let t = e.objectID {
            if let target = ws.object(t) {
                let eff = effective(target)
                let a = e.anchor ?? WPoint(x: 0.5, y: 0.5)
                return (eff.geom.fromLocal(WPoint(x: a.x * eff.geom.w, y: a.y * eff.geom.h)), false)
            }
            return (e.point ?? WPoint(x: 0, y: 0), true)
        }
        return (e.point ?? WPoint(x: 0, y: 0), false)
    }

    func addArrowHead(_ path: CGMutablePath, from a: CGPoint, to b: CGPoint, width: Double) {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let len = 10 + width * 2
        for d in [-0.45, 0.45] {
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - len * cos(ang + d), y: b.y - len * sin(ang + d)))
        }
    }

    /// Application, browser, and file surfaces.
    func configureSurface(_ l: ObjectLayer, _ o: CanvasObject, size: CGSize) {
        let ap = appearance
        let full = CGRect(origin: .zero, size: size)
        let status = context?.status(for: o)
        let active = context?.activeID == o.id
        l.body.isHidden = false
        l.body.frame = full
        l.body.backgroundColor = Theme.cardBackground.cg(ap)
        l.body.cornerRadius = o.kind == .file ? 8 : 10
        l.body.borderWidth = active ? 3 : 1
        l.body.borderColor = (active ? Theme.focus : Theme.cardBorder).cg(ap)
        l.body.shadowOpacity = 0.16
        l.body.shadowRadius = 10
        l.body.shadowOffset = CGSize(width: 0, height: 3)
        l.body.shadowColor = NSColor.black.cgColor
        // An explicit shadow path avoids an offscreen pass and its texture per layer.
        l.body.shadowPath = CGPath(roundedRect: full, cornerWidth: l.body.cornerRadius, cornerHeight: l.body.cornerRadius, transform: nil)
        l.body.masksToBounds = false
        let title = o.title
        let z = camera.zoom
        switch l.detail {
        case .icon:
            // Recognizable icon and short title only; sized in screen terms.
            let iconSide = min(size.width, size.height) * 0.55
            l.icon.isHidden = false
            l.icon.frame = CGRect(x: (size.width - iconSide) / 2, y: size.height * 0.12, width: iconSide, height: iconSide)
            l.icon.contents = context?.icon(for: o)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            setLabel(l.label, title, frame: CGRect(x: 4, y: size.height * 0.12 + iconSide + 4, width: size.width - 8, height: max(14 / z, size.height * 0.25)),
                     size: max(12 / z, 11), color: Theme.text, centered: true)
        case .thumbnail, .full:
            let bar: CGFloat = o.kind == .file ? 0 : min(30, size.height * 0.2)
            if bar > 0 {
                l.titleBar.isHidden = false
                l.titleBar.frame = CGRect(x: 0, y: 0, width: size.width, height: bar)
                l.titleBar.backgroundColor = NSColor.windowBackgroundColor.cg(ap)
                l.titleBar.cornerRadius = 10
                l.titleBar.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                l.icon.isHidden = false
                l.icon.frame = CGRect(x: 8, y: bar * 0.18, width: bar * 0.64, height: bar * 0.64)
                l.icon.contents = context?.icon(for: o)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                setLabel(l.label, title, frame: CGRect(x: 12 + bar * 0.64, y: bar * 0.2, width: size.width - 24 - bar, height: bar * 0.7),
                         size: min(13, bar * 0.45), color: Theme.text)
            }
            let content = CGRect(x: 0, y: bar, width: size.width, height: size.height - bar)
            l.image.isHidden = false
            l.image.frame = content.insetBy(dx: o.kind == .file ? 10 : 0, dy: o.kind == .file ? 10 : 0)
            l.image.contentsGravity = o.kind == .file ? .resizeAspect : .resizeAspect
            l.image.cornerRadius = o.kind == .file ? 4 : 0
            l.bucket = ImageCache.bucket(for: pixelsNeeded(o))
            let img: Any? = o.kind == .file ? context?.thumbnail(for: o) : context?.surfaceContents(for: o, pixels: pixelsNeeded(o))
            l.image.contents = img
            l.image.backgroundColor = o.kind == .file ? nil : NSColor.textBackgroundColor.cg(ap)
            if img == nil {
                l.image.isHidden = o.kind == .file
                if o.kind == .file {
                    l.icon.isHidden = false
                    let side = min(size.width, size.height) * 0.5
                    l.icon.frame = CGRect(x: (size.width - side) / 2, y: 12, width: side, height: side)
                    l.icon.contents = context?.icon(for: o)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            }
            if o.kind == .file {
                setLabel(l.label, title, frame: CGRect(x: 8, y: size.height - 30, width: size.width - 16, height: 24), size: 13, color: Theme.text, centered: true)
                l.image.frame = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 44)
            }
        }
        if let status { setBadge(l, status, width: size.width) }
    }

    func setBadge(_ l: ObjectLayer, _ st: SurfaceStatus, width: CGFloat) {
        let s = 1 / camera.zoom
        l.badge.isHidden = false
        let color: NSColor
        switch st.tone {
        case .normal: color = NSColor(white: 0.25, alpha: 0.85)
        case .live: color = NSColor.systemGreen.withAlphaComponent(0.92)
        case .warning: color = NSColor.systemOrange.withAlphaComponent(0.92)
        case .error: color = NSColor.systemRed.withAlphaComponent(0.92)
        }
        let prefix = st.tone == .live ? "● " : (st.tone == .error ? "⚠︎ " : "")
        let str = NSAttributedString(string: prefix + st.text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let w = min(str.size().width + 14, max(60, width / s - 12))
        l.badge.attributed = str
        l.badge.inset = CGSize(width: 7, height: 3)
        l.badge.backgroundColor = color.cgColor
        l.badge.cornerRadius = 9
        l.badge.bounds = CGRect(x: 0, y: 0, width: w, height: 19)
        l.badge.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        l.badge.position = CGPoint(x: width - (w + 8) * s, y: -26 * s)
        l.badge.contentsScale = backingScale
        l.badge.setNeedsDisplay()
    }

    func setText(_ t: TextLayer, _ o: CanvasObject, frame: CGRect, inset: CGSize, color: NSColor, size: Double, hidden: Bool, centered: Bool = false) {
        t.isHidden = hidden || o.text.isEmpty
        let para = NSMutableParagraphStyle()
        para.alignment = centered ? .center : .left
        para.lineBreakMode = .byWordWrapping
        t.attributed = RichText.attributed(o.text, marks: o.marks, font: .systemFont(ofSize: size), color: color, paragraph: para)
        t.inset = inset
        t.verticallyCentered = centered
        t.frame = frame
        t.setAffineTransform(.identity)
        t.setNeedsDisplay()
    }

    func setLabel(_ t: TextLayer, _ s: String, frame: CGRect, size: Double, color: NSColor, centered: Bool = false) {
        t.isHidden = false
        let para = NSMutableParagraphStyle()
        para.alignment = centered ? .center : .left
        para.lineBreakMode = .byTruncatingTail
        t.attributed = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: para,
        ])
        t.inset = .zero
        t.backgroundColor = nil
        t.setAffineTransform(.identity)
        t.frame = frame
        t.setNeedsDisplay()
    }
}

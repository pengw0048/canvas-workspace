import AppKit
import CanvasCore
import QuartzCore

enum Tool: String, CaseIterable {
    case pointer, hand, text, sticky, rect, ellipse, line, arrow, connector, pen, highlighter, eraser, frame

    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .hand: return "hand.raised"
        case .text: return "textformat"
        case .sticky: return "note.text"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .connector: return "point.topleft.down.to.point.bottomright.curvepath"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .frame: return "number"
        }
    }

    var key: String {
        switch self {
        case .pointer: return "v"
        case .hand: return "h"
        case .text: return "t"
        case .sticky: return "s"
        case .rect: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .connector: return "c"
        case .pen: return "p"
        case .highlighter: return "m"
        case .eraser: return "e"
        case .frame: return "f"
        }
    }

    var title: String {
        switch self {
        case .pointer: return "Select (V)"
        case .hand: return "Hand (H)"
        case .text: return "Text (T)"
        case .sticky: return "Sticky note (S)"
        case .rect: return "Rectangle (R)"
        case .ellipse: return "Ellipse (O)"
        case .line: return "Line (L)"
        case .arrow: return "Arrow (A)"
        case .connector: return "Connector (C)"
        case .pen: return "Pen (P)"
        case .highlighter: return "Highlighter (M)"
        case .eraser: return "Eraser (E)"
        case .frame: return "Frame (F)"
        }
    }
}

enum DragOp {
    case none
    case pan(start: CGPoint, camera: Camera)
    case move(ids: [ObjectID], start: WPoint, moved: Bool)
    case marquee(start: WPoint, additive: Bool, base: Set<ObjectID>)
    case resize(id: ObjectID, handle: Int, start: Geometry, startPoint: WPoint)
    case rotate(id: ObjectID, start: Geometry, startAngle: Double)
    case create(tool: Tool, start: WPoint)
    case ink(points: [WPoint])
    case erase(ids: Set<ObjectID>)
    case connector(start: Endpoint, current: WPoint)
    case region(objectID: ObjectID, start: CGPoint, current: CGPoint)
    case groupResize(id: ObjectID, handle: Int, start: WRect, startPoint: WPoint)
}

final class CanvasView: NSView, SceneContext {
    unowned let app: AppController
    let displayID: String
    var camera: Camera
    let renderer: SceneRenderer
    let overlay = CAShapeLayer()
    let overlayFill = CAShapeLayer()
    let presenceLayer = CALayer()
    var minimap: MinimapView?
    var tool: Tool = .pointer { didSet { toolbar?.update(); window?.invalidateCursorRects(for: self); updateCursor() } }
    var selection: Set<ObjectID> = [] {
        didSet {
            guard selection != oldValue else { return }
            // Surfaces show their title chip and full status only while selected.
            for id in selection.symmetricDifference(oldValue) where [.app, .browser, .file, .image].contains(ws.object(id)?.kind) {
                renderer.refreshSurface(id, ws)
            }
            selectionChanged()
        }
    }
    var enteredGroup: ObjectID?
    var drag: DragOp = .none
    var spaceHeld = false
    var lastPointerWorld: WPoint?
    var lastPointerTime = Date.distantPast
    var pasteCount = 0
    var lastPasteSignature = ""
    var cameraBack: [Camera] = []
    var focusReturn: Camera?
    var focusObject: ObjectID?
    var editor: TextEditor?
    weak var toolbar: ToolbarView?
    var hud: HUDView!
    var detailTimer: Timer?
    var cameraAnimation: Timer?
    var inkColor = Theme.inkColors[0]
    var stickyColor = Theme.stickyColors[0].1
    var highlightUntil: [ObjectID: Date] = [:]
    var remoteCursors: [String: (name: String, point: WPoint, color: NSColor, selection: [ObjectID], chat: String?)] = [:]
    var chatText: String?
    var chatField: NSTextField?
    var chatClear: Timer?
    var followUser: String?
    var regionTarget: ObjectID?
    var accessibilityCache: [ObjectID: ObjectAccessibilityElement] = [:]
    var springTarget: ObjectID?
    var springStart = Date.distantFuture
    var springFired = false

    init(app: AppController, frame: NSRect, displayID: String, view: PersonalView?) {
        self.app = app
        self.displayID = displayID
        camera = Camera(center: WPoint(x: view?.centerX ?? 0, y: view?.centerY ?? 0), zoom: view?.zoom ?? 1, viewSize: frame.size)
        renderer = SceneRenderer(camera: camera)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        renderer.context = self
        renderer.backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(renderer.worldLayer)
        for l in [overlayFill, overlay] as [CAShapeLayer] {
            l.actions = ObjectLayer.noActions
            l.fillColor = nil
            layer?.addSublayer(l)
        }
        presenceLayer.actions = ObjectLayer.noActions
        layer?.addSublayer(presenceLayer)
        overlay.strokeColor = Theme.selection.cgColor
        overlay.lineWidth = 1.5
        overlayFill.fillColor = Theme.selection.withAlphaComponent(0.08).cgColor
        overlayFill.strokeColor = Theme.selection.withAlphaComponent(0.6).cgColor
        overlayFill.lineWidth = 1
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff, .rtf, .html,
                                 NSPasteboard.PasteboardType(PortableSelection.pasteboardType),
                                 NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")])
        hud = HUDView(canvas: self)
        addSubview(hud)
        let tb = ToolbarView(canvas: self)
        addSubview(tb)
        toolbar = tb
        let mm = MinimapView(canvas: self)
        mm.isHidden = UserDefaults.standard.bool(forKey: "hideMinimap")
        addSubview(mm)
        minimap = mm
        applyCamera()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { false }

    var ws: Workspace { app.workspace }

    // MARK: SceneContext

    var sceneAppearance: NSAppearance { effectiveAppearance }
    func image(for asset: AssetID?, pixels: Double) -> CGImage? { app.images.image(asset, pixels: pixels) }
    func surfaceImage(for o: CanvasObject, pixels: Double) -> CGImage? { app.runtime.surfaceImage(for: o, pixels: pixels) }
    func surfaceContents(for o: CanvasObject, pixels: Double) -> Any? { app.runtime.surfaceContents(for: o, pixels: pixels) }
    func thumbnail(for o: CanvasObject) -> CGImage? { app.files.thumbnail(for: o) }
    func icon(for o: CanvasObject) -> NSImage? { app.runtime.icon(for: o) }
    func status(for o: CanvasObject) -> SurfaceStatus? { app.runtime.status(for: o) }
    var editingID: ObjectID? { editor?.objectID }
    func isSelected(_ id: ObjectID) -> Bool { selection.contains(id) }
    var presenting: Bool { app.presenting }
    var activeID: ObjectID? { app.runtime.activeObject }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let size = bounds.size
        if camera.viewSize != size { camera.viewSize = size; applyCamera() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.worldLayer.frame = bounds
        overlay.frame = bounds
        overlayFill.frame = bounds
        presenceLayer.frame = bounds
        CATransaction.commit()
        let safe = safeRect
        hud.frame = safe
        toolbar?.layoutIn(safe)
        minimap?.frame = NSRect(origin: CGPoint(x: safe.minX + 14, y: safe.maxY - MinimapView.size.height - 14), size: MinimapView.size)
        minimap?.refreshObjects()
        editor?.reposition()
    }

    /// The part of the view not under the menu bar or the Dock; chrome stays inside it.
    var safeRect: NSRect {
        guard let w = window, let sc = w.screen else { return bounds }
        let vis = sc.visibleFrame, wf = w.frame
        let top = max(0, wf.maxY - vis.maxY), bottom = max(0, vis.minY - wf.minY)
        let left = max(0, vis.minX - wf.minX), right = max(0, wf.maxX - vis.maxX)
        return NSRect(x: left, y: top, width: bounds.width - left - right, height: bounds.height - top - bottom)
    }

    override func viewDidChangeBackingProperties() {
        renderer.backingScale = window?.backingScaleFactor ?? 2
        renderer.refreshDetail(ws)
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        renderer.sync(ws)
        updateOverlay()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvasBackground.setFill()
        dirtyRect.fill()
        // Dot grid in screen space; spacing follows zoom in powers of 4.
        var spacing = 24.0 * camera.zoom
        while spacing < 12 { spacing *= 4 }
        while spacing > 96 { spacing /= 4 }
        let origin = camera.toView(WPoint(x: 0, y: 0))
        let startX = origin.x.truncatingRemainder(dividingBy: spacing) - spacing
        let startY = origin.y.truncatingRemainder(dividingBy: spacing) - spacing
        Theme.gridDot.setFill()
        let r = 1.0
        var y = startY
        while y < bounds.maxY + spacing {
            var x = startX
            while x < bounds.maxX + spacing {
                if dirtyRect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: y)) {
                    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
                }
                x += spacing
            }
            y += spacing
        }
    }

    func applyCamera() {
        renderer.applyCamera(camera)
        minimap?.refreshViewport()
        needsDisplay = true
        updateOverlay()
        editor?.reposition()
        app.runtime.cameraDidChange(self)
        scheduleDetailRefresh()
        app.personalViewChanged(self)
        if followUser == nil { app.collab?.publishPresence(from: self) }
    }

    func scheduleDetailRefresh() {
        detailTimer?.invalidate()
        detailTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.renderer.refreshDetail(self.ws)
        }
    }

    /// Changes the camera; records navigation history unless `record` is false.
    func setCamera(_ c: Camera, animated: Bool = true, record: Bool = true, duration: Double = 0.28, completion: (() -> Void)? = nil) {
        if record { pushBack() }
        cameraAnimation?.invalidate()
        renderer.flightTarget = nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce, duration > 0 else { camera = c; applyCamera(); completion?(); return }
        let from = camera
        renderer.flightTarget = c.visibleWorld
        renderer.refreshDetail(ws)
        let start = CACurrentMediaTime()
        cameraAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            // Ease in and out so long flights start and land softly.
            let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            // Interpolate zoom logarithmically for a steady feel.
            let z = exp(log(from.zoom) + (log(c.zoom) - log(from.zoom)) * e)
            self.camera.zoom = z
            self.camera.center = WPoint(x: from.center.x + (c.center.x - from.center.x) * e, y: from.center.y + (c.center.y - from.center.y) * e)
            self.applyCamera()
            if p >= 1 {
                t.invalidate()
                self.cameraAnimation = nil
                self.camera = c
                self.applyCamera()
                self.renderer.flightTarget = nil
                self.renderer.refreshDetail(self.ws)
                completion?()
            }
        }
        RunLoop.main.add(cameraAnimation!, forMode: .common)
    }

    func pushBack() {
        if cameraBack.last != camera { cameraBack.append(camera) }
        if cameraBack.count > 100 { cameraBack.removeFirst() }
    }

    func navigateBack() {
        guard let c = cameraBack.popLast() else { NSSound.beep(); return }
        var c2 = c
        c2.viewSize = camera.viewSize
        setCamera(c2, record: false)
    }

    func reveal(_ id: ObjectID, highlight: Bool = true) {
        guard let o = ws.object(id) else { return }
        var c = camera
        let b = o.geom.bounds
        c.fit(b, margin: 160, maxZoom: max(camera.zoom, 1))
        if c.zoom < 0.2 { c.zoom = 0.2 }
        setCamera(c)
        if highlight {
            highlightUntil[id] = Date().addingTimeInterval(1.6)
            updateOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in self?.updateOverlay() }
        }
    }

    func fitAll() {
        guard let b = WRect.union(ws.live.filter { $0.kind != .group }.map(\.geom.bounds)) else { return }
        var c = camera
        c.fit(b)
        setCamera(c)
    }

    func fitSelection() {
        guard let b = selectionBounds() else { return }
        var c = camera
        c.fit(b, margin: 120, maxZoom: 4)
        setCamera(c)
    }

    /// Temporarily fits one object for comfortable operation; world positions stay unchanged.
    func enterFocusView(_ id: ObjectID, oneToOne: Bool = false) {
        guard let o = ws.object(id) else { return }
        if focusReturn == nil { focusReturn = camera }
        focusObject = id
        var c = camera
        if oneToOne {
            c.zoom = 1
            c.center = o.geom.center
        } else {
            c.fit(o.geom.bounds, margin: 60, maxZoom: 4)
        }
        setCamera(c, record: false)
        hud.update()
    }

    /// Focus view at an exact camera; the completion runs once the camera has landed.
    func enterFocusView(_ id: ObjectID, camera c: Camera, duration: Double = 0, completion: (() -> Void)? = nil) {
        if focusReturn == nil { focusReturn = camera }
        focusObject = id
        hud.update()
        setCamera(c, animated: duration > 0, record: false, duration: duration, completion: completion)
    }

    func exitFocusView() {
        guard let r = focusReturn else { return }
        focusReturn = nil
        focusObject = nil
        var c = r
        c.viewSize = camera.viewSize
        setCamera(c, record: false)
        hud.update()
    }

    // MARK: Scene updates

    func workspaceChanged(_ ids: Set<ObjectID>) {
        selection = selection.filter { ws.object($0) != nil }
        renderer.sync(ws)
        renderer.refreshDetail(ws)
        updateOverlay()
        minimap?.refreshObjects()
        editor?.remoteUpdate()
        hud.update()
    }

    func selectionChanged() {
        updateOverlay()
        hud.update()
        app.selectionChanged(self)
        app.collab?.publishPresence(from: self)
    }

    func selectionBounds() -> WRect? {
        WRect.union(selection.compactMap { id -> WRect? in
            guard let o = ws.object(id) else { return nil }
            if o.kind == .group { return ws.groupBounds(id) }
            if o.kind == .connector {
                let a = ws.connectorEndpoint(o.props.start).point, b = ws.connectorEndpoint(o.props.end).point
                return WRect.enclosing([a, b])
            }
            return renderer.effective(o).geom.bounds
        })
    }

    /// Screen-space selection outlines, handles, marquee, and highlights.
    /// A fixed caption in the top-left corner (picture-in-picture participants).
    func showCaption(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.drawsBackground = true
        l.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        l.wantsLayer = true
        l.layer?.cornerRadius = 6
        l.layer?.masksToBounds = true
        l.sizeToFit()
        l.frame = NSRect(x: 10, y: 10, width: l.frame.width + 12, height: l.frame.height + 4)
        l.alignment = .center
        addSubview(l)
    }

    @objc func toggleMinimap(_ s: Any?) {
        guard let m = minimap else { return }
        m.isHidden.toggle()
        UserDefaults.standard.set(m.isHidden, forKey: "hideMinimap")
    }

    func updateOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        let fill = CGMutablePath()
        for id in selection {
            guard let o0 = ws.object(id) else { continue }
            if o0.kind == .group {
                if let b = ws.groupBounds(id) { path.addRect(camera.toView(b).insetBy(dx: -4, dy: -4)) }
                continue
            }
            let o = renderer.effective(o0)
            if o.kind == .connector {
                let a = camera.toView(ws.connectorEndpoint(o.props.start).point), b = camera.toView(ws.connectorEndpoint(o.props.end).point)
                for p in [a, b] { path.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)) }
                continue
            }
            addRotatedRect(path, o.geom, inset: -2)
        }
        if selection.count == 1, let gid = selection.first, ws.object(gid)?.kind == .group, let b = ws.groupBounds(gid) {
            let pseudo = CanvasObject(kind: .shape, geom: Geometry(x: b.x, y: b.y, w: b.w, h: b.h))
            for (_, p) in handlePoints(pseudo) { fill.addRect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)); path.addRect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }
        }
        if selection.count == 1, let id = selection.first, let o0 = ws.object(id), o0.kind != .group, o0.kind != .connector {
            let o = renderer.effective(o0)
            for (_, p) in handlePoints(o) { fill.addRect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)); path.addRect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }
            if let rp = rotationHandle(o) { path.addEllipse(in: CGRect(x: rp.x - 5, y: rp.y - 5, width: 10, height: 10)) }
            if o.kind == .app || o.kind == .file || o.kind == .browser || o.kind == .image || o.kind == .sticky || o.kind == .text {
                let g = exportGrip(o)
                path.addRoundedRect(in: g, cornerWidth: 4, cornerHeight: 4)
                path.move(to: CGPoint(x: g.midX, y: g.minY + 4)); path.addLine(to: CGPoint(x: g.midX, y: g.maxY - 4))
                path.move(to: CGPoint(x: g.midX - 3, y: g.maxY - 7)); path.addLine(to: CGPoint(x: g.midX, y: g.maxY - 4)); path.addLine(to: CGPoint(x: g.midX + 3, y: g.maxY - 7))
            }
        }
        if case .marquee(let s, _, _) = drag, let cur = lastPointerWorld {
            let r = camera.toView(WRect.enclosing([s, cur]))
            fill.addRect(r)
        }
        if case .region(let oid, let s, let c) = drag {
            let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
            fill.addRect(r)
            if let o = ws.object(oid) { path.addRect(camera.toView(o.geom.rect)) }
        }
        if case .create(let t, let s) = drag, let cur = lastPointerWorld {
            let r = camera.toView(WRect.enclosing([s, cur]))
            switch t {
            case .ellipse: fill.addEllipse(in: r)
            case .line, .arrow: fill.move(to: camera.toView(s)); fill.addLine(to: camera.toView(cur))
            default: fill.addRect(r)
            }
        }
        if case .connector(let s, let cur) = drag {
            fill.move(to: camera.toView(ws.connectorEndpoint(s).point))
            fill.addLine(to: camera.toView(cur))
        }
        if case .ink(let pts) = drag, let f = pts.first {
            fill.move(to: camera.toView(f))
            for p in pts.dropFirst() { fill.addLine(to: camera.toView(p)) }
        }
        let now = Date()
        let hl = CGMutablePath()
        for (id, until) in highlightUntil {
            if until < now { highlightUntil[id] = nil; continue }
            if let o = ws.object(id) { addRotatedRect(hl, o.geom, inset: -8) }
        }
        path.addPath(hl)
        overlay.path = path
        overlay.strokeColor = Theme.selection.cgColor
        overlayFill.path = fill
        updatePresence()
        CATransaction.commit()
    }

    func addRotatedRect(_ path: CGMutablePath, _ g: Geometry, inset: Double) {
        let pts = [(0.0, 0.0), (g.w, 0), (g.w, g.h), (0, g.h)].map { camera.toView(g.fromLocal(WPoint(x: $0.0, y: $0.1))) }
        guard let first = pts.first else { return }
        let c = camera.toView(g.center)
        func out(_ p: CGPoint) -> CGPoint {
            let dx = p.x - c.x, dy = p.y - c.y, l = max(1, hypot(dx, dy))
            return CGPoint(x: p.x - dx / l * inset, y: p.y - dy / l * inset)
        }
        path.move(to: out(first))
        for p in pts.dropFirst() { path.addLine(to: out(p)) }
        path.closeSubpath()
    }

    /// Resize handles in view coordinates: 0..7 clockwise from top-left.
    func handlePoints(_ o: CanvasObject) -> [(Int, CGPoint)] {
        let g = o.geom
        let small = g.w * camera.zoom < 28 || g.h * camera.zoom < 28
        let local: [(Int, Double, Double)] = small ? [(4, 1, 1)] : [
            (0, 0, 0), (1, 0.5, 0), (2, 1, 0), (3, 1, 0.5), (4, 1, 1), (5, 0.5, 1), (6, 0, 1), (7, 0, 0.5),
        ]
        if o.kind == .ink || (o.kind == .shape && (o.props.shape == .line || o.props.shape == .arrow)) {
            return [(0, camera.toView(g.fromLocal(WPoint(x: 0, y: 0)))), (4, camera.toView(g.fromLocal(WPoint(x: g.w, y: g.h))))]
        }
        return local.map { ($0.0, camera.toView(g.fromLocal(WPoint(x: $0.1 * g.w, y: $0.2 * g.h)))) }
    }

    func rotationHandle(_ o: CanvasObject) -> CGPoint? {
        guard o.kind.rotates, o.kind != .ink, !(o.kind == .shape && (o.props.shape == .line || o.props.shape == .arrow)) else { return nil }
        let top = camera.toView(o.geom.fromLocal(WPoint(x: o.geom.w / 2, y: 0)))
        let c = camera.toView(o.geom.center)
        let dx = top.x - c.x, dy = top.y - c.y, l = max(1, hypot(dx, dy))
        return CGPoint(x: top.x + dx / l * 22, y: top.y + dy / l * 22)
    }

    /// The export/content grip that starts a native content drag.
    func exportGrip(_ o: CanvasObject) -> CGRect {
        let tr = camera.toView(o.geom.fromLocal(WPoint(x: o.geom.w, y: 0)))
        return CGRect(x: tr.x + 8, y: tr.y, width: 18, height: 22)
    }

    // MARK: Presence

    func updatePresence() {
        minimap?.refreshCursors()
        presenceLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        // A participant shown picture-in-picture for a recording also draws its own automated pointer.
        if CommandLine.arguments.contains("--pip"), let lp = lastPointerWorld {
            drawCursor(at: camera.toView(lp), name: app.identity.name, color: app.collab?.myColor ?? .systemPink, chat: chatText)
        } else if chatField == nil, let t = chatText, !t.isEmpty, let lp = lastPointerWorld {
            // A sent message stays beside the real pointer while collaborators still see it.
            drawCursor(at: camera.toView(lp), name: app.identity.name, color: app.collab?.myColor ?? .systemPink, chat: t, arrow: false)
        }
        for (_, c) in remoteCursors {
            drawCursor(at: camera.toView(c.point), name: c.name, color: c.color, chat: c.chat)
            // Remote selection outlines use a dashed collaborator color, distinct from local selection.
            let sel = CAShapeLayer()
            let sp = CGMutablePath()
            for id in c.selection { if let o = ws.object(id), o.kind != .connector, o.kind != .group { addRotatedRect(sp, o.geom, inset: -4) } }
            sel.path = sp
            sel.strokeColor = c.color.cgColor
            sel.fillColor = nil
            sel.lineWidth = 1.5
            sel.lineDashPattern = [5, 3]
            presenceLayer.addSublayer(sel)
        }
    }

    // MARK: Capture flight

    /// Brackets lock onto the captured region, a scan line sweeps it and it flashes; then the image flies to its object.
    func flyCapture(_ img: CGImage, from src: WRect, to id: ObjectID) {
        guard let o = ws.object(id), let root = layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let from = camera.toView(src), to = camera.toView(o.geom.rect)
        let accent = NSColor(calibratedRed: 0.22, green: 0.89, blue: 1, alpha: 1).cgColor
        let now = CACurrentMediaTime()
        func animate(_ l: CALayer, _ key: String, _ a: Any, _ b: Any, at t: Double, for d: Double) {
            let an = CABasicAnimation(keyPath: key)
            an.fromValue = a
            an.toValue = b
            an.beginTime = now + t
            an.duration = d
            an.fillMode = .both
            an.isRemovedOnCompletion = false
            an.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(an, forKey: key)
        }
        let fx = CALayer()
        fx.frame = from
        root.addSublayer(fx)
        // Corner brackets snap in from slightly outside the region.
        let brackets = CAShapeLayer()
        brackets.frame = fx.bounds
        let arm = min(22, min(from.width, from.height) / 4)
        let path = CGMutablePath()
        for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (from.width, 0, -1, 1), (0, from.height, 1, -1), (from.width, from.height, -1, -1)] {
            path.move(to: CGPoint(x: x + dx * arm, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * arm))
        }
        brackets.path = path
        brackets.strokeColor = accent
        brackets.fillColor = nil
        brackets.lineWidth = 3
        brackets.shadowColor = accent
        brackets.shadowRadius = 6
        brackets.shadowOpacity = 0.9
        brackets.shadowOffset = .zero
        fx.addSublayer(brackets)
        animate(brackets, "transform.scale", 1.18, 1, at: 0, for: 0.18)
        animate(brackets, "opacity", 0, 1, at: 0, for: 0.12)
        // A tint and a bright scan line sweep the region from top to bottom.
        let tint = CALayer()
        tint.frame = fx.bounds
        tint.backgroundColor = accent.copy(alpha: 0.12)
        tint.masksToBounds = true
        fx.addSublayer(tint)
        let beam = CAGradientLayer()
        beam.colors = [accent.copy(alpha: 0)!, accent.copy(alpha: 0.85)!, NSColor.white.cgColor, accent.copy(alpha: 0)!]
        beam.locations = [0, 0.7, 0.85, 1]
        beam.frame = CGRect(x: 0, y: -28, width: from.width, height: 28)
        tint.addSublayer(beam)
        animate(beam, "position.y", -14, from.height + 14, at: 0.08, for: 0.34)
        animate(tint, "opacity", 1, 0, at: 0.42, for: 0.25)
        // The flash marks the moment pixels are taken.
        let flash = CALayer()
        flash.frame = fx.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        fx.addSublayer(flash)
        animate(flash, "opacity", 0.9, 0, at: 0.42, for: 0.3)
        animate(brackets, "opacity", 1, 0, at: 0.5, for: 0.25)
        renderer.layers[id]?.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            let chip = CALayer()
            chip.contents = img
            chip.contentsGravity = .resize
            chip.frame = from
            chip.cornerRadius = 6
            chip.masksToBounds = false
            chip.borderWidth = 1.5
            chip.borderColor = accent
            chip.shadowColor = accent
            chip.shadowRadius = 14
            chip.shadowOpacity = 0.8
            chip.shadowOffset = .zero
            root.addSublayer(chip)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setCompletionBlock { [weak self] in
                chip.removeFromSuperlayer()
                fx.removeFromSuperlayer()
                self?.renderer.layers[id]?.opacity = 1
            }
            chip.frame = to
            chip.shadowOpacity = 0
            CATransaction.commit()
        }
    }

    // MARK: Snapshot for evidence

    func snapshotPNG() -> Data? {
        let scale = renderer.backingScale
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if let l = layer {
            // render(in:) walks the layer tree in its own (flipped) geometry.
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
            for s in [renderer.worldLayer, overlayFill, overlay, presenceLayer] as [CALayer] { s.render(in: ctx) }
        }
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

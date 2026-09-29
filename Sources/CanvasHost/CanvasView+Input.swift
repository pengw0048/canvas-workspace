import AppKit
import CanvasCore

extension CanvasView {
    func viewPoint(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    func notePointer(_ w: WPoint) {
        lastPointerWorld = w
        lastPointerTime = Date()
        app.collab?.publishPointer(w, from: self)
    }

    /// The object a click selects: a group unless the user entered it.
    func selectable(_ o: CanvasObject) -> ObjectID {
        if let g = o.group, g != enteredGroup, ws.object(g) != nil { return g }
        return o.id
    }

    // MARK: Mouse

    /// While this participant controls a remote surface, events over it go to the host.
    func remoteTarget(_ vp: CGPoint) -> (ObjectID, Double, Double)? {
        guard let id = app.collab?.controlledObject, let o = ws.object(id) else { return nil }
        let r = camera.toView(app.runtime.contentRect(of: o))
        guard r.contains(vp) else { return nil }
        return (id, Double((vp.x - r.minX) / r.width), Double((vp.y - r.minY) / r.height))
    }

    func sendRemote(_ kind: RemoteInputEvent.Kind, _ e: NSEvent) -> Bool {
        guard let (id, x, y) = remoteTarget(viewPoint(e)) else { return false }
        var ev = RemoteInputEvent(kind: kind)
        ev.x = x
        ev.y = y
        app.collab?.sendInput(ev, to: id)
        return true
    }

    override func mouseDown(with e: NSEvent) {
        if sendRemote(.down, e) { return }
        if let a = app.runtime.activeObject, ws.object(a)?.kind == .browser { app.runtime.deactivate(capture: true) }
        window?.makeFirstResponder(self)
        if editor != nil { endEditing() }
        let vp = viewPoint(e)
        let wp = camera.toWorld(vp)
        notePointer(wp)
        if followUser != nil { stopFollowing() }
        if case .region = drag {
            drag = .region(objectID: regionTarget ?? "", start: vp, current: vp)
            return
        }
        if spaceHeld || tool == .hand {
            drag = .pan(start: vp, camera: camera)
            NSCursor.closedHand.set()
            return
        }
        switch tool {
        case .pointer: pointerDown(e, vp: vp, wp: wp)
        case .pen, .highlighter: drag = .ink(points: [wp])
        case .eraser: drag = .erase(ids: []); eraseAt(wp)
        case .connector:
            let hit = ws.hitTest(wp, zoom: camera.zoom, includeFrameInterior: true).first { $0.kind != .connector }
            drag = .connector(start: endpoint(for: hit, at: wp), current: wp)
        case .text:
            createAndEdit(.text, at: wp)
        case .sticky:
            createAndEdit(.sticky, at: wp)
        default:
            drag = .create(tool: tool, start: wp)
        }
        updateOverlay()
    }

    func endpoint(for hit: CanvasObject?, at wp: WPoint) -> Endpoint {
        guard let hit, hit.kind != .group else { return Endpoint(point: wp) }
        let l = hit.geom.toLocal(wp)
        let a = WPoint(x: min(1, max(0, l.x / max(1, hit.geom.w))), y: min(1, max(0, l.y / max(1, hit.geom.h))))
        return Endpoint(objectID: hit.id, anchor: a, point: wp)
    }

    func pointerDown(_ e: NSEvent, vp: CGPoint, wp: WPoint) {
        // Handles first: they have their own hit targets.
        if selection.count == 1, let id = selection.first, let o = ws.object(id), o.kind != .group, o.kind != .connector {
            if hitGrip(o, vp) {
                startExportDrag(ids: Array(selection), event: e)
                return
            }
            if let rp = rotationHandle(o), hypot(rp.x - vp.x, rp.y - vp.y) < 9 {
                let c = o.geom.center
                drag = .rotate(id: id, start: o.geom, startAngle: atan2(wp.y - c.y, wp.x - c.x))
                return
            }
            for (h, p) in handlePoints(o) where abs(p.x - vp.x) < 7 && abs(p.y - vp.y) < 7 {
                drag = .resize(id: id, handle: h, start: o.geom, startPoint: wp)
                return
            }
        }
        let hits = ws.hitTest(wp, zoom: camera.zoom)
        if e.clickCount == 2, let top = hits.first {
            activateOrEdit(top.id, at: wp)
            return
        }
        guard let top = hits.first else {
            if e.clickCount == 2 { createAndEdit(.text, at: wp); return }
            if enteredGroup != nil { enteredGroup = nil }
            let additive = e.modifierFlags.contains(.shift)
            drag = .marquee(start: wp, additive: additive, base: additive ? selection : [])
            if !additive { selection = [] }
            return
        }
        let target = selectable(top)
        if e.modifierFlags.contains(.shift) {
            if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
        } else if !selection.contains(target) {
            selection = [target]
        }
        let ids = Array(selection).filter { ws.object($0)?.kind != .connector || selection.count == 1 }
        if let who = app.collab?.claimedByOther(ws.movingSet(ids.isEmpty ? [target] : ids)) {
            hud.flash("\(who) is moving this right now. Try again in a moment.")
            return
        }
        drag = .move(ids: ids.isEmpty ? [target] : ids, start: wp, moved: false)
    }

    func hitGrip(_ o: CanvasObject, _ vp: CGPoint) -> Bool {
        guard [.app, .file, .browser, .image, .sticky, .text].contains(o.kind) else { return false }
        return exportGrip(o).insetBy(dx: -4, dy: -4).contains(vp)
    }

    override func mouseDragged(with e: NSEvent) {
        if case .none = drag, sendRemote(.drag, e) { return }
        let vp = viewPoint(e)
        let wp = camera.toWorld(vp)
        notePointer(wp)
        switch drag {
        case .pan(let start, let c0):
            var c = c0
            c.pan(dx: Double(vp.x - start.x), dy: Double(vp.y - start.y))
            camera = c
            applyCamera()
        case .move(let ids, let start, _):
            let dx = wp.x - start.x, dy = wp.y - start.y
            let set = ws.movingSet(ids)
            renderer.transientOffset = Dictionary(uniqueKeysWithValues: set.map { ($0, (dx, dy)) })
            drag = .move(ids: ids, start: start, moved: true)
            // Preview the proposed membership change; Option moves without reparenting.
            if e.modifierFlags.contains(.option) { renderer.dropTargetFrame = nil }
            else if case .some(let p) = ws.proposedParent(for: ids, dx: dx, dy: dy) { renderer.dropTargetFrame = p ?? "" }
            else { renderer.dropTargetFrame = nil }
            renderer.syncTransient(ws)
            hud.showHint(dropHint(ids: ids, option: e.modifierFlags.contains(.option), dx: dx, dy: dy))
            updateOverlay()
        case .marquee(let s, _, let base):
            let r = WRect.enclosing([s, wp])
            let inside = Set(ws.objects(in: r).map { selectable($0) })
            selection = base.union(inside)
            updateOverlay()
        case .resize(let id, let h, let g0, let p0):
            guard let o = ws.object(id) else { return }
            renderer.transientGeom[id] = resized(o, g0, handle: h, from: p0, to: wp, keepAspect: e.modifierFlags.contains(.shift))
            renderer.syncTransient(ws)
            updateOverlay()
        case .rotate(let id, let g0, let a0):
            let c = g0.center
            var r = g0.rotation + atan2(wp.y - c.y, wp.x - c.x) - a0
            if e.modifierFlags.contains(.shift) { r = (r / (.pi / 12)).rounded() * (.pi / 12) }
            var g = g0
            g.rotation = r
            renderer.transientGeom[id] = g
            renderer.syncTransient(ws)
            updateOverlay()
        case .ink(var pts):
            if let last = pts.last, last.distance(to: wp) * camera.zoom >= 1.5 { pts.append(wp) }
            drag = .ink(points: pts)
            updateOverlay()
        case .connector(let s, _):
            drag = .connector(start: s, current: wp)
            updateOverlay()
        case .region(let id, let s, _):
            drag = .region(objectID: id, start: s, current: vp)
            updateOverlay()
        case .erase:
            eraseAt(wp)
        case .create:
            updateOverlay()
        case .none:
            break
        }
    }

    /// Eraser: ink strokes under the pointer are marked, then removed on release.
    func eraseAt(_ wp: WPoint) {
        guard case .erase(var ids) = drag else { return }
        for o in ws.hitTest(wp, zoom: camera.zoom) where o.kind == .ink && !ids.contains(o.id) {
            ids.insert(o.id)
            renderer.layers[o.id]?.opacity = 0.25
        }
        drag = .erase(ids: ids)
    }

    func dropHint(ids: [ObjectID], option: Bool, dx: Double, dy: Double) -> String? {
        if option { return "Moving without changing frame membership" }
        guard case .some(let p) = ws.proposedParent(for: ids, dx: dx, dy: dy) else { return nil }
        if let p, let f = ws.object(p) {
            let shared = f.scope != Scope.privateID
            return shared ? "Drop to add to “\(f.title)” — visible to everyone in this shared frame" : "Drop to add to “\(f.title)”"
        }
        return "Drop to remove from frame"
    }

    func resized(_ o: CanvasObject, _ g0: Geometry, handle h: Int, from p0: WPoint, to p: WPoint, keepAspect: Bool) -> Geometry {
        if o.kind == .ink || (o.kind == .shape && (o.props.shape == .line || o.props.shape == .arrow)) {
            // Endpoint handles: the object box spans from start to end point.
            let a = g0.fromLocal(WPoint(x: 0, y: 0)), b = g0.fromLocal(WPoint(x: g0.w, y: g0.h))
            let na = h == 0 ? p : a, nb = h == 0 ? b : p
            if o.kind == .ink {
                return Geometry(x: min(na.x, nb.x), y: min(na.y, nb.y), w: max(4, abs(nb.x - na.x)), h: max(4, abs(nb.y - na.y)))
            }
            return Geometry(x: na.x, y: na.y, w: nb.x - na.x, h: nb.y - na.y)
        }
        let l0 = g0.toLocal(p0), l = g0.toLocal(p)
        let dx = l.x - l0.x, dy = l.y - l0.y
        var x0 = 0.0, y0 = 0.0, x1 = g0.w, y1 = g0.h
        if [0, 6, 7].contains(h) { x0 += dx }
        if [2, 3, 4].contains(h) { x1 += dx }
        if [0, 1, 2].contains(h) { y0 += dy }
        if [4, 5, 6].contains(h) { y1 += dy }
        let minSide = 12.0
        if x1 - x0 < minSide { if [0, 6, 7].contains(h) { x0 = x1 - minSide } else { x1 = x0 + minSide } }
        if y1 - y0 < minSide { if [0, 1, 2].contains(h) { y0 = y1 - minSide } else { y1 = y0 + minSide } }
        if keepAspect || o.kind == .image && !keepAspect && [0, 2, 4, 6].contains(h) {
            let ratio = g0.w / max(1, g0.h)
            let w = x1 - x0, hh = y1 - y0
            if w / max(1, hh) > ratio { let nw = hh * ratio; if [0, 6, 7].contains(h) { x0 = x1 - nw } else { x1 = x0 + nw } }
            else { let nh = w / ratio; if [0, 1, 2].contains(h) { y0 = y1 - nh } else { y1 = y0 + nh } }
        }
        // Map the new local box back to world, keeping rotation.
        let tl = g0.fromLocal(WPoint(x: x0, y: y0)), br = g0.fromLocal(WPoint(x: x1, y: y1))
        let c = WPoint(x: (tl.x + br.x) / 2, y: (tl.y + br.y) / 2)
        let w = x1 - x0, hh = y1 - y0
        return Geometry(x: c.x - w / 2, y: c.y - hh / 2, w: w, h: hh, rotation: g0.rotation)
    }

    override func mouseUp(with e: NSEvent) {
        if case .none = drag, sendRemote(.up, e) { return }
        let vp = viewPoint(e)
        let wp = camera.toWorld(vp)
        let op = drag
        drag = .none
        hud.showHint(nil)
        do {
            switch op {
            case .move(let ids, let start, let moved):
                renderer.transientOffset = [:]
                renderer.dropTargetFrame = nil
                if moved {
                    let dx = wp.x - start.x, dy = wp.y - start.y
                    var reparent: ObjectID?? = nil
                    if !e.modifierFlags.contains(.option), case .some(let p) = ws.proposedParent(for: ids, dx: dx, dy: dy) {
                        reparent = .some(p)
                    }
                    if try confirmPublication(ids: ids, reparent: reparent) {
                        try ws.move(ids, dx: dx, dy: dy, reparent: reparent)
                        if case .some(let p) = reparent { try app.applyScopeRules(ids: ids, newParent: p) }
                    } else {
                        try ws.move(ids, dx: dx, dy: dy)
                    }
                } else if e.clickCount == 1 && !e.modifierFlags.contains(.shift) {
                    // A plain click inside a multi-selection narrows it to the clicked object.
                    if let id = ws.hitTest(wp, zoom: camera.zoom).first.map({ selectable($0) }) { selection = [id] }
                }
                renderer.syncTransient(ws)
            case .resize(let id, _, _, _), .rotate(let id, _, _):
                if let g = renderer.transientGeom[id] {
                    renderer.transientGeom = [:]
                    try ws.setGeometry(id, g, name: { if case .rotate = op { return "Rotate" }; return "Resize" }())
                }
            case .create(let t, let s):
                try finishCreate(t, from: s, to: wp)
            case .ink(let pts):
                try finishInk(pts)
            case .connector(let s, _):
                let hit = ws.hitTest(wp, zoom: camera.zoom, includeFrameInterior: true).first { $0.kind != .connector && $0.id != s.objectID }
                let end = endpoint(for: hit, at: wp)
                let a = ws.connectorEndpoint(s).point
                if a.distance(to: wp) * camera.zoom > 6 {
                    var o = CanvasObject(kind: .connector, geom: Geometry(x: min(a.x, wp.x), y: min(a.y, wp.y), w: abs(a.x - wp.x), h: abs(a.y - wp.y)))
                    o.props.start = s
                    o.props.end = end
                    o.props.strokeWidth = 2
                    let id = try ws.create(o, name: "Create connector")
                    selection = [id]
                    tool = .pointer
                }
            case .region(let id, let s, let c):
                let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
                regionTarget = nil
                if r.width > 4 && r.height > 4 { app.captureRegion(objectID: id, viewRect: r, in: self) }
                else { hud.flash("Capture canceled") }
            case .erase(let ids):
                // The whole gesture is one undoable removal of the touched strokes.
                if !ids.isEmpty { try ws.removeFromCanvas(Array(ids)) }
                renderer.transientOffset = [:]
                for (_, l) in renderer.layers { l.opacity = 1 }
            case .marquee, .pan:
                updateCursor()
            case .none:
                break
            }
        } catch {
            app.report(error)
        }
        updateOverlay()
    }

    /// Previews a publication change caused by a drop and asks before committing.
    func confirmPublication(ids: [ObjectID], reparent: ObjectID??) throws -> Bool {
        guard case .some(let p) = reparent, let p, let f = ws.object(p), f.scope != Scope.privateID else { return true }
        let privateIDs = ids.filter { ws.object($0)?.scope == Scope.privateID }
        guard !privateIDs.isEmpty else { return true }
        let kinds = Set(privateIDs.compactMap { ws.object($0)?.kind })
        var detail = "Everyone with access to “\(f.title)” will see this material."
        if kinds.contains(.file) { detail += " File references share a preview only; file bytes stay on this Mac until you publish them." }
        if kinds.contains(.app) || kinds.contains(.browser) { detail += " Application surfaces share their last captured frame; live sharing and control need separate actions." }
        let alert = NSAlert()
        alert.messageText = "Share with “\(app.collab?.audienceLabel(scope: f.scope) ?? f.title)”?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Share")
        alert.addButton(withTitle: "Keep private")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func finishCreate(_ t: Tool, from s: WPoint, to e: WPoint) throws {
        var r = WRect.enclosing([s, e])
        let clickOnly = r.w * camera.zoom < 4 && r.h * camera.zoom < 4
        var o: CanvasObject
        switch t {
        case .rect, .ellipse:
            if clickOnly { r = WRect(x: s.x - 80, y: s.y - 50, w: 160, h: 100) }
            o = CanvasObject(kind: .shape, geom: Geometry(x: r.x, y: r.y, w: r.w, h: r.h))
            o.props.shape = t == .rect ? .rect : .ellipse
            o.props.strokeWidth = 2
            o.props.color = "#1E1E1E"
            o.props.fill = "#FFFFFF00"
        case .line, .arrow:
            let end = clickOnly ? WPoint(x: s.x + 160, y: s.y) : e
            o = CanvasObject(kind: .shape, geom: Geometry(x: s.x, y: s.y, w: end.x - s.x, h: end.y - s.y))
            o.props.shape = t == .line ? .line : .arrow
            o.props.strokeWidth = 2
            o.props.color = "#1E1E1E"
        case .frame:
            if clickOnly { r = WRect(x: s.x, y: s.y, w: 800, h: 560) }
            o = CanvasObject(kind: .frame, geom: Geometry(x: r.x, y: r.y, w: r.w, h: r.h))
            o.props.name = "Frame \(ws.live.filter { $0.kind == .frame }.count + 1)"
            // A new frame sits behind existing content; members are adopted explicitly below.
            o.z = FractionalIndex.between(nil, ws.minZ())
        default:
            return
        }
        let id = try ws.create(o)
        if t == .frame {
            // Adopt objects wholly inside the new frame as one command, so undo is predictable.
            let inside = ws.objects(in: r).filter { $0.id != id && $0.parent == ws.object(id)?.parent && $0.kind != .connector }
            if !inside.isEmpty {
                try ws.perform("Add to frame") { tx in for c in inside { tx.update(c.id) { $0.parent = id } } }
            }
        }
        selection = [id]
        tool = .pointer
    }

    func finishInk(_ pts: [WPoint]) throws {
        guard let f = pts.first else { return }
        let b = WRect.enclosing(pts)
        let pad = 2.0
        let g = Geometry(x: b.x - pad, y: b.y - pad, w: max(b.w + 2 * pad, 4), h: max(b.h + 2 * pad, 4))
        var o = CanvasObject(kind: .ink, geom: g)
        var flat: [Double] = []
        for p in (pts.count == 1 ? [f] : pts) { flat += [p.x - g.x, p.y - g.y] }
        o.props.inkPoints = flat
        o.props.logicalSize = [g.w, g.h]
        o.props.inkTool = tool == .highlighter ? "highlighter" : "pen"
        o.props.color = tool == .highlighter ? "#F5D90A" : inkColor
        o.props.strokeWidth = tool == .highlighter ? 16 : 3
        try ws.create(o, name: tool == .highlighter ? "Highlight" : "Draw")
    }

    func createAndEdit(_ kind: ObjectKind, at wp: WPoint) {
        var o: CanvasObject
        if kind == .sticky {
            o = CanvasObject(kind: .sticky, geom: Geometry(x: wp.x - 100, y: wp.y - 100, w: 200, h: 200))
            o.props.color = stickyColor
        } else {
            o = CanvasObject(kind: .text, geom: Geometry(x: wp.x, y: wp.y - 14, w: 280, h: 40))
            o.props.fontSize = 20
        }
        do {
            let id = try ws.create(o)
            selection = [id]
            tool = .pointer
            beginEditing(id, creating: true)
        } catch { app.report(error) }
    }

    func activateOrEdit(_ id: ObjectID, at wp: WPoint? = nil) {
        guard let o = ws.object(id) else { return }
        switch o.kind {
        case .sticky, .text, .shape, .connector:
            if o.kind == .shape && (o.props.shape == .line || o.props.shape == .arrow) { return }
            selection = [id]
            beginEditing(id)
        case .frame:
            renameFrame(id)
        case .group:
            enteredGroup = id
            if let wp, let hit = ws.hitTest(wp, zoom: camera.zoom).first(where: { $0.group == id }) { selection = [hit.id] }
        case .app, .browser:
            app.runtime.activate(id, in: self)
        case .file:
            app.files.open(id)
        case .image:
            if let live = o.props.liveOf { reveal(live) }
        case .ink:
            break
        }
    }

    func renameFrame(_ id: ObjectID) {
        guard let o = ws.object(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename frame"
        let tf = NSTextField(string: o.props.name ?? "")
        tf.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = tf
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tf
        if alert.runModal() == .alertFirstButtonReturn {
            try? ws.perform("Rename frame") { $0.update(id) { $0.props.name = tf.stringValue } }
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        let wp = camera.toWorld(viewPoint(e))
        notePointer(wp)
        if let top = ws.hitTest(wp, zoom: camera.zoom).first {
            let t = selectable(top)
            if !selection.contains(t) { selection = [t] }
        }
        NSMenu.popUpContextMenu(contextMenu(at: wp), with: e, for: self)
    }

    override func otherMouseDown(with e: NSEvent) {
        drag = .pan(start: viewPoint(e), camera: camera)
    }

    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { drag = .none }

    override func mouseMoved(with e: NSEvent) {
        let wp = camera.toWorld(viewPoint(e))
        notePointer(wp)
        updateCursor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    func updateCursor() {
        if spaceHeld || tool == .hand { NSCursor.openHand.set(); return }
        switch tool {
        case .pointer:
            guard let wp = lastPointerWorld else { NSCursor.arrow.set(); return }
            let vp = camera.toView(wp)
            if selection.count == 1, let id = selection.first, let o = ws.object(id), o.kind != .group {
                if hitGrip(o, vp) { NSCursor.dragCopy.set(); return }
                for (h, p) in handlePoints(o) where abs(p.x - vp.x) < 7 && abs(p.y - vp.y) < 7 {
                    ([1, 5].contains(h) ? NSCursor.resizeUpDown : [3, 7].contains(h) ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
                    return
                }
            }
            if ws.hitTest(wp, zoom: camera.zoom).first != nil { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    // MARK: Scroll and zoom

    override func scrollWheel(with e: NSEvent) {
        if let (id, x, y) = remoteTarget(viewPoint(e)) {
            var ev = RemoteInputEvent(kind: .scroll)
            ev.x = x; ev.y = y; ev.dx = Double(e.scrollingDeltaX); ev.dy = Double(e.scrollingDeltaY)
            app.collab?.sendInput(ev, to: id)
            return
        }
        if followUser != nil { stopFollowing() }
        let vp = viewPoint(e)
        if e.modifierFlags.contains(.command) {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            camera.zoom(by: exp(Double(dy) * 0.01), anchor: vp)
        } else if e.hasPreciseScrollingDeltas {
            camera.pan(dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY))
        } else {
            camera.pan(dx: Double(e.scrollingDeltaX) * 12, dy: Double(e.scrollingDeltaY) * 12)
        }
        applyCamera()
    }

    override func magnify(with e: NSEvent) {
        if followUser != nil { stopFollowing() }
        camera.zoom(by: 1 + Double(e.magnification), anchor: viewPoint(e))
        applyCamera()
    }

    override func smartMagnify(with e: NSEvent) {
        let wp = camera.toWorld(viewPoint(e))
        if let top = ws.hitTest(wp, zoom: camera.zoom).first { reveal(top.id, highlight: false) } else { fitAll() }
    }

    // MARK: Keyboard

    func sendRemoteKey(_ e: NSEvent, down: Bool) -> Bool {
        guard let id = app.collab?.controlledObject else { return false }
        var ev = RemoteInputEvent(kind: .key)
        ev.keyCode = Int(e.keyCode)
        ev.keyDown = down
        ev.text = e.characters
        ev.flags = UInt64(e.modifierFlags.rawValue)
        if ws.object(id)?.kind == .browser, down, let t = e.characters, !t.isEmpty, e.modifierFlags.intersection([.command, .control]).isEmpty, t.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
            ev = RemoteInputEvent(kind: .text)
            ev.text = t
        } else if ws.object(id)?.kind == .browser && !down { return true }
        app.collab?.sendInput(ev, to: id)
        return true
    }

    override func keyDown(with e: NSEvent) {
        if sendRemoteKey(e, down: true) { return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.keyCode == 49 && flags.isEmpty {  // space
            if !spaceHeld { spaceHeld = true; updateCursor() }
            return
        }
        if flags.contains(.shift) && !flags.contains(.command) {
            if e.keyCode == 18 { fitAll(); return }          // Shift-1
            if e.keyCode == 19 { fitSelection(); return }    // Shift-2
        }
        switch e.keyCode {
        case 48:  // Tab
            selectNext(backward: flags.contains(.shift))
            return
        case 53:  // Escape
            if case .region = drag { drag = .none; regionTarget = nil; hud.flash("Capture canceled"); updateOverlay(); return }
            if case .none = drag {} else { cancelDrag(); return }
            if focusReturn != nil { exitFocusView(); return }
            if enteredGroup != nil { enteredGroup = nil; return }
            if tool != .pointer { tool = .pointer; return }
            selection = []
            return
        case 36, 76:  // Return
            if let id = selection.first, selection.count == 1 { activateOrEdit(id) }
            return
        case 51, 117:  // Delete
            removeSelection()
            return
        case 123, 124, 125, 126:
            let step = (flags.contains(.shift) ? 10.0 : 1.0) / max(1, camera.zoom)
            let d: (Double, Double) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][e.keyCode]!
            if !selection.isEmpty { try? ws.move(Array(selection), dx: d.0, dy: d.1) }
            return
        default: break
        }
        if flags.isEmpty, let t = Tool.allCases.first(where: { $0.key == chars }) {
            tool = t
            return
        }
        if flags == [.command] && chars == "[" { try? ws.sendToBack(Array(selection)); return }
        if flags == [.command] && chars == "]" { try? ws.bringToFront(Array(selection)); return }
        super.keyDown(with: e)
    }

    override func keyUp(with e: NSEvent) {
        if sendRemoteKey(e, down: false) { return }
        if e.keyCode == 49 { spaceHeld = false; updateCursor(); return }
        super.keyUp(with: e)
    }

    func cancelDrag() {
        drag = .none
        renderer.transientOffset = [:]
        renderer.transientGeom = [:]
        renderer.dropTargetFrame = nil
        renderer.syncTransient(ws)
        hud.showHint(nil)
        updateOverlay()
    }

    func removeSelection() {
        guard !selection.isEmpty else { return }
        let ids = Array(selection)
        let running = ids.compactMap { ws.object($0) }.filter { $0.kind == .app && app.runtime.isRunning($0.id) }
        do {
            try ws.removeFromCanvas(ids)
            selection = []
            if !running.isEmpty {
                hud.flash("Removed from canvas. The application keeps running; its window is back on the desktop.")
                for o in running { app.runtime.release(o.id) }
            }
        } catch { app.report(error) }
    }

    func stopFollowing() {
        followUser = nil
        hud.update()
    }
}

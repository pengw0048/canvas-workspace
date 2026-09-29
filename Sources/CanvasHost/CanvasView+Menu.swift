import AppKit
import CanvasCore

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    var handler: () -> Void = {}
    convenience init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [.command], enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        self.handler = handler
        target = self
        isEnabled = enabled
    }
    @objc func run() { handler() }
}

extension NSMenu {
    func add(_ title: String, enabled: Bool = true, _ h: @escaping () -> Void) {
        let i = ActionItem(title, enabled: enabled, h)
        addItem(i)
    }
    func sub(_ title: String, _ build: (NSMenu) -> Void) {
        let m = NSMenu(title: title)
        build(m)
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = m
        addItem(i)
    }
}

extension CanvasView: NSMenuItemValidation {
    func perform(_ name: String, _ f: () throws -> Void) {
        do { try f() } catch { app.report(error) }
        _ = name
    }

    var selectedIDs: [ObjectID] { Array(selection) }

    func contextMenu(at wp: WPoint) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let ids = selectedIDs
        let objs = ids.compactMap { ws.object($0) }
        let one = objs.count == 1 ? objs.first : nil
        if objs.isEmpty {
            m.add("Paste") { self.pasteAt(wp) }
            m.add("Add sticky note") { self.createAndEdit(.sticky, at: wp) }
            m.add("Add text") { self.createAndEdit(.text, at: wp) }
            m.addItem(.separator())
            m.add("Bring in an application window…") { self.app.admitWindow(nil) }
            m.add("Import file or image…") { self.app.importFile(nil) }
            m.add("Add a web page…") { self.app.addWebPage(nil) }
            m.addItem(.separator())
            m.add("Name this place…") { self.app.nameCurrentPlace(self) }
            m.add("Fit all (⇧1)") { self.fitAll() }
            return m
        }
        if let o = one {
            switch o.kind {
            case .app:
                let r = app.runtime!
                m.add(r.activeObject == o.id ? "Return to canvas" : "Activate") {
                    r.activeObject == o.id ? r.deactivate(capture: true) : r.activate(o.id, in: self)
                }
                m.add("Capture window") { self.app.capture(objectID: o.id, in: self) }
                m.add("Capture region…") { self.beginRegionCapture(o.id) }
                m.add(r.isLive(o.id) ? "Stop live preview" : "Live preview") { r.toggleLive(o.id) }
                m.add("Create live view") { self.app.createLiveView(of: o.id, in: self) }
                m.add("Open another view…") { r.openAnotherView(o.id, in: self) }
                m.addItem(.separator())
                m.add("Open original") { r.openOriginal(o.id) }
                m.add("Reconnect / reopen") { r.reconnect(o.id, in: self) }
                m.add("Close application window…") { r.closeWindow(o.id) }
                m.add("Enter focus view") { self.enterFocusView(o.id, oneToOne: true) }
            case .browser:
                m.add("Activate") { self.app.runtime.activate(o.id, in: self) }
                m.add("Capture page") { self.app.capture(objectID: o.id, in: self) }
                m.add("Open in default browser") { self.app.browsers.openExternally(o.id) }
                if o.props.browserMode == .sharedRuntime {
                    m.add("Create live view") { self.app.createLiveView(of: o.id, in: self) }
                }
                m.add("Enter focus view") { self.enterFocusView(o.id, oneToOne: true) }
            case .file:
                m.add("Open") { self.app.files.open(o.id) }
                m.add("Reveal in Finder") { self.app.files.revealInFinder(o.id) }
                m.add("Relink…") { self.app.files.relink(o.id) }
                m.add("Duplicate file on disk…") { self.app.files.duplicateOnDisk(o.id, in: self) }
                m.add("Import a managed copy") { self.app.files.importManagedCopy(o.id, in: self) }
            case .image:
                if o.props.captureID != nil || o.props.sourceID != nil {
                    m.add("Reveal source") { self.app.revealSource(of: o.id, in: self) }
                    m.add("Open source") { self.app.openSource(of: o.id, in: self) }
                }
                if o.props.liveOf != nil {
                    m.add("Freeze as capture") { self.app.freeze(o.id, in: self) }
                }
                m.add("Crop to selection region…") { self.beginRegionCapture(o.id) }
                m.add("Export image…") { self.app.pasteboard.exportImage(ids: [o.id]) }
            case .frame:
                m.add("Rename…") { self.renameFrame(o.id) }
                m.add("Frame to content") { self.perform("Frame to content") { try self.ws.frameToContent(o.id) } }
                m.add("Tidy frame contents") { self.previewTidy(self.ws.children(of: o.id).map(\.id)) }
                m.add("Enter focus view") { self.enterFocusView(o.id) }
                m.add(o.scope == Scope.privateID ? "Share frame…" : "Sharing…") { self.app.shareFrame(o.id, in: self) }
            case .group:
                m.add("Ungroup") { self.perform("Ungroup") { try self.ws.ungroup(o.id) } }
                m.add("Enter group") { self.enteredGroup = o.id }
            case .sticky, .text, .shape:
                m.add("Edit text") { self.beginEditing(o.id) }
                if o.kind == .sticky {
                    m.sub("Color") { cm in
                        for (name, hex) in Theme.stickyColors {
                            cm.add(name) { self.perform("Color") { try self.ws.perform("Color") { $0.update(o.id) { $0.props.color = hex } } }; self.stickyColor = hex }
                        }
                    }
                }
            case .connector:
                m.add("Edit label") { self.beginEditing(o.id) }
            default: break
            }
            m.addItem(.separator())
        }
        m.add("Copy") { self.app.pasteboard.copy(ids: ids, mode: .standard) }
        m.add("Copy as image") { self.app.pasteboard.copy(ids: ids, mode: .image) }
        m.add("Copy text") { self.app.pasteboard.copy(ids: ids, mode: .text) }
        m.add("Copy link") { self.app.pasteboard.copy(ids: ids, mode: .link) }
        m.add("Drag out as file…") { self.app.pasteboard.exportImage(ids: ids) }
        m.add("Duplicate") { self.duplicateSelection() }
        m.addItem(.separator())
        m.sub("Arrange") { am in
            am.add("Bring to front") { self.perform("") { try self.ws.bringToFront(ids) } }
            am.add("Bring forward", enabled: one != nil) { self.perform("") { try self.ws.step(ids[0], forward: true) } }
            am.add("Send backward", enabled: one != nil) { self.perform("") { try self.ws.step(ids[0], forward: false) } }
            am.add("Send to back") { self.perform("") { try self.ws.sendToBack(ids) } }
            am.addItem(.separator())
            for (t, e) in [("Align left", AlignEdge.left), ("Align centers horizontally", .hcenter), ("Align right", .right),
                           ("Align top", .top), ("Align middles", .vcenter), ("Align bottom", .bottom)] {
                am.add(t, enabled: objs.count > 1) { self.perform(t) { try self.ws.align(ids, e) } }
            }
            am.add("Distribute horizontally", enabled: objs.count > 2) { self.perform("") { try self.ws.distribute(ids, .horizontal) } }
            am.add("Distribute vertically", enabled: objs.count > 2) { self.perform("") { try self.ws.distribute(ids, .vertical) } }
            am.add("Tidy…", enabled: objs.count > 1) { self.previewTidy(ids) }
        }
        m.add("Select behind") { self.selectBehind(at: wp) }
        if objs.count > 1 { m.add("Group") { self.perform("") { if let g = try self.ws.group(ids) { self.selection = [g] } } } }
        if let o = one, o.scope != Scope.privateID {
            m.add("Stop sharing this object…") { self.app.unshare(ids: [o.id], in: self) }
        }
        m.add("Inspect") { self.app.inspect(ids.first, in: self) }
        m.addItem(.separator())
        m.add("Remove from canvas") { self.removeSelection() }
        return m
    }

    /// Cycles to the next object below the topmost hit at the pointer.
    func selectBehind(at wp: WPoint) {
        let hits = ws.hitTest(wp, zoom: camera.zoom, includeFrameInterior: true).map { selectable($0) }
        var unique: [ObjectID] = []
        for h in hits where !unique.contains(h) { unique.append(h) }
        guard !unique.isEmpty else { return }
        if let cur = selection.first, let i = unique.firstIndex(of: cur) {
            selection = [unique[(i + 1) % unique.count]]
        } else {
            selection = [unique[min(1, unique.count - 1)]]
        }
    }

    /// Shows a tidy preview; one undoable command on confirmation.
    func previewTidy(_ ids: [ObjectID]) {
        let plan = ws.tidyPlan(ids)
        guard !plan.isEmpty else { return }
        var off: [ObjectID: (Double, Double)] = [:]
        for (id, d) in plan { for m in ws.movingSet([id]) { off[m] = d } }
        renderer.transientOffset = off
        renderer.syncTransient(ws)
        updateOverlay()
        let alert = NSAlert()
        alert.messageText = "Tidy \(plan.count) objects?"
        alert.informativeText = "The preview shows the proposed positions. You can undo this afterwards."
        alert.addButton(withTitle: "Tidy")
        alert.addButton(withTitle: "Cancel")
        let ok = alert.runModal() == .alertFirstButtonReturn
        renderer.transientOffset = [:]
        if ok { perform("Tidy") { try ws.tidy(ids) } }
        renderer.syncTransient(ws)
        updateOverlay()
    }

    func beginRegionCapture(_ id: ObjectID) {
        regionTarget = id
        reveal(id, highlight: false)
        drag = .region(objectID: id, start: .zero, current: .zero)
        hud.flash("Drag to choose the region to capture. Esc cancels.", seconds: 4)
        NSCursor.crosshair.set()
    }

    func duplicateSelection() {
        perform("Duplicate") {
            let new = try ws.duplicate(selectedIDs)
            if !new.isEmpty { selection = Set(new.filter { ws.object($0)?.parent == nil || !new.contains(ws.object($0)!.parent!) }) }
        }
    }

    /// Paste location: last intentional pointer location in view, else viewport center; repeated pastes offset.
    func pastePoint(size: WRect) -> WPoint {
        let vis = camera.visibleWorld
        var p: WPoint
        if let lp = lastPointerWorld, vis.contains(lp), Date().timeIntervalSince(lastPointerTime) < 600 {
            p = WPoint(x: lp.x - size.w / 2, y: lp.y - size.h / 2)
        } else {
            p = WPoint(x: vis.center.x - size.w / 2, y: vis.center.y - size.h / 2)
        }
        let sig = "\(Int(p.x))|\(Int(p.y))|\(NSPasteboard.general.changeCount)"
        if sig == lastPasteSignature { pasteCount += 1 } else { pasteCount = 0; lastPasteSignature = sig }
        let off = Double(pasteCount) * 24 / max(camera.zoom, 0.1)
        return WPoint(x: p.x + off, y: p.y + off)
    }

    func pasteAt(_ wp: WPoint?) {
        if let wp { lastPointerWorld = wp; lastPointerTime = Date() }
        app.pasteboard.paste(into: self)
    }

    // MARK: Responder chain edit actions

    @objc func copy(_ sender: Any?) { app.pasteboard.copy(ids: selectedIDs, mode: .standard) }
    @objc func cut(_ sender: Any?) {
        app.pasteboard.copy(ids: selectedIDs, mode: .standard)
        removeSelection()
    }
    @objc func paste(_ sender: Any?) { app.pasteboard.paste(into: self) }
    @objc func delete(_ sender: Any?) { removeSelection() }
    @objc override func selectAll(_ sender: Any?) {
        selection = Set(ws.live.filter { $0.kind != .group && ($0.group == nil || ws.object($0.group) == nil) }.map(\.id)
            + ws.live.filter { $0.kind == .group }.map(\.id))
    }
    @objc func duplicate(_ sender: Any?) { duplicateSelection() }
    @objc func undo(_ sender: Any?) {
        do {
            if let r = try ws.undo() {
                hud.flash(r.conflicts.isEmpty ? "Undid \(r.name)" : "Undid \(r.name) partly — \(r.conflicts.count) object(s) were changed later by someone else and kept their current state")
            }
        } catch { app.report(error) }
    }
    @objc func redo(_ sender: Any?) {
        do { if let r = try ws.redo() { hud.flash("Redid \(r.name)") } } catch { app.report(error) }
    }
    @objc func groupSelection(_ sender: Any?) { perform("Group") { if let g = try ws.group(selectedIDs) { selection = [g] } } }
    @objc func ungroupSelection(_ sender: Any?) {
        perform("Ungroup") { for id in selectedIDs where ws.object(id)?.kind == .group { try ws.ungroup(id) } }
    }
    @objc func fitAllAction(_ sender: Any?) { fitAll() }
    @objc func fitSelectionAction(_ sender: Any?) { fitSelection() }
    @objc func backAction(_ sender: Any?) { navigateBack() }
    @objc func zoomIn(_ sender: Any?) { camera.zoom(by: 1.25, anchor: CGPoint(x: bounds.midX, y: bounds.midY)); applyCamera() }
    @objc func zoomOut(_ sender: Any?) { camera.zoom(by: 0.8, anchor: CGPoint(x: bounds.midX, y: bounds.midY)); applyCamera() }
    @objc func zoomActual(_ sender: Any?) { var c = camera; c.zoom = 1; setCamera(c) }
    @objc func captureSelection(_ sender: Any?) {
        if let id = selectedIDs.first(where: { [.app, .browser].contains(ws.object($0)?.kind) }) { app.capture(objectID: id, in: self) }
        else { app.admitWindow(nil) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)): return !selection.isEmpty
        case #selector(undo(_:)): item.title = ws.undoStack.last.map { "Undo \($0.name)" } ?? "Undo"; return ws.canUndo
        case #selector(redo(_:)): item.title = ws.redoStack.last.map { "Redo \($0.name)" } ?? "Redo"; return ws.canRedo
        case #selector(groupSelection(_:)): return selection.count > 1
        case #selector(ungroupSelection(_:)): return selection.contains { ws.object($0)?.kind == .group }
        default: return true
        }
    }
}

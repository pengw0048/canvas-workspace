import AppKit
import CanvasCore

/// Search over objects, titles, filenames, text, and named places. Selecting moves the camera only.
final class SearchPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    unowned let app: AppController
    let panel: NSPanel
    let field = NSSearchField()
    let table = NSTableView()
    var results: [(String, String, () -> Void)] = []
    weak var canvas: CanvasView?

    init(app: AppController) {
        self.app = app
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340), styleMask: [.titled, .closable, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Search"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        let root = NSView(frame: panel.contentView!.bounds)
        field.frame = NSRect(x: 12, y: 300, width: 436, height: 26)
        field.autoresizingMask = [.width, .minYMargin]
        field.delegate = self
        field.target = self
        field.action = #selector(choose)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 436, height: 280))
        scroll.autoresizingMask = [.width, .height]
        let col = NSTableColumn(identifier: .init("r"))
        col.width = 420
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose)
        table.rowHeight = 34
        scroll.documentView = table
        root.addSubview(field)
        root.addSubview(scroll)
        panel.contentView = root
    }

    func show(in c: CanvasView) {
        canvas = c
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        update()
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.moveDown(_:)) { table.selectRowIndexes([min(table.selectedRow + 1, results.count - 1)], byExtendingSelection: false); return true }
        if sel == #selector(NSResponder.moveUp(_:)) { table.selectRowIndexes([max(table.selectedRow - 1, 0)], byExtendingSelection: false); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { panel.orderOut(nil); return true }
        return false
    }

    func update() {
        let q = field.stringValue
        let ws = app.workspace
        var r: [(String, String, () -> Void)] = []
        for p in ws.places() where q.isEmpty || p.name.lowercased().contains(q.lowercased()) {
            r.append(("⌖ \(p.name)", "Named place", { [weak self] in
                guard let c = self?.canvas else { return }
                var cam = c.camera
                cam.fit(p.rect, margin: 0, maxZoom: 16)
                c.setCamera(cam)
            }))
        }
        for o in ws.search(q).prefix(80) {
            let kind = o.kind == .app ? (o.props.appName ?? "Application") : o.kind.rawValue.capitalized
            r.append((o.title, kind, { [weak self] in self?.canvas?.reveal(o.id); self?.canvas?.selection = [o.id] }))
        }
        results = r
        table.reloadData()
        if !r.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc func choose() {
        let i = max(0, table.selectedRow)
        guard i < results.count else { return }
        results[i].2()
        panel.orderOut(nil)
        canvas?.window?.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let t = NSTextField(labelWithString: "")
        let a = NSMutableAttributedString(string: results[row].0 + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        a.append(NSAttributedString(string: results[row].1, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        t.attributedStringValue = a
        t.lineBreakMode = .byTruncatingTail
        return t
    }
}

/// Detailed provenance, source access, capability, recovery, and publication information.
final class InspectorPanel: NSObject {
    unowned let app: AppController
    let panel: NSPanel
    let text = NSTextView()
    weak var canvas: CanvasView?

    init(app: AppController) {
        self.app = app
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Inspector"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.autoresizingMask = [.width]
        text.frame = scroll.bounds
        scroll.documentView = text
        panel.contentView = scroll
    }

    func show(for c: CanvasView) {
        canvas = c
        if !panel.isVisible, let f = c.window?.frame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 580))
        }
        panel.orderFront(nil)
        refresh()
    }

    func refresh() {
        guard panel.isVisible, let c = canvas ?? app.activeCanvas else { return }
        let ws = app.workspace
        var lines: [String] = []
        let ids = Array(c.selection)
        if ids.isEmpty {
            lines.append("Workspace")
            lines.append("Objects: \(ws.live.count)")
            lines.append("Save: \(ws.saveState.label)")
            if !ws.pendingChanges.isEmpty { lines.append("Pending unsaved changes: \(ws.pendingChanges.count)") }
            lines.append("Screen recording: \(NativeWindows.screenCaptureAllowed ? "allowed" : "not allowed")")
            lines.append("Accessibility: \(NativeWindows.axTrusted ? "allowed" : "not allowed")")
            lines.append("Data folder: \(app.dataDir.path)")
        }
        for id in ids.prefix(5) {
            guard let o = ws.object(id) else { continue }
            lines.append("■ \(o.title)")
            lines.append("Type: \(o.kind.rawValue)")
            lines.append(String(format: "Position: %.0f, %.0f   Size: %.0f × %.0f", o.geom.x, o.geom.y, o.geom.w, o.geom.h))
            if o.geom.rotation != 0 { lines.append(String(format: "Rotation: %.0f°", o.geom.rotation * 180 / .pi)) }
            if let p = o.parent, let f = ws.object(p) { lines.append("Frame: \(f.title)") }
            if let g = o.group { lines.append("Group: \(g.prefix(8))") }
            lines.append("Sharing: \(o.scope == Scope.privateID ? "Private to this Mac" : "Shared in “\(app.collab?.shares[o.scope]?.title ?? o.scope)”")")
            if let ls = o.props.logicalSize, o.kind == .app || o.kind == .browser { lines.append(String(format: "Application size: %.0f × %.0f (canvas presentation is separate)", ls[0], ls[1])) }
            switch o.kind {
            case .app, .browser:
                lines.append("Recovery: \(o.kind == .app ? app.runtime.recoveryDepth(o).rawValue : "URL can be reopened; page state is not restored")")
                if let b = app.runtime.bindings[o.id] { lines.append("Connected: pid \(b.pid), window \(b.windowID) — verified by \(b.verifiedBy)") }
                if let s = app.session.source(o.props.sourceID) {
                    if let d = s.documentPath { lines.append("Document: \(d)") }
                    if let bid = s.bundleID { lines.append("App: \(bid)") }
                    if let u = s.url { lines.append("URL: \(u)") }
                }
                if let m = o.props.browserMode { lines.append("Mode: \(m.label)") }
                lines.append("Capabilities:")
                for (cap, st) in app.runtime.capabilities(o) { lines.append("  • \(cap.rawValue): \(st.text)") }
            case .file:
                if let u = app.files.resolvedURL(for: o) { lines.append("File: \(u.path)") } else { lines.append("File: missing") }
                lines.append("Relationship: reference to the existing file (not a copy)")
            case .image:
                if let src = o.props.liveOf { lines.append("Live view of: \(ws.object(src)?.title ?? "missing source")") }
                else { lines.append("Frozen image: never changes when its source changes") }
                if let cid = o.props.captureID, let r = app.session.store.record("capture", cid, as: CaptureRecord.self) {
                    lines.append("Captured: \(Date(timeIntervalSince1970: r.time).formatted())")
                    if let a = r.appName { lines.append("From: \(a)\(r.windowTitle.map { " — \($0)" } ?? "")") }
                    if let d = r.documentPath { lines.append("Source document: \(d)") }
                    if let u = r.url { lines.append("Source URL: \(u)") }
                    if let rg = r.region { lines.append(String(format: "Region: %.0f%%,%.0f%% %.0f%%×%.0f%% of the surface", rg[0] * 100, rg[1] * 100, rg[2] * 100, rg[3] * 100)) }
                    lines.append("Pixels: \(r.pixelSize.map(String.init).joined(separator: " × "))")
                }
                if let a = o.props.assetID { lines.append("Stored bytes: \(app.session.store.isAssetDurable(a) ? "saved on this device" : "not available locally")") }
            case .connector:
                let a = ws.connectorEndpoint(o.props.start), b = ws.connectorEndpoint(o.props.end)
                lines.append("Start: \(a.missing ? "missing target" : (o.props.start?.objectID.flatMap { ws.object($0)?.title } ?? "free point"))")
                lines.append("End: \(b.missing ? "missing target" : (o.props.end?.objectID.flatMap { ws.object($0)?.title } ?? "free point"))")
            default: break
            }
            lines.append("")
        }
        text.string = lines.joined(separator: "\n")
    }
}

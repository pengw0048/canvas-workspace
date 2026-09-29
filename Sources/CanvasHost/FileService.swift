import AppKit
import CanvasCore
import QuickLookThumbnailing

/// File objects are references to real files; managed copies are an explicit separate action.
final class FileService {
    unowned let app: AppController
    var thumbs: [ObjectID: (CGImage, Date)] = [:]
    var pendingThumb: Set<ObjectID> = []
    var mtimes: [ObjectID: Date] = [:]
    var changedAt: [ObjectID: Date] = [:]
    var missing: Set<ObjectID> = []
    var movedNote: [ObjectID: String] = [:]
    var timer: Timer?

    init(app: AppController) {
        self.app = app
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    var ws: Workspace { app.workspace }

    func stop() { timer?.invalidate() }

    /// Resolves the file through its bookmark first (survives moves and renames), then its path.
    func resolvedURL(for o: CanvasObject) -> URL? {
        guard var s = app.session.source(o.props.sourceID) else { return nil }
        if let bm = s.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, options: [.withoutUI], bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) {
                if u.path != s.path {
                    movedNote[o.id] = "Moved — found at \(u.lastPathComponent)"
                    s.path = u.path
                    if stale { s.bookmark = try? u.bookmarkData() }
                    app.session.putSource(s)
                    if o.props.fileName != u.lastPathComponent {
                        try? ws.perform("Update file name", recordUndo: false) { $0.update(o.id) { $0.props.fileName = u.lastPathComponent } }
                    }
                }
                return u
            }
        }
        if let p = s.path, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }

    @discardableResult
    func placeFiles(_ urls: [URL], at center: WPoint, in c: CanvasView) -> [ObjectID] {
        var ids: [ObjectID] = []
        for (i, u) in urls.enumerated() {
            var s = SourceRecord(kind: .file)
            s.path = u.path
            s.bookmark = try? u.bookmarkData()
            app.session.putSource(s)
            let isImage = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"].contains(u.pathExtension.lowercased())
            let w = isImage ? 260.0 : 200.0, h = isImage ? 240.0 : 220.0
            var o = CanvasObject(kind: .file, geom: Geometry(x: center.x - w / 2 + Double(i) * 30, y: center.y - h / 2 + Double(i) * 30, w: w, h: h))
            o.props.sourceID = s.id
            o.props.fileName = u.lastPathComponent
            do { ids.append(try ws.create(o, name: "Place file")) } catch { app.report(error) }
        }
        if !ids.isEmpty { c.selection = Set(ids) }
        return ids
    }

    func icon(for o: CanvasObject) -> NSImage? {
        if let u = resolvedURL(for: o) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSImage(systemSymbolName: "doc.questionmark", accessibilityDescription: "Missing file")
    }

    func thumbnail(for o: CanvasObject) -> CGImage? {
        if let t = thumbs[o.id] { return t.0 }
        requestThumbnail(o)
        return nil
    }

    func requestThumbnail(_ o: CanvasObject) {
        guard !pendingThumb.contains(o.id), let u = resolvedURL(for: o) else { return }
        pendingThumb.insert(o.id)
        let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: o.geom.w, height: o.geom.h - 34), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingThumb.remove(o.id)
                if let cg = rep?.cgImage {
                    self.thumbs[o.id] = (cg, Date())
                    for c in self.app.canvases { c.renderer.refreshSurface(o.id, self.ws) }
                }
            }
        }
    }

    func status(for o: CanvasObject) -> SurfaceStatus? {
        if missing.contains(o.id) { return SurfaceStatus(text: "File missing — relink", tone: .error) }
        if let n = movedNote[o.id] { return SurfaceStatus(text: n, tone: .normal) }
        if let t = changedAt[o.id], Date().timeIntervalSince(t) < 3600 {
            return SurfaceStatus(text: "Changed \(app.runtime.relative(t))", tone: .normal)
        }
        if o.scope != Scope.privateID, app.collab?.isRemoteObject(o) == true {
            return SurfaceStatus(text: "Preview only — file stays on the owner's Mac", tone: .normal)
        }
        return nil
    }

    /// Observes external changes: thumbnails refresh; captures of the file are untouched.
    func poll() {
        for o in ws.live where o.kind == .file {
            guard app.session.source(o.props.sourceID) != nil else { continue }
            guard let u = resolvedURL(for: o) else {
                if !missing.contains(o.id) { missing.insert(o.id); refresh(o.id) }
                continue
            }
            if missing.remove(o.id) != nil { refresh(o.id) }
            let m = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date
            if let m, let old = mtimes[o.id], m != old {
                changedAt[o.id] = Date()
                thumbs[o.id] = nil
                requestThumbnail(o)
                refresh(o.id)
            }
            mtimes[o.id] = m
        }
    }

    func refresh(_ id: ObjectID) { for c in app.canvases { c.renderer.refreshSurface(id, ws) } }

    func open(_ id: ObjectID) {
        guard let o = ws.object(id) else { return }
        guard let u = resolvedURL(for: o) else {
            if app.collab?.isRemoteObject(o) == true { app.activeCanvas?.hud.flash("This file is on a collaborator's Mac. Only its preview was shared."); return }
            app.activeCanvas?.hud.flash("The file is missing. Use Relink to choose its new location.")
            return
        }
        NSWorkspace.shared.open(u)
    }

    func revealInFinder(_ id: ObjectID) {
        guard let o = ws.object(id), let u = resolvedURL(for: o) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func relink(_ id: ObjectID) {
        guard let o = ws.object(id), var s = app.session.source(o.props.sourceID) else { return }
        let p = NSOpenPanel()
        p.message = "Choose the file this reference should point to"
        guard p.runModal() == .OK, let u = p.url else { return }
        s.path = u.path
        s.bookmark = try? u.bookmarkData()
        app.session.putSource(s)
        missing.remove(id)
        movedNote[id] = nil
        thumbs[id] = nil
        try? ws.perform("Relink file") { $0.update(id) { $0.props.fileName = u.lastPathComponent } }
    }

    /// An actual filesystem copy, clearly named, with a new reference object.
    func duplicateOnDisk(_ id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id), let u = resolvedURL(for: o) else { return }
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        var dest = u.deletingLastPathComponent().appendingPathComponent("\(base) copy" + (ext.isEmpty ? "" : ".\(ext)"))
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = u.deletingLastPathComponent().appendingPathComponent("\(base) copy \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: u, to: dest)
            placeFiles([dest], at: WPoint(x: o.geom.bounds.maxX + 40 + o.geom.w / 2, y: o.geom.center.y), in: c)
            c.hud.flash("Created a real copy on disk: \(dest.lastPathComponent)")
        } catch { app.report(error) }
    }

    /// Copies the bytes into workspace storage; the result no longer follows the original file.
    func importManagedCopy(_ id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id), let u = resolvedURL(for: o) else { return }
        let dir = app.dataDir.appendingPathComponent("managed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(newID())-\(u.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: u, to: dest)
            let ids = placeFiles([dest], at: WPoint(x: o.geom.bounds.maxX + 40 + o.geom.w / 2, y: o.geom.center.y), in: c)
            if let nid = ids.first {
                try ws.perform("Import managed copy") { $0.update(nid) { $0.props.name = "Managed copy of \(u.lastPathComponent)" } }
            }
            c.hud.flash("Imported a managed copy. It will not follow changes to the original.")
        } catch { app.report(error) }
    }

    /// The explicitly named filesystem deletion, separate from removing a canvas reference.
    func moveSourceToTrash(_ id: ObjectID) {
        guard let o = ws.object(id), let u = resolvedURL(for: o) else { return }
        let a = NSAlert()
        a.messageText = "Move “\(u.lastPathComponent)” to the Trash?"
        a.informativeText = "This deletes the source file from disk, not just this canvas reference. Other references will show it as missing."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([u]) { _, err in if let err { DispatchQueue.main.async { self.app.report(err) } } }
    }
}

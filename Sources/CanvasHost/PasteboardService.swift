import AppKit
import CanvasCore
import UniformTypeIdentifiers

enum CopyMode { case standard, image, text, link }

/// Internal clipboard payload: editable objects plus the asset bytes they need.
struct ClipboardPayload: Codable {
    var selection: PortableSelection
    var assets: [String: Data]
}

extension NSPasteboard.PasteboardType {
    static let canvasSelection = NSPasteboard.PasteboardType(PortableSelection.pasteboardType)
    static let pdfType = NSPasteboard.PasteboardType("com.adobe.pdf")
}

final class PasteboardService: NSObject {
    unowned let app: AppController
    init(app: AppController) { self.app = app }

    /// The system clipboard; `CANVAS_PASTEBOARD` names a private board for automated runs.
    static let board: NSPasteboard = ProcessInfo.processInfo.environment["CANVAS_PASTEBOARD"].map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
    var ws: Workspace { app.workspace }

    // MARK: Representations

    func textRepresentation(_ objs: [CanvasObject]) -> String? {
        let parts = objs.sorted { ($0.geom.y, $0.geom.x) < ($1.geom.y, $1.geom.x) }.compactMap { o -> String? in
            switch o.kind {
            case .sticky, .text, .shape, .connector: return o.text.isEmpty ? nil : o.text
            case .file: return app.session.source(o.props.sourceID)?.path.map { URL(fileURLWithPath: $0).lastPathComponent }
            case .browser: return o.props.url
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func fileURLs(_ objs: [CanvasObject]) -> [URL] {
        objs.filter { $0.kind == .file }.compactMap { app.files.resolvedURL(for: $0) }
    }

    func links(_ objs: [CanvasObject]) -> [URL] {
        objs.compactMap { o in
            if let u = o.props.url.flatMap(URL.init(string:)) { return u }
            if o.kind == .file { return app.files.resolvedURL(for: o) }
            return nil
        }
    }

    /// Renders a selection at export resolution independent of the current zoom.
    func renderComposition(_ ids: [ObjectID], scale: CGFloat = 2, background: NSColor? = .white, in other: Workspace? = nil) -> CGImage? {
        let ws = other ?? self.ws
        let set = ws.closure(ids)
        let objs = set.compactMap { ws.object($0) }.filter { $0.kind != .group }
        guard var b = WRect.union(objs.map { o -> WRect in
            if o.kind == .connector {
                return WRect.enclosing([ws.connectorEndpoint(o.props.start).point, ws.connectorEndpoint(o.props.end).point])
            }
            return o.geom.bounds
        }) else { return nil }
        let pad = objs.count == 1 && objs[0].kind == .image ? 0.0 : 16.0
        b = b.insetBy(-pad)
        var s = scale
        let maxPx = 36_000_000.0
        if Double(b.w * b.h) * Double(s * s) > maxPx { s = CGFloat(sqrt(maxPx / (b.w * b.h))) }
        let pw = Int(b.w * s), ph = Int(b.h * s)
        guard pw > 0, ph > 0, let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = SceneRenderer(camera: Camera(center: b.center, zoom: 1, viewSize: CGSize(width: b.w, height: b.h)))
        let ctxProvider = app.activeCanvas
        r.context = ctxProvider
        r.backingScale = s
        // Temporary workspace view limited to the selection.
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: b.w, height: b.h)
        root.isGeometryFlipped = true
        root.addSublayer(r.worldLayer)
        r.worldLayer.frame = root.bounds
        r.applyCamera(r.camera)
        r.syncSubset(ws, ids: Set(set))
        r.refreshDetail(ws)
        if let background { ctx.setFillColor(background.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph)) }
        // The layer tree is y-down; CGContext is y-up.
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: s, y: -s)
        root.render(in: ctx)
        return ctx.makeImage()
    }

    func pdfData(_ img: CGImage) -> Data {
        let d = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
        guard let consumer = CGDataConsumer(data: d as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        pdf.beginPDFPage(nil)
        pdf.draw(img, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return d as Data
    }

    func payload(_ ids: [ObjectID]) -> ClipboardPayload? {
        guard let sel = ws.portable(ids) else { return nil }
        var assets: [String: Data] = [:]
        var total = 0
        for a in sel.assets {
            guard let d = app.session.store.assetData(a) else { continue }
            total += d.count
            if total > 200_000_000 { break }
            assets[a] = d
        }
        return ClipboardPayload(selection: sel, assets: assets)
    }

    /// Builds one pasteboard item with several representations in semantic order.
    func makeItem(_ ids: [ObjectID], mode: CopyMode) throws -> NSPasteboardItem {
        let objs = ws.closure(ids).compactMap { ws.object($0) }.filter { $0.kind != .group }
        guard !objs.isEmpty else { throw CanvasError.permission("Nothing selected to copy") }
        let item = NSPasteboardItem()
        let onlyText = objs.allSatisfy { [.sticky, .text].contains($0.kind) }
        let singleImage = objs.count == 1 && objs[0].kind == .image
        let onlyFiles = objs.allSatisfy { $0.kind == .file }
        switch mode {
        case .text:
            guard let t = textRepresentation(objs) else { throw CanvasError.permission("The selection has no text") }
            item.setString(t, forType: .string)
            return item
        case .link:
            let ls = links(objs)
            guard let u = ls.first else { throw CanvasError.permission("The selection has no link") }
            item.setString(u.absoluteString, forType: u.isFileURL ? .fileURL : .URL)
            item.setString(ls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
            return item
        case .image:
            guard let img = singleImage ? app.images.fullImage(objs[0].props.assetID) : renderComposition(ids) else {
                throw CanvasError.permission("The selection could not be rendered")
            }
            guard let png = pngData(img, maxPixels: 60_000_000) else { throw CanvasError.permission("Encoding failed") }
            item.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: img).tiffRepresentation { item.setData(tiff, forType: .tiff) }
            return item
        case .standard:
            if let p = payload(ids), let d = try? JSONEncoder().encode(p) { item.setData(d, forType: .canvasSelection) }
            if onlyText {
                let t = textRepresentation(objs) ?? ""
                let attr = NSMutableAttributedString()
                for (i, o) in objs.sorted(by: { ($0.geom.y, $0.geom.x) < ($1.geom.y, $1.geom.x) }).enumerated() where !o.text.isEmpty {
                    if i > 0 && attr.length > 0 { attr.append(NSAttributedString(string: "\n\n")) }
                    attr.append(RichText.attributed(o.text, marks: o.marks, font: .systemFont(ofSize: o.props.fontSize ?? 14), color: .textColor))
                }
                let range = NSRange(location: 0, length: attr.length)
                if let rtf = attr.rtf(from: range, documentAttributes: [:]) { item.setData(rtf, forType: .rtf) }
                if let html = try? attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) { item.setData(html, forType: .html) }
                item.setString(t, forType: .string)
            } else if singleImage, let a = objs[0].props.assetID, let d = app.session.store.assetData(a) {
                item.setData(d, forType: .png)
                if let img = app.images.fullImage(a), let tiff = NSBitmapImageRep(cgImage: img).tiffRepresentation { item.setData(tiff, forType: .tiff) }
            } else if onlyFiles {
                let urls = fileURLs(objs)
                guard let first = urls.first else { throw CanvasError.permission("The file is missing. Relink it before copying.") }
                item.setString(first.absoluteString, forType: .fileURL)
                item.setString(first.lastPathComponent, forType: .string)
            } else if objs.count == 1, objs[0].kind == .browser, let u = objs[0].props.url {
                item.setString(u, forType: .URL)
                item.setString(u, forType: .string)
                if let img = app.runtime.surfaceImage(for: objs[0]), let png = pngData(img, maxPixels: 20_000_000) { item.setData(png, forType: .png) }
            } else {
                // Mixed composition: the composed visual is the default paste into image-capable apps.
                // It is rendered only when a destination asks, from a snapshot taken now.
                guard let provider = CompositionProvider(snapshotOf: ids, service: self) else {
                    throw CanvasError.permission("The selection could not be rendered")
                }
                item.setDataProvider(provider, forTypes: [.png, .pdfType])
                if objs.count == 1, objs[0].kind == .app, let s = app.session.source(objs[0].props.sourceID), let p = s.documentPath {
                    item.setString(URL(fileURLWithPath: p).absoluteString, forType: .URL)
                }
            }
            return item
        }
    }

    /// Writes to the system pasteboard. Representations are prepared first so a failure keeps the old clipboard.
    func copy(ids: [ObjectID], mode: CopyMode) {
        guard !ids.isEmpty else { return }
        do {
            let item = try makeItem(ids, mode: mode)
            let pb = PasteboardService.board
            pb.clearContents()
            if !pb.writeObjects([item]) { throw CanvasError.permission("The system clipboard rejected the data") }
            let what: String
            switch mode {
            case .standard: what = "Copied"
            case .image: what = "Copied as image"
            case .text: what = "Copied text"
            case .link: what = "Copied link"
            }
            app.activeCanvas?.hud.flash(what, seconds: 1.2)
            app.activeCanvas?.copyEffect(ids)
        } catch {
            app.activeCanvas?.hud.flash("Copy failed: \(error)", seconds: 4)
        }
    }

    // MARK: Paste and drop

    func paste(into c: CanvasView) {
        let pb = PasteboardService.board
        let created = importPasteboard(pb, at: nil, in: c)
        if created.isEmpty { c.hud.flash("The clipboard has nothing the canvas can use") }
    }

    /// Creates canvas objects from a pasteboard. `at` is a drop point; nil uses paste placement.
    @discardableResult
    func importPasteboard(_ pb: NSPasteboard, at drop: WPoint?, in c: CanvasView) -> [ObjectID] {
        do {
            if let d = pb.data(forType: .canvasSelection), let p = try? JSONDecoder().decode(ClipboardPayload.self, from: d) {
                var staged: [StagedAsset] = []
                for (id, bytes) in p.assets where !app.session.store.isAssetDurable(id) {
                    let img = NSImage(data: bytes)
                    staged.append(try app.session.store.stageAsset(bytes, mime: "image/png", width: Int(img?.size.width ?? 0), height: Int(img?.size.height ?? 0)))
                }
                let tl = drop.map { WPoint(x: $0.x - p.selection.bounds.w / 2, y: $0.y - p.selection.bounds.h / 2) } ?? c.pastePoint(size: p.selection.bounds)
                if !staged.isEmpty { try ws.perform("Import assets", assets: staged, recordUndo: false) { _ in } }
                let ids = try ws.paste(p.selection, topLeft: tl)
                c.selection = Set(ids.filter { id in ws.object(id).map { $0.parent == nil || !ids.contains($0.parent!) } ?? false })
                return ids
            }
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                let p = drop ?? c.pastePoint(size: WRect(x: 0, y: 0, w: 200, h: 220))
                return app.files.placeFiles(urls, at: WPoint(x: p.x + 100, y: p.y + 110), in: c)
            }
            if let img = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff, .pdfType]) != nil,
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                guard let png = pb.data(forType: .png) ?? pngData(cg, maxPixels: 60_000_000) else { return [] }
                let a = try app.session.store.stageAsset(png, mime: "image/png", width: cg.width, height: cg.height)
                app.images.put(a.id, cg)
                let size = img.size
                let scale = min(1, 900 / max(size.width, size.height))
                let r = WRect(x: 0, y: 0, w: size.width * scale, h: size.height * scale)
                let tl = drop.map { WPoint(x: $0.x - r.w / 2, y: $0.y - r.h / 2) } ?? c.pastePoint(size: r)
                var o = CanvasObject(kind: .image, geom: Geometry(x: tl.x, y: tl.y, w: r.w, h: r.h))
                o.props.assetID = a.id
                o.props.name = "Pasted image"
                if let src = pb.string(forType: .URL) { o.props.url = src }
                let id = try ws.create(o, name: "Paste image", assets: [a])
                c.selection = [id]
                return [id]
            }
            if let s = pb.string(forType: .URL) ?? pb.string(forType: .string).flatMap({ isWebURL($0) ? $0 : nil }), let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true {
                let p = drop ?? c.pastePoint(size: WRect(x: 0, y: 0, w: 640, h: 450))
                return [app.browsers.createPage(u, mode: .reference, at: WPoint(x: p.x + 320, y: p.y + 225), in: c)].compactMap { $0 }
            }
            if pb.string(forType: .URL) == nil, let rtf = pb.data(forType: .rtf), let attr = NSAttributedString(rtf: rtf, documentAttributes: nil), attr.length > 0,
               !RichText.marks(from: attr).isEmpty {
                // Formatted text keeps bold, italic, and links.
                let s = attr.string
                let lines = s.split(separator: "\n", omittingEmptySubsequences: false).count
                let w = min(560.0, max(160, Double(s.count) * 9)), h = max(40.0, Double(lines) * 28 + 12)
                let tl = drop.map { WPoint(x: $0.x - w / 2, y: $0.y - h / 2) } ?? c.pastePoint(size: WRect(x: 0, y: 0, w: w, h: h))
                var o = CanvasObject(kind: .text, geom: Geometry(x: tl.x, y: tl.y, w: w, h: h), text: s)
                o.props.fontSize = 18
                o.marks = RichText.marks(from: attr)
                let id = try ws.create(o, name: "Paste text")
                c.selection = [id]
                return [id]
            }
            if let s = pb.string(forType: .string), !s.isEmpty {
                let lines = s.split(separator: "\n", omittingEmptySubsequences: false).count
                let w = min(560.0, max(160, Double(s.count) * 9)), h = max(40.0, Double(lines) * 28 + 12)
                let r = WRect(x: 0, y: 0, w: w, h: h)
                let tl = drop.map { WPoint(x: $0.x - w / 2, y: $0.y - h / 2) } ?? c.pastePoint(size: r)
                var o = CanvasObject(kind: .text, geom: Geometry(x: tl.x, y: tl.y, w: w, h: h), text: s)
                o.props.fontSize = 18
                let id = try ws.create(o, name: "Paste text")
                c.selection = [id]
                return [id]
            }
        } catch {
            c.hud.flash("Paste failed: \(error)", seconds: 4)
        }
        return []
    }

    func isWebURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("http://") || t.hasPrefix("https://")) && !t.contains(" ") && !t.contains("\n")
    }

    // MARK: Export to file

    func exportImage(ids: [ObjectID]) {
        guard let img = (ids.count == 1 ? ws.object(ids[0]).flatMap { $0.kind == .image ? app.images.fullImage($0.props.assetID) : nil } : nil) ?? renderComposition(ids),
              let png = pngData(img, maxPixels: 80_000_000) else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "Canvas export.png"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try png.write(to: url, options: .atomic); app.activeCanvas?.hud.flash("Exported \(url.lastPathComponent)") }
        catch { app.report(error) }
    }
}

// MARK: Native drag out (export grip) and drag in

extension SceneRenderer {
    /// Builds layers for a subset of objects, used for offscreen export rendering.
    func syncSubset(_ ws: Workspace, ids: Set<ObjectID>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let order = ws.renderOrder().filter { ids.contains($0.id) && $0.kind != .group }
        var sub: [CALayer] = []
        for o in order {
            let l = makeLayer(o)
            l.detail = .full
            configure(l, o, ws)
            sub.append(l)
        }
        worldLayer.sublayers = sub
        CATransaction.commit()
    }
}

/// Deferred clipboard delivery of a composed image. The snapshot keeps the copied state even if the
/// canvas changes before the paste; asset bytes stay in the content-addressed store.
final class CompositionProvider: NSObject, NSPasteboardItemDataProvider {
    static var alive: [CompositionProvider] = []
    let snapshot: Workspace
    /// Weak: switching workspaces replaces the service while the clipboard still holds this provider.
    weak var service: PasteboardService?
    var rendered: CGImage?

    init?(snapshotOf ids: [ObjectID], service: PasteboardService) {
        guard let sel = service.ws.portable(ids) else { return nil }
        let doc = ScopeDocument(id: Scope.privateID)
        guard (try? doc.initializeSchema(title: "Clipboard")) != nil else { return nil }
        snapshot = Workspace(workspaceID: service.ws.workspaceID, user: service.ws.user)
        snapshot.addScope(doc)
        self.service = service
        super.init()
        let objs = snapshot.instantiate(sel, topLeft: WPoint(x: sel.bounds.x, y: sel.bounds.y))
        guard (try? snapshot.perform("Snapshot", recordUndo: false, { tx in for o in objs { tx.create(o) } })) != nil else { return nil }
        Self.alive.append(self)
        if Self.alive.count > 4 { Self.alive.removeFirst() }
    }

    func image() -> CGImage? {
        if rendered == nil { rendered = service?.renderComposition(snapshot.live.map(\.id), in: snapshot) }
        return rendered
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let img = image() else { Diagnostics.record("clipboard", "deferred render failed"); return }
        // Compositions paste at a document-friendly width; the full pixels are kept for zooming.
        if type == .png, let d = pngData(img, maxPixels: 60_000_000, displayWidth: min(480, Double(img.width) / 2)) { item.setData(d, forType: .png) }
        if type == .pdfType, let service { item.setData(service.pdfData(img), forType: .pdfType) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Self.alive.removeAll { $0 === self }
    }
}

final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let data: Data
    let name: String
    init(data: Data, name: String) { self.data = data; self.name = name }
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try data.write(to: url, options: .atomic); completionHandler(nil) } catch { completionHandler(error) }
    }
}

extension CanvasView: NSDraggingSource {
    static var promiseDelegates: [PromiseDelegate] = []

    /// Starts a native content drag: text, image, file, or a composed PNG file promise.
    func startExportDrag(ids: [ObjectID], event: NSEvent) {
        let objs = ws.closure(ids).compactMap { ws.object($0) }.filter { $0.kind != .group }
        guard !objs.isEmpty else { return }
        var items: [NSDraggingItem] = []
        let vp = viewPoint(event)
        let preview = app.pasteboard.renderComposition(ids, scale: 1, background: nil)
        let dragImage = preview.map { NSImage(cgImage: $0, size: NSSize(width: min(240, CGFloat($0.width)), height: min(240, CGFloat($0.width)) * CGFloat($0.height) / CGFloat(max(1, $0.width)))) }
        let frame = NSRect(x: vp.x - 40, y: vp.y - 40, width: dragImage?.size.width ?? 80, height: dragImage?.size.height ?? 80)
        if objs.allSatisfy({ $0.kind == .file }) {
            for o in objs {
                guard let u = app.files.resolvedURL(for: o) else { continue }
                let it = NSDraggingItem(pasteboardWriter: u as NSURL)
                it.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: u.path))
                items.append(it)
            }
        } else if objs.allSatisfy({ [.sticky, .text].contains($0.kind) }), let t = app.pasteboard.textRepresentation(objs) {
            let it = NSDraggingItem(pasteboardWriter: t as NSString)
            it.setDraggingFrame(frame, contents: dragImage)
            items.append(it)
        } else {
            let img = objs.count == 1 && objs[0].kind == .image ? app.images.fullImage(objs[0].props.assetID) : app.pasteboard.renderComposition(ids)
            guard let img, let png = pngData(img, maxPixels: 60_000_000) else { return }
            let name = (objs.count == 1 ? objs[0].title : "Canvas composition").replacingOccurrences(of: "/", with: "-") + ".png"
            let del = PromiseDelegate(data: png, name: name)
            CanvasView.promiseDelegates.append(del)
            let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: del)
            let it = NSDraggingItem(pasteboardWriter: provider)
            it.setDraggingFrame(frame, contents: dragImage)
            items.append(it)
        }
        guard !items.isEmpty else { hud.flash("Nothing to drag: the file may be missing"); return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation {
        // Content export copies; it never moves or deletes the original file.
        ctx == .outsideApplication ? [.copy, .link] : .copy
    }

    /// Spring-loading: hovering a drag over a connected app surface brings its real window there,
    /// so the app itself receives the drop.
    func draggingSession(_ s: NSDraggingSession, movedTo p: NSPoint) {
        guard let win = window else { return }
        let vp = convert(win.convertPoint(fromScreen: p), from: nil)
        let wp = camera.toWorld(vp)
        let hit = ws.hitTest(wp, zoom: camera.zoom).first { $0.kind == .app && app.runtime.isRunning($0.id) }
        if hit?.id != springTarget {
            springTarget = hit?.id
            springStart = Date()
            springFired = false
            if hit != nil { hud.showHint("Hold to drop into \(hit!.title)") } else { hud.showHint(nil) }
        } else if let id = springTarget, !springFired, Date().timeIntervalSince(springStart) > 0.5 {
            springFired = true
            hud.showHint(nil)
            app.runtime.springLoad(id, in: self)
        }
    }

    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        springTarget = nil
        springFired = false
        hud.showHint(nil)
        if operation == [] { hud.flash("Drag canceled — nothing changed", seconds: 1.5) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { CanvasView.promiseDelegates.removeAll() }
    }

    // MARK: Destination

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        if s.draggingSource as? CanvasView === self { return [] }
        return acceptable(s) ? .copy : []
    }

    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { draggingEntered(s) }

    func acceptable(_ s: NSDraggingInfo) -> Bool {
        let pb = s.draggingPasteboard
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return pb.availableType(from: [.canvasSelection, .fileURL, .URL, .png, .tiff, .string, .rtf, .pdfType]) != nil
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let wp = camera.toWorld(convert(s.draggingLocation, from: nil))
        let pb = s.draggingPasteboard
        if pb.availableType(from: [.fileURL]) == nil, let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let dir = app.dataDir.appendingPathComponent("received", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for r in receivers {
                r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, err in
                    guard let self else { return }
                    if let err { self.hud.flash("The dropped file could not be received: \(err.localizedDescription)"); return }
                    self.app.files.placeFiles([url], at: wp, in: self)
                }
            }
            return true
        }
        let created = app.pasteboard.importPasteboard(pb, at: wp, in: self)
        if created.isEmpty { hud.flash("The canvas cannot use this drop") }
        return !created.isEmpty
    }
}

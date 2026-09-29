import AppKit
import CanvasCore
import WebKit

/// Browser surfaces in the three declared modes (§10). Each object's web view is a real browser session
/// owned by this host; offscreen web views keep running.
final class BrowserService: NSObject, WKNavigationDelegate {
    unowned let app: AppController
    var views: [ObjectID: WKWebView] = [:]
    var snapshots: [ObjectID: (CGImage, Date)] = [:]
    var loadError: [ObjectID: String] = [:]
    var activeID: ObjectID?
    /// Scroll-follow: who a page currently follows, and a scroll waiting for its page to load.
    var followedBy: [ObjectID: String] = [:]
    var pendingScroll: [ObjectID: () -> Void] = [:]
    lazy var scrollReporter = PageScrollReporter(self)
    weak var activeCanvas: CanvasView?
    /// Holds inactive web views so they keep rendering.
    lazy var parking: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1600, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.orderBack(nil)
        return w
    }()

    init(app: AppController) { self.app = app }
    var ws: Workspace { app.workspace }

    func isRunning(_ id: ObjectID) -> Bool { views[id] != nil }

    func promptForPage(in c: CanvasView) {
        let a = NSAlert()
        a.messageText = "Add a web page"
        a.informativeText = "Reference pages render for each person separately. Provider documents open with each person's own account. A shared browser runtime is one browser session with one controller."
        let url = NSTextField(string: "https://")
        url.frame = NSRect(x: 0, y: 30, width: 380, height: 24)
        let mode = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26), pullsDown: false)
        for m in [BrowserMode.reference, .providerDocument, .sharedRuntime] { mode.addItem(withTitle: m.label) }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        box.addSubview(url)
        box.addSubview(mode)
        a.accessoryView = box
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = url
        guard a.runModal() == .alertFirstButtonReturn, let u = URL(string: url.stringValue.trimmingCharacters(in: .whitespaces)), u.scheme != nil else { return }
        let m = [BrowserMode.reference, .providerDocument, .sharedRuntime][mode.indexOfSelectedItem]
        if let id = createPage(u, mode: m, at: c.camera.visibleWorld.center, in: c) { c.selection = [id] }
    }

    @discardableResult
    func createPage(_ u: URL, mode: BrowserMode, at center: WPoint, in c: CanvasView) -> ObjectID? {
        var s = SourceRecord(kind: .url)
        s.url = u.absoluteString
        app.session.putSource(s)
        var o = CanvasObject(kind: .browser, geom: Geometry(x: center.x - 320, y: center.y - 215, w: 640, h: 430))
        o.props.url = u.absoluteString
        o.props.browserMode = mode
        o.props.sourceID = s.id
        o.props.name = u.isFileURL ? u.deletingPathExtension().lastPathComponent : (u.host ?? u.absoluteString)
        o.props.logicalSize = [1280, 860]
        do {
            let id = try ws.create(o, name: "Add web page")
            if mode != .providerDocument { _ = webView(for: id) }
            return id
        } catch { app.report(error); return nil }
    }

    func webView(for id: ObjectID) -> WKWebView? {
        if let v = views[id] { return v }
        guard let o = ws.object(id), let u = o.props.url.flatMap(URL.init(string:)) else { return nil }
        let cfg = WKWebViewConfiguration()
        // Each reference page and shared runtime has its own session; no cookies are copied between people.
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(PageScrollReporter.script)
        cfg.userContentController.add(scrollReporter, name: "canvasScroll")
        let size = o.props.logicalSize ?? [1280, 860]
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: size[0], height: size[1]), configuration: cfg)
        v.navigationDelegate = self
        v.allowsMagnification = false
        v.setValue(false, forKey: "drawsBackground")
        views[id] = v
        parking.contentView?.addSubview(v)
        v.load(URLRequest(url: u))
        return v
    }

    /// Loads a new address in a page surface; the URL becomes part of its source state.
    func navigate(_ id: ObjectID, to u: URL) {
        try? ws.perform("Navigate") { $0.update(id) { $0.props.url = u.absoluteString } }
        webView(for: id)?.load(URLRequest(url: u))
    }

    func id(of v: WKWebView) -> ObjectID? { views.first { $0.value === v }?.key }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = id(of: webView) else { return }
        pendingScroll.removeValue(forKey: id)?()
        loadError[id] = nil
        if let cur = webView.url?.absoluteString, let o = ws.object(id), o.props.url != cur || (webView.title.map { !$0.isEmpty && $0 != o.props.name } ?? false) {
            // The current URL is part of the surface's source state.
            try? ws.perform("Navigate", recordUndo: false) { $0.update(id) { $0.props.url = cur; $0.props.name = (webView.title?.isEmpty == false ? webView.title : nil) ?? webView.url?.host ?? $0.props.name } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshSnapshot(id, store: true) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }

    func failed(_ v: WKWebView, _ e: Error) {
        guard let id = id(of: v) else { return }
        loadError[id] = "Page unavailable: \(e.localizedDescription)"
        refresh(id)
    }

    func frame(for o: CanvasObject) -> CGImage? { snapshots[o.id]?.0 }

    func snapshot(_ id: ObjectID, _ done: @escaping (CGImage?) -> Void) {
        guard let v = webView(for: id) else { done(nil); return }
        let cfg = WKSnapshotConfiguration()
        v.takeSnapshot(with: cfg) { img, _ in
            done(img?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    func refreshSnapshot(_ id: ObjectID, store: Bool) {
        snapshot(id) { [weak self] img in
            guard let self, let img else { return }
            self.snapshots[id] = (img, Date())
            if store { self.app.capture.storePreview(img, for: id) }
            self.refresh(id)
            self.app.collab?.surfaceFrame(img, for: id)
        }
    }

    func refresh(_ id: ObjectID) {
        for c in app.canvases {
            c.renderer.refreshSurface(id, ws)
            for o in ws.live where o.props.liveOf == id { c.renderer.refreshSurface(o.id, ws) }
        }
    }

    func status(for o: CanvasObject) -> SurfaceStatus? {
        if let e = loadError[o.id] { return SurfaceStatus(text: e, tone: .error) }
        switch o.props.browserMode ?? .reference {
        case .reference:
            if let f = followedBy[o.id], app.canvases.contains(where: { $0.followUser == f }) {
                return SurfaceStatus(text: "Reference page · following \(app.collab?.name(of: f) ?? "a collaborator")'s scroll", tone: .live)
            }
            return SurfaceStatus(text: "Reference page · as rendered for you", tone: .normal)
        case .providerDocument: return SurfaceStatus(text: "Provider document · opens with your own account", tone: .normal)
        case .sharedRuntime:
            if let ctl = app.collab?.controllerLabel(o.id) { return SurfaceStatus(text: "Shared browser runtime · \(ctl)", tone: .live) }
            return SurfaceStatus(text: "Shared browser runtime · one session", tone: .normal)
        }
    }

    func capabilities(_ o: CanvasObject) -> [(Capability, CapabilityStatus)] {
        let mode = o.props.browserMode ?? .reference
        let embedded = mode != .providerDocument
        return [
            (.stillCapture, embedded ? .available : .unsupported("provider documents open in your own browser")),
            (.liveCapture, embedded ? .available : .unsupported("not embedded")),
            (.activate, .available),
            (.nativeInput, embedded ? .available : .unsupported("edits happen in the provider's editor")),
            (.remoteInput, mode == .sharedRuntime ? .available : .unsupported("only a shared browser runtime accepts one controller")),
            (.sourceIdentity, .available),
            (.sourceReopen, .available),
            (.sessionRestore, embedded ? .unavailable("the URL is restored; page state such as form drafts is not") : .unsupported("owned by the provider")),
            (.publication, embedded ? .available : .unsupported("share the link; each person uses their own access")),
        ]
    }

    // MARK: Activation: the web view is embedded at the object's projected rect and accepts input at scale

    func activate(_ id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id) else { return }
        if o.props.browserMode == .providerDocument { openExternally(id); return }
        if app.collab?.isRemoteSurface(o) == true { app.collab?.requestControl(id, from: c); return }
        if app.collab?.localMayOperate(id) == false { c.hud.flash("A collaborator controls this browser session. Reclaim control first."); return }
        deactivate()
        guard let v = webView(for: id) else { return }
        activeID = id
        activeCanvas = c
        app.runtime.setActiveExternal(id, canvas: c)
        v.removeFromSuperview()
        c.addSubview(v, positioned: .below, relativeTo: c.hud)
        reposition()
        c.window?.makeFirstResponder(v)
        refresh(id)
        app.collab?.localActivity(on: id)
    }

    func reposition() {
        guard let id = activeID, let c = activeCanvas, let o = ws.object(id), let v = views[id] else { return }
        let content = app.runtime.contentRect(of: o)
        let r = c.camera.toView(content)
        let ls = o.props.logicalSize ?? [1280, 860]
        // Page zoom keeps the page's own layout width, so the live page matches its preview.
        v.frame = r
        v.pageZoom = r.width / ls[0]
    }

    func deactivate() {
        guard let id = activeID, let v = views[id] else { activeID = nil; return }
        activeID = nil
        let ls = ws.object(id)?.props.logicalSize ?? [1280, 860]
        v.removeFromSuperview()
        v.frame = NSRect(x: 0, y: 0, width: ls[0], height: ls[1])
        v.pageZoom = 1
        parking.contentView?.addSubview(v)
        activeCanvas?.window?.makeFirstResponder(activeCanvas)
        refreshSnapshot(id, store: true)
        activeCanvas = nil
    }

    func openExternally(_ id: ObjectID) {
        guard let u = ws.object(id)?.props.url.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Delivers a remote controller's input to the shared runtime (validated by the caller).
    func deliver(_ e: RemoteInputEvent, to id: ObjectID) {
        guard let v = views[id] else { return }
        let ls = ws.object(id)?.props.logicalSize ?? [1280, 860]
        let p = NSPoint(x: e.x * ls[0], y: e.y * ls[1])
        let inWin: NSPoint
        if v.window === parking { inWin = v.convert(p, to: nil) } else { inWin = v.convert(p, to: nil) }
        let wn = v.window?.windowNumber ?? 0
        switch e.kind {
        case .down, .up, .drag, .move:
            let type: NSEvent.EventType = [.down: .leftMouseDown, .up: .leftMouseUp, .drag: .leftMouseDragged, .move: .mouseMoved][e.kind]!
            if let ev = NSEvent.mouseEvent(with: type, location: inWin, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: wn, context: nil, eventNumber: 0, clickCount: 1, pressure: e.kind == .down ? 1 : 0) {
                switch type {
                case .leftMouseDown: v.mouseDown(with: ev)
                case .leftMouseUp: v.mouseUp(with: ev)
                case .leftMouseDragged: v.mouseDragged(with: ev)
                default: v.mouseMoved(with: ev)
                }
            }
        case .scroll:
            v.evaluateJavaScript("window.scrollBy(\(e.dx), \(e.dy))")
        case .text:
            let js = "document.activeElement && document.execCommand('insertText', false, \(jsString(e.text ?? "")))"
            v.evaluateJavaScript(js)
        case .key:
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: wn, context: nil, characters: e.text ?? "", charactersIgnoringModifiers: e.text ?? "",
                                         isARepeat: false, keyCode: UInt16(e.keyCode ?? 0)) {
                v.keyDown(with: ev)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshSnapshot(id, store: false) }
    }

    func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        let arr = String(data: d, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}

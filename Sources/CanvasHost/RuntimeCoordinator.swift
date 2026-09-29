import AppKit
import ApplicationServices
import CanvasCore
import CoreImage

/// How much of an application's context can be continued (§8.3).
enum RecoveryDepth: String {
    case visualOnly = "Last visual only"
    case sourceReopen = "Source can be reopened"
    case adapterSession = "Adapter session"
    case survivingRuntime = "Running window"
}

enum RuntimeState: Equatable { case none, opening, connected, disconnected, failed(String) }

/// Ephemeral connection between a canvas object and a live window. Never persisted as identity.
struct WindowBinding {
    var windowID: CGWindowID
    var pid: pid_t
    var bundleID: String?
    var ax: AXUIElement?
    var verifiedBy: String
}

enum Capability: String, CaseIterable {
    case stillCapture = "Still capture", liveCapture = "Live preview", activate = "Activate",
         move = "Position window", resize = "Resize window", childUI = "Dialogs and palettes",
         nativeInput = "Native input", remoteInput = "Remote control", sourceIdentity = "Source identity",
         sourceReopen = "Reopen source", sessionRestore = "Session restoration", dirtyState = "Unsaved-changes detection",
         gracefulClose = "Close window normally", publication = "Share surface"
}

enum CapabilityStatus {
    case available
    case unsupported(String)
    case permissionRequired(String)
    case unavailable(String)

    var text: String {
        switch self {
        case .available: return "Available"
        case .unsupported(let r): return "Not supported — \(r)"
        case .permissionRequired(let r): return r
        case .unavailable(let r): return "Unavailable — \(r)"
        }
    }
}

final class RuntimeCoordinator: NSObject {
    unowned let app: AppController
    var bindings: [ObjectID: WindowBinding] = [:]
    var state: [ObjectID: RuntimeState] = [:]
    var activeObject: ObjectID?
    var activeCanvas: CanvasView?
    var liveObjects: Set<ObjectID> = []
    var frames: [ObjectID: CGImage] = [:]
    var frameTimes: [ObjectID: Date] = [:]
    var degradedReason: [ObjectID: String] = [:]
    var achievedDepth: [ObjectID: RecoveryDepth] = [:]
    var openingRequests: [ObjectID: UUID] = [:]
    var returnPanel: NSPanel?
    var watchTimer: Timer?
    var iconCache: [String: NSImage] = [:]
    /// Per-app rules: admit future document windows of this bundle near a world point.
    var admitRules: [String: WPoint] = [:]
    var knownWindows: Set<CGWindowID> = []

    init(app: AppController) {
        self.app = app
        super.init()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.watch() }
        if let d = app.session.store.meta("admitRules")?.data(using: .utf8), let r = try? JSONDecoder().decode([String: WPoint].self, from: d) {
            admitRules = r
            knownWindows = Set(NativeWindows.list().map(\.windowID))
        }
    }

    func saveAdmitRules() {
        if let d = try? JSONEncoder().encode(admitRules), let s = String(data: d, encoding: .utf8) { try? app.session.store.setMeta("admitRules", s) }
    }

    var ws: Workspace { app.workspace }

    func source(_ o: CanvasObject) -> SourceRecord? { app.session.source(o.props.sourceID) }

    // MARK: Presentation queries

    func surfaceImage(for o: CanvasObject, pixels: Double = 2048) -> CGImage? {
        if o.kind == .browser { return app.collab?.remoteFrame(o.id) ?? app.browsers.frame(for: o) ?? app.images.image(o.props.previewAssetID, pixels: pixels) }
        if let f = frames[o.id] { return f }
        if let l = liveImage(o.id) { return l }
        if let r = app.collab?.remoteFrame(o.id) { return r }
        return app.images.image(o.props.previewAssetID, pixels: pixels)
    }

    func icon(for o: CanvasObject) -> NSImage? {
        switch o.kind {
        case .app:
            let key = o.props.appBundleID ?? o.props.appName ?? "app"
            if let i = iconCache[key] { return i }
            var img: NSImage?
            if let b = o.props.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                img = NSWorkspace.shared.icon(forFile: url.path)
            }
            img = img ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            iconCache[key] = img
            return img
        case .browser:
            return NSImage(systemSymbolName: o.props.browserMode == .providerDocument ? "doc.richtext" : "globe", accessibilityDescription: nil)
        case .file:
            return app.files.icon(for: o)
        default:
            return nil
        }
    }

    func isRunning(_ id: ObjectID) -> Bool { bindings[id] != nil }
    func isLive(_ id: ObjectID) -> Bool { liveObjects.contains(id) }

    func status(for o: CanvasObject) -> SurfaceStatus? {
        switch o.kind {
        case .app:
            if case .opening? = state[o.id] { return SurfaceStatus(text: "Opening…", tone: .normal) }
            if let r = degradedReason[o.id] { return SurfaceStatus(text: r, tone: .warning) }
            if case .failed(let r)? = state[o.id] { return SurfaceStatus(text: r, tone: .error) }
            if bindings[o.id] != nil {
                if app.collab?.isPublishingLive(o.id) == true { return SurfaceStatus(text: "Live · shared", tone: .live) }
                if liveObjects.contains(o.id) { return SurfaceStatus(text: "Live", tone: .live) }
                if activeObject == o.id { return SurfaceStatus(text: "Active", tone: .live) }
                if let t = frameTimes[o.id] ?? o.props.previewTime.map(Date.init(timeIntervalSince1970:)), Date().timeIntervalSince(t) > 60 {
                    return SurfaceStatus(text: "Preview from \(relative(t))", tone: .normal)
                }
                return nil
            }
            if let remote = app.collab?.remoteSurfaceStatus(o) { return remote }
            if let t = o.props.previewTime {
                return SurfaceStatus(text: "Last captured \(relative(Date(timeIntervalSince1970: t))) · not connected", tone: .warning)
            }
            return SurfaceStatus(text: "Not connected", tone: .warning)
        case .browser:
            return app.browsers.status(for: o)
        case .file:
            return app.files.status(for: o)
        case .image:
            if let src = o.props.liveOf {
                if let s = ws.object(src), bindings[src] != nil || app.browsers.isRunning(src) {
                    return liveObjects.contains(src) || s.kind == .browser ? SurfaceStatus(text: "Live view", tone: .live)
                        : SurfaceStatus(text: "Live view · paused", tone: .normal)
                }
                return SurfaceStatus(text: "Live view · source unavailable", tone: .warning)
            }
            if let pending = app.capture.pendingStatus(o.id) { return pending }
            return nil
        default:
            return nil
        }
    }

    func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    var inputOwnerText: String {
        if let a = activeObject, let o = ws.object(a) {
            if o.kind == .browser { return "Input: \(o.title) — Esc or click outside returns" }
            return "Input: \(o.props.appName ?? "Application") — ⌃⌥Space returns to canvas"
        }
        if let c = app.activeCanvas, c.editor != nil { return "Input: editing text" }
        return "Input: canvas"
    }

    // MARK: Capabilities (§7.3)

    func capabilities(_ o: CanvasObject) -> [(Capability, CapabilityStatus)] {
        guard o.kind == .app else { return app.browsers.capabilities(o) }
        let sc = NativeWindows.screenCaptureAllowed, ax = NativeWindows.axTrusted
        let bound = bindings[o.id] != nil
        let src = source(o)
        let needSC = CapabilityStatus.permissionRequired("Allow screen recording")
        let needAX = CapabilityStatus.permissionRequired("Allow Accessibility control")
        let notConnected = CapabilityStatus.unavailable("reconnect or reopen first")
        func gate(_ perm: Bool, _ p: CapabilityStatus) -> CapabilityStatus { !perm ? p : (bound ? .available : notConnected) }
        return [
            (.stillCapture, gate(sc, needSC)),
            (.liveCapture, gate(sc, needSC)),
            (.activate, bound ? .available : notConnected),
            (.move, gate(ax, needAX)),
            (.resize, gate(ax, needAX)),
            (.childUI, bound ? .available : notConnected),
            (.nativeInput, bound ? (ax ? .available : .unavailable("the window appears where the app placed it; positioning needs Accessibility")) : notConnected),
            (.remoteInput, !ax ? needAX : (bound ? .available : notConnected)),
            (.sourceIdentity, src?.documentPath != nil ? .available : .unsupported("the app does not report a document file for this window")),
            (.sourceReopen, src?.documentPath != nil ? .available : (src?.bundleID != nil ? .unavailable("only the application can be relaunched") : .unsupported("no source recorded"))),
            (.sessionRestore, (src.flatMap { app.session.store.record("recovery", $0.id, as: TextDocumentSession.self) } != nil)
                ? .available : .unsupported("no adapter state recorded; only text documents save selection and scroll")),
            (.dirtyState, .unsupported("unsaved changes are unknown for ordinary windows")),
            (.gracefulClose, gate(ax, needAX)),
            (.publication, gate(sc, needSC)),
        ]
    }

    func recoveryDepth(_ o: CanvasObject) -> RecoveryDepth {
        if bindings[o.id] != nil { return .survivingRuntime }
        if let sid = o.props.sourceID, app.session.store.record("recovery", sid, as: TextDocumentSession.self) != nil { return .adapterSession }
        if let s = source(o), s.documentPath != nil { return .sourceReopen }
        return .visualOnly
    }

    // MARK: Admission (§7.1)

    func showAdmission(in c: CanvasView) {
        let wins = NativeWindows.list(onScreenOnly: false).filter { w in !bindings.values.contains { $0.windowID == w.windowID } && w.onScreen }
        let a = NSAlert()
        a.messageText = "Bring an application window onto the canvas"
        var info = "The window keeps its own process and document. It is placed near the current view."
        if !NativeWindows.screenCaptureAllowed { info += "\n\nScreen recording is not allowed yet, so window titles and previews are unavailable." }
        if !NativeWindows.axTrusted { info += "\nAccessibility is not allowed yet, so the host cannot position the real window." }
        a.informativeText = info
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        for w in wins { popup.addItem(withTitle: w.label) }
        let rule = NSButton(checkboxWithTitle: "Also bring in future document windows of this app", target: nil, action: nil)
        let stack = NSStackView(views: [popup, rule])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 56)
        a.accessoryView = stack
        a.addButton(withTitle: "Bring In")
        a.addButton(withTitle: "Launch Application…")
        a.addButton(withTitle: "Cancel")
        if !NativeWindows.screenCaptureAllowed || !NativeWindows.axTrusted { a.addButton(withTitle: "Permissions…") }
        if wins.isEmpty { a.buttons[0].isEnabled = false }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let w = wins[popup.indexOfSelectedItem]
            if let id = admit(w, at: c.camera.visibleWorld.center, in: c) {
                if rule.state == .on, let b = w.bundleID {
                    admitRules[b] = c.camera.visibleWorld.center
                    saveAdmitRules()
                    knownWindows = Set(NativeWindows.list().map(\.windowID))
                }
                c.selection = [id]
            }
        case .alertSecondButtonReturn:
            launchApplication(in: c)
        case NSApplication.ModalResponse(rawValue: 1003):
            requestPermissions()
        default: break
        }
    }

    func requestPermissions() {
        if !NativeWindows.screenCaptureAllowed {
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        if !NativeWindows.axTrusted { NativeWindows.requestAccessibility() }
    }

    /// Creates an application surface for a real window. Returns the new object ID.
    @discardableResult
    func admit(_ w: NativeWindow, at center: WPoint, in c: CanvasView?) -> ObjectID? {
        let runApp = NSRunningApplication(processIdentifier: w.pid)
        var src = SourceRecord(kind: .window)
        src.bundleID = runApp?.bundleIdentifier
        src.appName = runApp?.localizedName ?? w.ownerName
        src.pidHint = w.pid
        src.windowNumberHint = w.windowID
        src.originalFrame = [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height]
        let ax = NativeWindows.axWindow(for: w)
        if let ax, let p = NativeWindows.documentPath(ax) {
            src.documentPath = p
            src.documentBookmark = try? URL(fileURLWithPath: p).bookmarkData()
        }
        src.lastTitle = ax.flatMap(NativeWindows.title) ?? w.title
        app.session.putSource(src)
        var o = CanvasObject(kind: .app, geom: Geometry(x: center.x - w.frame.width / 2, y: center.y - w.frame.height / 2 - 15,
                                                         w: w.frame.width, h: w.frame.height + 30))
        o.props.sourceID = src.id
        o.props.appBundleID = src.bundleID
        o.props.appName = src.appName
        // Titles can contain private information; they stay local unless the object is shared.
        o.props.windowTitle = src.lastTitle
        o.props.logicalSize = [w.frame.width, w.frame.height]
        do {
            let id = try ws.create(o, name: "Bring in window")
            bindings[id] = WindowBinding(windowID: w.windowID, pid: w.pid, bundleID: src.bundleID, ax: ax, verifiedBy: "admitted by user")
            state[id] = .connected
            achievedDepth[id] = .survivingRuntime
            refreshPreview(id)
            return id
        } catch {
            app.report(error)
            return nil
        }
    }

    func launchApplication(in c: CanvasView) {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.message = "Choose an application to launch onto the canvas"
        guard p.runModal() == .OK, let url = p.url else { return }
        let center = c.camera.visibleWorld.center
        let before = Set(NativeWindows.list().map(\.windowID))
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] ra, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err { self.app.report(err); return }
                guard let ra else { return }
                self.waitForWindow(pid: ra.processIdentifier, excluding: before, timeout: 15) { w in
                    guard let w else { c.hud.flash("\(ra.localizedName ?? "The app") opened without a window to bring in"); return }
                    if let id = self.admit(w, at: center, in: c) { c.selection = [id]; NSApp.activate(ignoringOtherApps: true) }
                }
            }
        }
    }

    func waitForWindow(pid: pid_t?, bundleID: String? = nil, excluding: Set<CGWindowID>, timeout: Double, match: ((NativeWindow) -> Bool)? = nil, _ done: @escaping (NativeWindow?) -> Void) {
        let start = Date()
        func poll() {
            let cands = NativeWindows.list(onScreenOnly: true).filter {
                !excluding.contains($0.windowID) && (pid == nil || $0.pid == pid) && (bundleID == nil || $0.bundleID == bundleID) && (match?($0) ?? true)
            }
            if let w = cands.first { done(w); return }
            if Date().timeIntervalSince(start) > timeout { done(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
        }
        poll()
    }

    // MARK: Activation (hybrid preview → real window)

    /// Content rect of a surface in world coordinates: aspect-fit below the title bar.
    func contentRect(of o: CanvasObject) -> WRect {
        let bar = [.app, .browser].contains(o.kind) ? min(30, o.geom.h * 0.2) : 0
        let area = WRect(x: o.geom.x, y: o.geom.y + bar, w: o.geom.w, h: o.geom.h - bar)
        guard let ls = o.props.logicalSize, ls.count == 2, ls[0] > 0, ls[1] > 0 else { return area }
        let s = min(area.w / ls[0], area.h / ls[1])
        let w = ls[0] * s, h = ls[1] * s
        return WRect(x: area.x + (area.w - w) / 2, y: area.y + (area.h - h) / 2, w: w, h: h)
    }

    func activate(_ id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id) else { return }
        if o.kind == .browser { app.browsers.activate(id, in: c); return }
        guard o.kind == .app else { return }
        if app.collab?.isRemoteSurface(o) == true { app.collab?.requestControl(id, from: c); return }
        guard let b = verifiedBinding(id) else {
            reconnect(id, in: c, thenActivate: true)
            return
        }
        if activeObject != nil && activeObject != id { deactivate(capture: true, raiseCanvas: false) }
        // Spatially coherent transition: go to the zoom where the preview matches the real window 1:1.
        let content = contentRect(of: o)
        let logicalW = o.props.logicalSize?.first ?? content.w
        var cam = c.camera
        cam.zoom = logicalW / content.w
        cam.center = content.center
        let needMove = NativeWindows.axTrusted && b.ax != nil
        c.enterFocusView(id, camera: cam)
        activeObject = id
        activeCanvas = c
        if needMove, let ax = b.ax, let window = c.window {
            let viewRect = c.camera.toView(content)
            let inWindow = c.convert(viewRect, to: nil)
            let cocoa = window.convertToScreen(inWindow)
            let global = NativeWindows.globalRect(fromCocoa: cocoa)
            NativeWindows.setOrigin(ax, CGPoint(x: global.minX.rounded(), y: global.minY.rounded()))
            if NativeWindows.isMinimized(ax) { AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            NativeWindows.raise(ax)
            degradedReason[id] = nil
        } else {
            degradedReason[id] = NativeWindows.axTrusted ? "Window could not be positioned" : "Positioning needs Accessibility"
        }
        NSRunningApplication(processIdentifier: b.pid)?.activate(options: [])
        showReturnPanel(for: id)
        app.collab?.localActivity(on: id)
        refreshAll(id)
    }

    /// Marks an in-host surface (a browser runtime) as the input owner.
    func setActiveExternal(_ id: ObjectID, canvas: CanvasView) {
        if let cur = activeObject, cur != id { deactivate(capture: true, raiseCanvas: false) }
        activeObject = id
        activeCanvas = canvas
        for c in app.canvases { c.hud.update() }
    }

    /// Brings the real window over its surface without changing the camera (drag spring-loading).
    func springLoad(_ id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id), let b = verifiedBinding(id), let ax = b.ax, let window = c.window,
              let w = NativeWindows.window(b.windowID) else { return }
        let r = c.camera.toView(contentRect(of: o))
        let center = window.convertPoint(toScreen: c.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
        let g = NativeWindows.primaryHeight - center.y
        NativeWindows.setOrigin(ax, CGPoint(x: (center.x - w.frame.width / 2).rounded(), y: (g - w.frame.height / 2).rounded()))
        NativeWindows.raise(ax)
        NSRunningApplication(processIdentifier: b.pid)?.activate(options: [])
        activeObject = id
        activeCanvas = c
        showReturnPanel(for: id)
        refreshAll(id)
    }

    /// Returns input to the canvas. The application keeps running.
    func deactivate(capture: Bool, raiseCanvas: Bool = true) {
        guard let id = activeObject else { return }
        if ws.objects[id]?.kind == .browser {
            activeObject = nil
            activeCanvas = nil
            app.browsers.deactivate()
            refreshAll(id)
            return
        }
        activeObject = nil
        returnPanel?.orderOut(nil)
        if capture { refreshPreview(id) }
        let c = activeCanvas
        activeCanvas = nil
        if raiseCanvas {
            NSApp.activate(ignoringOtherApps: true)
            c?.window?.makeKeyAndOrderFront(nil)
            c?.window?.makeFirstResponder(c)
        }
        c?.exitFocusView()
        refreshAll(id)
    }

    func showReturnPanel(for id: ObjectID) {
        if returnPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 34), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            let v = makePanel()
            v.frame = p.contentView!.bounds
            v.autoresizingMask = [.width, .height]
            let b = pill("Return to canvas  ⌃⌥Space", symbol: "arrow.uturn.backward.circle", target: self, action: #selector(returnClicked))
            b.frame = NSRect(x: 8, y: 4, width: 234, height: 26)
            v.addSubview(b)
            p.contentView?.addSubview(v)
            returnPanel = p
        }
        guard let screen = activeCanvas?.window?.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        returnPanel?.setFrameOrigin(NSPoint(x: f.midX - 125, y: f.maxY - 44))
        returnPanel?.orderFrontRegardless()
    }

    @objc func returnClicked() { deactivate(capture: true) }

    @objc func appActivated(_ n: Notification) {
        guard let ra = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard let id = activeObject, let b = bindings[id] else { return }
        if ra.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // The user clicked the canvas: input returns to the host.
            deactivate(capture: true, raiseCanvas: false)
        } else if ra.processIdentifier != b.pid {
            deactivate(capture: true, raiseCanvas: false)
        }
    }

    @objc func appTerminated(_ n: Notification) {
        guard let ra = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for (id, b) in bindings where b.pid == ra.processIdentifier { lose(id, reason: "\(ra.localizedName ?? "The app") quit") }
    }

    func lose(_ id: ObjectID, reason: String) {
        bindings[id] = nil
        liveObjects.remove(id)
        app.capture.stopLive(id)
        frames[id] = liveImage(id)
        liveBuffers[id] = nil
        liveImageCache[id] = nil
        state[id] = .disconnected
        if activeObject == id { activeObject = nil; returnPanel?.orderOut(nil); activeCanvas?.exitFocusView() }
        app.collab?.runtimeLost(id)
        refreshAll(id)
        Diagnostics.record("runtime", "binding lost: \(reason)")
        app.activeCanvas?.hud.flash("\(reason). The canvas object and its last visual are kept.")
    }

    /// Session fields the generic text-document adapter saves (§8.3 "adapter session").
    struct TextDocumentSession: Codable, Equatable {
        var adapter = "ax-text-document"
        var version = 1
        var documentPath: String
        var documentModified: Double
        var selection: [Int]
        var visibleStart: Int
        var saved: Double
    }

    /// Records selection and scroll position for connected text documents, when they change.
    func saveAdapterSessions() {
        for (id, b) in bindings {
            guard let ax = b.ax, let doc = NativeWindows.documentPath(ax), let t = NativeWindows.textArea(in: ax),
                  let sel = NativeWindows.range(t, kAXSelectedTextRangeAttribute as String), let o = ws.object(id), let sid = o.props.sourceID else { continue }
            let vis = NativeWindows.range(t, kAXVisibleCharacterRangeAttribute as String)?.location ?? 0
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: doc)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
            var s = TextDocumentSession(documentPath: doc, documentModified: mtime, selection: [sel.location, sel.length], visibleStart: vis, saved: 0)
            let old = app.session.store.record("recovery", sid, as: TextDocumentSession.self)
            if var o2 = old { o2.saved = 0; if o2 == s { continue } }
            s.saved = Date().timeIntervalSince1970
            try? app.session.store.putRecord("recovery", sid, s)
        }
    }

    /// Restores saved fields after a reopen, only when the document is unchanged since they were saved.
    func restoreAdapterSession(_ id: ObjectID) -> Bool {
        guard let o = ws.object(id), let sid = o.props.sourceID, let s = app.session.store.record("recovery", sid, as: TextDocumentSession.self),
              let b = bindings[id], let ax = b.ax, NativeWindows.documentPath(ax) == s.documentPath, let t = NativeWindows.textArea(in: ax) else { return false }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: s.documentPath)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? -1
        guard abs(mtime - s.documentModified) < 1 else {
            Diagnostics.record("recovery", "document changed since session was saved; not replaying selection")
            return false
        }
        // Scroll by selecting the first visible character, then restore the actual selection.
        NativeWindows.setRange(t, kAXSelectedTextRangeAttribute as String, CFRange(location: s.visibleStart, length: 0))
        return NativeWindows.setRange(t, kAXSelectedTextRangeAttribute as String, CFRange(location: s.selection[0], length: s.selection[1]))
    }

    /// Periodic verification of bound windows and admission rules.
    func watch() {
        let wins = NativeWindows.list()
        let byID = Dictionary(uniqueKeysWithValues: wins.map { ($0.windowID, $0) })
        for (id, b) in bindings {
            if byID[b.windowID] == nil || NSRunningApplication(processIdentifier: b.pid) == nil {
                lose(id, reason: "The window closed")
            }
        }
        saveAdapterSessions()
        // While connected, the live window is the identity; follow the app's own document renames.
        for (id, b) in bindings {
            guard let ax = b.ax, let doc = NativeWindows.documentPath(ax), let o = ws.object(id), var src = source(o), src.documentPath != doc else { continue }
            src.documentPath = doc
            src.documentBookmark = try? URL(fileURLWithPath: doc).bookmarkData()
            src.lastTitle = NativeWindows.title(ax) ?? src.lastTitle
            app.session.putSource(src)
            let title = src.lastTitle
            try? ws.perform("Document renamed", recordUndo: false) { $0.update(id) { $0.props.windowTitle = title } }
        }
        if !admitRules.isEmpty {
            for w in wins where w.onScreen && !knownWindows.contains(w.windowID) {
                knownWindows.insert(w.windowID)
                if let b = w.bundleID, let p = admitRules[b], !bindings.values.contains(where: { $0.windowID == w.windowID }) {
                    admit(w, at: WPoint(x: p.x + Double.random(in: -60...60), y: p.y + Double.random(in: -60...60)), in: app.activeCanvas)
                }
            }
        }
    }

    // MARK: Resume protocol (§8.3)

    /// A binding that still points at the same process and window.
    func verifiedBinding(_ id: ObjectID) -> WindowBinding? {
        guard var b = bindings[id] else { return nil }
        guard let w = NativeWindows.window(b.windowID), w.pid == b.pid, NSRunningApplication(processIdentifier: b.pid) != nil else {
            lose(id, reason: "The window is no longer available")
            return nil
        }
        if b.ax == nil, NativeWindows.axTrusted { b.ax = NativeWindows.axWindow(for: w); bindings[id] = b }
        return b
    }

    /// On launch: reconnect only verified surviving runtimes; everything else shows stored previews.
    func startupScan() {
        let wins = NativeWindows.list()
        for o in ws.live where o.kind == .app {
            guard let s = source(o), let pid = s.pidHint, let num = s.windowNumberHint,
                  let w = wins.first(where: { $0.windowID == num }), w.pid == pid,
                  let ra = NSRunningApplication(processIdentifier: pid), ra.bundleIdentifier == s.bundleID else {
                state[o.id] = .disconnected
                continue
            }
            let ax = NativeWindows.axWindow(for: w)
            if let doc = s.documentPath, let ax, let now = NativeWindows.documentPath(ax), now != doc {
                // Same window number but a different document: do not rebind silently.
                state[o.id] = .disconnected
                continue
            }
            bindings[o.id] = WindowBinding(windowID: num, pid: pid, bundleID: s.bundleID, ax: ax, verifiedBy: "process and window survived host restart")
            state[o.id] = .connected
            achievedDepth[o.id] = .survivingRuntime
        }
        app.canvases.forEach { $0.renderer.sync(ws) }
    }

    /// Reconnects a surviving window, or reopens the recorded source, and reports the depth reached.
    func reconnect(_ id: ObjectID, in c: CanvasView, thenActivate: Bool = false) {
        guard let o = ws.object(id), o.kind == .app else { return }
        if verifiedBinding(id) != nil {
            c.hud.flash("Already connected to the running window")
            if thenActivate { activate(id, in: c) }
            return
        }
        if openingRequests[id] != nil { c.hud.flash("Already opening…"); return }
        guard let s = source(o) else { c.hud.flash("No source was recorded. The last captured visual is kept."); return }
        let token = UUID()
        openingRequests[id] = token
        state[id] = .opening
        refreshAll(id)
        let finish: (NativeWindow?, RecoveryDepth, String) -> Void = { [weak self] w, depth, how in
            guard let self, self.openingRequests[id] == token else { return }
            self.openingRequests[id] = nil
            guard let w else {
                self.state[id] = .failed("Could not reopen")
                self.refreshAll(id)
                c.hud.flash("Could not find or reopen the window. The last captured visual is kept.")
                return
            }
            self.bind(id, to: w, verifiedBy: how)
            var achieved = depth
            if depth == .sourceReopen, self.restoreAdapterSession(id) { achieved = .adapterSession }
            self.achievedDepth[id] = achieved
            switch achieved {
            case .survivingRuntime: c.hud.flash("Reconnected to the running window (\(how))")
            case .adapterSession: c.hud.flash("Reopened the document and restored its selection and scroll position. Unsaved edits from the earlier session are not restored.", seconds: 5)
            default: c.hud.flash("Reopened the source file. Unsaved state from the earlier session is not restored.")
            }
            if thenActivate { self.activate(id, in: c) }
        }
        // 1. A surviving window of the same app showing the same document.
        let wins = NativeWindows.list()
        if let doc = currentDocumentPath(s) {
            let matches = wins.filter { w in
                w.bundleID == s.bundleID && NativeWindows.axWindow(for: w).flatMap(NativeWindows.documentPath) == doc
            }
            if matches.count == 1 { finish(matches[0], .survivingRuntime, "same document"); return }
            if matches.count > 1 { chooseWindow(matches, for: id, in: c) { w in finish(w, .survivingRuntime, "chosen by you") }; return }
            // 2. Reopen the current source with its application.
            let url = URL(fileURLWithPath: doc)
            guard FileManager.default.fileExists(atPath: doc) else {
                openingRequests[id] = nil
                state[id] = .failed("Source file missing")
                refreshAll(id)
                c.hud.flash("The document is missing. Use Relink or keep the last captured visual.")
                return
            }
            let before = Set(wins.map(\.windowID))
            let cfg = NSWorkspace.OpenConfiguration()
            if let b = s.bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in }
            } else {
                NSWorkspace.shared.open(url)
            }
            waitForWindow(pid: nil, bundleID: s.bundleID, excluding: before, timeout: 15, match: { w in
                // Confirm identity before binding.
                NativeWindows.axWindow(for: w).flatMap(NativeWindows.documentPath) == doc || !NativeWindows.axTrusted
            }) { w in finish(w, .sourceReopen, "reopened document") }
            return
        }
        // 3. Only the application is known: titles alone are not identity, so ask.
        let cands = wins.filter { $0.bundleID == s.bundleID && $0.bundleID != nil }
        if !cands.isEmpty {
            chooseWindow(cands, for: id, in: c) { w in finish(w, .survivingRuntime, "chosen by you") }
            return
        }
        openingRequests[id] = nil
        state[id] = .disconnected
        refreshAll(id)
        if let b = s.bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            let a = NSAlert()
            a.messageText = "\(s.appName ?? "The application") has no matching window"
            a.informativeText = "This surface did not record a document file. You can open the application and choose a window to connect, or keep the last captured visual."
            a.addButton(withTitle: "Open Application")
            a.addButton(withTitle: "Keep Visual")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
        } else {
            c.hud.flash("The application is not available. The last captured visual is kept.")
        }
    }

    func currentDocumentPath(_ s: SourceRecord) -> String? {
        if let bm = s.documentBookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) {
                if u.path != s.documentPath {
                    var s2 = s
                    s2.documentPath = u.path
                    if stale { s2.documentBookmark = try? u.bookmarkData() }
                    app.session.putSource(s2)
                }
                return u.path
            }
        }
        return s.documentPath
    }

    func chooseWindow(_ cands: [NativeWindow], for id: ObjectID, in c: CanvasView, _ done: @escaping (NativeWindow?) -> Void) {
        let a = NSAlert()
        a.messageText = "Several windows could match"
        a.informativeText = "Choose the window this surface should connect to. Similar titles are not enough to decide automatically."
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        for w in cands { pop.addItem(withTitle: w.label) }
        a.accessoryView = pop
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        done(a.runModal() == .alertFirstButtonReturn ? cands[pop.indexOfSelectedItem] : nil)
    }

    func bind(_ id: ObjectID, to w: NativeWindow, verifiedBy: String) {
        let ax = NativeWindows.axWindow(for: w)
        bindings[id] = WindowBinding(windowID: w.windowID, pid: w.pid, bundleID: w.bundleID, ax: ax, verifiedBy: verifiedBy)
        state[id] = .connected
        if let o = ws.object(id), var s = source(o) {
            s.pidHint = w.pid
            s.windowNumberHint = w.windowID
            if s.originalFrame == nil { s.originalFrame = [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height] }
            if let ax, let p = NativeWindows.documentPath(ax) { s.documentPath = p; s.documentBookmark = try? URL(fileURLWithPath: p).bookmarkData() }
            app.session.putSource(s)
        }
        refreshPreview(id)
    }

    /// Explicitly binds an existing object to a window picked by the user.
    func openAnotherView(_ id: ObjectID, in c: CanvasView) {
        c.hud.flash("Ordinary applications decide whether a second view exists. Use the app's own New Window command, then bring that window in.", seconds: 5)
    }

    func openOriginal(_ id: ObjectID) {
        guard let o = ws.object(id) else { return }
        if let b = bindings[id] {
            NSRunningApplication(processIdentifier: b.pid)?.activate(options: [])
            if let ax = b.ax { NativeWindows.raise(ax) }
        } else if let s = source(o), let doc = currentDocumentPath(s) {
            NSWorkspace.shared.open(URL(fileURLWithPath: doc))
        } else if let b = o.props.appBundleID, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    /// Invokes the application's normal close flow; the canvas object and its recovery state stay.
    func closeWindow(_ id: ObjectID) {
        guard let b = verifiedBinding(id) else { app.activeCanvas?.hud.flash("The window is not connected"); return }
        refreshPreview(id)
        guard let ax = b.ax else { app.activeCanvas?.hud.flash("Closing needs Accessibility permission"); return }
        NSRunningApplication(processIdentifier: b.pid)?.activate(options: [])
        NativeWindows.raise(ax)
        if !NativeWindows.pressClose(ax) { app.activeCanvas?.hud.flash("The window has no close button that the host can press") }
    }

    /// Removing from the canvas never terminates the runtime.
    func release(_ id: ObjectID) {
        if activeObject == id { deactivate(capture: false) }
        app.capture.stopLive(id)
        liveObjects.remove(id)
        if let b = bindings[id], let ax = b.ax, let o = ws.objects[id], let s = source(o), let f = s.originalFrame, f.count == 4 {
            NativeWindows.setOrigin(ax, CGPoint(x: f[0], y: f[1]))
        }
        bindings[id] = nil
        frames[id] = nil
    }

    // MARK: Previews

    func toggleLive(_ id: ObjectID) {
        if liveObjects.contains(id) {
            liveObjects.remove(id)
            app.capture.stopLive(id)
            if let img = liveImage(id) { frames[id] = img }
            liveBuffers[id] = nil
            liveImageCache[id] = nil
        } else if let b = verifiedBinding(id) {
            liveObjects.insert(id)
            app.capture.startLive(id, windowID: b.windowID)
        } else {
            app.activeCanvas?.hud.flash("Reconnect the window before starting a live preview")
        }
        refreshAll(id)
    }

    /// Captures a fresh still for the stored preview; failure keeps the previous preview.
    func refreshPreview(_ id: ObjectID) {
        guard let b = bindings[id] else { return }
        app.capture.stillImage(windowID: b.windowID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let img):
                self.frames[id] = img
                self.frameTimes[id] = Date()
                self.app.capture.storePreview(img, for: id)
            case .failure(let e):
                if !NativeWindows.screenCaptureAllowed { self.degradedReason[id] = "Allow screen recording for previews" }
                NSLog("Preview capture failed: %@", "\(e)")
            }
            self.refreshAll(id)
        }
    }

    var liveBuffers: [ObjectID: CVPixelBuffer] = [:]
    var liveImageCache: [ObjectID: (CVPixelBuffer, CGImage)] = [:]
    let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// A still image of the current live frame, made only when something needs one (copy, capture, sharing).
    func liveImage(_ id: ObjectID) -> CGImage? {
        guard let pb = liveBuffers[id] else { return nil }
        if let c = liveImageCache[id], c.0 === pb { return c.1 }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let img = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        liveImageCache[id] = (pb, img)
        return img
    }

    /// Layer contents for a surface: the live IOSurface when streaming, else a still image.
    func surfaceContents(for o: CanvasObject, pixels: Double) -> Any? {
        let src = o.props.liveOf ?? o.id
        if let pb = liveBuffers[src], let surf = CVPixelBufferGetIOSurface(pb) { return surf.takeUnretainedValue() }
        if let so = o.props.liveOf.flatMap({ ws.object($0) }) { return surfaceImage(for: so, pixels: pixels) ?? app.images.image(o.props.assetID, pixels: pixels) }
        return surfaceImage(for: o, pixels: pixels)
    }

    func didReceiveLiveFrame(_ pb: CVPixelBuffer, for id: ObjectID) {
        guard liveObjects.contains(id) else { return }
        liveBuffers[id] = pb
        frameTimes[id] = Date()
        frames[id] = nil
        let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        let views = ws.live.filter { $0.props.liveOf == id }.map(\.id)
        for c in app.canvases { c.renderer.setLiveContents(surf, for: [id] + views) }
        app.collab?.surfaceFrame(for: id) { [weak self] in self?.liveImage(id) }
    }

    func didReceiveFrame(_ img: CGImage, for id: ObjectID) {
        frames[id] = img
        frameTimes[id] = Date()
        for c in app.canvases {
            c.renderer.refreshSurface(id, ws)
            for o in ws.live where o.props.liveOf == id { c.renderer.refreshSurface(o.id, ws) }
        }
        app.collab?.surfaceFrame(img, for: id)
    }

    func refreshAll(_ id: ObjectID) {
        for c in app.canvases {
            c.renderer.refreshSurface(id, ws)
            for o in ws.live where o.props.liveOf == id { c.renderer.refreshSurface(o.id, ws) }
            c.hud.update()
        }
        app.inspector?.refresh()
    }

    func objectsChanged(_ ids: Set<ObjectID>) {
        for id in ids where ws.object(id) == nil && bindings[id] != nil { release(id) }
    }

    func cameraDidChange(_ c: CanvasView) {
        if app.browsers.activeCanvas === c { app.browsers.reposition() }
        // Capture budget: offscreen live surfaces drop to a low rate but keep running.
        let vis = c.camera.visibleWorld
        for id in liveObjects {
            guard let o = ws.object(id) else { continue }
            app.capture.setLiveBudget(id, visible: vis.intersects(o.geom.bounds), pixels: c.renderer.pixelsNeeded(o))
        }
    }

    // MARK: Exit and recovery (§7.1)

    /// Moves every managed window whose frame is off all displays onto the main display.
    func recoverWindowsOntoDisplays(silent: Bool) {
        var moved = 0
        guard let main = NSScreen.main?.visibleFrame else { return }
        for (_, b) in bindings {
            guard let ax = b.ax, let f = NativeWindows.frame(of: ax) else { continue }
            if !NativeWindows.isOnSomeDisplay(f) || !silent {
                let g = NativeWindows.globalRect(fromCocoa: main)
                if !NativeWindows.isOnSomeDisplay(f) {
                    NativeWindows.setOrigin(ax, CGPoint(x: g.minX + 40 + Double(moved * 30), y: g.minY + 40 + Double(moved * 30)))
                    moved += 1
                }
            }
        }
        if !silent { app.activeCanvas?.hud.flash(moved == 0 ? "All managed windows are on a display" : "Moved \(moved) window(s) onto the main display") }
    }

    /// On exit, returns admitted windows to their original placement when it is still on a display.
    func restoreForExit() {
        if activeObject != nil { deactivate(capture: true, raiseCanvas: false) }
        for (id, b) in bindings {
            guard let ax = b.ax, let o = ws.object(id), let s = source(o), let f = s.originalFrame, f.count == 4 else { continue }
            let r = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if NativeWindows.isOnSomeDisplay(r) { NativeWindows.setOrigin(ax, r.origin) }
        }
        recoverWindowsOntoDisplays(silent: true)
    }

    func stop() {
        watchTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func shutdown() {
        for id in liveObjects { app.capture.stopLive(id) }
        returnPanel?.orderOut(nil)
        for (id, b) in bindings {
            guard let o = ws.objects[id], var s = source(o) else { continue }
            s.pidHint = b.pid
            s.windowNumberHint = b.windowID
            app.session.putSource(s)
        }
    }
}

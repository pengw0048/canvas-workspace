import AppKit
import Carbon.HIToolbox
import CanvasCore

/// A borderless desktop-scale window that can become key.
final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct Identity: Codable {
    var id: String
    var name: String
}

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let profile: String
    let dataDir: URL
    let windowed: Bool
    var session: WorkspaceSession!
    var workspace: Workspace { session.workspace }
    var identity: Identity!
    var windows: [CanvasWindow] = []
    var canvases: [CanvasView] = []
    var images: ImageCache!
    var runtime: RuntimeCoordinator!
    var files: FileService!
    var browsers: BrowserService!
    var pasteboard: PasteboardService!
    var capture: CaptureService!
    var collab: Collaboration?
    var automation: Automation?
    var hotKeys: HotKeys!
    var inspector: InspectorPanel?
    var search: SearchPanel?
    var saveRetry: Timer?
    var history: HistoryPanel?

    init(profile: String, windowed: Bool) {
        self.profile = profile
        self.windowed = windowed
        let base = ProcessInfo.processInfo.environment["CANVAS_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CanvasWorkspace")
        dataDir = base.appendingPathComponent(profile, isDirectory: true)
        super.init()
    }

    var activeCanvas: CanvasView? {
        canvases.first { $0.window?.isKeyWindow == true } ?? canvases.first
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            identity = loadIdentity()
        } catch {
            fail(error, dataDir)
            return
        }
        let last = workspaceRegistry().first { $0.id == UserDefaults.standard.string(forKey: "lastWorkspace.\(profile)") }
        guard openWorkspace(at: last.map { directory(for: $0) } ?? dataDir) else { return }
        buildMenu()
        hotKeys = HotKeys()
        for (name, def, action) in [("hostCommand", "ctrl+opt+space", #selector(hostCommandAction)),
                                    ("captureCommand", "ctrl+opt+c", #selector(globalCapture)),
                                    ("reclaimCommand", "ctrl+opt+cmd+r", #selector(emergencyReclaimAction))] {
            let sc = Shortcut.configured(name, default: def)
            if !hotKeys.register(keyCode: sc.keyCode, modifiers: sc.modifiers, { [weak self] in _ = self?.perform(action) }) {
                Diagnostics.record("hotkey", "\(name) could not be registered; another app may own it")
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if ProcessInfo.processInfo.environment["CANVAS_AUTOMATION"] != nil || CommandLine.arguments.contains("--automation") {
            automation = Automation(app: self)
        }
        if !CommandLine.arguments.contains("--background") { NSApp.activate(ignoringOtherApps: true) }
    }

    func fail(_ error: Error, _ dir: URL) {
        let a = NSAlert()
        a.messageText = "The workspace could not be opened"
        a.informativeText = "\(error)\n\nData folder: \(dir.path)"
        a.runModal()
        if session == nil { NSApp.terminate(nil) }
    }

    // MARK: Workspaces

    struct WorkspaceEntry: Codable { var id: String; var name: String; var folder: String? }

    var registryURL: URL { dataDir.appendingPathComponent("workspaces.json") }

    /// The default workspace lives at the profile root; others in `workspaces/<id>`.
    func workspaceRegistry() -> [WorkspaceEntry] {
        var list = (try? JSONDecoder().decode([WorkspaceEntry].self, from: Data(contentsOf: registryURL))) ?? []
        if !list.contains(where: { $0.folder == nil }) { list.insert(WorkspaceEntry(id: "default", name: "Workspace", folder: nil), at: 0) }
        return list
    }

    func saveRegistry(_ l: [WorkspaceEntry]) { try? JSONEncoder().encode(l).write(to: registryURL, options: .atomic) }

    func directory(for e: WorkspaceEntry) -> URL {
        e.folder.map { dataDir.appendingPathComponent("workspaces", isDirectory: true).appendingPathComponent($0, isDirectory: true) } ?? dataDir
    }

    var currentWorkspaceEntry: WorkspaceEntry? {
        workspaceRegistry().first { directory(for: $0).standardizedFileURL == session?.store.directory.standardizedFileURL }
    }

    /// Opens a workspace; the previous one is saved and its windows are left where they are.
    @discardableResult
    func openWorkspace(at dir: URL) -> Bool {
        let newSession: WorkspaceSession
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            newSession = try WorkspaceSession(directory: dir, user: identity.id)
        } catch { fail(error, dir); return false }
        if session != nil {
            workspace.flush()
            for c in canvases { personalViewChanged(c, force: true) }
            runtime.shutdown()
            runtime.stop()
            files.stop()
            collab?.stop()
            inspector?.panel.orderOut(nil)
            history?.panel.orderOut(nil)
        }
        session = newSession
        _ = session.store.collectOrphanAssets()
        images = ImageCache(store: session.store)
        capture = CaptureService(app: self)
        runtime = RuntimeCoordinator(app: self)
        files = FileService(app: self)
        browsers = BrowserService(app: self)
        pasteboard = PasteboardService(app: self)
        collab = Collaboration(app: self)
        workspace.onChange = { [weak self] ids in self?.workspaceChanged(ids) }
        workspace.onSaveState = { [weak self] s in self?.saveStateChanged(s) }
        buildWindows()
        runtime.startupScan()
        if let e = currentWorkspaceEntry {
            UserDefaults.standard.set(e.id, forKey: "lastWorkspace.\(profile)")
            for w in windows { w.title = e.name }
        }
        return true
    }

    func newWorkspace() {
        let a = NSAlert()
        a.messageText = "New workspace"
        a.informativeText = "A separate canvas with its own objects, sharing, and history."
        let tf = NSTextField(string: "")
        tf.placeholderString = "Name"
        tf.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        createWorkspace(named: tf.stringValue.isEmpty ? "Untitled workspace" : tf.stringValue)
    }

    @discardableResult
    func createWorkspace(named name: String) -> WorkspaceEntry {
        var l = workspaceRegistry()
        let e = WorkspaceEntry(id: newID(), name: name, folder: newID())
        l.append(e)
        saveRegistry(l)
        openWorkspace(at: directory(for: e))
        return e
    }

    func switchWorkspace(_ id: String) {
        guard let e = workspaceRegistry().first(where: { $0.id == id }), e.id != currentWorkspaceEntry?.id else { return }
        openWorkspace(at: directory(for: e))
        activeCanvas?.hud.flash("Opened “\(e.name)”")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace.flush()
        if case .failed(let r) = workspace.saveState {
            let a = NSAlert()
            a.messageText = "Some changes are not saved"
            a.informativeText = "Saving failed: \(r). You can export the unsaved workspace before leaving."
            a.addButton(withTitle: "Export…")
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Quit without saving")
            switch a.runModal() {
            case .alertFirstButtonReturn: exportWorkspace(nil); return .terminateCancel
            case .alertSecondButtonReturn: return .terminateCancel
            default: break
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ n: Notification) {
        for c in canvases { personalViewChanged(c, force: true) }
        runtime.shutdown()
        collab?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func loadIdentity() -> Identity {
        let url = dataDir.appendingPathComponent("identity.json")
        if let d = try? Data(contentsOf: url), let i = try? JSONDecoder().decode(Identity.self, from: d) { return i }
        let name = ProcessInfo.processInfo.environment["CANVAS_USER_NAME"] ?? (profile == "default" ? NSFullUserName() : profile.capitalized)
        let i = Identity(id: newID(), name: name)
        try? JSONEncoder().encode(i).write(to: url, options: .atomic)
        return i
    }

    // MARK: Windows (one camera per display)

    func buildWindows() {
        for w in windows { w.orderOut(nil) }
        windows = []
        canvases = []
        let screens = windowed ? [NSScreen.main!] : NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "\(i)"
            let frame: NSRect
            let style: NSWindow.StyleMask
            if windowed {
                let v = screen.visibleFrame
                frame = NSRect(x: v.minX + 60, y: v.minY + 60, width: min(1280, v.width - 120), height: min(820, v.height - 120))
                style = [.titled, .closable, .resizable, .miniaturizable]
            } else {
                frame = screen.visibleFrame
                style = [.borderless]
            }
            let w = CanvasWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            w.title = "Canvas Workspace"
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.managed, .fullScreenNone]
            w.acceptsMouseMovedEvents = true
            w.delegate = self
            w.setFrame(frame, display: false)
            let pv = session.store.record("view", viewKey(displayID), as: PersonalView.self)
            let cv = CanvasView(app: self, frame: NSRect(origin: .zero, size: frame.size), displayID: displayID, view: pv)
            cv.autoresizingMask = [.width, .height]
            w.contentView = cv
            cv.renderer.sync(workspace)
            cv.renderer.refreshDetail(workspace)
            windows.append(w)
            canvases.append(cv)
            // `--background` keeps development runs behind the user's windows without taking focus.
            if CommandLine.arguments.contains("--background") { w.orderBack(nil) } else { w.makeKeyAndOrderFront(nil) }
            w.makeFirstResponder(cv)
        }
    }

    @objc func screensChanged() {
        guard !windowed else { return }
        for c in canvases { personalViewChanged(c, force: true) }
        buildWindows()
        runtime.recoverWindowsOntoDisplays(silent: true)
    }

    func viewKey(_ display: String) -> String { "\(identity.id)|\(display)" }

    private var viewSaveTimers: [String: Timer] = [:]

    func personalViewChanged(_ c: CanvasView, force: Bool = false) {
        let save = { [weak self, weak c] in
            guard let self, let c else { return }
            let pv = PersonalView(centerX: c.camera.center.x, centerY: c.camera.center.y, zoom: c.camera.zoom,
                                  back: c.cameraBack.suffix(20).map { [$0.center.x, $0.center.y, $0.zoom] })
            try? self.session.store.putRecord("view", self.viewKey(c.displayID), pv)
        }
        viewSaveTimers[c.displayID]?.invalidate()
        if force { save(); return }
        viewSaveTimers[c.displayID] = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in save() }
    }

    // MARK: Model notifications

    func workspaceChanged(_ ids: Set<ObjectID>) {
        for c in canvases { c.workspaceChanged(ids) }
        runtime.objectsChanged(ids)
        inspector?.refresh()
    }

    func saveStateChanged(_ s: SaveState) {
        for c in canvases { c.hud.update() }
        saveRetry?.invalidate()
        if case .failed = s {
            saveRetry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.workspace.flush() }
        }
    }

    func selectionChanged(_ c: CanvasView) { inspector?.refresh() }

    func report(_ error: Error) {
        Diagnostics.record("error", "\(error)")
        activeCanvas?.hud.flash("\(error)", seconds: 5)
    }

    // MARK: Host command and exit

    /// Configurable global host command (default ⌃⌥Space): return input to the canvas.
    func hostCommand() {
        if let id = collab?.controlledObject {
            collab?.releaseControl(id)
            activeCanvas?.hud.flash("Released control of the remote application")
        } else if runtime.activeObject != nil {
            runtime.deactivate(capture: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            activeCanvas?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc func hostCommandAction() { hostCommand() }
    @objc func emergencyReclaimAction() { emergencyReclaim() }

    /// Global capture command: the active surface, else the frontmost window of the frontmost app.
    @objc func globalCapture() {
        guard let c = activeCanvas else { return }
        if let id = runtime.activeObject { capture.captureObject(id, region: nil, in: c); return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let w = NativeWindows.list(onScreenOnly: true).first(where: { $0.pid == front.processIdentifier }) else {
            if let sel = c.selection.first(where: { [.app, .browser].contains(workspace.object($0)?.kind) }) { capture.captureObject(sel, region: nil, in: c) }
            else { c.hud.flash("Nothing to capture: activate an application or select a window surface") }
            return
        }
        capture.captureLooseWindow(w, in: c)
    }

    /// Emergency host shortcut (⌃⌥⌘R): reclaim control of any shared application.
    func emergencyReclaim() {
        collab?.reclaimAll(reason: "Host emergency shortcut")
        hostCommand()
    }

    @objc func exitToDesktop(_ sender: Any?) {
        runtime.restoreForExit()
        workspace.flush()
        for c in canvases { personalViewChanged(c, force: true) }
        NSApp.terminate(nil)
    }

    @objc func hideCanvas(_ sender: Any?) {
        runtime.deactivate(capture: true)
        NSApp.hide(nil)
    }

    // MARK: Actions used by views

    func applyScopeRules(ids: [ObjectID], newParent: ObjectID?) throws {
        guard let p = newParent, let f = workspace.object(p), f.scope != Scope.privateID else { return }
        // Native material joins the shared scope; files and app surfaces share only a preview.
        let movable = workspace.movingSet(ids).filter { workspace.object($0)?.scope == Scope.privateID }
        try workspace.moveToScope(movable, scope: f.scope)
        collab?.publishAssets(for: movable)
    }

    func capture(objectID: ObjectID, in c: CanvasView) {
        capture.captureObject(objectID, region: nil, in: c)
    }

    func captureRegion(objectID: ObjectID, viewRect: CGRect, in c: CanvasView) {
        guard let o = workspace.object(objectID) else { return }
        let content = runtime.contentRect(of: o)
        let r = c.camera.toView(content)
        let norm = CGRect(x: (viewRect.minX - r.minX) / r.width, y: (viewRect.minY - r.minY) / r.height,
                          width: viewRect.width / r.width, height: viewRect.height / r.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !norm.isNull, norm.width > 0.001, norm.height > 0.001 else { c.hud.flash("The region is outside the surface"); return }
        if o.kind == .image { capture.cropImage(objectID, normalized: norm, in: c) }
        else { capture.captureObject(objectID, region: norm, in: c) }
    }

    func createLiveView(of id: ObjectID, in c: CanvasView) { capture.createLiveView(of: id, in: c) }
    func freeze(_ id: ObjectID, in c: CanvasView) { capture.freeze(id, in: c) }

    func revealSource(of id: ObjectID, in c: CanvasView) {
        guard let o = workspace.object(id) else { return }
        if let target = workspace.live.first(where: { $0.id != id && ($0.id == o.props.liveOf || (o.props.sourceID != nil && $0.props.sourceID == o.props.sourceID && [.app, .browser, .file].contains($0.kind))) }) {
            c.reveal(target.id)
        } else {
            c.hud.flash("The source is not on this canvas. Use Open source to reopen it.")
        }
    }

    func openSource(of id: ObjectID, in c: CanvasView) {
        guard let o = workspace.object(id) else { return }
        if let target = workspace.live.first(where: { $0.id != id && o.props.sourceID != nil && $0.props.sourceID == o.props.sourceID && [.app, .browser].contains($0.kind) }) {
            runtime.activate(target.id, in: c)
        } else if let s = session.source(o.props.sourceID) {
            if let p = s.documentPath ?? s.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
            else if let u = s.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
            else { c.hud.flash("No reopenable source was recorded for this capture") }
        } else if let u = o.props.url.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(u)
        } else {
            c.hud.flash("No source was recorded for this image")
        }
    }

    func nameCurrentPlace(_ c: CanvasView) {
        let a = NSAlert()
        a.messageText = "Name this place"
        let tf = NSTextField(string: "")
        tf.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty else { return }
        let p = NamedPlace(name: tf.stringValue, rect: c.camera.visibleWorld)
        try? workspace.setPlace(p, id: p.id)
    }

    func shareFrame(_ id: ObjectID, in c: CanvasView) { collab?.shareFrame(id, from: c) }
    func unshare(ids: [ObjectID], in c: CanvasView) { collab?.unshare(ids, from: c) }

    func inspect(_ id: ObjectID?, in c: CanvasView) {
        if inspector == nil { inspector = InspectorPanel(app: self) }
        inspector?.show(for: c)
    }

    @objc func toggleInspector(_ s: Any?) {
        if let i = inspector, i.panel.isVisible { i.panel.orderOut(nil) } else if let c = activeCanvas { inspect(nil, in: c) }
    }

    @objc func showHistory(_ s: Any?) {
        if history == nil { history = HistoryPanel(app: self) }
        let sel = activeCanvas?.selection.first.flatMap { workspace.object($0)?.scope } ?? Scope.privateID
        history?.show(scope: sel)
    }

    @objc func showSearch(_ s: Any?) {
        if search == nil { search = SearchPanel(app: self) }
        if let c = activeCanvas { search?.show(in: c) }
    }

    @objc func importFile(_ s: Any?) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "Choose files to place on the canvas as references"
        guard p.runModal() == .OK, let c = activeCanvas else { return }
        let center = c.camera.visibleWorld.center
        files.placeFiles(p.urls, at: center, in: c)
    }

    @objc func admitWindow(_ s: Any?) {
        guard let c = activeCanvas else { return }
        runtime.showAdmission(in: c)
    }

    @objc func addWebPage(_ s: Any?) {
        guard let c = activeCanvas else { return }
        browsers.promptForPage(in: c)
    }

    @objc func recoverWindows(_ s: Any?) { runtime.recoverWindowsOntoDisplays(silent: false) }

    @objc func exportWorkspace(_ s: Any?) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Workspace export.canvasworkspace"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (id, s) in workspace.scopes { try s.doc.save().write(to: url.appendingPathComponent("\(id).automerge")) }
            let assets = Set(workspace.live.compactMap { $0.props.assetID } + workspace.live.compactMap { $0.props.previewAssetID })
            let ad = url.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: ad, withIntermediateDirectories: true)
            for a in assets { if let d = session.store.assetData(a) { try d.write(to: ad.appendingPathComponent(a)) } }
            activeCanvas?.hud.flash("Exported the workspace, including unsaved changes held in memory")
        } catch { report(error) }
    }

    @objc func simulateStorageFailure(_ s: NSMenuItem) {
        let on = session.store.injectedFailure == nil
        session.store.injectedFailure = on ? .chunks : nil
        s.state = on ? .on : .off
        activeCanvas?.hud.flash(on ? "Storage failure simulation on: saves will fail" : "Storage failure simulation off")
        if !on { workspace.flush() }
    }

    @objc func simulateAssetFailure(_ s: NSMenuItem) {
        let on = session.store.injectedFailure != .assets
        session.store.injectedFailure = on ? .assets : nil
        s.state = on ? .on : .off
        activeCanvas?.hud.flash(on ? "Asset write failure simulation on" : "Asset write failure simulation off")
        if !on { workspace.flush() }
    }

    @objc func goToPlace(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let p = workspace.places().first(where: { $0.id == id }), let c = activeCanvas else { return }
        var cam = c.camera
        cam.fit(p.rect, margin: 0, maxZoom: 16)
        c.setCamera(cam)
    }

    @objc func showGuide(_ s: Any?) {
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/USER-GUIDE.md")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(string: "https://github.com/pengw0048/canvas-workspace/blob/main/docs/USER-GUIDE.md")!) }
    }

    // MARK: Menus

    func workspaceMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.sub("Workspaces") { wm in
            for e in self.workspaceRegistry() {
                let i = ActionItem(e.name) { self.switchWorkspace(e.id) }
                i.state = e.id == self.currentWorkspaceEntry?.id ? .on : .off
                wm.addItem(i)
            }
            wm.addItem(.separator())
            wm.add("New Workspace…") { self.newWorkspace() }
        }
        m.add("Search…  ⌘F") { self.showSearch(nil) }
        m.add("Back  ⌘[") { self.activeCanvas?.navigateBack() }
        m.add("Fit all  ⇧1") { self.activeCanvas?.fitAll() }
        let places = workspace.places()
        if !places.isEmpty {
            m.sub("Places") { pm in
                for p in places.sorted(by: { $0.name < $1.name }) {
                    let i = NSMenuItem(title: p.name, action: #selector(goToPlace(_:)), keyEquivalent: "")
                    i.target = self
                    i.representedObject = p.id
                    pm.addItem(i)
                }
            }
        }
        m.add("Name this place…") { if let c = self.activeCanvas { self.nameCurrentPlace(c) } }
        m.addItem(.separator())
        m.add("Bring in an application window…") { self.admitWindow(nil) }
        m.add("Import file or image…") { self.importFile(nil) }
        m.add("Add a web page…") { self.addWebPage(nil) }
        m.addItem(.separator())
        m.add("Collaboration…") { self.collab?.showPanel() }
        m.add("Inspector") { self.toggleInspector(nil) }
        m.add("History…") { self.showHistory(nil) }
        m.add("Bring managed windows onto a display") { self.recoverWindows(nil) }
        m.add("Export workspace…") { self.exportWorkspace(nil) }
        m.add("Export diagnostics…") { Diagnostics.export(app: self) }
        m.addItem(.separator())
        m.add("Hide canvas (apps keep running)") { self.hideCanvas(nil) }
        m.add("Exit to desktop") { self.exitToDesktop(nil) }
        return m
    }

    func buildMenu() {
        let main = NSMenu()
        func top(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            build(m)
            item.submenu = m
            main.addItem(item)
        }
        func item(_ m: NSMenu, _ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.target = target
            m.addItem(i)
        }
        top("Canvas Workspace") { m in
            item(m, "About Canvas Workspace", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            item(m, "Hide Canvas", #selector(hideCanvas(_:)), "h", target: self)
            item(m, "Exit to Desktop", #selector(exitToDesktop(_:)), "q", target: self)
        }
        top("File") { m in
            item(m, "Import File or Image…", #selector(importFile(_:)), "o", target: self)
            item(m, "Bring In Application Window…", #selector(admitWindow(_:)), "n", [.command, .shift], target: self)
            item(m, "Add Web Page…", #selector(addWebPage(_:)), "l", [.command, .shift], target: self)
            m.addItem(.separator())
            item(m, "Export Workspace…", #selector(exportWorkspace(_:)), "e", [.command, .shift], target: self)
        }
        top("Edit") { m in
            item(m, "Undo", #selector(CanvasView.undo(_:)), "z")
            item(m, "Redo", #selector(CanvasView.redo(_:)), "z", [.command, .shift])
            m.addItem(.separator())
            item(m, "Cut", #selector(NSText.cut(_:)), "x")
            item(m, "Copy", #selector(NSText.copy(_:)), "c")
            item(m, "Paste", #selector(NSText.paste(_:)), "v")
            item(m, "Duplicate", #selector(CanvasView.duplicate(_:)), "d")
            item(m, "Delete", #selector(NSText.delete(_:)), "")
            item(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            item(m, "Group", #selector(CanvasView.groupSelection(_:)), "g")
            item(m, "Ungroup", #selector(CanvasView.ungroupSelection(_:)), "g", [.command, .shift])
            item(m, "Capture", #selector(CanvasView.captureSelection(_:)), "c", [.command, .shift])
            m.addItem(.separator())
            item(m, "Find…", #selector(showSearch(_:)), "f", target: self)
        }
        top("Format") { m in
            let b = NSMenuItem(title: "Bold", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b")
            b.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
            b.target = NSFontManager.shared
            m.addItem(b)
            let i = NSMenuItem(title: "Italic", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i")
            i.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
            i.target = NSFontManager.shared
            m.addItem(i)
            item(m, "Add Link…", #selector(CanvasView.addLink(_:)), "k")
        }
        top("View") { m in
            item(m, "Zoom In", #selector(CanvasView.zoomIn(_:)), "=")
            item(m, "Zoom Out", #selector(CanvasView.zoomOut(_:)), "-")
            item(m, "Actual Size", #selector(CanvasView.zoomActual(_:)), "0")
            item(m, "Fit All", #selector(CanvasView.fitAllAction(_:)), "1", [.shift])
            item(m, "Fit Selection", #selector(CanvasView.fitSelectionAction(_:)), "2", [.shift])
            item(m, "Back", #selector(CanvasView.backAction(_:)), "[", [.command, .option])
            m.addItem(.separator())
            item(m, "Inspector", #selector(toggleInspector(_:)), "i", [.command, .option], target: self)
            item(m, "Workspace History…", #selector(showHistory(_:)), "y", [.command, .shift], target: self)
            item(m, "Collaboration…", #selector(Collaboration.showPanelAction(_:)), "k", [.command, .shift], target: collab)
        }
        top("Window") { m in
            item(m, "Bring Managed Windows onto a Display", #selector(recoverWindows(_:)), "", target: self)
            item(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        }
        top("Debug") { m in
            item(m, "Simulate Storage Failure", #selector(simulateStorageFailure(_:)), "", target: self)
            item(m, "Simulate Asset Write Failure", #selector(simulateAssetFailure(_:)), "", target: self)
        }
        top("Help") { m in
            item(m, "Canvas Workspace Guide", #selector(showGuide(_:)), "?", target: self)
        }
        NSApp.mainMenu = main
    }
}

/// Carbon global hot keys; no Accessibility permission is needed.
final class HotKeys {
    var handlers: [UInt32: () -> Void] = [:]
    var refs: [EventHotKeyRef] = []
    var nextID: UInt32 = 1
    static var shared: HotKeys?

    init() {
        HotKeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.shared?.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, _ h: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4357_534B), id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Hot key registration failed (%d); another app may own this shortcut", status)
            return false
        }
        refs.append(ref)
        handlers[id] = h
        return true
    }
}

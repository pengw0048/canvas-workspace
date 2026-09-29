import AppKit
import Automerge
import CanvasCore

/// Local test-automation socket (`<data dir>/automation.sock`), enabled with `--automation`.
/// Each line is a command; each reply is one JSON line. Used to gather acceptance evidence.
final class Automation {
    unowned let app: AppController
    let path: String
    var fd: Int32 = -1
    var savedHeads: [ObjectID: Set<ChangeHash>] = [:]

    init(app: AppController) {
        self.app = app
        let preferred = app.dataDir.appendingPathComponent("automation.sock").path
        // Unix socket paths are limited to 104 bytes.
        path = ProcessInfo.processInfo.environment["CANVAS_AUTOMATION_SOCKET"]
            ?? (preferred.utf8.count < 100 ? preferred : NSTemporaryDirectory() + "cw-\(app.profile).sock")
        NSLog("Automation socket: %@", path)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { p in path.withCString { strncpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count - 1) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(fd, 4) == 0 else { NSLog("automation socket failed"); return }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }

    func serve(_ c: Int32) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            while let nl = buf.firstIndex(of: 10) {
                let line = String(data: buf[buf.startIndex..<nl], encoding: .utf8) ?? ""
                buf = buf[(nl + 1)...]
                var reply = ""
                DispatchQueue.main.sync { reply = self.handle(line) }
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
            }
        }
        close(c)
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func objJSON(_ o: CanvasObject) -> [String: Any] {
        var d: [String: Any] = ["id": o.id, "kind": o.kind.rawValue, "x": o.geom.x, "y": o.geom.y, "w": o.geom.w, "h": o.geom.h,
                                "rotation": o.geom.rotation, "z": o.z, "scope": o.scope, "text": o.text, "title": o.title]
        if let p = o.parent { d["parent"] = p }
        if let g = o.group { d["group"] = g }
        d["props"] = o.props.fieldMap()
        if let st = app.runtime.status(for: o) { d["status"] = st.text }
        return d
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return json(["error": "empty"]) }
        let arg = parts.count > 1 ? parts[1] : ""
        let args = arg.split(separator: " ").map(String.init)
        let ws = app.workspace
        guard let c = app.activeCanvas else { return json(["error": "no canvas"]) }
        do {
            switch cmd {
            case "state":
                return json(["objects": ws.live.map(objJSON), "selection": Array(c.selection), "camera": [c.camera.center.x, c.camera.center.y, c.camera.zoom],
                             "save": ws.saveState.label, "pending": ws.pendingChanges.count, "active": app.runtime.activeObject ?? "",
                             "input": app.runtime.inputOwnerText, "bindings": app.runtime.bindings.mapValues { "\($0.pid):\($0.windowID)" },
                             "undo": ws.undoStack.map(\.name), "scopes": Array(ws.scopes.keys), "collab": app.collab?.statusText ?? "",
                             "presence": app.collab?.presence.values.map(\.name) ?? [], "controlled": app.collab?.controlledObject ?? "",
                             "ax": NativeWindows.axTrusted, "screenRecording": NativeWindows.screenCaptureAllowed])
            case "create":
                let d = try JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any] ?? [:]
                let kind = ObjectKind(rawValue: d["kind"] as? String ?? "sticky") ?? .sticky
                var o = CanvasObject(kind: kind, geom: Geometry(x: d["x"] as? Double ?? 0, y: d["y"] as? Double ?? 0, w: d["w"] as? Double ?? 200, h: d["h"] as? Double ?? 200,
                                                               rotation: d["rotation"] as? Double ?? 0), text: d["text"] as? String ?? "")
                if let p = d["props"] as? [String: Any] {
                    var m: [String: String] = [:]
                    for (k, v) in p { if let s = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed) { m[k] = String(data: s, encoding: .utf8) } }
                    o.props = ObjectProps(fieldMap: m)
                }
                if let p = d["parent"] as? String { o.parent = p }
                if let s = d["scope"] as? String { o.scope = s }
                let id = try ws.create(o)
                return json(["id": id])
            case "select":
                c.selection = Set(args.filter { ws.object($0) != nil })
                return json(["selection": Array(c.selection)])
            case "copy":
                let mode: CopyMode = ["image": .image, "text": .text, "link": .link][args.first ?? ""] ?? .standard
                app.pasteboard.copy(ids: Array(c.selection), mode: mode)
                return json(["types": PasteboardService.board.types?.map(\.rawValue) ?? []])
            case "paste":
                if args.count == 2, let x = Double(args[0]), let y = Double(args[1]) { c.lastPointerWorld = WPoint(x: x, y: y); c.lastPointerTime = Date() }
                let before = Set(ws.live.map(\.id))
                app.pasteboard.paste(into: c)
                return json(["created": ws.live.map(\.id).filter { !before.contains($0) }])
            case "pbrtf":
                guard let d = PasteboardService.board.data(forType: .rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil) else { return json(["error": "no rtf"]) }
                return json(["marks": RichText.marks(from: a).map { "\($0.name):\($0.start)-\($0.end)" }, "html": PasteboardService.board.data(forType: .html) != nil])
            case "marks":
                let sp = arg.split(separator: " ", maxSplits: 1).map(String.init)
                let ms = try JSONDecoder().decode([TextMark].self, from: Data(sp[1].utf8))
                try ws.setMarks(sp[0], ms)
                return json(["marks": ws.object(sp[0])?.marks.map { "\($0.name):\($0.start)-\($0.end)" } ?? []])
            case "pbtypes":
                return json(["types": PasteboardService.board.types?.map(\.rawValue) ?? [], "string": PasteboardService.board.string(forType: .string) ?? ""])
            case "move":
                let rp: ObjectID?? = args.count > 3 ? .some(args[3] == "none" ? nil : args[3]) : nil
                try ws.move([args[0]], dx: Double(args[1]) ?? 0, dy: Double(args[2]) ?? 0, reparent: rp)
                if case .some(let p) = rp { try app.applyScopeRules(ids: [args[0]], newParent: p) }
                return json(["ok": true])
            case "geom":
                guard let o = ws.object(args[0]) else { return json(["error": "missing"]) }
                var g = o.geom
                g.x = Double(args[1]) ?? g.x; g.y = Double(args[2]) ?? g.y; g.w = Double(args[3]) ?? g.w; g.h = Double(args[4]) ?? g.h
                try ws.setGeometry(o.id, g)
                return json(["ok": true])
            case "text":
                let sp = arg.split(separator: " ", maxSplits: 1).map(String.init)
                try ws.perform("Edit text") { $0.update(sp[0]) { $0.text = sp.count > 1 ? sp[1] : "" } }
                return json(["ok": true])
            case "splice":
                // splice <id> <start> <delete> <text…> against the heads captured by `base <id>`.
                let sp = arg.split(separator: " ", maxSplits: 3).map(String.init)
                guard let o = ws.object(sp[0]) else { return json(["error": "missing"]) }
                try ws.spliceText(o.id, baseHeads: savedHeads[o.id] ?? ws.heads(o.scope), start: Int(sp[1]) ?? 0, delete: Int(sp[2]) ?? 0, insert: sp.count > 3 ? sp[3] : "")
                return json(["text": ws.object(o.id)?.text ?? ""])
            case "base":
                guard let o = ws.object(args[0]) else { return json(["error": "missing"]) }
                savedHeads[o.id] = ws.heads(o.scope)
                return json(["text": o.text])
            case "undo": let r = try ws.undo(); return json(["name": r?.name ?? "", "conflicts": r?.conflicts ?? []])
            case "redo": let r = try ws.redo(); return json(["name": r?.name ?? ""])
            case "remove": try ws.removeFromCanvas(args); return json(["ok": true])
            case "duplicate": return json(["ids": try ws.duplicate(args)])
            case "group": return json(["id": try ws.group(args) ?? ""])
            case "tidy": try ws.tidy(args); return json(["ok": true])
            case "align": try ws.align(Array(args.dropFirst()), AlignEdge(rawValue: args[0]) ?? .left); return json(["ok": true])
            case "front": try ws.bringToFront(args); return json(["ok": true])
            case "camera":
                c.camera.center = WPoint(x: Double(args[0]) ?? 0, y: Double(args[1]) ?? 0)
                c.camera.zoom = Double(args[2]) ?? 1
                c.applyCamera()
                c.renderer.refreshDetail(ws)
                return json(["ok": true])
            case "fit": c.cameraAnimation?.invalidate(); var cam = c.camera; cam.fit(WRect.union(ws.live.map(\.geom.bounds)) ?? cam.visibleWorld); c.camera = cam; c.applyCamera(); c.renderer.refreshDetail(ws); return json(["ok": true])
            case "hit":
                let hits = ws.hitTest(WPoint(x: Double(args[0]) ?? 0, y: Double(args[1]) ?? 0), zoom: c.camera.zoom)
                return json(["hits": hits.map(\.id)])
            case "snapshot":
                c.renderer.refreshDetail(ws)
                CATransaction.flush()
                guard let png = c.snapshotPNG() else { return json(["error": "snapshot failed"]) }
                try png.write(to: URL(fileURLWithPath: arg))
                return json(["path": arg])
            case "render":
                // Offscreen composition render of the given IDs, as used by copy.
                guard let img = app.pasteboard.renderComposition(Array(args.dropFirst())), let png = pngData(img, maxPixels: 60_000_000) else { return json(["error": "render failed"]) }
                try png.write(to: URL(fileURLWithPath: args[0]))
                return json(["path": args[0], "size": [img.width, img.height]])
            case "windows":
                return json(["windows": NativeWindows.list(onScreenOnly: true).map { ["id": $0.windowID, "pid": $0.pid, "owner": $0.ownerName, "title": $0.title ?? "", "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }])
            case "admit":
                guard let wid = UInt32(args[0]), let w = NativeWindows.list().first(where: { $0.windowID == wid }) else { return json(["error": "no such window"]) }
                let at = args.count >= 3 ? WPoint(x: Double(args[1]) ?? 0, y: Double(args[2]) ?? 0) : c.camera.visibleWorld.center
                return json(["id": app.runtime.admit(w, at: at, in: c) ?? ""])
            case "activate":
                c.activateOrEdit(args[0])
                return json(["active": app.runtime.activeObject ?? ""])
            case "deactivate":
                app.runtime.deactivate(capture: true)
                return json(["ok": true])
            case "reconnect":
                app.runtime.reconnect(args[0], in: c)
                return json(["state": "\(app.runtime.state[args[0]] ?? .none)"])
            case "capture":
                let region = args.count == 5 ? CGRect(x: Double(args[1])!, y: Double(args[2])!, width: Double(args[3])!, height: Double(args[4])!) : nil
                app.capture.captureObject(args[0], region: region, in: c)
                return json(["ok": true])
            case "live":
                app.runtime.toggleLive(args[0])
                return json(["live": app.runtime.isLive(args[0])])
            case "liveview":
                app.createLiveView(of: args[0], in: c)
                return json(["selection": Array(c.selection)])
            case "freeze":
                app.freeze(args[0], in: c)
                return json(["ok": true])
            case "files":
                let urls = args.map { URL(fileURLWithPath: $0) }
                return json(["ids": app.files.placeFiles(urls, at: c.camera.visibleWorld.center, in: c)])
            case "page":
                let m = BrowserMode(rawValue: args.count > 1 ? args[1] : "reference") ?? .reference
                return json(["id": app.browsers.createPage(URL(string: args[0])!, mode: m, at: c.camera.visibleWorld.center, in: c) ?? ""])
            case "fail":
                app.session.store.injectedFailure = args.first.flatMap(StorageFailure.init(rawValue:))
                if app.session.store.injectedFailure == nil { ws.flush() }
                return json(["failure": args.first ?? "none", "save": ws.saveState.label])
            case "share":
                guard let f = ws.object(args[0]), f.kind == .frame else { return json(["error": "not a frame"]) }
                // Non-interactive share for automation: same steps as the confirmed dialog.
                let sid = "share-" + newID()
                let doc = ScopeDocument(id: sid)
                try doc.initializeSchema(title: f.title)
                doc.commit("init")
                try app.session.attachScope(doc)
                let members = [f.id] + ws.descendants(of: f.id)
                try app.collab?.publishPreviews(for: members.compactMap { ws.object($0) })
                try ws.moveToScope(members, scope: sid)
                let code = args.count > 1 ? args[1] : Collaboration.makeInviteCode()
                app.collab?.shares[sid] = ShareInfo(scopeID: sid, title: f.title, hosted: true, inviteCode: code)
                app.collab?.saveShare(sid)
                app.collab?.startHosting()
                return json(["scope": sid, "code": code])
            case "port":
                return json(["port": app.collab?.listenPort ?? 0])
            case "join":
                app.collab?.connect(to: ShareInfo(scopeID: "pending", title: "Joining", hosted: false, inviteCode: args[0], hostEndpoint: args[1]))
                return json(["ok": true])
            case "follow":
                c.followUser = args.first
                c.hud.update()
                return json(["ok": true])
            case "requestcontrol":
                app.collab?.requestControl(args[0], from: c)
                return json(["ok": true])
            case "grant":
                // Automation stands in for the host clicking Grant.
                guard let collab = app.collab else { return json(["error": "no collab"]) }
                var arb = collab.arbiters[args[0]] ?? ControlArbiter()
                let (g, rel) = arb.grant(to: args[1])
                collab.arbiters[args[0]] = arb
                collab.releaseHeld(rel, object: args[0])
                collab.send(to: args[1], WireMessage("control-granted", ["o": args[0], "g": "\(g)"]))
                collab.broadcast(WireMessage("control-state", ["o": args[0], "user": args[1]]))
                return json(["generation": g])
            case "reclaim":
                app.collab?.reclaim(args[0], reason: "Host reclaimed control")
                return json(["ok": true])
            case "input":
                // input <objectID> <kind> <x> <y> [text]
                var e = RemoteInputEvent(kind: RemoteInputEvent.Kind(rawValue: args[1]) ?? .move)
                e.x = Double(args[2]) ?? 0; e.y = Double(args[3]) ?? 0
                if args.count > 4 { e.text = args[4...].joined(separator: " ") }
                app.collab?.sendInput(e, to: args[0])
                return json(["ok": true])
            case "rawinput":
                // rawinput <objectID> <generation> <seq> <kind> — sends an arbitrary (possibly stale) event.
                var e = RemoteInputEvent(kind: RemoteInputEvent.Kind(rawValue: args[3]) ?? .move)
                e.x = 0.5; e.y = 0.5
                app.collab?.upstream?.send(WireMessage("input", ["o": args[0], "g": args[1], "seq": args[2]], payload: (try? JSONEncoder().encode(e)) ?? Data()))
                return json(["ok": true])
            case "arbiter":
                guard let a = app.collab?.arbiters[args[0]] else { return json(["controller": ""]) }
                return json(["controller": a.controller ?? "", "generation": a.generation, "lastSeq": a.lastSeq])
            case "winid":
                return json(["id": c.window?.windowNumber ?? 0])
            case "assetreq":
                app.collab?.upstream?.send(WireMessage("asset-request", ["id": args[0]]))
                return json(["ok": true])
            case "hasasset":
                return json(["durable": app.session.store.isAssetDurable(args[0])])
            case "js":
                let sp = arg.split(separator: " ", maxSplits: 1).map(String.init)
                guard let v = app.browsers.webView(for: sp[0]) else { return json(["error": "no web view"]) }
                var result = ""
                var done = false
                v.evaluateJavaScript(sp[1]) { r, e in result = "\(r ?? e.map { "\($0)" } ?? "nil")"; done = true }
                let until = Date().addingTimeInterval(3)
                while !done && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                return json(["result": result])
            case "removemember":
                app.collab?.removeMember(args[0])
                return json(["ok": true])
            case "focus":
                NSApp.activate(ignoringOtherApps: true)
                c.window?.makeKeyAndOrderFront(nil)
                return json(["ok": true])
            case "screen":
                // World point → global screen point (top-left origin) for input drivers.
                let vp = c.camera.toView(WPoint(x: Double(args[0]) ?? 0, y: Double(args[1]) ?? 0))
                let sp = c.window!.convertPoint(toScreen: c.convert(vp, to: nil))
                return json(["x": sp.x, "y": NativeWindows.primaryHeight - sp.y])
            case "grip":
                guard let o = ws.object(args[0]) else { return json(["error": "missing"]) }
                let g = c.exportGrip(o)
                let sp = c.window!.convertPoint(toScreen: c.convert(CGPoint(x: g.midX, y: g.midY), to: nil))
                return json(["x": sp.x, "y": NativeWindows.primaryHeight - sp.y])
            case "bindwin":
                // Stands in for the user's choice in the "Several windows could match" dialog.
                guard let w = NativeWindows.window(UInt32(args[1]) ?? 0) else { return json(["error": "no window"]) }
                app.runtime.bind(args[0], to: w, verifiedBy: "chosen by you")
                return json(["bindings": app.runtime.bindings.mapValues { "\($0.pid):\($0.windowID)" }])
            case "populate":
                // §14 profile: 500 mixed objects, 50 of them with stored 1600×1000 previews.
                let n = Int(args.first ?? "500") ?? 500
                var staged: [StagedAsset] = []
                var objs: [CanvasObject] = []
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                for i in 0..<n {
                    let x = Double(i % 25) * 420, y = Double(i / 25) * 340
                    var o: CanvasObject
                    switch i % 10 {
                    case 0:
                        let ctx = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        ctx.setFillColor(CGColor(red: Double(i % 7) / 7, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
                        ctx.setFillColor(.white); for k in 0..<40 { ctx.fill(CGRect(x: 40, y: 40 + k * 22, width: 800 + ((k * 37 + i * 13) % 600), height: 12)) }
                        let png = pngData(ctx.makeImage()!, maxPixels: 2_000_000)!
                        let a = try app.session.store.stageAsset(png, mime: "image/png", width: 1600, height: 1000)
                        staged.append(a)
                        o = CanvasObject(kind: .image, geom: Geometry(x: x, y: y, w: 380, h: 240)); o.props.assetID = a.id
                    case 1, 2, 3: o = CanvasObject(kind: .sticky, geom: Geometry(x: x, y: y, w: 200, h: 200), text: "Note \(i): a representative sticky with several words of text"); o.props.color = "#FFE58A"
                    case 4, 5: o = CanvasObject(kind: .text, geom: Geometry(x: x, y: y, w: 360, h: 60), text: "Text object \(i) with a sentence that wraps across lines"); o.props.fontSize = 20
                    case 6, 7: o = CanvasObject(kind: .shape, geom: Geometry(x: x, y: y, w: 300, h: 180, rotation: Double(i % 5) * 0.1), text: "Shape \(i)"); o.props.shape = i % 2 == 0 ? .rect : .ellipse; o.props.strokeWidth = 2; o.props.color = "#1E1E1E"
                    default:
                        var pts: [Double] = []; for k in 0..<60 { pts += [Double(k) * 5, 60 + 50 * sin(Double(k + i) / 6)] }
                        o = CanvasObject(kind: .ink, geom: Geometry(x: x, y: y, w: 300, h: 120)); o.props.inkPoints = pts; o.props.logicalSize = [300, 120]; o.props.strokeWidth = 3; o.props.color = "#0B84F3"
                    }
                    o.z = FractionalIndex.between(objs.last?.z, nil)
                    objs.append(o)
                }
                let t0 = Date()
                try ws.perform("Populate", assets: staged, recordUndo: false) { tx in for o in objs { tx.create(o) } }
                return json(["created": objs.count, "seconds": Date().timeIntervalSince(t0)])
            case "rss":
                return json(["rss_mb": Double(Self.residentBytes()) / 1_048_576])
            case "bench":
                // Main-thread cost per camera frame (update + layer commit), not display frame time.
                let frames = Int(args.first ?? "300") ?? 300
                var times: [Double] = []
                let start = c.camera
                for f in 0..<frames {
                    let t = Double(f) / Double(frames)
                    let t0 = CACurrentMediaTime()
                    c.camera.center = WPoint(x: 5000 * t, y: 2000 * sin(t * .pi * 2))
                    c.camera.zoom = 0.15 + 1.2 * (0.5 + 0.5 * sin(t * .pi * 4))
                    c.applyCamera()
                    if f % 10 == 0 { c.renderer.refreshDetail(ws) }
                    CATransaction.flush()
                    times.append((CACurrentMediaTime() - t0) * 1000)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                }
                c.camera = start
                c.applyCamera()
                let sorted = times.sorted()
                func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                let t1 = CACurrentMediaTime(); c.renderer.refreshDetail(ws); CATransaction.flush()
                return json(["frames": frames, "p50_ms": pct(0.5), "p95_ms": pct(0.95), "max_ms": sorted.last ?? 0, "over_100ms": times.filter { $0 > 100 }.count,
                             "detail_refresh_ms": (CACurrentMediaTime() - t1) * 1000, "objects": ws.live.count,
                             "rss_mb": Double(Self.residentBytes()) / 1_048_576])
            case "history":
                app.showHistory(nil)
                let n = Int(args.first ?? "") ?? -1
                if n >= 0, let h = app.history { h.table.selectRowIndexes([n], byExtendingSelection: false) }
                return json(["entries": app.history?.entries.prefix(8).map { "\($0.name) @ \($0.time)" } ?? [], "info": app.history?.info.stringValue ?? ""])
            case "historyshot":
                guard let img = app.history?.preview.image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return json(["error": "no preview"]) }
                try png.write(to: URL(fileURLWithPath: arg))
                return json(["path": arg])
            case "historyrestore":
                app.history?.restore()
                return json(["ok": true])
            case "identity":
                return json(["id": app.identity.id, "name": app.identity.name])
            case "flush":
                ws.flush()
                return json(["save": ws.saveState.label])
            case "quit":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.app.exitToDesktop(nil) }
                return json(["ok": true])
            default:
                return json(["error": "unknown command \(cmd)"])
            }
        } catch {
            return json(["error": "\(error)"])
        }
    }
}

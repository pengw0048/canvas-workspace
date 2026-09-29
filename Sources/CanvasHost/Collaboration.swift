import AppKit
import Automerge
import CanvasCore
import CryptoKit
import Network

/// Local record of a shared scope this device hosts or joined.
struct ShareInfo: Codable {
    var scopeID: ScopeID
    var title: String
    var hosted: Bool
    var inviteCode: String?
    var hostEndpoint: String?
    var hostName: String?
    /// Host only: authorized member IDs and names.
    var members: [String: String] = [:]
    var revoked: [String] = []
    /// Host: members limited to viewing. Member: whether this device is view-only.
    var viewers: [String] = []
    var viewOnly: Bool = false
    var lastContact: Double?
    /// Host: this share's listening port, reused so members can reconnect to a stored address.
    var port: UInt16?

    init(scopeID: ScopeID, title: String, hosted: Bool, inviteCode: String? = nil, hostEndpoint: String? = nil) {
        self.scopeID = scopeID; self.title = title; self.hosted = hosted; self.inviteCode = inviteCode; self.hostEndpoint = hostEndpoint
    }

    /// Records written by earlier versions lack newer fields; missing fields take their defaults.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        scopeID = try c.decode(ScopeID.self, forKey: .scopeID)
        title = try c.decode(String.self, forKey: .title)
        hosted = try c.decode(Bool.self, forKey: .hosted)
        inviteCode = try c.decodeIfPresent(String.self, forKey: .inviteCode)
        hostEndpoint = try c.decodeIfPresent(String.self, forKey: .hostEndpoint)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        members = try c.decodeIfPresent([String: String].self, forKey: .members) ?? [:]
        revoked = try c.decodeIfPresent([String].self, forKey: .revoked) ?? []
        viewers = try c.decodeIfPresent([String].self, forKey: .viewers) ?? []
        viewOnly = try c.decodeIfPresent(Bool.self, forKey: .viewOnly) ?? false
        lastContact = try c.decodeIfPresent(Double.self, forKey: .lastContact)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port)
    }
}

struct Presence {
    var userID: String
    var name: String
    var color: NSColor
    var pointer: WPoint?
    var selection: [ObjectID]
    var camera: (Double, Double, Double)?
    var claims: [ObjectID: Date]
    var seen: Date
    var chat: String?
}

final class Peer {
    let conn: NWConnection
    var buffer = Data()
    var userID: String?
    var name: String?
    var scopes: Set<ScopeID> = []
    var viewOnly: Set<ScopeID> = []
    /// Host side: the share whose invite code (TLS key) this connection used.
    var hostedScope: ScopeID?
    var uploadedAssets: Set<AssetID> = []
    var sync: [ScopeID: SyncState] = [:]
    var pendingSends = 0
    var onMessage: ((Peer, WireMessage) -> Void)?
    var onClose: ((Peer) -> Void)?
    var closed = false

    init(_ c: NWConnection) { conn = c }

    func start(queue: DispatchQueue = .main) {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            do {
                for m in try WireMessage.decode(&self.buffer) { self.onMessage?(self, m) }
            } catch {
                Diagnostics.record("network", "closed a connection that sent a malformed message")
                self.close()
                return
            }
            if done || err != nil { self.close(); return }
            self.receive()
        }
    }

    func send(_ m: WireMessage) {
        guard !closed else { return }
        pendingSends += 1
        conn.send(content: m.encode(), completion: .contentProcessed { [weak self] _ in self?.pendingSends -= 1 })
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?(self)
    }
}

final class Collaboration: NSObject {
    unowned let app: AppController
    var shares: [ScopeID: ShareInfo] = [:]
    // Host side
    /// One listener per hosted share: its invite code is that share's key, so a code opens only its share.
    var listeners: [ScopeID: NWListener] = [:]
    var listenRetries = 0
    var listenPorts: [ScopeID: UInt16] = [:]
    var listenPort: UInt16? { listenPorts.values.min() }
    var peers: [Peer] = []
    var arbiters: [ObjectID: ControlArbiter] = [:]
    var liveShared: Set<ObjectID> = []
    var lastFrameSent: [ObjectID: Date] = [:]
    var lastInjection = Date.distantPast
    var reclaimTimer: Timer?
    // Participant side
    var upstream: Peer?
    var upstreamShare: ScopeID?
    var connecting = false
    var myGrants: [ObjectID: UInt64] = [:]
    var controllers: [ObjectID: String] = [:]
    var seqs: [ObjectID: UInt64] = [:]
    var remoteFrames: [ObjectID: (CGImage, Date)] = [:]
    var requestedAssets: Set<AssetID> = []
    // Both
    var presence: [String: Presence] = [:]
    var myColor = NSColor.systemPink

    static let palette: [NSColor] = [0xE5484D, 0x8E4EC6, 0x12A594, 0x3E63DD, 0xF76B15, 0xD6409F, 0x0090FF, 0x46A758].map {
        NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
    }

    /// A fixed sRGB color per person, the same in every process and on every launch.
    static func color(for userID: String) -> NSColor {
        let h = userID.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// When someone already present has the same color, the person with the larger ID moves to the next free color.
    func resolveColorClash() {
        let hex = { (c: NSColor) in c.usingColorSpace(.sRGB).map { "\(Int($0.redComponent * 255)),\(Int($0.greenComponent * 255)),\(Int($0.blueComponent * 255))" } ?? "" }
        let others = presence.values.filter { $0.userID != me }
        guard others.contains(where: { hex($0.color) == hex(myColor) && $0.userID < me }) else { return }
        let used = Set(others.map { hex($0.color) })
        guard let free = Self.palette.first(where: { !used.contains(hex($0)) }) else { return }
        myColor = free
        lastPresenceSent = .distantPast
        if let c = app.activeCanvas { publishPresence(from: c) }
    }
    var panel: CollaborationPanel?
    var presenceTimer: Timer?
    var lastPresenceSent = Date.distantPast
    var isConnected: Bool { peers.contains { $0.userID != nil } || (upstream.map { !$0.closed } ?? false) }
    var browser: NWBrowser?
    var discovered: [NWBrowser.Result] = []

    init(app: AppController) {
        self.app = app
        super.init()
        myColor = Self.color(for: app.identity.id)
        shares = app.session.store.records("share", as: ShareInfo.self)
        for (id, s) in shares where app.workspace.scopes[id] == nil { _ = s; shares[id] = nil }
        for (id, s) in shares where s.viewOnly { app.workspace.readOnlyScopes.insert(id) }
        app.workspace.onLocalScopeChange = { [weak self] s in self?.scopeChanged(s) }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.watchLocalInput() }
        // Resume hosting or membership without granting any control.
        if shares.values.contains(where: { $0.hosted }) { startHosting() }
        if let m = shares.values.first(where: { !$0.hosted }) { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connect(to: m) } }
    }

    var ws: Workspace { app.workspace }
    var me: String { app.identity.id }

    // MARK: Status

    /// True while a connected peer has not yet acknowledged this device's latest shared changes.
    var isSyncing: Bool {
        let connected = peers.filter { $0.userID != nil && !$0.closed } + (upstream.map { $0.closed ? [] : [$0] } ?? [])
        for p in connected {
            for sid in p.scopes where !(p === upstream && (shares[sid]?.viewOnly ?? false)) {
                guard let doc = ws.scopes[sid], let st = p.sync[sid] else { continue }
                if st.theirHeads != doc.doc.heads() { return true }
            }
        }
        return false
    }

    var statusText: String? {
        if !listeners.isEmpty {
            let n = peers.filter { $0.userID != nil }.count
            return n == 0 ? "Sharing · no one connected" : "\(isSyncing ? "Syncing…" : "Shared") · \(n) connected"
        }
        if let u = upstream, !u.closed { return "\(isSyncing ? "Syncing…" : "Shared") with \(shares[upstreamShare ?? ""]?.hostName ?? "host")" }
        if shares.values.contains(where: { !$0.hosted }) { return connecting ? "Connecting…" : "Host offline · local edits kept" }
        return nil
    }

    func name(of user: String) -> String? { presence[user]?.name }

    func audienceLabel(scope: ScopeID) -> String {
        guard let s = shares[scope] else { return "shared frame" }
        let n = s.hosted ? s.members.count : max(1, presence.count)
        return "\(s.title) (\(n) \(n == 1 ? "person" : "people") besides you)"
    }

    func isRemoteObject(_ o: CanvasObject) -> Bool { shares[o.scope].map { !$0.hosted } ?? false }
    func isRemoteSurface(_ o: CanvasObject) -> Bool { [.app, .browser].contains(o.kind) && isRemoteObject(o) && o.props.browserMode != .providerDocument && !(o.kind == .browser && o.props.browserMode == .reference) }
    func isPublishingLive(_ id: ObjectID) -> Bool { liveShared.contains(id) }
    func remoteFrame(_ id: ObjectID) -> CGImage? { remoteFrames[id]?.0 }

    func controllerLabel(_ id: ObjectID) -> String? {
        if let a = arbiters[id], let c = a.controller { return c == me ? "you control" : "\(name(of: c) ?? "a collaborator") controls" }
        if let c = controllers[id] { return c == me ? "you control" : "\(name(of: c) ?? "someone") controls" }
        return nil
    }

    func localMayOperate(_ id: ObjectID) -> Bool {
        if let a = arbiters[id], let c = a.controller, c != me {
            // A local action on the shared app reclaims control first.
            reclaim(id, reason: "The host started using the application")
        }
        return true
    }

    func remoteSurfaceStatus(_ o: CanvasObject) -> SurfaceStatus? {
        guard isRemoteObject(o) else { return nil }
        let online = upstream.map { !$0.closed } ?? false
        if !online {
            let t = shares[o.scope]?.lastContact.map { app.runtime.relative(Date(timeIntervalSince1970: $0)) } ?? "unknown"
            return SurfaceStatus(text: "Host offline · last update \(t)", tone: .warning)
        }
        if let g = myGrants[o.id], g > 0 { return SurfaceStatus(text: "You control · ⌃⌥Space releases", tone: .live) }
        if let c = controllers[o.id] { return SurfaceStatus(text: "\(name(of: c) ?? "Someone") controls", tone: .live) }
        if let f = remoteFrames[o.id], Date().timeIntervalSince(f.1) < 3 { return SurfaceStatus(text: "Live from host", tone: .live) }
        if let t = o.props.previewTime { return SurfaceStatus(text: "Shared visual from \(app.runtime.relative(Date(timeIntervalSince1970: t)))", tone: .normal) }
        return SurfaceStatus(text: "Shared visual", tone: .normal)
    }

    // MARK: Sharing a frame (host)

    func shareFrame(_ frameID: ObjectID, from c: CanvasView) {
        guard let f = ws.object(frameID) else { return }
        if f.scope != Scope.privateID { showPanel(); return }
        let members = [frameID] + ws.descendants(of: frameID)
        let objs = members.compactMap { ws.object($0) }
        let files = objs.filter { $0.kind == .file }.count
        let apps = objs.filter { $0.kind == .app }.count
        let a = NSAlert()
        a.messageText = "Share “\(f.title)”?"
        var t = "People you invite will see and edit \(objs.count) object(s) in this frame, including their text and captured images."
        if files > 0 { t += "\n• \(files) file reference(s): a preview and file name are shared; the file bytes stay on this Mac." }
        if apps > 0 { t += "\n• \(apps) application surface(s): the last captured frame and window title are shared. Live sharing and control are separate actions." }
        t += "\n\nRevoking access later stops future updates; it cannot retract copies someone already made."
        a.informativeText = t
        a.addButton(withTitle: "Share")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let sid = "share-" + newID()
            let doc = ScopeDocument(id: sid)
            try doc.initializeSchema(title: f.title)
            doc.commit("init")
            try app.session.attachScope(doc)
            try publishPreviews(for: objs)
            try ws.moveToScope(members, scope: sid)
            let code = Self.makeInviteCode()
            shares[sid] = ShareInfo(scopeID: sid, title: f.title, hosted: true, inviteCode: code)
            saveShare(sid)
            startHosting()
            showPanel()
        } catch { app.report(error) }
    }

    /// Files and app surfaces share a chosen preview, never local bytes.
    func publishPreviews(for objs: [CanvasObject]) throws {
        for o in objs where o.kind == .file && o.props.previewAssetID == nil {
            guard let img = app.files.thumbnail(for: o), let png = pngData(img, maxPixels: 1_000_000) else { continue }
            let a = try app.session.store.stageAsset(png, mime: "image/png", width: img.width, height: img.height)
            try ws.perform("Share preview", assets: [a], recordUndo: false) { $0.update(o.id) { $0.props.previewAssetID = a.id } }
        }
    }

    func unshare(_ ids: [ObjectID], from c: CanvasView) {
        let a = NSAlert()
        a.messageText = "Stop sharing this object?"
        a.informativeText = "Others will no longer receive it or its updates. Copies they already made are not retracted. The object stays on your canvas as private material."
        a.addButton(withTitle: "Stop Sharing")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // A private copy replaces the shared one; the shared copy is removed for everyone.
        do {
            for id in ids {
                guard let o = ws.object(id), o.scope != Scope.privateID else { continue }
                var copy = o
                copy.scope = Scope.privateID
                copy.id = newID()
                copy.parent = nil
                try ws.perform("Stop sharing") { tx in
                    tx.create(copy)
                    tx.update(id) { $0.deleted = true }
                }
                liveShared.remove(id)
            }
        } catch { app.report(error) }
    }

    static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<12).map { _ in alphabet.randomElement()! }).enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? "-\($0.element)" : "\($0.element)" }.joined()
    }

    func saveShare(_ id: ScopeID) {
        if let s = shares[id] { try? app.session.store.putRecord("share", id, s) } else { app.session.store.deleteRecord("share", id) }
    }

    // MARK: Transport

    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(code.uppercased().replacingOccurrences(of: "-", with: "").utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data("canvas-workspace-v1".utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let ident = "canvas-workspace".data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, ident as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.noDelay = true
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        // A relaunched host rebinds its share port while old connections are still in TIME_WAIT.
        p.allowLocalEndpointReuse = true
        return p
    }

    /// Starts a listener for every hosted share that lacks one.
    func startHosting() {
        let envPort = UInt16(ProcessInfo.processInfo.environment["CANVAS_PORT"] ?? "")
        for (i, share) in shares.values.filter({ $0.hosted }).sorted(by: { $0.scopeID < $1.scopeID }).enumerated() where listeners[share.scopeID] == nil {
            guard let code = share.inviteCode else { continue }
            let sid = share.scopeID
            do {
                // Earlier versions stored one device-wide port; the first share keeps it so members reconnect.
                let legacy = UInt16(app.session.store.meta("listenPort") ?? "")
                let port = share.port ?? (i == 0 ? (envPort ?? legacy) : nil) ?? 0
                let l = try NWListener(using: Self.parameters(code: code), on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
                l.service = NWListener.Service(name: "\(share.title) — \(app.identity.name)", type: "_canvasws._tcp")
                l.stateUpdateHandler = { [weak self] st in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if case .ready = st, let p = l.port?.rawValue {
                            self.listenPorts[sid] = p
                            self.shares[sid]?.port = p
                            self.saveShare(sid)
                            self.refreshUI()
                        }
                        if case .failed(let e) = st {
                            self.listeners[sid] = nil
                            self.listenPorts[sid] = nil
                            // A previous instance may still be releasing the port right after a relaunch.
                            if case .posix(.EADDRINUSE) = e, self.listenRetries < 20 {
                                self.listenRetries += 1
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startHosting() }
                            } else { self.app.report(e) }
                        }
                    }
                }
                l.newConnectionHandler = { [weak self] c in
                    DispatchQueue.main.async { self?.accept(c, share: sid) }
                }
                l.start(queue: .main)
                listeners[sid] = l
            } catch { app.report(error) }
        }
    }

    func stopListener(_ sid: ScopeID) {
        listeners[sid]?.cancel()
        listeners[sid] = nil
        listenPorts[sid] = nil
    }

    func accept(_ c: NWConnection, share: ScopeID) {
        let p = Peer(c)
        p.hostedScope = share
        p.onMessage = { [weak self] peer, m in self?.hostReceive(peer, m) }
        p.onClose = { [weak self] peer in self?.peerClosed(peer) }
        peers.append(p)
        p.start()
    }

    func peerClosed(_ p: Peer) {
        peers.removeAll { $0 === p }
        if let u = p.userID {
            presence[u] = nil
            // A controller that disconnects loses its grant; control is never handed on automatically.
            for (id, a) in arbiters where a.controller == u { reclaim(id, reason: "\(p.name ?? "The controller") disconnected") }
        }
        refreshUI()
    }

    // MARK: Host message handling

    func hostReceive(_ p: Peer, _ m: WireMessage) {
        switch m.type {
        case "hello":
            guard let u = m["user"], let n = m["name"] else { p.close(); return }
            // The TLS key proved the invite code of exactly one share; only that share is granted.
            let allowed = shares.values.filter { $0.hosted && $0.scopeID == p.hostedScope && !$0.revoked.contains(u) }
            if allowed.isEmpty {
                p.send(WireMessage("access-revoked", ["reason": "The host revoked your access"]))
                p.close()
                return
            }
            p.userID = u
            p.name = n
            for var s in allowed {
                s.members[u] = n
                shares[s.scopeID] = s
                saveShare(s.scopeID)
                p.scopes.insert(s.scopeID)
                if s.viewers.contains(u) { p.viewOnly.insert(s.scopeID) }
                p.sync[s.scopeID] = SyncState()
            }
            p.send(WireMessage("welcome", ["host": app.identity.name, "hostUser": me,
                                           "scopes": allowed.map { "\($0.scopeID)\t\($0.title)\t\($0.viewers.contains(u) ? "view" : "edit")" }.joined(separator: "\n")]))
            for s in p.scopes { pushSync(s, to: p) }
            sendPresence(to: [p])
            for (id, a) in arbiters { if let c = a.controller { p.send(WireMessage("control-state", ["o": id, "user": c])) } }
            refreshUI()
            app.activeCanvas?.hud.flash("\(n) joined")
        case "sync":
            guard let s = m["scope"], p.scopes.contains(s), let doc = ws.scopes[s], let st = p.sync[s] else {
                p.send(WireMessage("error", ["reason": "no access to that scope"]))
                return
            }
            do {
                if p.viewOnly.contains(s) {
                    // A viewer's message updates what we know they have, but its changes never reach the document.
                    let probe = doc.doc.fork()
                    let before = probe.heads()
                    try probe.receiveSyncMessage(state: st, message: m.payload)
                    if probe.heads() != before { Diagnostics.record("sharing", "ignored edits from view-only member \(p.name ?? "?")") }
                    pushSync(s, to: p)
                    return
                }
                try doc.doc.receiveSyncMessage(state: st, message: m.payload)
                ws.scopeDidMerge(s)
                for q in peers where q.scopes.contains(s) { pushSync(s, to: q) }
                refreshUI()
            } catch { NSLog("sync error: %@", "\(error)") }
        case "asset-request":
            guard let a = m["id"] else { return }
            let permitted = p.scopes.contains { ws.scopes[$0]?.referencedAssets().contains(a) ?? false }
            if permitted, let d = app.session.store.assetData(a) { p.send(WireMessage("asset", ["id": a], payload: d)) }
            else { p.send(WireMessage("asset-denied", ["id": a])) }
        case "asset":
            // Upload from a member for material they placed in a shared scope.
            guard let a = m["id"], !p.scopes.subtracting(p.viewOnly).isEmpty else { return }
            receiveAsset(a, m.payload, relay: p)
        case "presence":
            guard let u = p.userID else { return }
            updatePresence(from: m, user: u)
            for q in peers where q !== p && q.userID != nil { q.send(m) }
        case "control-request":
            // Only editors of the scope that holds the surface may ask.
            guard let o = m["o"], let u = p.userID, let obj = ws.object(o), p.scopes.subtracting(p.viewOnly).contains(obj.scope) else {
                p.send(WireMessage("control-denied", ["o": m["o"] ?? "", "reason": "You do not have edit access to this surface"]))
                return
            }
            hostControlRequest(o, from: u, name: p.name ?? "A collaborator")
        case "control-release":
            guard let o = m["o"], let u = p.userID, arbiters[o]?.controller == u else { return }
            reclaim(o, reason: "\(p.name ?? "The controller") released control")
        case "input":
            guard let o = m["o"], let u = p.userID, let g = UInt64(m["g"] ?? ""), let s = UInt64(m["seq"] ?? ""),
                  let e = try? JSONDecoder().decode(RemoteInputEvent.self, from: m.payload) else { return }
            hostInput(o, from: u, generation: g, seq: s, event: e, peer: p)
        case "transfer-text", "transfer-file", "copy-from-app":
            guard let o = m["o"], let u = p.userID, let g = UInt64(m["g"] ?? ""), arbiters[o]?.controller == u, arbiters[o]?.generation == g else {
                Diagnostics.record("transfer", "\(m.type) refused: sender does not hold the current grant")
                p.send(WireMessage("transfer-result", ["ok": "0", "reason": "You do not currently control this application"]))
                return
            }
            hostTransfer(m, object: o, peer: p)
        default:
            break
        }
    }

    func pushSync(_ s: ScopeID, to p: Peer) {
        guard let doc = ws.scopes[s], let st = p.sync[s] else { return }
        var n = 0
        while let msg = doc.doc.generateSyncMessage(state: st), n < 8 {
            p.send(WireMessage("sync", ["scope": s], payload: msg))
            n += 1
        }
    }

    func scopeChanged(_ s: ScopeID) {
        guard shares[s] != nil else { return }
        if shares[s]?.hosted == true {
            for p in peers where p.scopes.contains(s) { pushSync(s, to: p) }
        } else if let u = upstream, !u.closed {
            pushSync(s, to: u)
            uploadMissingAssets(s)
        }
        refreshUI()
    }

    func receiveAsset(_ id: AssetID, _ bytes: Data, relay: Peer?) {
        guard !app.session.store.isAssetDurable(id) else { return }
        let img = NSImage(data: bytes)
        do {
            let a = try app.session.store.stageAsset(bytes, mime: "image/png", width: Int(img?.size.width ?? 0), height: Int(img?.size.height ?? 0))
            guard a.id == id else { return }
            try ws.perform("Receive asset", assets: [a], recordUndo: false) { _ in }
            requestedAssets.remove(id)
            for c in app.canvases { c.renderer.sync(ws) }
        } catch { NSLog("asset receive failed: %@", "\(error)") }
    }

    // MARK: Control (host)

    func hostControlRequest(_ o: ObjectID, from u: String, name: String) {
        guard let obj = ws.object(obj: o) else { return }
        if obj.kind == .app && !NativeWindows.axTrusted {
            send(to: u, WireMessage("control-denied", ["o": o, "reason": "Remote control is unavailable on the host: Accessibility permission is not granted"]))
            return
        }
        if obj.kind == .app && app.runtime.verifiedBinding(o) == nil {
            send(to: u, WireMessage("control-denied", ["o": o, "reason": "The host's application window is not connected"]))
            return
        }
        let a = NSAlert()
        a.messageText = "\(name) asks to control “\(obj.title)”"
        a.informativeText = "They will operate this application on your Mac with your account. You can reclaim control at any time with the Reclaim button, by using the application yourself, or with ⌃⌥⌘R."
        a.addButton(withTitle: "Grant Control")
        a.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else {
            send(to: u, WireMessage("control-denied", ["o": o, "reason": "The host declined"]))
            return
        }
        // The requester may have left while the dialog was open; never grant to a departed peer.
        guard peers.contains(where: { $0.userID == u && !$0.closed }) else { return }
        var arb = arbiters[o] ?? ControlArbiter()
        let (g, release) = arb.grant(to: u)
        arbiters[o] = arb
        releaseHeld(release, object: o)
        if obj.kind == .app, let c = app.activeCanvas { app.runtime.activate(o, in: c) }
        if obj.kind == .browser { _ = app.browsers.webView(for: o) }
        send(to: u, WireMessage("control-granted", ["o": o, "g": "\(g)"]))
        broadcast(WireMessage("control-state", ["o": o, "user": u]))
        if !liveShared.contains(o) { toggleLiveShare(o) }
        refreshUI()
    }

    func reclaim(_ o: ObjectID, reason: String) {
        guard var arb = arbiters[o], arb.controller != nil else { return }
        Diagnostics.record("control", "reclaimed: \(reason)")
        let release = arb.revoke()
        arbiters[o] = arb
        releaseHeld(release, object: o)
        broadcast(WireMessage("control-revoked", ["o": o, "reason": reason]))
        app.activeCanvas?.hud.flash("Control returned to you: \(reason)")
        app.runtime.refreshAll(o)
        refreshUI()
    }

    func reclaimAll(reason: String) {
        for (id, a) in arbiters where a.controller != nil { reclaim(id, reason: reason) }
        for (id, g) in myGrants where g > 0 { releaseControl(id) }
    }

    /// Releases keys and buttons still held by a former controller.
    func releaseHeld(_ r: (keys: Set<Int>, mouse: Bool), object o: ObjectID) {
        guard ws.object(o)?.kind == .app, NativeWindows.axTrusted else { return }
        let src = CGEventSource(stateID: .privateState)
        for k in r.keys { CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: false)?.post(tap: .cghidEventTap) }
        if r.mouse {
            let loc = CGEvent(source: nil)?.location ?? .zero
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func hostInput(_ o: ObjectID, from u: String, generation g: UInt64, seq s: UInt64, event e: RemoteInputEvent, peer: Peer) {
        guard var arb = arbiters[o] else { return }
        let verdict = arb.check(from: u, generation: g, seq: s, event: e)
        arbiters[o] = arb
        guard verdict == .accept else {
            if case .reject(let r) = verdict { peer.send(WireMessage("input-rejected", ["o": o, "reason": r])) }
            return
        }
        guard let obj = ws.object(o) else { return }
        if obj.kind == .browser { app.browsers.deliver(e, to: o); return }
        if let r = inject(e, into: o) {
            Diagnostics.record("control", "remote input paused: \(r)")
            arb.pause(r)
            arbiters[o] = arb
            peer.send(WireMessage("input-rejected", ["o": o, "reason": r]))
        } else if arb.paused != nil {
            arb.pause(nil)
            arbiters[o] = arb
        }
    }

    /// Posts one event after verifying the granted window family is the safe target.
    func inject(_ e: RemoteInputEvent, into o: ObjectID) -> String? {
        guard NativeWindows.axTrusted else { return "Remote control is unavailable: Accessibility permission is not granted on the host" }
        guard let b = app.runtime.verifiedBinding(o), let win = NativeWindows.window(b.windowID) else { return "The shared window is no longer available" }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == b.pid else {
            return "Paused: the shared application is not frontmost on the host"
        }
        let src = CGEventSource(stateID: .privateState)
        let p = CGPoint(x: win.frame.minX + e.x * win.frame.width, y: win.frame.minY + e.y * win.frame.height)
        switch e.kind {
        case .down, .up, .drag, .move, .scroll:
            guard topWindowOwner(at: p) == b.pid else { return "Paused: another window covers the shared application at that point" }
            lastInjection = Date()
            if e.kind == .scroll {
                CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(-e.dy), wheel2: Int32(-e.dx), wheel3: 0)?.post(tap: .cghidEventTap)
            } else {
                let type: CGEventType = [.down: .leftMouseDown, .up: .leftMouseUp, .drag: .leftMouseDragged, .move: .mouseMoved][e.kind]!
                CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        case .key:
            lastInjection = Date()
            // The target was verified as frontmost just above; the HID path keeps menu shortcuts working.
            let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(e.keyCode ?? 0), keyDown: e.keyDown ?? true)
            ev?.flags = CGEventFlags(rawValue: e.flags)
            ev?.post(tap: .cghidEventTap)
        case .text:
            lastInjection = Date()
            for ch in (e.text ?? "").utf16 {
                var c = ch
                for down in [true, false] {
                    // A letter key code makes some apps insert that letter instead of the Unicode string.
                    // The HID path reaches the key window's first responder like real typing.
                    let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: down)
                    ev?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                    ev?.post(tap: .cghidEventTap)
                }
            }
        }
        return nil
    }

    func topWindowOwner(at p: CGPoint) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in info {
            // Dock (20) and system layers span the screen without taking clicks; our own panels are not targets.
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < 20, let b = w[kCGWindowBounds as String] as? [String: Double],
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            if r.contains(p) { return pid }
        }
        return nil
    }

    /// Local physical input on a remotely controlled app reclaims control before the host's input continues.
    func watchLocalInput() {
        let controlled = arbiters.filter { $0.value.controller != nil && $0.value.controller != me }
        guard !controlled.isEmpty else { return }
        let any = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        guard idle < 0.12, Date().timeIntervalSince(lastInjection) > 0.4 else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (id, _) in controlled {
            if ws.object(id)?.kind == .app, let b = app.runtime.bindings[id], b.pid == front {
                reclaim(id, reason: "The host used the application locally")
            }
        }
    }

    /// Explicit controller-to-host transfers; never a mirrored global clipboard.
    func hostTransfer(_ m: WireMessage, object o: ObjectID, peer p: Peer) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        func restoreLater(_ changeAfterWrite: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // Do not overwrite a clipboard change the host made in the meantime.
                guard pb.changeCount == changeAfterWrite else { return }
                pb.clearContents()
                pb.writeObjects(saved)
            }
        }
        func pasteIntoApp() -> String? {
            let v = RemoteInputEvent(kind: .key)
            var down = v; down.keyCode = 9; down.keyDown = true; down.flags = CGEventFlags.maskCommand.rawValue
            var up = down; up.keyDown = false
            return inject(down, into: o) ?? inject(up, into: o)
        }
        // A shared browser runtime lives in this process: text goes straight into the page, no clipboard.
        if ws.object(o)?.kind == .browser {
            guard m.type == "transfer-text" else {
                p.send(WireMessage("transfer-result", ["ok": "0", "reason": "This browser session accepts text transfers only"]))
                return
            }
            var e = RemoteInputEvent(kind: .text)
            e.text = String(data: m.payload, encoding: .utf8) ?? ""
            app.browsers.deliver(e, to: o)
            Diagnostics.record("transfer", "text \(e.text?.count ?? 0) chars into browser session")
            p.send(WireMessage("transfer-result", ["ok": "1", "reason": "Inserted \(e.text?.count ?? 0) characters into the page"]))
            return
        }
        switch m.type {
        case "transfer-text":
            let text = String(data: m.payload, encoding: .utf8) ?? ""
            pb.clearContents()
            pb.setString(text, forType: .string)
            let cc = pb.changeCount
            let err = pasteIntoApp()
            restoreLater(cc)
            Diagnostics.record("transfer", "text \(text.count) chars: \(err ?? "pasted")")
            p.send(WireMessage("transfer-result", ["ok": err == nil ? "1" : "0", "reason": err ?? "Pasted \(text.count) characters into the application"]))
        case "transfer-file":
            let name = (m["name"] ?? "Transferred file").replacingOccurrences(of: "/", with: "-")
            let payload = m.payload
            let fallback = app.dataDir.appendingPathComponent("received", isDirectory: true)
            // File work runs off the main thread: a privacy prompt for Downloads must not freeze the host.
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Canvas Workspace Transfers", isDirectory: true)
                if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) == nil { dir = fallback }
                let result: Result<URL, Error> = Result {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(name)
                    try payload.write(to: dest, options: .atomic)
                    guard (try? Data(contentsOf: dest)).map({ SHA256.hash(data: $0) == SHA256.hash(data: payload) }) == true else {
                        throw CanvasError.storage("verification failed")
                    }
                    return dest
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let dest):
                        // The grant may have ended while the file was being written.
                        guard let arb = self.arbiters[o], arb.controller == p.userID else {
                            p.send(WireMessage("transfer-result", ["ok": "1", "reason": "Delivered \(name) to the host; not pasted because control ended"]))
                            return
                        }
                        pb.clearContents()
                        pb.writeObjects([dest as NSURL])
                        let cc = pb.changeCount
                        let err = pasteIntoApp()
                        restoreLater(cc)
                        Diagnostics.record("transfer", "file \(payload.count) bytes to \(dest.deletingLastPathComponent().lastPathComponent): \(err ?? "pasted")")
                        p.send(WireMessage("transfer-result", ["ok": "1", "reason": "Delivered \(name) (\(payload.count) bytes) to the host" + (err == nil ? " and pasted it into the application" : "; paste failed: \(err!)")]))
                    case .failure(let error):
                        Diagnostics.record("transfer", "file failed: \(error)")
                        p.send(WireMessage("transfer-result", ["ok": "0", "reason": "File transfer failed: \(error)"]))
                    }
                }
            }
        case "copy-from-app":
            let before = pb.changeCount
            var down = RemoteInputEvent(kind: .key); down.keyCode = 8; down.keyDown = true; down.flags = CGEventFlags.maskCommand.rawValue
            var up = down; up.keyDown = false
            if let err = inject(down, into: o) ?? inject(up, into: o) {
                p.send(WireMessage("transfer-result", ["ok": "0", "reason": err])); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard pb.changeCount != before else { p.send(WireMessage("transfer-result", ["ok": "0", "reason": "The application did not copy anything"])); return }
                if let s = pb.string(forType: .string) { p.send(WireMessage("clipboard", ["kind": "text"], payload: Data(s.utf8))) }
                else if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff) { p.send(WireMessage("clipboard", ["kind": "image"], payload: d)) }
                pb.clearContents()
                pb.writeObjects(saved)
            }
        default: break
        }
    }

    func toggleLiveShare(_ id: ObjectID) {
        guard let o = ws.object(id), shares[o.scope]?.hosted == true else {
            app.activeCanvas?.hud.flash("Move the application into a shared frame before sharing it live")
            return
        }
        if liveShared.contains(id) {
            liveShared.remove(id)
            if o.kind == .app, app.runtime.isLive(id) { app.runtime.toggleLive(id) }
        } else {
            liveShared.insert(id)
            if o.kind == .app, !app.runtime.isLive(id) { app.runtime.toggleLive(id) }
            if o.kind == .browser { app.browsers.refreshSnapshot(id, store: false) }
        }
        app.runtime.refreshAll(id)
        refreshUI()
    }

    /// Publishes a live frame to members of the object's scope only.
    func surfaceFrame(_ img: CGImage, for id: ObjectID) { surfaceFrame(for: id) { img } }

    /// Publishes a live frame; the image is only produced when a frame is actually due.
    func surfaceFrame(for id: ObjectID, make: () -> CGImage?) {
        guard liveShared.contains(id), let o = ws.object(id), shares[o.scope]?.hosted == true else { return }
        if let t = lastFrameSent[id], Date().timeIntervalSince(t) < 1.0 / 15 { return }
        guard peers.contains(where: { $0.scopes.contains(o.scope) }), let img = make() else { return }
        lastFrameSent[id] = Date()
        // JPEG has no alpha: flatten onto white so window corners do not turn black.
        var src = img
        let s = min(1, 1600.0 / Double(img.width))
        if let ctx = CGContext(data: nil, width: Int(Double(img.width) * s), height: Int(Double(img.height) * s), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            src = ctx.makeImage() ?? img
        }
        guard let jpeg = NSBitmapImageRep(cgImage: src).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return }
        let m = WireMessage("frame", ["o": id, "time": "\(Date().timeIntervalSince1970)"], payload: jpeg)
        for p in peers where p.scopes.contains(o.scope) && p.pendingSends < 6 { p.send(m) }
    }

    func runtimeLost(_ id: ObjectID) {
        if arbiters[id]?.controller != nil { reclaim(id, reason: "The application window closed") }
        liveShared.remove(id)
    }

    func localActivity(on id: ObjectID) {
        if let a = arbiters[id], let c = a.controller, c != me { reclaim(id, reason: "The host started using the application") }
    }

    func send(to user: String, _ m: WireMessage) { for p in peers where p.userID == user { p.send(m) } }
    func broadcast(_ m: WireMessage) { for p in peers where p.userID != nil { p.send(m) } }

    // MARK: Participant

    func joinDialog() {
        startBrowsing()
        let a = NSAlert()
        a.messageText = "Join a shared workspace"
        a.informativeText = "Enter the invite code from the host. Choose a host found on this network, or type an address such as 192.168.1.20:52000."
        let code = NSTextField(string: "")
        code.placeholderString = "Invite code"
        let addr = NSComboBox(frame: .zero)
        addr.placeholderString = "Host (found nearby or host:port)"
        for r in discovered { if case .service(let n, _, _, _) = r.endpoint { addr.addItem(withObjectValue: n) } }
        let stack = NSStackView(views: [code, addr])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        code.frame.size.width = 360
        addr.frame.size.width = 360
        a.accessoryView = stack
        a.addButton(withTitle: "Join")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = code
        guard a.runModal() == .alertFirstButtonReturn, !code.stringValue.isEmpty else { return }
        let info = ShareInfo(scopeID: "pending", title: "Joining…", hosted: false, inviteCode: code.stringValue.trimmingCharacters(in: .whitespaces), hostEndpoint: addr.stringValue)
        connect(to: info)
    }

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_canvasws._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in DispatchQueue.main.async { self?.discovered = Array(results) } }
        b.start(queue: .main)
        browser = b
    }

    func endpoint(for s: String) -> NWEndpoint? {
        if let r = discovered.first(where: { if case .service(let n, _, _, _) = $0.endpoint { return n == s }; return false }) { return r.endpoint }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else {
            return s.isEmpty ? nil : .service(name: s, type: "_canvasws._tcp", domain: "local.", interface: nil)
        }
        return .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port)
    }

    func connect(to info: ShareInfo) {
        guard let code = info.inviteCode, let ep = endpoint(for: info.hostEndpoint ?? "") else {
            app.activeCanvas?.hud.flash("Enter the host address")
            return
        }
        upstream?.close()
        connecting = true
        let c = NWConnection(to: ep, using: Self.parameters(code: code))
        let p = Peer(c)
        p.onMessage = { [weak self] peer, m in self?.participantReceive(peer, m, info: info) }
        p.onClose = { [weak self] _ in
            guard let self else { return }
            if self.connecting && info.scopeID == "pending" {
                self.app.activeCanvas?.hud.flash("Could not join: check the invite code and host address, or the host may have removed your access", seconds: 6)
            }
            self.connecting = false
            // Losing the host releases any control grant; it is not restored on reconnect.
            self.myGrants.removeAll()
            self.controllers.removeAll()
            self.presence.removeAll()
            self.refreshUI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.upstream === p, let s = self.shares.values.first(where: { !$0.hosted }) else { return }
                self.connect(to: s)
            }
        }
        upstream = p
        p.start()
        p.send(WireMessage("hello", ["user": me, "name": app.identity.name, "v": "1"]))
        refreshUI()
    }

    func participantReceive(_ p: Peer, _ m: WireMessage, info: ShareInfo) {
        switch m.type {
        case "welcome":
            connecting = false
            let scopes = (m["scopes"] ?? "").split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            for s in scopes where s.count >= 2 {
                let sid = s[0]
                if ws.scopes[sid] == nil { try? app.session.attachScope(ScopeDocument(id: sid)) }
                var si = shares[sid] ?? ShareInfo(scopeID: sid, title: s[1], hosted: false)
                si.inviteCode = info.inviteCode
                si.hostEndpoint = info.hostEndpoint
                si.hostName = m["host"]
                si.lastContact = Date().timeIntervalSince1970
                si.viewOnly = s.count > 2 && s[2] == "view"
                if si.viewOnly { ws.readOnlyScopes.insert(sid) } else { ws.readOnlyScopes.remove(sid) }
                shares[sid] = si
                saveShare(sid)
                p.scopes.insert(sid)
                p.sync[sid] = SyncState()
                upstreamShare = sid
                pushSync(sid, to: p)
                uploadMissingAssets(sid)
            }
            app.activeCanvas?.hud.flash("Connected to \(m["host"] ?? "the host")")
            refreshUI()
        case "sync":
            guard let s = m["scope"], let doc = ws.scopes[s], let st = p.sync[s] else { return }
            do {
                try doc.doc.receiveSyncMessage(state: st, message: m.payload)
                ws.scopeDidMerge(s)
                pushSync(s, to: p)
                shares[s]?.lastContact = Date().timeIntervalSince1970
                requestMissingAssets(s)
                refreshUI()
            } catch { NSLog("sync error: %@", "\(error)") }
        case "asset":
            if let a = m["id"] { receiveAsset(a, m.payload, relay: nil) }
        case "asset-denied":
            if let a = m["id"] { requestedAssets.remove(a) }
        case "presence":
            if let u = m["u"] { updatePresence(from: m, user: u) }
        case "frame":
            guard let o = m["o"], let img = NSImage(data: m.payload)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            remoteFrames[o] = (img, Date())
            for c in app.canvases {
                c.renderer.refreshSurface(o, ws)
                for l in ws.live where l.props.liveOf == o { c.renderer.refreshSurface(l.id, ws) }
            }
        case "control-granted":
            guard let o = m["o"], let g = UInt64(m["g"] ?? "") else { return }
            myGrants[o] = g
            controllers[o] = me
            seqs[o] = 0
            app.activeCanvas?.hud.flash("You control this application. Press ⌃⌥Space to release.", seconds: 4)
            app.runtime.refreshAll(o)
            refreshUI()
        case "control-denied":
            app.activeCanvas?.hud.flash("Control not granted: \(m["reason"] ?? "")", seconds: 4)
        case "control-state":
            if let o = m["o"], let u = m["user"] { controllers[o] = u; app.runtime.refreshAll(o) }
        case "control-revoked":
            guard let o = m["o"] else { return }
            if myGrants[o] != nil { app.activeCanvas?.hud.flash("Control ended: \(m["reason"] ?? "")", seconds: 4) }
            myGrants[o] = nil
            controllers[o] = nil
            app.runtime.refreshAll(o)
            refreshUI()
        case "input-rejected":
            app.activeCanvas?.hud.flash("Input not delivered: \(m["reason"] ?? "")", seconds: 2.5)
        case "transfer-result":
            app.activeCanvas?.hud.flash(m["reason"] ?? "", seconds: 4)
        case "clipboard":
            let pb = PasteboardService.board
            pb.clearContents()
            if m["kind"] == "text" { pb.setString(String(data: m.payload, encoding: .utf8) ?? "", forType: .string) }
            else { pb.setData(m.payload, forType: .png) }
            app.activeCanvas?.hud.flash("Copied from the remote application to your clipboard")
        case "access-revoked":
            recoverRevoked(reason: m["reason"] ?? "Access was revoked")
        default: break
        }
    }

    func requestMissingAssets(_ s: ScopeID) {
        guard let doc = ws.scopes[s], let u = upstream else { return }
        for a in doc.referencedAssets() where !app.session.store.isAssetDurable(a) && !requestedAssets.contains(a) {
            requestedAssets.insert(a)
            u.send(WireMessage("asset-request", ["id": a]))
        }
    }

    /// Material a member places in a shared scope uploads its bytes to the host.
    func uploadMissingAssets(_ s: ScopeID) {
        guard let doc = ws.scopes[s], let u = upstream, !(shares[s]?.viewOnly ?? false) else { return }
        for a in doc.referencedAssets() where !u.uploadedAssets.contains(a) {
            guard let d = app.session.store.assetData(a) else { continue }
            u.uploadedAssets.insert(a)
            u.send(WireMessage("asset", ["id": a], payload: d))
        }
    }

    func publishAssets(for ids: [ObjectID]) {
        for id in ids { if let o = ws.object(id), shares[o.scope]?.hosted == false { uploadMissingAssets(o.scope) } }
    }

    /// Keeps a revoked member's material as a private, recoverable draft.
    func recoverRevoked(reason: String) {
        let revokedScopes = shares.values.filter { !$0.hosted }.map(\.scopeID)
        var recovered = 0
        for s in revokedScopes {
            guard let doc = ws.scopes[s] else { continue }
            let objs = doc.readAll().values.filter { !$0.deleted }
            let sel = PortableSelection(workspaceID: "recovered", objects: objs, bounds: WRect.union(objs.map(\.geom.bounds)) ?? WRect(x: 0, y: 0, w: 1, h: 1), assets: [])
            let copies = ws.instantiate(sel, topLeft: WPoint(x: sel.bounds.x, y: sel.bounds.y))
            try? ws.perform("Recover draft") { tx in for var c in copies { c.props.name = c.props.name ?? "Recovered from \(shares[s]?.title ?? "shared frame")"; tx.create(c) } }
            recovered += copies.count
            ws.removeScope(s)
            try? app.session.store.deleteScope(s)
            shares[s] = nil
            saveShare(s)
        }
        upstream?.close()
        upstream = nil
        let a = NSAlert()
        a.messageText = "Access to the shared workspace ended"
        a.informativeText = "\(reason). \(recovered) object(s) you could see, including any unsent edits, were kept as a private recovered copy on your canvas. They are not published anywhere."
        if let w = app.activeCanvas?.window { a.beginSheetModal(for: w) } else { a.runModal() }
        refreshUI()
    }

    func requestControl(_ id: ObjectID, from c: CanvasView) {
        guard let u = upstream, !u.closed else { c.hud.flash("The host is offline. Control cannot be requested."); return }
        if myGrants[id] != nil { c.hud.flash("You already control this application"); return }
        u.send(WireMessage("control-request", ["o": id]))
        c.hud.flash("Asked the host for control…")
    }

    func releaseControl(_ id: ObjectID) {
        upstream?.send(WireMessage("control-release", ["o": id]))
        myGrants[id] = nil
        controllers[id] = nil
        app.runtime.refreshAll(id)
        refreshUI()
    }

    /// The object this participant currently controls, if any.
    var controlledObject: ObjectID? { myGrants.first(where: { $0.value > 0 })?.key }

    func sendInput(_ e: RemoteInputEvent, to id: ObjectID) {
        guard let g = myGrants[id], let u = upstream else { return }
        let n = (seqs[id] ?? 0) + 1
        seqs[id] = n
        u.send(WireMessage("input", ["o": id, "g": "\(g)", "seq": "\(n)"], payload: (try? JSONEncoder().encode(e)) ?? Data()))
    }

    func transferClipboardText(to id: ObjectID) {
        guard let g = myGrants[id], let u = upstream else { return }
        guard let s = PasteboardService.board.string(forType: .string) else { app.activeCanvas?.hud.flash("Your clipboard has no text"); return }
        u.send(WireMessage("transfer-text", ["o": id, "g": "\(g)"], payload: Data(s.utf8)))
        app.activeCanvas?.hud.flash("Sending \(s.count) characters…")
    }

    func transferFile(to id: ObjectID, url chosen: URL? = nil) {
        guard let g = myGrants[id], let u = upstream else { return }
        var url = chosen
        if url == nil {
            let p = NSOpenPanel()
            p.message = "Choose a file to send to the host's application"
            guard p.runModal() == .OK else { return }
            url = p.url
        }
        guard let url, let d = try? Data(contentsOf: url) else { return }
        guard d.count < WireMessage.maxSize - 4096 else {
            app.activeCanvas?.hud.flash("The file is too large to transfer (limit \(WireMessage.maxSize / 1_048_576) MB)")
            return
        }
        u.send(WireMessage("transfer-file", ["o": id, "g": "\(g)", "name": url.lastPathComponent], payload: d))
        app.activeCanvas?.hud.flash("Sending \(url.lastPathComponent) (\(d.count) bytes)…")
    }

    func copyFromRemote(_ id: ObjectID) {
        guard let g = myGrants[id], let u = upstream else { return }
        u.send(WireMessage("copy-from-app", ["o": id, "g": "\(g)"]))
    }

    // MARK: Presence

    func publishPresence(from c: CanvasView) {
        guard Date().timeIntervalSince(lastPresenceSent) > 0.05, peers.contains(where: { $0.userID != nil }) || (upstream.map { !$0.closed } ?? false) else { return }
        lastPresenceSent = Date()
        let m = presenceMessage(from: c)
        broadcast(m)
        upstream?.send(m)
    }

    func publishPointer(_ w: WPoint, from c: CanvasView) { publishPresence(from: c) }

    func presenceMessage(from c: CanvasView) -> WireMessage {
        // Only IDs of shared objects leave the device.
        let sel = c.selection.filter { ws.object($0).map { shares[$0.scope] != nil } ?? false }
        var claims: [ObjectID] = []
        if case .move(let ids, _, true) = c.drag { claims = ws.movingSet(ids).filter { ws.object($0).map { shares[$0.scope] != nil } ?? false } }
        let p = c.lastPointerWorld ?? c.camera.center
        let hex = myColor.usingColorSpace(.sRGB).map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#FF2D55"
        return WireMessage("presence", ["u": me, "n": app.identity.name, "c": hex, "px": "\(p.x)", "py": "\(p.y)",
                                        "sel": sel.joined(separator: ","), "cam": "\(c.camera.center.x),\(c.camera.center.y),\(c.camera.zoom),\(c.camera.viewSize.width),\(c.camera.viewSize.height)",
                                        "claims": claims.joined(separator: ","), "chat": c.chatText ?? ""])
    }

    func sendPresence(to ps: [Peer]) {
        guard let c = app.activeCanvas else { return }
        let m = presenceMessage(from: c)
        for p in ps { p.send(m) }
        for (_, pr) in presence where pr.userID != me {
            // Relay known presence so a newcomer sees everyone.
            _ = pr
        }
    }

    func updatePresence(from m: WireMessage, user u: String) {
        guard u != me else { return }
        let camParts = (m["cam"] ?? "").split(separator: ",").compactMap { Double($0) }
        var claims: [ObjectID: Date] = [:]
        for id in (m["claims"] ?? "").split(separator: ",").map(String.init) where !id.isEmpty { claims[id] = Date().addingTimeInterval(4) }
        let pr = Presence(userID: u, name: m["n"] ?? "Collaborator", color: NSColor(hex: m["c"]) ?? .systemPink,
                          pointer: Double(m["px"] ?? "").flatMap { x in Double(m["py"] ?? "").map { WPoint(x: x, y: $0) } },
                          selection: (m["sel"] ?? "").split(separator: ",").map(String.init),
                          camera: camParts.count >= 3 ? (camParts[0], camParts[1], camParts[2]) : nil, claims: claims, seen: Date(),
                          chat: m["chat"].flatMap { $0.isEmpty ? nil : String($0.prefix(280)) })
        presence[u] = pr
        resolveColorClash()
        for c in app.canvases {
            if let p = pr.pointer { c.remoteCursors[u] = (pr.name, p, pr.color, pr.selection, pr.chat) }
            if c.followUser == u, let cam = pr.camera {
                // Show the region the leader sees, scaled to this view's size, and ease toward it.
                var next = c.camera
                next.center = WPoint(x: cam.0, y: cam.1)
                next.zoom = cam.2
                if camParts.count == 5, camParts[3] > 0, camParts[4] > 0 {
                    next.zoom = cam.2 * min(c.camera.viewSize.width / camParts[3], c.camera.viewSize.height / camParts[4])
                }
                c.setCamera(next, animated: true, record: false, duration: 0.15)
            }
            c.updateOverlay()
        }
    }

    /// Objects another participant is currently dragging (short-lived movement claims).
    func claimedByOther(_ ids: [ObjectID]) -> String? {
        let now = Date()
        for (_, p) in presence {
            for id in ids { if let exp = p.claims[id], exp > now { return p.name } }
        }
        return nil
    }

    func tick() {
        let now = Date()
        for (u, p) in presence where now.timeIntervalSince(p.seen) > 30 {
            presence[u] = nil
            for c in app.canvases { c.remoteCursors[u] = nil; c.updateOverlay() }
        }
        if let c = app.activeCanvas { publishPresence(from: c) }
        panel?.refresh()
    }

    // MARK: UI

    func refreshUI() {
        for c in app.canvases { c.hud.update() }
        panel?.refresh()
    }

    @objc func showPanelAction(_ s: Any?) { showPanel() }

    func showPanel() {
        if panel == nil { panel = CollaborationPanel(collab: self) }
        panel?.show()
    }

    func stop() {
        reclaimAll(reason: "The host is closing")
        for p in peers { p.close() }
        upstream?.onClose = nil
        upstream?.close()
        for (sid, _) in listeners { stopListener(sid) }
        presenceTimer?.invalidate()
        reclaimTimer?.invalidate()
        browser?.cancel()
    }

    /// Changes a member's role; it applies from their next connection, which is started now.
    func setRole(_ user: String, viewOnly: Bool) {
        for (id, var s) in shares where s.hosted {
            s.viewers.removeAll { $0 == user }
            if viewOnly { s.viewers.append(user) }
            shares[id] = s
            saveShare(id)
        }
        for p in peers where p.userID == user { p.close() }
        refreshUI()
    }

    /// Revokes a member. Member IDs are self-chosen, so the share's invite code also rotates; members
    /// who stay keep their connection and need the new code to reconnect later.
    func removeMember(_ user: String) {
        for (id, var s) in shares where s.hosted && s.members[user] != nil {
            s.members[user] = nil
            if !s.revoked.contains(user) { s.revoked.append(user) }
            s.inviteCode = Self.makeInviteCode()
            s.port = nil
            shares[id] = s
            saveShare(id)
            stopListener(id)
        }
        startHosting()
        for p in peers where p.userID == user {
            p.send(WireMessage("access-revoked", ["reason": "The host removed your access"]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { p.close() }
        }
        refreshUI()
    }
}

extension Workspace {
    func object(obj id: ObjectID) -> CanvasObject? { object(id) }
}

/// Collaboration status and actions.
final class CollaborationPanel: NSObject {
    unowned let collab: Collaboration
    let panel: NSPanel
    let text = NSTextField(wrappingLabelWithString: "")
    let buttons = NSStackView()

    init(collab: Collaboration) {
        self.collab = collab
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Collaboration"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.spacing = 10
        text.font = .systemFont(ofSize: 12)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 390
        buttons.orientation = .vertical
        buttons.alignment = .leading
        root.addArrangedSubview(text)
        root.addArrangedSubview(buttons)
        panel.contentView = root
    }

    func show() {
        refresh()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func button(_ t: String, _ h: @escaping () -> Void) -> NSButton {
        let item = ActionItem(t, h)
        let b = NSButton(title: t, target: item, action: #selector(ActionItem.run))
        objc_setAssociatedObject(b, "handler", item, .OBJC_ASSOCIATION_RETAIN)
        b.bezelStyle = .rounded
        return b
    }

    func refresh() {
        guard panel.isVisible || buttons.arrangedSubviews.isEmpty else { return }
        let c = collab
        var lines: [String] = ["You: \(c.app.identity.name)"]
        let hosted = c.shares.values.filter { $0.hosted }
        if !hosted.isEmpty {
            lines.append("")
            lines.append("Hosting on this Mac" + (c.listenPort.map { " · port \($0)" } ?? " · starting…"))
            for s in hosted {
                lines.append("• \(s.title) — invite code \(s.inviteCode ?? "?")")
                if !s.members.isEmpty { lines.append("   Members: " + s.members.values.sorted().joined(separator: ", ")) }
            }
            let online = c.peers.compactMap(\.name)
            lines.append("Connected now: " + (online.isEmpty ? "no one" : online.joined(separator: ", ")))
            for (id, a) in c.arbiters where a.controller != nil {
                lines.append("Control: \(c.name(of: a.controller!) ?? "someone") controls “\(c.ws.object(id)?.title ?? id)”")
            }
            if !c.liveShared.isEmpty { lines.append("Live surfaces: " + c.liveShared.compactMap { c.ws.object($0)?.title }.joined(separator: ", ")) }
            lines.append("Invite code and address are needed to join. Access to previews, file bytes, and control are separate.")
        }
        let joined = c.shares.values.filter { !$0.hosted }
        if !joined.isEmpty {
            lines.append("")
            let online = c.upstream.map { !$0.closed } ?? false
            lines.append("Member of \(joined.map(\.title).joined(separator: ", ")) hosted by \(joined.first?.hostName ?? "host") · \(online ? "online" : "host offline")")
            if let o = c.controlledObject { lines.append("You control “\(c.ws.object(o)?.title ?? o)”.") }
        }
        if hosted.isEmpty && joined.isEmpty { lines.append("\nNothing is shared. Right-click a frame and choose Share frame… to share it, or join someone else's workspace.") }
        if !c.presence.isEmpty { lines.append("\nHere now: " + c.presence.values.map(\.name).joined(separator: ", ")) }
        text.stringValue = lines.joined(separator: "\n")
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.addArrangedSubview(button("Join a shared workspace…") { c.joinDialog() })
        if !hosted.isEmpty {
            buttons.addArrangedSubview(button("Reclaim control of all shared apps") { c.reclaimAll(reason: "The host reclaimed control") })
            if let cv = c.app.activeCanvas, let id = cv.selection.first, let o = c.ws.object(id), [.app, .browser].contains(o.kind), c.shares[o.scope]?.hosted == true {
                buttons.addArrangedSubview(button(c.liveShared.contains(id) ? "Stop sharing “\(o.title)” live" : "Share “\(o.title)” live") { c.toggleLiveShare(id) })
            }
            var allMembers: [String: String] = [:]
            for s in hosted { allMembers.merge(s.members) { a, _ in a } }
            for (u, n) in allMembers.sorted(by: { $0.value < $1.value }) {
                let isViewer = hosted.contains { $0.viewers.contains(u) }
                buttons.addArrangedSubview(button(isViewer ? "Let \(n) edit" : "Make \(n) view-only") { c.setRole(u, viewOnly: !isViewer) })
                buttons.addArrangedSubview(button("Remove \(n)'s access…") {
                    let a = NSAlert()
                    a.messageText = "Remove \(n)'s access?"
                    a.informativeText = "They stop receiving updates. Material they already copied cannot be retracted."
                    a.addButton(withTitle: "Remove")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { c.removeMember(u) }
                })
            }
        }
        if let o = c.controlledObject {
            buttons.addArrangedSubview(button("Paste my clipboard text into the remote app") { c.transferClipboardText(to: o) })
            buttons.addArrangedSubview(button("Send a file to the remote app…") { c.transferFile(to: o) })
            buttons.addArrangedSubview(button("Copy from the remote app to my clipboard") { c.copyFromRemote(o) })
            buttons.addArrangedSubview(button("Release control") { c.releaseControl(o) })
        }
        for p in c.presence.values {
            buttons.addArrangedSubview(button("Follow \(p.name)") {
                c.app.activeCanvas?.followUser = p.userID
                c.app.activeCanvas?.hud.update()
            })
        }
    }
}

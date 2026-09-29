import Automerge
import Foundation
import Testing
@testable import CanvasCore

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("cw-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func note(_ x: Double, _ y: Double, _ text: String = "n") -> CanvasObject {
    CanvasObject(kind: .sticky, geom: Geometry(x: x, y: y, w: 100, h: 100), text: text)
}

@Test func fractionalIndexOrdering() {
    var keys: [String] = [FractionalIndex.between(nil, nil)]
    for _ in 0..<200 { keys.append(FractionalIndex.between(keys.last, nil)) }
    #expect(keys == keys.sorted())
    var a = "V", b = "W"
    for _ in 0..<100 {
        let m = FractionalIndex.between(a, b)
        #expect(a < m && m < b)
        b = m
    }
    let first = FractionalIndex.between(nil, "V")
    #expect(first < "V")
    a = FractionalIndex.between(nil, nil)
}

@Test func persistReloadRoundTrip() throws {
    let dir = tempDir()
    var id = ""
    do {
        let s = try WorkspaceSession(directory: dir, user: "alice")
        let n = note(10, 20, "hello")
        id = n.id
        try s.workspace.perform("Create") { $0.create(n) }
        try s.workspace.perform("Move") { $0.update(id) { $0.geom = $0.geom.offset(5, 5) } }
        try s.workspace.perform("Edit") { $0.update(id) { $0.text = "hello world"; $0.props.color = "#ffcc00" } }
        #expect(s.workspace.saveState.label == "Saved on this device")
    }
    let s2 = try WorkspaceSession(directory: dir, user: "alice")
    let o = try #require(s2.workspace.object(id))
    #expect(o.geom.x == 15 && o.geom.y == 25)
    #expect(o.text == "hello world")
    #expect(o.props.color == "#ffcc00")
}

@Test func compactedScopeReloads() throws {
    let dir = tempDir()
    let s = try WorkspaceSession(directory: dir, user: "a")
    let n = note(0, 0)
    try s.workspace.perform("Create") { $0.create(n) }
    try s.store.compact(scope: Scope.privateID, full: s.workspace.scopes[Scope.privateID]!.doc.save())
    try s.workspace.perform("Move") { $0.update(n.id) { $0.geom.x = 42 } }
    let s2 = try WorkspaceSession(directory: dir, user: "a")
    #expect(s2.workspace.object(n.id)?.geom.x == 42)
}

@Test func undoRedoOwnCommands() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    let ws = s.workspace
    let n = note(0, 0)
    try ws.perform("Create") { $0.create(n) }
    try ws.perform("Move") { $0.update(n.id) { $0.geom.x = 50 } }
    try ws.undo()
    #expect(ws.object(n.id)?.geom.x == 0)
    try ws.undo()
    #expect(ws.object(n.id) == nil)
    try ws.redo()
    #expect(ws.object(n.id) != nil)
    try ws.redo()
    #expect(ws.object(n.id)?.geom.x == 50)
}

/// Two replicas of one shared scope, synchronized through Automerge sync messages.
final class Pair {
    let a: Workspace, b: Workspace
    let da: ScopeDocument, db: ScopeDocument
    let sa = SyncState(), sb = SyncState()
    init() throws {
        da = ScopeDocument(id: "shared")
        try da.initializeSchema(title: "S")
        da.commit("init")
        db = ScopeDocument(id: "shared", doc: da.doc.fork())
        a = Workspace(workspaceID: "w", user: "alice")
        b = Workspace(workspaceID: "w", user: "bob")
        a.addScope(da); b.addScope(db)
    }
    func sync() throws {
        for _ in 0..<10 {
            var moved = false
            if let m = da.doc.generateSyncMessage(state: sa) { try db.doc.receiveSyncMessage(state: sb, message: m); moved = true }
            if let m = db.doc.generateSyncMessage(state: sb) { try da.doc.receiveSyncMessage(state: sa, message: m); moved = true }
            if !moved { break }
        }
        a.scopeDidMerge("shared"); b.scopeDidMerge("shared")
    }
}

@Test func concurrentTextMergesAtOperationLevel() throws {
    let p = try Pair()
    var n = note(0, 0, "base")
    n.scope = "shared"
    try p.a.perform("Create") { $0.create(n) }
    try p.sync()
    try p.a.perform("Edit") { $0.update(n.id) { $0.text = "base A" } }
    try p.b.perform("Edit") { $0.update(n.id) { $0.text = "B base" } }
    try p.sync()
    #expect(p.a.object(n.id)?.text == "B base A")
    #expect(p.b.object(n.id)?.text == "B base A")
}

@Test func concurrentMovesAreAtomic() throws {
    let p = try Pair()
    var n = note(0, 0)
    n.scope = "shared"
    try p.a.perform("Create") { $0.create(n) }
    try p.sync()
    try p.a.perform("Move") { $0.update(n.id) { $0.geom.x = 100 } }
    try p.b.perform("Move") { $0.update(n.id) { $0.geom.y = 200 } }
    try p.sync()
    let ga = try #require(p.a.object(n.id)).geom, gb = try #require(p.b.object(n.id)).geom
    #expect(ga == gb)
    // One whole move wins; never x from one and y from the other.
    #expect((ga.x == 100 && ga.y == 0) || (ga.x == 0 && ga.y == 200))
}

@Test func undoDoesNotOverwriteOthersLaterWork() throws {
    let p = try Pair()
    var n = note(0, 0, "t")
    n.scope = "shared"
    try p.a.perform("Create") { $0.create(n) }
    try p.sync()
    try p.a.perform("Move") { $0.update(n.id) { $0.geom.x = 10 } }
    try p.sync()
    try p.b.perform("Move") { $0.update(n.id) { $0.geom.x = 99 } }
    try p.b.perform("Color") { $0.update(n.id) { $0.props.color = "red" } }
    try p.sync()
    let r = try #require(try p.a.undo())
    #expect(r.conflicts == [n.id])
    try p.sync()
    #expect(p.b.object(n.id)?.geom.x == 99)
    #expect(p.a.object(n.id)?.props.color == "red")
}

@Test func replayedChangesDoNotDoubleApplyFrameMove() throws {
    let p = try Pair()
    var f = CanvasObject(kind: .frame, geom: Geometry(x: 0, y: 0, w: 500, h: 500))
    f.scope = "shared"
    var m = note(10, 10); m.scope = "shared"; m.parent = f.id
    try p.a.perform("Create") { $0.create(f); $0.create(m) }
    try p.sync()
    let before = p.da.doc.heads()
    try p.a.perform("Move frame") { tx in
        for id in [f.id, m.id] { tx.update(id) { $0.geom = $0.geom.offset(100, 0) } }
    }
    let changes = try p.da.doc.encodeChangesSince(heads: before)
    try p.db.doc.applyEncodedChanges(encoded: changes)
    try p.db.doc.applyEncodedChanges(encoded: changes)
    p.b.scopeDidMerge("shared")
    #expect(p.b.object(m.id)?.geom.x == 110)
    #expect(p.b.object(f.id)?.geom.x == 100)
}

@Test func deletionIsATombstoneAndConcurrentEditSurvives() throws {
    let p = try Pair()
    var n = note(0, 0, "keep")
    n.scope = "shared"
    try p.a.perform("Create") { $0.create(n) }
    try p.sync()
    try p.a.perform("Delete") { $0.update(n.id) { $0.deleted = true } }
    try p.b.perform("Edit") { $0.update(n.id) { $0.text = "keep edited" } }
    try p.sync()
    #expect(p.a.object(n.id) == nil)
    #expect(p.a.objects[n.id]?.text == "keep edited")
}

@Test func publicationMovesObjectOutOfPrivateDocument() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    let shared = ScopeDocument(id: "shared")
    try shared.initializeSchema(title: "S")
    shared.commit("init")
    try s.attachScope(shared)
    let frame = CanvasObject(kind: .frame, geom: Geometry(x: 0, y: 0, w: 10, h: 10))
    var n = note(0, 0, "secret-free")
    n.parent = frame.id
    try s.workspace.perform("Create") { $0.create(frame); $0.create(n) }
    try s.workspace.moveToScope([n.id], scope: "shared")
    #expect(s.workspace.scopes[Scope.privateID]!.read(n.id) == nil)
    let pub = try #require(shared.read(n.id))
    // Private parent metadata is not published.
    #expect(pub.parent == nil)
    #expect(s.workspace.object(n.id)?.scope == "shared")
}

@Test func failedSaveStaysPendingUntilRetry() throws {
    let dir = tempDir()
    let s = try WorkspaceSession(directory: dir, user: "a")
    s.store.injectedFailure = .chunks
    let n = note(0, 0, "pending")
    try s.workspace.perform("Create") { $0.create(n) }
    guard case .failed = s.workspace.saveState else { Issue.record("expected failure"); return }
    #expect(!s.workspace.pendingChanges.isEmpty)
    // Reopening now shows only the confirmed state.
    let mid = try WorkspaceSession(directory: dir, user: "a")
    #expect(mid.workspace.object(n.id) == nil)
    s.store.injectedFailure = nil
    s.workspace.flush()
    #expect(s.workspace.saveState.label == "Saved on this device")
    let after = try WorkspaceSession(directory: dir, user: "a")
    #expect(after.workspace.object(n.id)?.text == "pending")
}

@Test func assetsAreDurableBeforeReference() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    s.store.injectedFailure = .assets
    #expect(throws: CanvasError.self) { _ = try s.store.stageAsset(Data([1, 2, 3]), mime: "image/png", width: 1, height: 1) }
    s.store.injectedFailure = nil
    let a = try s.store.stageAsset(Data([1, 2, 3]), mime: "image/png", width: 1, height: 1)
    #expect(!s.store.isAssetDurable(a.id))
    var img = CanvasObject(kind: .image, geom: Geometry(x: 0, y: 0, w: 1, h: 1))
    img.props.assetID = a.id
    try s.workspace.perform("Capture", assets: [a]) { $0.create(img) }
    #expect(s.store.isAssetDurable(a.id))
}

@Test func renderOrderPlacesFrameBeforeMembers() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    var f = CanvasObject(kind: .frame, geom: Geometry(x: 0, y: 0, w: 10, h: 10))
    f.z = "z"
    var n = note(0, 0)
    n.z = "a"; n.parent = f.id
    let other = note(0, 0)
    try s.workspace.perform("c") { $0.create(f); $0.create(n); $0.create(other) }
    let order = s.workspace.renderOrder().map(\.id)
    #expect(order.firstIndex(of: f.id)! < order.firstIndex(of: n.id)!)
}

@Test func concurrentSplicesFromStaleBaseBothSurvive() throws {
    let p = try Pair()
    var n = note(0, 0, "Research notes")
    n.scope = "shared"
    try p.a.perform("Create") { $0.create(n) }
    try p.sync()
    let baseA = p.a.heads("shared"), baseB = p.b.heads("shared")
    try p.a.spliceText(n.id, baseHeads: baseA, start: 0, delete: 0, insert: "Alice: ")
    try p.sync()
    // Bob's editor still shows the old text; his append must not remove Alice's insertion.
    try p.b.spliceText(n.id, baseHeads: baseB, start: 14, delete: 0, insert: " (Bob)")
    try p.sync()
    #expect(p.a.object(n.id)?.text == "Alice: Research notes (Bob)")
    #expect(p.b.object(n.id)?.text == "Alice: Research notes (Bob)")
}

@Test func removedConnectorTargetLeavesMarkedFreeEndpoint() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    let ws = s.workspace
    let a = note(0, 0), b = note(300, 0)
    var c = CanvasObject(kind: .connector, geom: Geometry(x: 0, y: 0, w: 1, h: 1))
    c.props.start = Endpoint(objectID: a.id, anchor: WPoint(x: 1, y: 0.5))
    c.props.end = Endpoint(objectID: b.id, anchor: WPoint(x: 0, y: 0.5))
    try ws.perform("c") { $0.create(a); $0.create(b); $0.create(c) }
    try ws.removeFromCanvas([b.id])
    let e = ws.connectorEndpoint(ws.object(c.id)!.props.end)
    #expect(e.missing && e.point == WPoint(x: 300, y: 50))
    #expect(ws.object(c.id) != nil)
    try ws.undo()
    #expect(!ws.connectorEndpoint(ws.object(c.id)!.props.end).missing)
}

@Test func frameMoveCarriesDescendantsAndRejectsCycles() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    let ws = s.workspace
    let outer = CanvasObject(kind: .frame, geom: Geometry(x: 0, y: 0, w: 1000, h: 1000))
    var inner = CanvasObject(kind: .frame, geom: Geometry(x: 100, y: 100, w: 400, h: 400)); inner.parent = outer.id
    var n = note(150, 150); n.parent = inner.id
    let outside = note(2000, 0)
    try ws.perform("c") { $0.create(outer); $0.create(inner); $0.create(n); $0.create(outside) }
    try ws.move([outer.id], dx: 10, dy: 0)
    #expect(ws.object(n.id)?.geom.x == 160 && ws.object(inner.id)?.geom.x == 110 && ws.object(outside.id)?.geom.x == 2000)
    // Resizing a frame changes its boundary, not its members.
    try ws.setGeometry(inner.id, Geometry(x: 110, y: 100, w: 50, h: 50))
    #expect(ws.object(n.id)?.geom.w == 100)
    // Dropping a frame into its own descendant is ignored.
    try ws.move([outer.id], dx: 0, dy: 0, reparent: .some(inner.id))
    #expect(ws.object(outer.id)?.parent == nil)
    // The ignored reparent recorded nothing, so two undos reverse the resize and the move.
    try ws.undo(); try ws.undo()
    #expect(ws.object(n.id)?.geom.x == 150)
}

@Test func copySemanticsForFilesAppsAndConnectors() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    let ws = s.workspace
    var file = CanvasObject(kind: .file, geom: Geometry(x: 0, y: 0, w: 200, h: 200)); file.props.sourceID = "src-1"
    var app = CanvasObject(kind: .app, geom: Geometry(x: 300, y: 0, w: 400, h: 300)); app.props.previewAssetID = "asset-1"; app.props.sourceID = "src-2"
    let other = note(900, 0)
    var conn = CanvasObject(kind: .connector, geom: Geometry(x: 0, y: 0, w: 1, h: 1))
    conn.props.start = Endpoint(objectID: file.id); conn.props.end = Endpoint(objectID: other.id)
    try ws.perform("c") { $0.create(file); $0.create(app); $0.create(other); $0.create(conn) }
    let sel = try #require(ws.portable([file.id, app.id]))
    // File copies stay references to the same source; app surfaces become frozen visuals.
    #expect(sel.objects.contains { $0.kind == .file && $0.props.sourceID == "src-1" })
    #expect(sel.objects.contains { $0.kind == .image && $0.props.assetID == "asset-1" })
    // A connector to an unselected object is not copied implicitly.
    #expect(!sel.objects.contains { $0.kind == .connector })
    let ids = try ws.paste(sel, topLeft: WPoint(x: 0, y: 500))
    #expect(Set(ids).isDisjoint(with: [file.id, app.id]))
}

@Test func formattingMarksPersistAndSync() throws {
    let p = try Pair()
    var n = CanvasObject(kind: .text, geom: Geometry(x: 0, y: 0, w: 300, h: 40), text: "Bold and link")
    n.scope = "shared"
    n.marks = [TextMark(name: "bold", start: 0, end: 4, value: "true")]
    try p.a.perform("Create") { $0.create(n) }
    try p.sync()
    #expect(p.b.object(n.id)?.marks == [TextMark(name: "bold", start: 0, end: 4, value: "true")])
    try p.b.setMarks(n.id, [TextMark(name: "bold", start: 0, end: 4, value: "true"), TextMark(name: "link", start: 9, end: 13, value: "https://example.com")])
    try p.sync()
    #expect(p.a.object(n.id)?.marks.contains(TextMark(name: "link", start: 9, end: 13, value: "https://example.com")) == true)
    // Text inserted before a span shifts it.
    try p.a.spliceText(n.id, baseHeads: p.a.heads("shared"), start: 0, delete: 0, insert: "Very ")
    try p.sync()
    #expect(p.b.object(n.id)?.marks.first { $0.name == "bold" }?.start == 5)
}

@Test func historicalArrangementPreviewsAndRestoresAsOneUndoableCommand() throws {
    let s = try WorkspaceSession(directory: tempDir(), user: "a")
    let ws = s.workspace
    let n = note(0, 0, "v1")
    try ws.perform("Create") { $0.create(n) }
    let doc = ws.scopes[Scope.privateID]!
    let mark = try #require(doc.history().first).hash
    try ws.perform("Move") { $0.update(n.id) { $0.geom.x = 500; $0.text = "v2" } }
    let later = note(900, 0, "later")
    try ws.perform("Create") { $0.create(later) }
    let past = try doc.state(at: mark)
    #expect(past[n.id]?.geom.x == 0 && past[later.id] == nil)
    #expect(ws.object(n.id)?.geom.x == 500)   // preview did not change the scene
    try ws.restore(scope: Scope.privateID, to: past)
    #expect(ws.object(n.id)?.geom.x == 0 && ws.object(n.id)?.text == "v1" && ws.object(later.id) == nil)
    try ws.undo()
    #expect(ws.object(n.id)?.geom.x == 500 && ws.object(later.id) != nil)
}

@Test func controlArbiterRejectsStaleAndReplayedInput() {
    var a = ControlArbiter(startingAt: 100)
    let (g1, _) = a.grant(to: "bob")
    var down = RemoteInputEvent(kind: .down)
    #expect(a.check(from: "bob", generation: g1, seq: 1, event: down) == .accept)
    #expect(a.check(from: "bob", generation: g1, seq: 1, event: down) != .accept)      // replay
    #expect(a.check(from: "carol", generation: g1, seq: 2, event: down) != .accept)    // not controller
    let released = a.revoke()
    #expect(released.mouse)                                                          // held button released
    #expect(a.check(from: "bob", generation: g1, seq: 3, event: down) != .accept)      // revoked grant
    let (g2, _) = a.grant(to: "bob")
    #expect(g2 != g1)
    a.pause("covered")
    down.kind = .move
    #expect(a.check(from: "bob", generation: g2, seq: 1, event: down) != .accept)      // paused target
    #expect(a.check(from: "bob", generation: g2, seq: 2, event: RemoteInputEvent(kind: .up)) == .accept)
}

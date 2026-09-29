import Automerge
import Foundation

public protocol WorkspacePersistence: AnyObject {
    /// Durably commits encoded document changes together with already-staged assets.
    func commit(changes: [ScopeID: Data], assets: [StagedAsset]) throws
}

public enum SaveState: Equatable, Sendable {
    case saved(Date)
    case pending
    case failed(String)

    public var label: String {
        switch self {
        case .saved: return "Saved on this device"
        case .pending: return "Saving…"
        case .failed(let r): return "Not saved — \(r)"
        }
    }
}

/// One recorded field change for per-author undo.
public struct FieldChange: Sendable {
    public var id: ObjectID
    public var field: Field
    public var before: CanvasObject?
    public var after: CanvasObject
}

public struct UndoEntry: Sendable {
    public var name: String
    public var changes: [FieldChange]
}

public struct UndoResult: Sendable {
    public var name: String
    /// Objects whose later edits by someone else prevented a faithful inverse.
    public var conflicts: [ObjectID]
}

/// The mutable transaction handed to `Workspace.perform`.
public final class Transaction {
    unowned let ws: Workspace
    var working: [ObjectID: CanvasObject] = [:]
    var original: [ObjectID: CanvasObject?] = [:]
    var order: [ObjectID] = []

    init(_ ws: Workspace) { self.ws = ws }

    public func object(_ id: ObjectID) -> CanvasObject? { working[id] ?? ws.objects[id] }

    public func create(_ o: CanvasObject) {
        var o = o
        if o.author.isEmpty { o.author = ws.user }
        if original[o.id] == nil { original[o.id] = .some(nil); order.append(o.id) }
        working[o.id] = o
    }

    public func update(_ id: ObjectID, _ body: (inout CanvasObject) -> Void) {
        guard var o = object(id) else { return }
        if original[id] == nil { original[id] = ws.objects[id]; order.append(id) }
        body(&o)
        working[id] = o
    }
}

public final class Workspace {
    public let workspaceID: String
    public private(set) var scopes: [ScopeID: ScopeDocument] = [:]
    public private(set) var objects: [ObjectID: CanvasObject] = [:]
    public var user: String
    public weak var persistence: WorkspacePersistence?

    public private(set) var saveState: SaveState = .saved(Date())
    /// Encoded changes that failed to reach durable storage; retried in order.
    public private(set) var pendingChanges: [(ScopeID, Data)] = []
    var pendingAssets: [StagedAsset] = []

    public private(set) var undoStack: [UndoEntry] = []
    public private(set) var redoStack: [UndoEntry] = []

    /// Called with the IDs that changed (locally or remotely).
    public var onChange: ((Set<ObjectID>) -> Void)?
    public var onSaveState: ((SaveState) -> Void)?
    /// Called after a local change to a scope; collaboration pushes sync messages from here.
    public var onLocalScopeChange: ((ScopeID) -> Void)?

    public init(workspaceID: String, user: String) {
        self.workspaceID = workspaceID
        self.user = user
    }

    // MARK: Scopes

    public func addScope(_ s: ScopeDocument) {
        scopes[s.id] = s
        reloadScope(s.id)
    }

    public func removeScope(_ id: ScopeID) {
        scopes[id] = nil
        let gone = Set(objects.values.filter { $0.scope == id }.map(\.id))
        for g in gone { objects[g] = nil }
        onChange?(gone)
    }

    @discardableResult
    public func reloadScope(_ id: ScopeID) -> Set<ObjectID> {
        guard let s = scopes[id] else { return [] }
        let fresh = s.readAll()
        var changed = Set<ObjectID>()
        for (oid, o) in objects where o.scope == id && fresh[oid] == nil { objects[oid] = nil; changed.insert(oid) }
        for (oid, o) in fresh where objects[oid] != o { objects[oid] = o; changed.insert(oid) }
        return changed
    }

    /// Applies changes merged into a scope document from elsewhere and persists them.
    public func scopeDidMerge(_ id: ScopeID) {
        guard let s = scopes[id] else { return }
        let changed = reloadScope(id)
        persist([id: s.takeNewChanges()], assets: [])
        if !changed.isEmpty { onChange?(changed) }
    }

    // MARK: Queries

    public var live: [CanvasObject] { objects.values.filter { !$0.deleted } }

    public func object(_ id: ObjectID?) -> CanvasObject? {
        guard let id, let o = objects[id], !o.deleted else { return nil }
        return o
    }

    public func children(of frame: ObjectID) -> [CanvasObject] {
        live.filter { $0.parent == frame }
    }

    public func descendants(of frame: ObjectID) -> [ObjectID] {
        var out: [ObjectID] = []
        var stack = [frame]
        var seen: Set<ObjectID> = [frame]
        while let f = stack.popLast() {
            for c in children(of: f) where !seen.contains(c.id) {
                seen.insert(c.id); out.append(c.id); stack.append(c.id)
            }
        }
        return out
    }

    public func groupMembers(_ group: ObjectID) -> [ObjectID] {
        live.filter { $0.group == group }.map(\.id)
    }

    /// True if `ancestor` is `id` or one of its frame ancestors.
    public func isAncestor(_ ancestor: ObjectID, of id: ObjectID) -> Bool {
        var cur: ObjectID? = id
        var guardCount = 0
        while let c = cur, guardCount < 10_000 {
            if c == ancestor { return true }
            cur = objects[c]?.parent
            guardCount += 1
        }
        return false
    }

    static func zLess(_ a: CanvasObject, _ b: CanvasObject) -> Bool {
        a.z != b.z ? a.z < b.z : a.id < b.id
    }

    /// Back-to-front order: a frame precedes its members.
    public func renderOrder() -> [CanvasObject] {
        let all = live
        let ids = Set(all.map(\.id))
        var byParent: [ObjectID?: [CanvasObject]] = [:]
        for o in all {
            let p = o.parent.flatMap { ids.contains($0) ? $0 : nil }
            byParent[p, default: []].append(o)
        }
        var out: [CanvasObject] = []
        var visited = Set<ObjectID>()
        func visit(_ parent: ObjectID?) {
            for o in (byParent[parent] ?? []).sorted(by: Self.zLess) where !visited.contains(o.id) {
                visited.insert(o.id)
                out.append(o)
                if o.kind == .frame { visit(o.id) }
            }
        }
        visit(nil)
        // Members of non-frame parents or cycles still render.
        for o in all.sorted(by: Self.zLess) where !visited.contains(o.id) { out.append(o) }
        return out
    }

    public func maxZ() -> String? { live.map(\.z).max() }
    public func minZ() -> String? { live.map(\.z).min() }

    public func connectorEndpoint(_ e: Endpoint?) -> (point: WPoint, missing: Bool) {
        guard let e else { return (WPoint(x: 0, y: 0), true) }
        if let oid = e.objectID {
            if let t = object(oid) {
                let a = e.anchor ?? WPoint(x: 0.5, y: 0.5)
                return (t.geom.fromLocal(WPoint(x: a.x * t.geom.w, y: a.y * t.geom.h)), false)
            }
            return (e.point ?? WPoint(x: 0, y: 0), true)
        }
        return (e.point ?? WPoint(x: 0, y: 0), false)
    }

    // MARK: Commands

    /// Runs a local command, writes the minimal field changes, persists them, and records undo.
    @discardableResult
    public func perform(_ name: String, assets: [StagedAsset] = [], recordUndo: Bool = true,
                        _ body: (Transaction) throws -> Void) throws -> Set<ObjectID> {
        let tx = Transaction(self)
        try body(tx)
        var changes: [FieldChange] = []
        var touchedScopes = Set<ScopeID>()
        for id in tx.order {
            guard let after = tx.working[id], let scope = scopes[after.scope] else { continue }
            let before = tx.original[id] ?? nil
            if let before {
                for f in Field.diff(before, after) {
                    try scope.set(id, field: f, to: after)
                    changes.append(FieldChange(id: id, field: f, before: before, after: after))
                }
            } else {
                try scope.create(after)
                changes.append(FieldChange(id: id, field: .deleted, before: nil, after: after))
            }
            touchedScopes.insert(after.scope)
        }
        guard !changes.isEmpty || !assets.isEmpty else { return [] }
        var encoded: [ScopeID: Data] = [:]
        for s in touchedScopes {
            scopes[s]!.commit(Self.commitMessage(name: name, author: user))
            encoded[s] = scopes[s]!.takeNewChanges()
        }
        let changed = Set(tx.order)
        for id in changed { if let o = tx.working[id] { objects[id] = o } }
        persist(encoded, assets: assets)
        if recordUndo && !changes.isEmpty {
            undoStack.append(UndoEntry(name: name, changes: changes))
            if undoStack.count > 500 { undoStack.removeFirst(undoStack.count - 500) }
            redoStack.removeAll()
        }
        for s in touchedScopes { onLocalScopeChange?(s) }
        onChange?(changed)
        return changed
    }

    static func commitMessage(name: String, author: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: ["op": name, "author": author], options: .sortedKeys)) ?? Data()
        return String(data: d, encoding: .utf8) ?? name
    }

    public func heads(_ scope: ScopeID) -> Set<ChangeHash> { scopes[scope]?.doc.heads() ?? [] }

    /// A text edit expressed as a splice against the text the editor last saw.
    /// Concurrent edits by others are preserved; see `ScopeDocument.splice`.
    public func spliceText(_ id: ObjectID, baseHeads: Set<ChangeHash>, start: Int, delete: Int, insert: String) throws {
        guard let before = objects[id], let s = scopes[before.scope] else { throw CanvasError.missingObject(id) }
        try s.splice(id, baseHeads: baseHeads, start: start, delete: delete, insert: insert)
        s.commit(Self.commitMessage(name: "Edit text", author: user))
        var after = before
        after.text = s.read(id)?.text ?? before.text
        objects[id] = after
        persist([s.id: s.takeNewChanges()], assets: [])
        undoStack.append(UndoEntry(name: "Edit text", changes: [FieldChange(id: id, field: .text, before: before, after: after)]))
        redoStack.removeAll()
        onLocalScopeChange?(s.id)
        onChange?([id])
    }

    /// Applies formatting spans for the given names, changing only names whose spans differ.
    public func setMarks(_ id: ObjectID, _ desired: [TextMark], names: [String] = ["bold", "italic", "link"]) throws {
        guard let before = objects[id], let s = scopes[before.scope] else { throw CanvasError.missingObject(id) }
        let want = TextMark.normalized(desired)
        var changed = false
        for n in names where before.marks.filter({ $0.name == n }) != want.filter({ $0.name == n }) {
            try s.setMarks(id, name: n, desired: want)
            changed = true
        }
        guard changed else { return }
        s.commit(Self.commitMessage(name: "Format text", author: user))
        var after = before
        after.marks = s.read(id)?.marks ?? want
        objects[id] = after
        persist([s.id: s.takeNewChanges()], assets: [])
        onLocalScopeChange?(s.id)
        onChange?([id])
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Reverses this author's latest command without overwriting later edits by others.
    @discardableResult
    public func undo() throws -> UndoResult? {
        guard let entry = undoStack.popLast() else { return nil }
        let (applied, conflicts) = try invert(entry, forward: false)
        redoStack.append(applied)
        return UndoResult(name: entry.name, conflicts: conflicts)
    }

    @discardableResult
    public func redo() throws -> UndoResult? {
        guard let entry = redoStack.popLast() else { return nil }
        let (applied, conflicts) = try invert(entry, forward: true)
        undoStack.append(applied)
        return UndoResult(name: entry.name, conflicts: conflicts)
    }

    private func invert(_ entry: UndoEntry, forward: Bool) throws -> (UndoEntry, [ObjectID]) {
        var conflicts: [ObjectID] = []
        var kept: [FieldChange] = []
        try perform(entry.name, recordUndo: false) { tx in
            let seq = forward ? entry.changes : entry.changes.reversed()
            for c in seq {
                // Expected current value and target value for this direction.
                let expect: CanvasObject? = forward ? c.before : c.after
                let target: CanvasObject? = forward ? c.after : c.before
                guard let cur = tx.object(c.id) else { conflicts.append(c.id); continue }
                if c.before == nil {
                    // Creation: undo tombstones, redo revives.
                    let wantDeleted = !forward
                    if cur.deleted == wantDeleted { continue }
                    tx.update(c.id) { $0.deleted = wantDeleted }
                    kept.append(c)
                    continue
                }
                guard let expect, let target else { continue }
                if !c.field.equal(cur, expect) {
                    conflicts.append(c.id)
                    continue
                }
                tx.update(c.id) { c.field.copy(from: target, into: &$0) }
                kept.append(c)
            }
        }
        let applied = UndoEntry(name: entry.name, changes: forward ? kept : kept.reversed())
        return (applied, Array(Set(conflicts)))
    }

    // MARK: Publication

    /// Moves objects to another scope document. Not part of canvas undo; publication is explicit.
    public func moveToScope(_ ids: [ObjectID], scope target: ScopeID) throws {
        guard let dst = scopes[target] else { throw CanvasError.scopeNotReady(target) }
        var encoded: [ScopeID: Data] = [:]
        var srcs = Set<ScopeID>()
        for id in ids {
            guard var o = objects[id], o.scope != target, let src = scopes[o.scope] else { continue }
            // A private parent is not published with its child.
            if let p = o.parent, objects[p]?.scope != target { o.parent = nil }
            o.scope = target
            try dst.create(o)
            try src.purge(id)
            objects[id] = o
            srcs.insert(src.id)
        }
        for s in srcs.union([target]) {
            scopes[s]!.commit(Self.commitMessage(name: "Change sharing", author: user))
            encoded[s] = scopes[s]!.takeNewChanges()
        }
        // Undo entries that reference moved objects cannot be replayed across scopes.
        let moved = Set(ids)
        undoStack.removeAll { $0.changes.contains { moved.contains($0.id) } }
        redoStack.removeAll { $0.changes.contains { moved.contains($0.id) } }
        persist(encoded, assets: [])
        for s in srcs.union([target]) { onLocalScopeChange?(s) }
        onChange?(moved)
    }

    // MARK: Persistence

    func persist(_ changes: [ScopeID: Data], assets: [StagedAsset]) {
        for (s, d) in changes where !d.isEmpty { pendingChanges.append((s, d)) }
        pendingAssets.append(contentsOf: assets)
        flush()
    }

    /// Retries all pending changes in order; the save state stays failed until they commit.
    public func flush() {
        guard let persistence, !(pendingChanges.isEmpty && pendingAssets.isEmpty) else {
            if persistence != nil { setSave(.saved(Date())) }
            return
        }
        var grouped: [ScopeID: Data] = [:]
        for (s, d) in pendingChanges { grouped[s, default: Data()].append(d) }
        do {
            try persistence.commit(changes: grouped, assets: pendingAssets)
            pendingChanges.removeAll()
            pendingAssets.removeAll()
            setSave(.saved(Date()))
        } catch {
            setSave(.failed("\(error)"))
        }
    }

    private func setSave(_ s: SaveState) {
        if case .saved = s, case .saved = saveState { saveState = s; return }
        saveState = s
        onSaveState?(s)
    }
}

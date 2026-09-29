import Foundation

public enum AlignEdge: String, Sendable { case left, hcenter, right, top, vcenter, bottom }
public enum Axis: String, Sendable { case horizontal, vertical }

public extension Workspace {
    // MARK: Creation

    func nextZ() -> String { FractionalIndex.between(maxZ(), nil) }

    /// The innermost frame whose box contains `rect`, excluding `excluding` and its descendants.
    func frameContaining(_ rect: WRect, excluding: Set<ObjectID> = []) -> CanvasObject? {
        live.filter { $0.kind == .frame && !excluding.contains($0.id) && $0.geom.rect.contains(rect) }
            .filter { f in !excluding.contains { isAncestor($0, of: f.id) } }
            .min { $0.geom.w * $0.geom.h < $1.geom.w * $1.geom.h }
    }

    @discardableResult
    func create(_ o: CanvasObject, name: String? = nil, assets: [StagedAsset] = []) throws -> ObjectID {
        var o = o
        if o.z == "a0" || o.z.isEmpty { o.z = nextZ() }
        if o.parent == nil, o.kind != .connector {
            o.parent = frameContaining(o.geom.bounds, excluding: [o.id])?.id
        }
        if let p = o.parent, let ps = objects[p]?.scope, ps != o.scope, scopes[ps] != nil {
            // Native material placed inside a shared frame joins that frame's scope.
            o.scope = ps
        }
        try perform(name ?? "Create \(o.kind.rawValue)", assets: assets) { $0.create(o) }
        return o.id
    }

    // MARK: Selection expansion

    /// Objects that move with `ids`: group members and frame descendants.
    func movingSet(_ ids: [ObjectID]) -> [ObjectID] {
        var out: [ObjectID] = []
        var seen = Set<ObjectID>()
        func add(_ id: ObjectID) {
            guard !seen.contains(id), let o = object(id) else { return }
            seen.insert(id)
            if o.kind == .group {
                for m in groupMembers(id) { add(m) }
                return
            }
            out.append(id)
            if o.kind == .frame { for d in descendants(of: id) { add(d) } }
        }
        for id in ids { add(id) }
        return out
    }

    /// Selection plus descendants, used for copy, delete, and duplicate.
    func closure(_ ids: [ObjectID]) -> [ObjectID] {
        var out = movingSet(ids)
        for id in ids where object(id)?.kind == .group && !out.contains(id) { out.append(id) }
        return out
    }

    // MARK: Geometry commands

    /// Moves objects and their dependents as one atomic command with an explicit affected set.
    func move(_ ids: [ObjectID], dx: Double, dy: Double, reparent: ObjectID?? = nil) throws {
        let set = movingSet(ids)
        try perform("Move") { tx in
            for id in set { tx.update(id) { $0.geom = $0.geom.offset(dx, dy) } }
            // Free connector endpoints owned by moved connectors move too.
            for id in set where tx.object(id)?.kind == .connector {
                tx.update(id) { c in
                    if c.props.start?.objectID == nil, let p = c.props.start?.point { c.props.start?.point = WPoint(x: p.x + dx, y: p.y + dy) }
                    if c.props.end?.objectID == nil, let p = c.props.end?.point { c.props.end?.point = WPoint(x: p.x + dx, y: p.y + dy) }
                }
            }
            if case .some(let target) = reparent {
                for id in ids {
                    guard let o = tx.object(id), o.parent != target else { continue }
                    if let t = target, self.isAncestor(id, of: t) { continue }
                    tx.update(id) { $0.parent = target }
                }
            }
        }
    }

    /// Proposed new parent for a drop; nil result means "no change".
    func proposedParent(for ids: [ObjectID], dx: Double, dy: Double) -> ObjectID?? {
        let moving = Set(movingSet(ids))
        guard let first = ids.first, let o = object(first) else { return nil }
        let rects = ids.compactMap { object($0)?.geom.bounds.offsetBy(dx, dy) }
        guard let b = WRect.union(rects) else { return nil }
        let target = frameContaining(b, excluding: moving)?.id
        if ids.allSatisfy({ object($0)?.parent == target }) { return nil }
        _ = o
        return .some(target)
    }

    func setGeometry(_ id: ObjectID, _ g: Geometry, name: String = "Resize") throws {
        try perform(name) { $0.update(id) { $0.geom = g } }
    }

    func align(_ ids: [ObjectID], _ edge: AlignEdge) throws {
        let objs = ids.compactMap { object($0) }
        guard objs.count > 1, let b = WRect.union(objs.map(\.geom.bounds)) else { return }
        var deltas: [ObjectID: (Double, Double)] = [:]
        for o in objs {
            let r = o.geom.bounds
            switch edge {
            case .left: deltas[o.id] = (b.minX - r.minX, 0)
            case .right: deltas[o.id] = (b.maxX - r.maxX, 0)
            case .hcenter: deltas[o.id] = (b.center.x - r.center.x, 0)
            case .top: deltas[o.id] = (0, b.minY - r.minY)
            case .bottom: deltas[o.id] = (0, b.maxY - r.maxY)
            case .vcenter: deltas[o.id] = (0, b.center.y - r.center.y)
            }
        }
        try applyDeltas(deltas, name: "Align")
    }

    func distribute(_ ids: [ObjectID], _ axis: Axis) throws {
        let objs = ids.compactMap { object($0) }
        guard objs.count > 2 else { return }
        let sorted = objs.sorted { axis == .horizontal ? $0.geom.bounds.minX < $1.geom.bounds.minX : $0.geom.bounds.minY < $1.geom.bounds.minY }
        let total = sorted.reduce(0) { $0 + (axis == .horizontal ? $1.geom.bounds.w : $1.geom.bounds.h) }
        let first = sorted.first!.geom.bounds, last = sorted.last!.geom.bounds
        let span = axis == .horizontal ? last.maxX - first.minX : last.maxY - first.minY
        let gap = (span - total) / Double(sorted.count - 1)
        var cursor = axis == .horizontal ? first.minX : first.minY
        var deltas: [ObjectID: (Double, Double)] = [:]
        for o in sorted {
            let r = o.geom.bounds
            if axis == .horizontal { deltas[o.id] = (cursor - r.minX, 0); cursor += r.w + gap }
            else { deltas[o.id] = (0, cursor - r.minY); cursor += r.h + gap }
        }
        try applyDeltas(deltas, name: "Distribute")
    }

    /// Target positions for tidy: a reading-order grid anchored at the selection's top-left.
    func tidyPlan(_ ids: [ObjectID], spacing: Double = 24) -> [ObjectID: (Double, Double)] {
        let objs = ids.compactMap { object($0) }
        guard objs.count > 1, let b = WRect.union(objs.map(\.geom.bounds)) else { return [:] }
        let rowTol = (objs.map(\.geom.bounds.h).max() ?? 0) / 2
        let sorted = objs.sorted {
            abs($0.geom.bounds.minY - $1.geom.bounds.minY) > rowTol ? $0.geom.bounds.minY < $1.geom.bounds.minY : $0.geom.bounds.minX < $1.geom.bounds.minX
        }
        let cols = Int(ceil(sqrt(Double(sorted.count))))
        var deltas: [ObjectID: (Double, Double)] = [:]
        var y = b.minY
        var i = 0
        while i < sorted.count {
            let row = sorted[i..<min(i + cols, sorted.count)]
            var x = b.minX
            for o in row {
                let r = o.geom.bounds
                deltas[o.id] = (x - r.minX, y - r.minY)
                x += r.w + spacing
            }
            y += (row.map(\.geom.bounds.h).max() ?? 0) + spacing
            i += cols
        }
        return deltas
    }

    func tidy(_ ids: [ObjectID]) throws { try applyDeltas(tidyPlan(ids), name: "Tidy") }

    func applyDeltas(_ deltas: [ObjectID: (Double, Double)], name: String) throws {
        try perform(name) { tx in
            for (id, d) in deltas where d.0 != 0 || d.1 != 0 {
                for m in self.movingSet([id]) { tx.update(m) { $0.geom = $0.geom.offset(d.0, d.1) } }
            }
        }
    }

    /// Resizes a frame to enclose its members plus padding; members do not move.
    func frameToContent(_ frame: ObjectID, padding: Double = 32) throws {
        let kids = children(of: frame)
        guard let f = object(frame), let b = WRect.union(kids.map(\.geom.bounds)) else { return }
        var g = f.geom
        g.x = b.minX - padding; g.y = b.minY - padding; g.w = b.w + 2 * padding; g.h = b.h + 2 * padding
        try setGeometry(frame, g, name: "Frame to content")
    }

    // MARK: Stacking

    func bringToFront(_ ids: [ObjectID]) throws {
        let objs = ids.compactMap { object($0) }.sorted(by: Workspace.zLess)
        let keys = FractionalIndex.sequence(after: maxZ(), count: objs.count)
        try perform("Bring to front") { tx in for (o, k) in zip(objs, keys) { tx.update(o.id) { $0.z = k } } }
    }

    func sendToBack(_ ids: [ObjectID]) throws {
        let objs = ids.compactMap { object($0) }.sorted(by: Workspace.zLess)
        var keys: [String] = []
        var hi = minZ()
        for _ in objs { let k = FractionalIndex.between(nil, hi); keys.insert(k, at: 0); hi = k }
        try perform("Send to back") { tx in for (o, k) in zip(objs, keys) { tx.update(o.id) { $0.z = k } } }
    }

    /// Moves one step above the next overlapping object (forward) or below the previous (backward).
    func step(_ id: ObjectID, forward: Bool) throws {
        guard let o = object(id) else { return }
        let peers = live.filter { $0.id != id && $0.parent == o.parent && $0.geom.bounds.intersects(o.geom.bounds) }
            .sorted(by: Workspace.zLess)
        let all = live.filter { $0.parent == o.parent }.sorted(by: Workspace.zLess)
        if forward {
            guard let next = peers.first(where: { Workspace.zLess(o, $0) }) else { return }
            let after = all.first { Workspace.zLess(next, $0) && $0.id != id }
            let k = FractionalIndex.between(next.z, after?.z)
            try perform("Bring forward") { $0.update(id) { $0.z = k } }
        } else {
            guard let prev = peers.last(where: { Workspace.zLess($0, o) }) else { return }
            let before = all.last { Workspace.zLess($0, prev) && $0.id != id }
            let k = FractionalIndex.between(before?.z, prev.z)
            try perform("Send backward") { $0.update(id) { $0.z = k } }
        }
    }

    // MARK: Grouping

    @discardableResult
    func group(_ ids: [ObjectID]) throws -> ObjectID? {
        let objs = ids.compactMap { object($0) }.filter { $0.kind != .group }
        guard objs.count > 1, let b = WRect.union(objs.map(\.geom.bounds)) else { return nil }
        let g = CanvasObject(kind: .group, geom: Geometry(x: b.x, y: b.y, w: b.w, h: b.h), z: nextZ(),
                             parent: objs.first?.parent, author: user, scope: objs.first!.scope)
        try perform("Group") { tx in
            tx.create(g)
            for o in objs { tx.update(o.id) { $0.group = g.id } }
        }
        return g.id
    }

    /// Geometry of group members after scaling the group's bounds from `old` to `new`.
    /// Application and file members change presentation size only; their windows are untouched.
    func scaledMembers(_ gid: ObjectID, from old: WRect, to new: WRect) -> [ObjectID: Geometry] {
        let sx = new.w / max(old.w, 1), sy = new.h / max(old.h, 1)
        var out: [ObjectID: Geometry] = [:]
        for id in movingSet([gid]) {
            guard let o = object(id) else { continue }
            var g = o.geom
            g.x = new.x + (g.x - old.x) * sx
            g.y = new.y + (g.y - old.y) * sy
            g.w *= sx
            g.h *= sy
            out[id] = g
        }
        return out
    }

    func scaleGroup(_ gid: ObjectID, from old: WRect, to new: WRect) throws {
        let plan = scaledMembers(gid, from: old, to: new)
        let sx = new.w / max(old.w, 1), sy = new.h / max(old.h, 1)
        try perform("Scale group") { tx in
            for (id, g) in plan { tx.update(id) { $0.geom = g } }
            for id in plan.keys where tx.object(id)?.kind == .connector {
                tx.update(id) { c in
                    func sc(_ p: WPoint?) -> WPoint? { p.map { WPoint(x: new.x + ($0.x - old.x) * sx, y: new.y + ($0.y - old.y) * sy) } }
                    let sp = c.props.start?.point, ep = c.props.end?.point
                    if c.props.start?.objectID == nil { c.props.start?.point = sc(sp) }
                    if c.props.end?.objectID == nil { c.props.end?.point = sc(ep) }
                }
            }
        }
    }

    func ungroup(_ gid: ObjectID) throws {
        let members = groupMembers(gid)
        try perform("Ungroup") { tx in
            for m in members { tx.update(m) { $0.group = nil } }
            tx.update(gid) { $0.deleted = true }
        }
    }

    func groupBounds(_ gid: ObjectID) -> WRect? {
        WRect.union(groupMembers(gid).compactMap { object($0)?.geom.bounds })
    }

    // MARK: Removal

    /// Removes objects from the canvas (tombstones). Connectors keep a marked free endpoint.
    func removeFromCanvas(_ ids: [ObjectID]) throws {
        let set = Set(closure(ids))
        try perform("Remove from canvas") { tx in
            for id in set { tx.update(id) { $0.deleted = true } }
            for c in self.live where c.kind == .connector && !set.contains(c.id) {
                for isStart in [true, false] {
                    let e = isStart ? c.props.start : c.props.end
                    guard let target = e?.objectID, set.contains(target) else { continue }
                    let p = self.connectorEndpoint(e).point
                    tx.update(c.id) { if isStart { $0.props.start?.point = p } else { $0.props.end?.point = p } }
                }
            }
        }
    }

    // MARK: Places

    func setPlace(_ p: NamedPlace?, id: String) throws {
        guard let s = scopes[Scope.privateID] else { return }
        try s.setPlace(p, id: id)
        s.commit(Workspace.commitMessage(name: "Named place", author: user))
        persist([Scope.privateID: s.takeNewChanges()], assets: [])
    }

    func places() -> [NamedPlace] { scopes.values.flatMap { $0.places() } }

    // MARK: Search

    func search(_ q: String) -> [CanvasObject] {
        let needle = q.lowercased()
        guard !needle.isEmpty else { return [] }
        return live.filter { o in
            [o.text, o.title, o.props.name ?? "", o.props.fileName ?? "", o.props.appName ?? "", o.props.windowTitle ?? "", o.props.url ?? ""]
                .contains { $0.lowercased().contains(needle) }
        }.sorted { $0.title < $1.title }
    }
}

public extension WRect {
    func offsetBy(_ dx: Double, _ dy: Double) -> WRect { WRect(x: x + dx, y: y + dy, w: w, h: h) }
}

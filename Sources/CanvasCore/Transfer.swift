import Foundation

/// Editable canvas material in the internal pasteboard representation.
public struct PortableSelection: Codable, Equatable, Sendable {
    public static let pasteboardType = "ai.canvasworkspace.selection"
    public var workspaceID: String
    public var objects: [CanvasObject]
    public var bounds: WRect
    public var assets: [AssetID]

    public init(workspaceID: String, objects: [CanvasObject], bounds: WRect, assets: [AssetID]) {
        self.workspaceID = workspaceID; self.objects = objects; self.bounds = bounds; self.assets = assets
    }
}

public extension Workspace {
    /// Captures the selection for copy/duplicate following §4.1 and §6.2 semantics.
    /// Frames and groups include descendants; connectors need both ends unless explicitly selected;
    /// application surfaces become frozen visuals.
    func portable(_ ids: [ObjectID]) -> PortableSelection? {
        let explicit = Set(ids)
        let set = closure(ids)
        let inSet = Set(set)
        var out: [CanvasObject] = []
        for id in set {
            guard var o = object(id) else { continue }
            if o.kind == .connector && !explicit.contains(id) {
                let ends = [o.props.start?.objectID, o.props.end?.objectID].compactMap { $0 }
                if !ends.allSatisfy({ inSet.contains($0) }) { continue }
            }
            if o.kind == .app || (o.kind == .browser && o.props.browserMode == .sharedRuntime) {
                // Runtime ownership is not copied: the copy is a frozen visual with a source link.
                guard let preview = o.props.previewAssetID else { continue }
                var p = ObjectProps()
                p.assetID = preview
                p.name = "Capture of \(o.title)"
                p.sourceID = o.props.sourceID
                p.url = o.props.url
                o.props = p
                o.kind = .image
                o.text = ""
            }
            out.append(o)
        }
        guard let b = WRect.union(out.filter { $0.kind != .group }.map(\.geom.bounds)) else { return nil }
        let assets = Set(out.compactMap { $0.props.assetID }).sorted()
        return PortableSelection(workspaceID: workspaceID, objects: out, bounds: b, assets: assets)
    }

    /// New objects for a paste with fresh identities and remapped internal references.
    func instantiate(_ sel: PortableSelection, topLeft: WPoint, scope: ScopeID = Scope.privateID) -> [CanvasObject] {
        var map: [ObjectID: ObjectID] = [:]
        for o in sel.objects { map[o.id] = newID() }
        let dx = topLeft.x - sel.bounds.x, dy = topLeft.y - sel.bounds.y
        let zs = FractionalIndex.sequence(after: maxZ(), count: sel.objects.count)
        let sameWorkspace = sel.workspaceID == workspaceID
        let ordered = sel.objects.sorted(by: Workspace.zLess)
        var out: [CanvasObject] = []
        for (o, z) in zip(ordered, zs) {
            var n = o
            n.id = map[o.id]!
            n.geom = o.geom.offset(dx, dy)
            n.z = z
            n.parent = o.parent.flatMap { map[$0] }
            n.group = o.group.flatMap { map[$0] }
            n.deleted = false
            n.author = user
            n.created = Date().timeIntervalSince1970
            n.scope = scope
            func remap(_ e: Endpoint?) -> Endpoint? {
                guard var e else { return nil }
                if let t = e.objectID {
                    if let m = map[t] { e.objectID = m }
                    else if !(sameWorkspace && object(t) != nil) { e.objectID = nil }
                }
                if let p = e.point { e.point = WPoint(x: p.x + dx, y: p.y + dy) }
                return e
            }
            if n.kind == .connector {
                n.props.start = remap(o.props.start)
                n.props.end = remap(o.props.end)
            }
            out.append(n)
        }
        return out
    }

    @discardableResult
    func paste(_ sel: PortableSelection, topLeft: WPoint) throws -> [ObjectID] {
        let objs = instantiate(sel, topLeft: topLeft)
        let top = objs.filter { $0.parent == nil && $0.kind != .connector }
        let frame = WRect.union(top.map(\.geom.bounds)).flatMap { frameContaining($0) }
        try perform("Paste") { tx in
            for var o in objs {
                if o.parent == nil && o.kind != .connector, let f = frame { o.parent = f.id; o.scope = f.scope }
                tx.create(o)
            }
        }
        return objs.map(\.id)
    }

    /// Duplicate in place with a visible offset.
    @discardableResult
    func duplicate(_ ids: [ObjectID], offset: Double = 24) throws -> [ObjectID] {
        guard let sel = portable(ids) else { return [] }
        return try paste(sel, topLeft: WPoint(x: sel.bounds.x + offset, y: sel.bounds.y + offset))
    }

    // MARK: Hit testing

    /// Topmost-first objects under a world point. Frames hit only on their border and label.
    func hitTest(_ p: WPoint, zoom: Double, includeFrameInterior: Bool = false) -> [CanvasObject] {
        let slop = 4 / zoom
        var hits: [CanvasObject] = []
        for o in renderOrder().reversed() {
            switch o.kind {
            case .group:
                continue
            case .frame:
                let label = WRect(x: o.geom.x, y: o.geom.y - 22 / zoom, w: max(120 / zoom, o.geom.w * 0.5), h: 22 / zoom)
                let border = 8 / zoom
                let inOuter = o.geom.contains(p, slop: border)
                let inInner = o.geom.rect.insetBy(border).contains(p)
                if label.contains(p) || (inOuter && (!inInner || includeFrameInterior)) { hits.append(o) }
            case .connector:
                let a = connectorEndpoint(o.props.start).point, b = connectorEndpoint(o.props.end).point
                if segmentDistance(p, a, b) <= max(6 / zoom, (o.props.strokeWidth ?? 2) / 2) { hits.append(o) }
            case .shape where o.props.shape == .line || o.props.shape == .arrow:
                let a = o.geom.fromLocal(WPoint(x: 0, y: 0)), b = o.geom.fromLocal(WPoint(x: o.geom.w, y: o.geom.h))
                if segmentDistance(p, a, b) <= max(6 / zoom, (o.props.strokeWidth ?? 2) / 2) { hits.append(o) }
            case .ink:
                guard o.geom.contains(p, slop: slop + 6 / zoom), let pts = o.props.inkPoints, pts.count >= 2 else { continue }
                let l = o.geom.toLocal(p)
                let tol = max(6 / zoom, (o.props.strokeWidth ?? 3))
                var hit = false
                var i = 0
                while i + 3 < pts.count {
                    if segmentDistance(l, WPoint(x: pts[i], y: pts[i + 1]), WPoint(x: pts[i + 2], y: pts[i + 3])) <= tol { hit = true; break }
                    i += 2
                }
                if pts.count == 2 && l.distance(to: WPoint(x: pts[0], y: pts[1])) <= tol { hit = true }
                if hit { hits.append(o) }
            default:
                if o.geom.contains(p, slop: slop) { hits.append(o) }
            }
        }
        return hits
    }

    func objects(in r: WRect) -> [CanvasObject] {
        live.filter { $0.kind != .group && r.contains($0.geom.bounds) }
    }
}

public func segmentDistance(_ p: WPoint, _ a: WPoint, _ b: WPoint) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return p.distance(to: WPoint(x: a.x + t * dx, y: a.y + t * dy))
}

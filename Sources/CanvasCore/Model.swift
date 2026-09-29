import Foundation

public typealias ObjectID = String
public typealias ScopeID = String
public typealias AssetID = String
public typealias SourceID = String

public func newID() -> String { UUID().uuidString.lowercased() }

public enum ObjectKind: String, Codable, CaseIterable, Sendable {
    case sticky, text, shape, ink, image, frame, group, connector, file, app, browser

    /// Kinds that rotate freely; application and file previews stay upright.
    public var rotates: Bool { [.sticky, .text, .shape, .ink, .image].contains(self) }
    public var hasText: Bool { [.sticky, .text, .shape, .connector].contains(self) }
}

public enum ShapeType: String, Codable, Sendable { case rect, ellipse, line, arrow }

/// World-space geometry. `x`,`y` is the top-left corner; y grows downward.
public struct Geometry: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double, rotation: Double
    public init(x: Double, y: Double, w: Double, h: Double, rotation: Double = 0) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.rotation = rotation
    }
    public var rect: WRect { WRect(x: x, y: y, w: w, h: h) }
    public var center: WPoint { WPoint(x: x + w / 2, y: y + h / 2) }
    public func offset(_ dx: Double, _ dy: Double) -> Geometry {
        Geometry(x: x + dx, y: y + dy, w: w, h: h, rotation: rotation)
    }

    /// Axis-aligned bounds including rotation.
    public var bounds: WRect {
        guard rotation != 0 else { return rect }
        let c = center, cs = cos(rotation), sn = sin(rotation)
        let corners = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].map {
            WPoint(x: c.x + $0.0 * cs - $0.1 * sn, y: c.y + $0.0 * sn + $0.1 * cs)
        }
        return WRect.enclosing(corners)
    }

    /// Point in object-local unrotated coordinates relative to top-left.
    public func toLocal(_ p: WPoint) -> WPoint {
        let c = center, dx = p.x - c.x, dy = p.y - c.y
        let cs = cos(-rotation), sn = sin(-rotation)
        return WPoint(x: dx * cs - dy * sn + w / 2, y: dx * sn + dy * cs + h / 2)
    }

    public func fromLocal(_ p: WPoint) -> WPoint {
        let lx = p.x - w / 2, ly = p.y - h / 2, cs = cos(rotation), sn = sin(rotation)
        let c = center
        return WPoint(x: c.x + lx * cs - ly * sn, y: c.y + lx * sn + ly * cs)
    }

    public func contains(_ p: WPoint, slop: Double = 0) -> Bool {
        let l = toLocal(p)
        return l.x >= -slop && l.y >= -slop && l.x <= w + slop && l.y <= h + slop
    }

    var encoded: String { "\(x) \(y) \(w) \(h) \(rotation)" }
    init?(encoded: String) {
        let v = encoded.split(separator: " ").compactMap { Double($0) }
        guard v.count == 5 else { return nil }
        self.init(x: v[0], y: v[1], w: v[2], h: v[3], rotation: v[4])
    }
}

public struct WPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func distance(to o: WPoint) -> Double { hypot(x - o.x, y - o.y) }
}

public struct WRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var center: WPoint { WPoint(x: x + w / 2, y: y + h / 2) }
    public func contains(_ p: WPoint) -> Bool { p.x >= x && p.y >= y && p.x <= maxX && p.y <= maxY }
    public func contains(_ r: WRect) -> Bool { r.x >= x && r.y >= y && r.maxX <= maxX && r.maxY <= maxY }
    public func intersects(_ r: WRect) -> Bool { r.x <= maxX && r.maxX >= x && r.y <= maxY && r.maxY >= y }
    public func union(_ r: WRect) -> WRect {
        let nx = min(x, r.x), ny = min(y, r.y)
        return WRect(x: nx, y: ny, w: max(maxX, r.maxX) - nx, h: max(maxY, r.maxY) - ny)
    }
    public func insetBy(_ d: Double) -> WRect { WRect(x: x + d, y: y + d, w: w - 2 * d, h: h - 2 * d) }
    public static func enclosing(_ pts: [WPoint]) -> WRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let nx = xs.min() ?? 0, ny = ys.min() ?? 0
        return WRect(x: nx, y: ny, w: (xs.max() ?? 0) - nx, h: (ys.max() ?? 0) - ny)
    }
    public static func union(_ rs: [WRect]) -> WRect? {
        guard var r = rs.first else { return nil }
        for o in rs.dropFirst() { r = r.union(o) }
        return r
    }
}

/// A connector endpoint: attached to an object anchor, or free in world space.
public struct Endpoint: Codable, Equatable, Hashable, Sendable {
    public var objectID: ObjectID?
    /// Normalized anchor in the target's local box (0...1).
    public var anchor: WPoint?
    /// Free world position, also the last known position when a target is removed.
    public var point: WPoint?
    public init(objectID: ObjectID? = nil, anchor: WPoint? = nil, point: WPoint? = nil) {
        self.objectID = objectID; self.anchor = anchor; self.point = point
    }
}

public enum BrowserMode: String, Codable, Sendable {
    case reference, providerDocument, sharedRuntime
    public var label: String {
        switch self {
        case .reference: return "Reference page"
        case .providerDocument: return "Provider document"
        case .sharedRuntime: return "Shared browser runtime"
        }
    }
}

/// Non-text, non-geometry properties. Each field merges independently.
public struct ObjectProps: Codable, Equatable, Sendable {
    public var color: String?
    public var fill: String?
    public var strokeWidth: Double?
    public var fontSize: Double?
    public var shape: ShapeType?
    /// Ink stroke points (x,y pairs) in object-local coordinates.
    public var inkPoints: [Double]?
    public var inkTool: String?
    public var assetID: AssetID?
    public var captureID: String?
    public var name: String?
    public var sourceID: SourceID?
    public var start: Endpoint?
    public var end: Endpoint?
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    /// Application window logical size in points, independent of canvas presentation size.
    public var logicalSize: [Double]?
    public var previewAssetID: AssetID?
    public var previewTime: Double?
    public var url: String?
    public var browserMode: BrowserMode?
    /// This image is a live view that follows the given object while it is available.
    public var liveOf: ObjectID?
    public var fileName: String?
    public var locked: Bool?

    public init() {}

    static let keys: [String] = [
        "color", "fill", "strokeWidth", "fontSize", "shape", "inkPoints", "inkTool", "assetID",
        "captureID", "name", "sourceID", "start", "end", "appBundleID", "appName", "windowTitle",
        "logicalSize", "previewAssetID", "previewTime", "url", "browserMode", "liveOf", "fileName", "locked",
    ]

    /// JSON-encoded value per non-nil key.
    public func fieldMap() -> [String: String] {
        let data = (try? JSONEncoder.sorted.encode(self)) ?? Data()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]),
               let s = String(data: d, encoding: .utf8) { out[k] = s }
        }
        return out
    }

    public init(fieldMap: [String: String]) {
        var obj: [String: Any] = [:]
        for (k, s) in fieldMap {
            if let d = s.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) {
                obj[k] = v
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let p = try? JSONDecoder().decode(ObjectProps.self, from: d) { self = p } else { self.init() }
    }
}

public struct CanvasObject: Codable, Equatable, Sendable {
    public var id: ObjectID
    public var kind: ObjectKind
    public var geom: Geometry
    public var z: String
    /// Frame membership.
    public var parent: ObjectID?
    /// Group membership.
    public var group: ObjectID?
    public var deleted: Bool
    public var props: ObjectProps
    public var text: String
    public var author: String
    public var created: Double
    /// Scope document that holds this object; not stored inside the object.
    public var scope: ScopeID

    public init(id: ObjectID = newID(), kind: ObjectKind, geom: Geometry, z: String = "a0",
                parent: ObjectID? = nil, group: ObjectID? = nil, props: ObjectProps = ObjectProps(),
                text: String = "", author: String = "", created: Double = Date().timeIntervalSince1970,
                scope: ScopeID = Scope.privateID) {
        self.id = id; self.kind = kind; self.geom = geom; self.z = z; self.parent = parent
        self.group = group; self.deleted = false; self.props = props; self.text = text
        self.author = author; self.created = created; self.scope = scope
    }

    public var title: String {
        switch kind {
        case .frame: return props.name ?? "Frame"
        case .file: return props.fileName ?? "File"
        case .app: return props.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? props.appName ?? "Application"
        case .browser: return props.name ?? props.url ?? "Web page"
        case .image: return props.name ?? (props.captureID != nil ? "Capture" : "Image")
        default:
            let t = text.split(separator: "\n").first.map(String.init) ?? ""
            return t.isEmpty ? kind.rawValue.capitalized : t
        }
    }
}

public enum Scope {
    public static let privateID: ScopeID = "private"
}

public struct NamedPlace: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var rect: WRect
    public init(id: String = newID(), name: String, rect: WRect) { self.id = id; self.name = name; self.rect = rect }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

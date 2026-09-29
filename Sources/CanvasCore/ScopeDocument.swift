import Automerge
import Foundation

/// One publication scope backed by an Automerge document.
///
/// Schema: ROOT { schema, title, objects: { id: { kind, geom, z, parent, group, deleted, author,
/// created, props: { key: json }, text: Text } }, places: { id: json } }.
public final class ScopeDocument {
    public static let schemaVersion: Int64 = 1

    public let id: ScopeID
    public let doc: Document

    public init(id: ScopeID, doc: Document = Document()) {
        self.id = id
        self.doc = doc
    }

    public convenience init(id: ScopeID, bytes: Data) throws {
        self.init(id: id, doc: try Document(bytes))
    }

    /// Creates the root maps. Only the creator of a scope calls this; joiners receive it by sync.
    public func initializeSchema(title: String) throws {
        try doc.put(obj: .ROOT, key: "schema", value: .Int(Self.schemaVersion))
        try doc.put(obj: .ROOT, key: "title", value: .String(title))
        _ = try doc.putObject(obj: .ROOT, key: "objects", ty: .Map)
        _ = try doc.putObject(obj: .ROOT, key: "places", ty: .Map)
    }

    public var isInitialized: Bool { objectsMap != nil }

    public var title: String {
        if case .Scalar(.String(let s))? = try? doc.get(obj: .ROOT, key: "title") { return s }
        return ""
    }

    var objectsMap: ObjId? {
        if case .Object(let o, _)? = try? doc.get(obj: .ROOT, key: "objects") { return o }
        return nil
    }

    var placesMap: ObjId? {
        if case .Object(let o, _)? = try? doc.get(obj: .ROOT, key: "places") { return o }
        return nil
    }

    func objectMap(_ id: ObjectID) -> ObjId? {
        guard let objs = objectsMap else { return nil }
        if case .Object(let o, _)? = try? doc.get(obj: objs, key: id) { return o }
        return nil
    }

    // MARK: Reading

    public func objectIDs() -> [ObjectID] {
        guard let objs = objectsMap else { return [] }
        return doc.keys(obj: objs)
    }

    public func readAll() -> [ObjectID: CanvasObject] {
        var out: [ObjectID: CanvasObject] = [:]
        for id in objectIDs() { if let o = read(id) { out[id] = o } }
        return out
    }

    public func read(_ oid: ObjectID) -> CanvasObject? {
        guard let m = objectMap(oid) else { return nil }
        func str(_ k: String) -> String? {
            if case .Scalar(.String(let s))? = try? doc.get(obj: m, key: k) { return s }
            return nil
        }
        guard let kindS = str("kind"), let kind = ObjectKind(rawValue: kindS),
              let g = str("geom").flatMap(Geometry.init(encoded:)) else { return nil }
        var o = CanvasObject(id: oid, kind: kind, geom: g, z: str("z") ?? "V", scope: id)
        o.parent = str("parent")
        o.group = str("group")
        if case .Scalar(.Boolean(let d))? = try? doc.get(obj: m, key: "deleted") { o.deleted = d }
        if case .Scalar(.F64(let c))? = try? doc.get(obj: m, key: "created") { o.created = c }
        o.author = str("author") ?? ""
        if case .Object(let t, _)? = try? doc.get(obj: m, key: "text") { o.text = (try? doc.text(obj: t)) ?? "" }
        if case .Object(let p, _)? = try? doc.get(obj: m, key: "props") {
            var fields: [String: String] = [:]
            for k in doc.keys(obj: p) {
                if case .Scalar(.String(let s))? = try? doc.get(obj: p, key: k) { fields[k] = s }
            }
            o.props = ObjectProps(fieldMap: fields)
        }
        return o
    }

    public func places() -> [NamedPlace] {
        guard let pm = placesMap else { return [] }
        return doc.keys(obj: pm).compactMap { k in
            if case .Scalar(.String(let s))? = try? doc.get(obj: pm, key: k), let d = s.data(using: .utf8) {
                return try? JSONDecoder().decode(NamedPlace.self, from: d)
            }
            return nil
        }
    }

    // MARK: Writing

    public func create(_ o: CanvasObject) throws {
        guard let objs = objectsMap else { throw CanvasError.scopeNotReady(id) }
        let m = try doc.putObject(obj: objs, key: o.id, ty: .Map)
        try doc.put(obj: m, key: "kind", value: .String(o.kind.rawValue))
        try doc.put(obj: m, key: "geom", value: .String(o.geom.encoded))
        try doc.put(obj: m, key: "z", value: .String(o.z))
        try doc.put(obj: m, key: "parent", value: o.parent.map { .String($0) } ?? .Null)
        try doc.put(obj: m, key: "group", value: o.group.map { .String($0) } ?? .Null)
        try doc.put(obj: m, key: "deleted", value: .Boolean(o.deleted))
        try doc.put(obj: m, key: "author", value: .String(o.author))
        try doc.put(obj: m, key: "created", value: .F64(o.created))
        let p = try doc.putObject(obj: m, key: "props", ty: .Map)
        for (k, v) in o.props.fieldMap() { try doc.put(obj: p, key: k, value: .String(v)) }
        let t = try doc.putObject(obj: m, key: "text", ty: .Text)
        if !o.text.isEmpty { try doc.spliceText(obj: t, start: 0, delete: 0, value: o.text) }
    }

    public func set(_ oid: ObjectID, field: Field, to o: CanvasObject) throws {
        guard let m = objectMap(oid) else { throw CanvasError.missingObject(oid) }
        switch field {
        case .geom: try doc.put(obj: m, key: "geom", value: .String(o.geom.encoded))
        case .z: try doc.put(obj: m, key: "z", value: .String(o.z))
        case .parent: try doc.put(obj: m, key: "parent", value: o.parent.map { .String($0) } ?? .Null)
        case .group: try doc.put(obj: m, key: "group", value: o.group.map { .String($0) } ?? .Null)
        case .deleted: try doc.put(obj: m, key: "deleted", value: .Boolean(o.deleted))
        case .text:
            let t: ObjId
            if case .Object(let existing, _)? = try doc.get(obj: m, key: "text") { t = existing }
            else { t = try doc.putObject(obj: m, key: "text", ty: .Text) }
            try doc.updateText(obj: t, value: o.text)
        case .prop(let key):
            let p: ObjId
            if case .Object(let existing, _)? = try doc.get(obj: m, key: "props") { p = existing }
            else { p = try doc.putObject(obj: m, key: "props", ty: .Map) }
            if let v = o.props.fieldMap()[key] { try doc.put(obj: p, key: key, value: .String(v)) }
            else { try doc.delete(obj: p, key: key) }
        }
    }

    func textObject(_ oid: ObjectID) throws -> ObjId {
        guard let m = objectMap(oid) else { throw CanvasError.missingObject(oid) }
        if case .Object(let t, _)? = try doc.get(obj: m, key: "text") { return t }
        return try doc.putObject(obj: m, key: "text", ty: .Text)
    }

    /// Splices text at a position observed at `baseHeads`, mapped through concurrent changes.
    /// Positions count Unicode scalars.
    public func splice(_ oid: ObjectID, baseHeads: Set<ChangeHash>, start: Int, delete: Int, insert: String) throws {
        let t = try textObject(oid)
        let baseLen = Int(doc.lengthAt(obj: t, heads: baseHeads))
        var pos: UInt64
        if start >= baseLen || baseHeads.isEmpty {
            // End-anchored: map the last character before the edit, then step past it.
            if start > 0, !baseHeads.isEmpty, let c = try? doc.cursor(obj: t, position: UInt64(start - 1), heads: baseHeads) {
                pos = (try doc.position(obj: t, cursor: c)) + 1
            } else { pos = baseHeads.isEmpty ? UInt64(start) : doc.length(obj: t) }
        } else {
            let c = try doc.cursor(obj: t, position: UInt64(start), heads: baseHeads)
            pos = try doc.position(obj: t, cursor: c)
        }
        pos = min(pos, doc.length(obj: t))
        let del = min(Int64(delete), Int64(doc.length(obj: t) - pos))
        try doc.spliceText(obj: t, start: pos, delete: del, value: insert.isEmpty ? nil : insert)
    }

    /// Maps a scalar offset observed at `baseHeads` to the current text.
    public func mapPosition(_ oid: ObjectID, baseHeads: Set<ChangeHash>, position: Int) -> Int? {
        guard let t = try? textObject(oid) else { return nil }
        let baseLen = Int(doc.lengthAt(obj: t, heads: baseHeads))
        if position >= baseLen {
            guard position > 0, let c = try? doc.cursor(obj: t, position: UInt64(position - 1), heads: baseHeads),
                  let p = try? doc.position(obj: t, cursor: c) else { return Int(doc.length(obj: t)) }
            return Int(p) + 1
        }
        guard let c = try? doc.cursor(obj: t, position: UInt64(position), heads: baseHeads), let p = try? doc.position(obj: t, cursor: c) else { return nil }
        return Int(p)
    }

    /// Removes an object record entirely. Used only when an object leaves this scope by publication.
    public func purge(_ oid: ObjectID) throws {
        guard let objs = objectsMap else { return }
        try doc.delete(obj: objs, key: oid)
    }

    public func setPlace(_ p: NamedPlace?, id pid: String) throws {
        guard let pm = placesMap else { throw CanvasError.scopeNotReady(id) }
        if let p, let d = try? JSONEncoder.sorted.encode(p), let s = String(data: d, encoding: .utf8) {
            try doc.put(obj: pm, key: pid, value: .String(s))
        } else {
            try doc.delete(obj: pm, key: pid)
        }
    }

    public func commit(_ message: String) { doc.commitWith(message: message) }

    /// Encoded changes made since the previous call; appended to durable storage.
    public func takeNewChanges() -> Data { doc.encodeNewChanges() }
}

/// A single mergeable field of an object.
public enum Field: Hashable, Sendable {
    case geom, z, parent, group, deleted, text
    case prop(String)

    public static func diff(_ a: CanvasObject, _ b: CanvasObject) -> [Field] {
        var out: [Field] = []
        if a.geom != b.geom { out.append(.geom) }
        if a.z != b.z { out.append(.z) }
        if a.parent != b.parent { out.append(.parent) }
        if a.group != b.group { out.append(.group) }
        if a.deleted != b.deleted { out.append(.deleted) }
        if a.text != b.text { out.append(.text) }
        let fa = a.props.fieldMap(), fb = b.props.fieldMap()
        for k in Set(fa.keys).union(fb.keys).sorted() where fa[k] != fb[k] { out.append(.prop(k)) }
        return out
    }

    public func equal(_ a: CanvasObject, _ b: CanvasObject) -> Bool {
        switch self {
        case .geom: return a.geom == b.geom
        case .z: return a.z == b.z
        case .parent: return a.parent == b.parent
        case .group: return a.group == b.group
        case .deleted: return a.deleted == b.deleted
        case .text: return a.text == b.text
        case .prop(let k): return a.props.fieldMap()[k] == b.props.fieldMap()[k]
        }
    }

    /// Copies this field's value from `src` into `dst`.
    public func copy(from src: CanvasObject, into dst: inout CanvasObject) {
        switch self {
        case .geom: dst.geom = src.geom
        case .z: dst.z = src.z
        case .parent: dst.parent = src.parent
        case .group: dst.group = src.group
        case .deleted: dst.deleted = src.deleted
        case .text: dst.text = src.text
        case .prop(let k):
            var m = dst.props.fieldMap()
            m[k] = src.props.fieldMap()[k]
            dst.props = ObjectProps(fieldMap: m)
        }
    }
}

public enum CanvasError: Error, CustomStringConvertible {
    case scopeNotReady(ScopeID)
    case missingObject(ObjectID)
    case storage(String)
    case cycle
    case permission(String)

    public var description: String {
        switch self {
        case .scopeNotReady(let s): return "Scope \(s) has not been synchronized yet"
        case .missingObject(let o): return "Object \(o) is not in this workspace"
        case .storage(let s): return "Storage failure: \(s)"
        case .cycle: return "Frame membership cannot form a cycle"
        case .permission(let s): return s
        }
    }
}

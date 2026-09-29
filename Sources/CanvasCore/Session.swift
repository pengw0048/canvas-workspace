import Automerge
import Foundation

public enum SourceKind: String, Codable, Sendable { case file, url, window }

/// Local, restricted source metadata. Never written into a scope document.
public struct SourceRecord: Codable, Equatable, Sendable {
    public var id: SourceID
    public var kind: SourceKind
    public var path: String?
    public var bookmark: Data?
    public var url: String?
    public var bundleID: String?
    public var appName: String?
    /// Document file reported by the application for this window, when known.
    public var documentPath: String?
    public var documentBookmark: Data?
    public var lastTitle: String?
    /// Ephemeral runtime hints; never treated as identity on their own.
    public var pidHint: Int32?
    public var windowNumberHint: UInt32?
    /// Window frame before admission, in global top-left coordinates, for exit restoration.
    public var originalFrame: [Double]?
    public init(id: SourceID = newID(), kind: SourceKind) { self.id = id; self.kind = kind }
}

/// A personal camera for one user and display.
public struct PersonalView: Codable, Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    public var back: [[Double]]
    public init(centerX: Double = 0, centerY: Double = 0, zoom: Double = 1, back: [[Double]] = []) {
        self.centerX = centerX; self.centerY = centerY; self.zoom = zoom; self.back = back
    }
}

/// Opens a workspace from local storage and wires persistence.
public final class WorkspaceSession {
    public let store: Store
    public let workspace: Workspace

    public init(directory: URL, user: String) throws {
        store = try Store(directory: directory)
        let wsID: String
        if let s = store.meta("workspaceID") { wsID = s } else {
            wsID = newID()
            try store.setMeta("workspaceID", wsID)
        }
        workspace = Workspace(workspaceID: wsID, user: user)
        let chunks = try store.loadScopes()
        for (scope, parts) in chunks {
            let doc = ScopeDocument(id: scope, doc: Document())
            for p in parts { try doc.doc.applyEncodedChanges(encoded: p) }
            _ = doc.takeNewChanges()
            if store.chunkCount(scope: scope) > 200 { try? store.compact(scope: scope, full: doc.doc.save()) }
            workspace.addScope(doc)
        }
        if workspace.scopes[Scope.privateID] == nil {
            let doc = ScopeDocument(id: Scope.privateID)
            try doc.initializeSchema(title: "Workspace")
            doc.commit("init")
            try store.commit(changes: [Scope.privateID: doc.takeNewChanges()], assets: [])
            workspace.addScope(doc)
        }
        workspace.persistence = store
    }

    /// Every asset an object (live or tombstoned, so undo can revive it) or a capture record references.
    public func referencedAssets() -> Set<AssetID> {
        var s = Set<AssetID>()
        for o in workspace.objects.values {
            if let a = o.props.assetID { s.insert(a) }
            if let a = o.props.previewAssetID { s.insert(a) }
        }
        struct Cap: Decodable { var assetID: String }
        for c in store.records("capture", as: Cap.self).values { s.insert(c.assetID) }
        return s
    }

    /// Adds a new or joined shared scope and persists its current state.
    public func attachScope(_ doc: ScopeDocument) throws {
        try store.commit(changes: [doc.id: doc.takeNewChanges()], assets: [])
        workspace.addScope(doc)
    }

    public func source(_ id: SourceID?) -> SourceRecord? {
        id.flatMap { store.record("source", $0, as: SourceRecord.self) }
    }

    public func putSource(_ s: SourceRecord) {
        try? store.putRecord("source", s.id, s)
    }
}

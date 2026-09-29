import Automerge
import Foundation

public struct HistoryEntry: Sendable, Equatable {
    public var hash: ChangeHash
    public var name: String
    public var author: String
    public var time: Date
}

public extension ScopeDocument {
    /// Committed operations, newest first.
    func history(limit: Int = 300) -> [HistoryEntry] {
        doc.getHistory().suffix(limit * 2).reversed().compactMap { h -> HistoryEntry? in
            guard let c = doc.change(hash: h) else { return nil }
            let meta = c.message.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            let name = meta?["op"] ?? c.message ?? "Change"
            // Bookkeeping changes are not arrangements a person would restore.
            if ["init", "Update preview", "Receive asset", "Import assets"].contains(name) { return nil }
            return HistoryEntry(hash: h, name: name, author: meta?["author"] ?? "", time: c.timestamp)
        }.prefix(limit).map { $0 }
    }

    /// The scope's objects as of a change (read-only; nothing is applied).
    func state(at hash: ChangeHash) throws -> [ObjectID: CanvasObject] {
        ScopeDocument(id: id, doc: try doc.forkAt(heads: [hash])).readAll()
    }
}

public extension Workspace {
    /// Restores a historical arrangement of one scope as one new, undoable command.
    /// Objects created later are removed with tombstones; nothing outside the canvas is replayed.
    @discardableResult
    func restore(scope: ScopeID, to historic: [ObjectID: CanvasObject]) throws -> Int {
        var n = 0
        try perform("Restore arrangement") { tx in
            for (id, cur) in objects where cur.scope == scope {
                if let h = historic[id] {
                    // Previews are runtime state, not arrangement; old preview bytes may be collected.
                    let fields = Field.diff(cur, h).filter { $0 != .prop("previewAssetID") && $0 != .prop("previewTime") }
                    guard !fields.isEmpty else { continue }
                    tx.update(id) { o in for f in fields { f.copy(from: h, into: &o) } }
                    n += 1
                } else if !cur.deleted {
                    tx.update(id) { $0.deleted = true }
                    n += 1
                }
            }
        }
        return n
    }
}

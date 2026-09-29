import CryptoKit
import Foundation
import SQLite3

public struct StagedAsset: Sendable, Equatable {
    public var id: AssetID
    public var mime: String
    public var width: Int
    public var height: Int
    public var size: Int
}

public struct AssetRecord: Sendable, Equatable {
    public var id: AssetID
    public var mime: String
    public var width: Int
    public var height: Int
    public var size: Int
}

/// Controlled storage failures for recovery testing (`CANVAS_FAIL_STORAGE=chunks|assets`).
public enum StorageFailure: String, Sendable { case chunks, assets }

/// Local durable workspace storage: SQLite for document chunks and local records, files for assets.
public final class Store: WorkspacePersistence {
    public let directory: URL
    public let assetsDir: URL
    let stagingDir: URL
    var db: OpaquePointer?
    public var injectedFailure: StorageFailure?

    static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        self.directory = directory
        assetsDir = directory.appendingPathComponent("assets", isDirectory: true)
        stagingDir = directory.appendingPathComponent("staging", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("workspace.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CanvasError.storage("cannot open \(path)")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
        try exec("""
            CREATE TABLE IF NOT EXISTS chunks(seq INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, full INTEGER NOT NULL, bytes BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, mime TEXT, width INTEGER, height INTEGER, size INTEGER, created REAL);
            CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(kind, id));
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            """)
        if let e = ProcessInfo.processInfo.environment["CANVAS_FAIL_STORAGE"] { injectedFailure = StorageFailure(rawValue: e) }
        cleanStaging()
    }

    deinit { sqlite3_close(db) }

    // MARK: SQL helpers

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw CanvasError.storage(m)
        }
    }

    enum Bind { case text(String), blob(Data), int(Int), real(Double) }

    func run(_ sql: String, _ binds: [Bind] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw CanvasError.storage(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(st, idx, s, -1, Self.SQLITE_TRANSIENT)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(d.count), Self.SQLITE_TRANSIENT) }
            case .int(let n): sqlite3_bind_int64(st, idx, Int64(n))
            case .real(let r): sqlite3_bind_double(st, idx, r)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { row?(st!) ; continue }
            if rc == SQLITE_DONE { break }
            throw CanvasError.storage(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func text(_ st: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    static func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(st, i))
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: n)
    }

    // MARK: Documents

    /// Stored chunks per scope: the latest full save followed by later incremental changes.
    public func loadScopes() throws -> [ScopeID: [Data]] {
        var out: [ScopeID: [Data]] = [:]
        try run("SELECT scope, full, bytes FROM chunks ORDER BY seq") { st in
            let s = Self.text(st, 0), full = sqlite3_column_int(st, 1) != 0, b = Self.blob(st, 2)
            if full { out[s] = [b] } else { out[s, default: []].append(b) }
        }
        return out
    }

    public func commit(changes: [ScopeID: Data], assets: [StagedAsset]) throws {
        if injectedFailure == .chunks { throw CanvasError.storage("injected chunk write failure") }
        try exec("BEGIN IMMEDIATE")
        do {
            for a in assets {
                try run("INSERT OR IGNORE INTO assets(id,mime,width,height,size,created) VALUES(?,?,?,?,?,?)",
                        [.text(a.id), .text(a.mime), .int(a.width), .int(a.height), .int(a.size), .real(Date().timeIntervalSince1970)])
            }
            for (s, d) in changes.sorted(by: { $0.key < $1.key }) where !d.isEmpty {
                try run("INSERT INTO chunks(scope, full, bytes) VALUES(?,0,?)", [.text(s), .blob(d)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Replaces a scope's chunks with one full save in a single transaction.
    public func compact(scope: ScopeID, full: Data) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM chunks WHERE scope = ?", [.text(scope)])
            try run("INSERT INTO chunks(scope, full, bytes) VALUES(?,1,?)", [.text(scope), .blob(full)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func chunkCount(scope: ScopeID) -> Int {
        var n = 0
        try? run("SELECT COUNT(*) FROM chunks WHERE scope = ?", [.text(scope)]) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    public func deleteScope(_ scope: ScopeID) throws {
        try run("DELETE FROM chunks WHERE scope = ?", [.text(scope)])
    }

    // MARK: Assets

    /// Writes bytes to staging, fsyncs, and renames into the content-addressed asset directory.
    /// The asset becomes referenced only when a later `commit` includes it.
    public func stageAsset(_ data: Data, mime: String, width: Int, height: Int) throws -> StagedAsset {
        if injectedFailure == .assets { throw CanvasError.storage("injected asset write failure") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dest = assetsDir.appendingPathComponent(hash)
        let staged = StagedAsset(id: hash, mime: mime, width: width, height: height, size: data.count)
        if FileManager.default.fileExists(atPath: dest.path) { return staged }
        let tmp = stagingDir.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw CanvasError.storage("cannot create staging file")
        }
        let fh = try FileHandle(forWritingTo: tmp)
        do {
            try fh.write(contentsOf: data)
            try fh.synchronize()
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: tmp)
            throw CanvasError.storage("asset write failed: \(error.localizedDescription)")
        }
        if rename(tmp.path, dest.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CanvasError.storage("asset rename failed: \(String(cString: strerror(errno)))")
        }
        let dfd = open(assetsDir.path, O_RDONLY)
        if dfd >= 0 { fsync(dfd); close(dfd) }
        return staged
    }

    public func assetURL(_ id: AssetID) -> URL { assetsDir.appendingPathComponent(id) }

    public func assetData(_ id: AssetID) -> Data? { try? Data(contentsOf: assetURL(id)) }

    public func assetRecord(_ id: AssetID) -> AssetRecord? {
        var r: AssetRecord?
        try? run("SELECT id,mime,width,height,size FROM assets WHERE id = ?", [.text(id)]) { st in
            r = AssetRecord(id: Self.text(st, 0), mime: Self.text(st, 1), width: Int(sqlite3_column_int64(st, 2)),
                            height: Int(sqlite3_column_int64(st, 3)), size: Int(sqlite3_column_int64(st, 4)))
        }
        return r
    }

    /// True when the asset row is committed and its bytes exist.
    public func isAssetDurable(_ id: AssetID) -> Bool {
        assetRecord(id) != nil && FileManager.default.fileExists(atPath: assetURL(id).path)
    }

    func cleanStaging() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }

    /// Removes asset files that no committed row references (interrupted writes).
    public func collectOrphanAssets() -> Int {
        var known = Set<String>()
        try? run("SELECT id FROM assets") { known.insert(Self.text($0, 0)) }
        var removed = 0
        for f in (try? FileManager.default.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil)) ?? []
        where !known.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
            removed += 1
        }
        return removed
    }

    // MARK: Local records (restricted metadata, personal views, recovery descriptors)

    public func putRecord<T: Encodable>(_ kind: String, _ id: String, _ value: T) throws {
        let d = try JSONEncoder.sorted.encode(value)
        try run("INSERT OR REPLACE INTO records(kind,id,json) VALUES(?,?,?)", [.text(kind), .text(id), .text(String(data: d, encoding: .utf8)!)])
    }

    public func record<T: Decodable>(_ kind: String, _ id: String, as: T.Type) -> T? {
        var s: String?
        try? run("SELECT json FROM records WHERE kind = ? AND id = ?", [.text(kind), .text(id)]) { s = Self.text($0, 0) }
        return s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func records<T: Decodable>(_ kind: String, as: T.Type) -> [String: T] {
        var out: [String: T] = [:]
        try? run("SELECT id, json FROM records WHERE kind = ?", [.text(kind)]) { st in
            if let d = Self.text(st, 1).data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: d) {
                out[Self.text(st, 0)] = v
            }
        }
        return out
    }

    public func deleteRecord(_ kind: String, _ id: String) {
        try? run("DELETE FROM records WHERE kind = ? AND id = ?", [.text(kind), .text(id)])
    }

    public func meta(_ key: String) -> String? {
        var s: String?
        try? run("SELECT value FROM meta WHERE key = ?", [.text(key)]) { s = Self.text($0, 0) }
        return s
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [.text(key), .text(value)])
    }
}

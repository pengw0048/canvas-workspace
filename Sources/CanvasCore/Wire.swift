import Foundation

/// Collaboration wire message: a JSON header plus optional binary payload.
public struct WireMessage: Sendable {
    public var header: [String: String]
    public var payload: Data

    public init(_ type: String, _ fields: [String: String] = [:], payload: Data = Data()) {
        var h = fields
        h["t"] = type
        header = h
        self.payload = payload
    }

    public var type: String { header["t"] ?? "" }
    public subscript(_ k: String) -> String? { header[k] }

    /// Largest accepted message (header plus payload).
    public static let maxSize = 256 * 1_048_576

    /// [u32 total][u32 headerLen][header JSON][payload], big-endian lengths.
    /// Callers must keep payloads under `maxSize`.
    public func encode() -> Data {
        let h = (try? JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) ?? Data("{}".utf8)
        var out = Data()
        let total = UInt32(4 + h.count + payload.count)
        out.append(contentsOf: withUnsafeBytes(of: total.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(h.count).bigEndian, Array.init))
        out.append(h)
        out.append(payload)
        return out
    }

    public enum DecodeError: Error { case malformed }

    /// Decodes as many whole messages as `buffer` holds, leaving the remainder.
    /// Throws on lengths that are inconsistent or over `maxSize`; the connection should then close.
    public static func decode(_ buffer: inout Data) throws -> [WireMessage] {
        var out: [WireMessage] = []
        while buffer.count >= 8 {
            let b = [UInt8](buffer.prefix(8))
            let total = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            let hl = Int(UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]))
            guard total >= 4, total <= maxSize, hl <= total - 4 else { throw DecodeError.malformed }
            guard buffer.count >= 4 + total else { break }
            let start = buffer.startIndex
            let hData = buffer.subdata(in: (start + 8)..<(start + 8 + hl))
            let payload = buffer.subdata(in: (start + 8 + hl)..<(start + 4 + total))
            buffer = buffer.subdata(in: (start + 4 + total)..<buffer.endIndex)
            let header = ((try? JSONSerialization.jsonObject(with: hData)) as? [String: String]) ?? [:]
            out.append(WireMessage(header: header, payload: payload))
        }
        return out
    }

    init(header: [String: String], payload: Data) { self.header = header; self.payload = payload }
}

/// Which assets a participant may fetch from a scope: only those its objects reference.
public extension ScopeDocument {
    func referencedAssets() -> Set<AssetID> {
        var s = Set<AssetID>()
        for o in readAll().values {
            if let a = o.props.assetID { s.insert(a) }
            if let a = o.props.previewAssetID { s.insert(a) }
        }
        return s
    }
}

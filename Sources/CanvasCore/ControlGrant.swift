import Foundation

/// A remote input event, normalized to the shared surface (0...1).
public struct RemoteInputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case down, up, drag, move, scroll, key, text }
    public var kind: Kind
    public var x: Double = 0
    public var y: Double = 0
    public var dx: Double = 0
    public var dy: Double = 0
    public var keyCode: Int?
    public var keyDown: Bool?
    public var text: String?
    public var flags: UInt64 = 0
    public init(kind: Kind) { self.kind = kind }
}

/// Single-controller arbitration for one shared runtime (§9.3).
///
/// Grants are session-bound and carry a generation. Events from any other generation, or replayed
/// sequence numbers, are rejected. Every transfer reports the keys and buttons that must be released.
public struct ControlArbiter: Sendable {
    public private(set) var controller: String?
    public private(set) var generation: UInt64 = 0
    public private(set) var lastSeq: UInt64 = 0
    public private(set) var heldKeys: Set<Int> = []
    public private(set) var mouseDown = false
    public private(set) var paused: String?

    /// Generations start from the session clock so grants from an earlier host session never match.
    public init(startingAt g: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) { generation = g }

    public enum Verdict: Equatable, Sendable {
        case accept
        case reject(String)
    }

    /// Grants control to `user`, returning inputs to release from the previous controller.
    public mutating func grant(to user: String) -> (generation: UInt64, release: (keys: Set<Int>, mouse: Bool)) {
        let release = (heldKeys, mouseDown)
        generation += 1
        controller = user
        lastSeq = 0
        heldKeys = []
        mouseDown = false
        paused = nil
        return (generation, release)
    }

    /// Revokes the current grant (reclaim, disconnect, or expiry). No automatic hand-off.
    public mutating func revoke() -> (keys: Set<Int>, mouse: Bool) {
        let release = (heldKeys, mouseDown)
        generation += 1
        controller = nil
        heldKeys = []
        mouseDown = false
        return release
    }

    public mutating func pause(_ reason: String?) { paused = reason }

    public mutating func check(from user: String, generation g: UInt64, seq: UInt64, event: RemoteInputEvent) -> Verdict {
        guard let c = controller, c == user else { return .reject("not the controller") }
        guard g == generation else { return .reject("stale grant") }
        guard seq > lastSeq else { return .reject("duplicate or reordered event") }
        if let p = paused, event.kind != .up, !(event.kind == .key && event.keyDown == false) { return .reject(p) }
        lastSeq = seq
        switch event.kind {
        case .down: mouseDown = true
        case .up: mouseDown = false
        case .key:
            if let k = event.keyCode {
                if event.keyDown == true { heldKeys.insert(k) } else { heldKeys.remove(k) }
            }
        default: break
        }
        return .accept
    }
}

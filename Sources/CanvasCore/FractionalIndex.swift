import Foundation

/// Base-62 fractional keys for stacking order; ties break by object ID.
public enum FractionalIndex {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = digits.count
    static let value: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })

    /// A key strictly between `a` and `b` (nil means open-ended).
    public static func between(_ a: String?, _ b: String?) -> String {
        let da = (a ?? "").compactMap { value[$0] }
        let db = b.map { $0.compactMap { value[$0] } }
        if let db, !(compare(da, db) < 0) {
            // Out-of-order input: fall back to just after `a`.
            return String(midpoint(da, nil).map { digits[$0] })
        }
        return String(midpoint(da, db).map { digits[$0] })
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : -1, y = i < b.count ? b[i] : -1
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func midpoint(_ a: [Int], _ b: [Int]?) -> [Int] {
        if let b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : 0) == b[n] { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + midpoint(Array(a.dropFirst(min(n, a.count))), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first ?? 0
        let digitB = b?.first ?? base
        if digitB - digitA > 1 { return [(digitA + digitB) / 2] }
        if let b, b.count > 1 { return [b[0]] }
        return [digitA] + midpoint(Array(a.dropFirst()), nil)
    }

    /// `n` ascending keys after `a`.
    public static func sequence(after a: String?, count n: Int) -> [String] {
        var out: [String] = []
        var last = a
        for _ in 0..<n {
            let k = between(last, nil)
            out.append(k)
            last = k
        }
        return out
    }
}

import AppKit

enum Theme {
    static let canvasBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.955, alpha: 1)
    }
    static let gridDot = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.12)
    }
    static let selection = NSColor.controlAccentColor
    static let focus = NSColor.systemOrange
    static let danger = NSColor.systemRed
    static let cardBackground = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.2, alpha: 1) : .white
    }
    static let cardBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.14)
    }
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor

    static let stickyColors: [(String, String)] = [
        ("Yellow", "#FFE58A"), ("Orange", "#FFC48A"), ("Pink", "#FFB3C7"), ("Purple", "#D5C2FF"),
        ("Blue", "#AFD3FF"), ("Green", "#B8E6B0"), ("Gray", "#E3E3E3"),
    ]
    static let inkColors: [String] = ["#1E1E1E", "#E5484D", "#0B84F3", "#30A46C", "#F5A524"]
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            self.init(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                      blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
        } else if s.count == 6 {
            self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                      blue: CGFloat(v & 0xff) / 255, alpha: 1)
        } else { return nil }
    }

    /// Resolves a dynamic color for use in a CALayer under the given appearance.
    func cg(_ appearance: NSAppearance) -> CGColor {
        var out = cgColor
        appearance.performAsCurrentDrawingAppearance { out = self.cgColor }
        return out
    }
}

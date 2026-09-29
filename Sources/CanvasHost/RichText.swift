import AppKit
import CanvasCore

/// Conversion between canvas text marks and attributed strings (rendering, editing, clipboard).
enum RichText {
    static func attributed(_ text: String, marks: [TextMark], font: NSFont, color: NSColor, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraph { base[.paragraphStyle] = paragraph }
        let s = NSMutableAttributedString(string: text, attributes: base)
        for m in marks {
            let a = text.utf16Offset(scalar: m.start), b = text.utf16Offset(scalar: m.end)
            guard b > a else { continue }
            let r = NSRange(location: a, length: b - a)
            switch m.name {
            case "bold", "italic":
                s.enumerateAttribute(.font, in: r) { v, sub, _ in
                    let f = (v as? NSFont) ?? font
                    let trait: NSFontTraitMask = m.name == "bold" ? .boldFontMask : .italicFontMask
                    s.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
                }
            case "link":
                s.addAttributes([.link: m.value, .underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.linkColor], range: r)
            default: break
            }
        }
        return s
    }

    /// Marks described by an attributed string's fonts and links.
    static func marks(from s: NSAttributedString) -> [TextMark] {
        let text = s.string
        var out: [TextMark] = []
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttributes(in: full) { attrs, r, _ in
            let a = text.scalarOffset(utf16: r.location), b = text.scalarOffset(utf16: r.location + r.length)
            if let f = attrs[.font] as? NSFont {
                let t = NSFontManager.shared.traits(of: f)
                if t.contains(.boldFontMask) { out.append(TextMark(name: "bold", start: a, end: b, value: "true")) }
                if t.contains(.italicFontMask) { out.append(TextMark(name: "italic", start: a, end: b, value: "true")) }
            }
            if let l = attrs[.link] { out.append(TextMark(name: "link", start: a, end: b, value: (l as? URL)?.absoluteString ?? "\(l)")) }
        }
        return TextMark.normalized(out)
    }
}

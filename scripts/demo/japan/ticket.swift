// Draws the train ticket PDF for the trip demo: swift ticket.swift <out.pdf>
import AppKit
var box = CGRect(x: 0, y: 0, width: 520, height: 250)
let ctx = CGContext(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 1).setFill()
NSBezierPath(roundedRect: box.insetBy(dx: 6, dy: 6), xRadius: 16, yRadius: 16).fill()
NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.3, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: 6, y: 196, width: 508, height: 48)).fill()
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: NSColor = .black, _ w: NSFont.Weight = .regular) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c]).draw(at: CGPoint(x: x, y: y))
}
text("JR 新幹線 のぞみ 7号", 24, 208, 20, .white, .semibold)
text("東京", 24, 120, 40, .black, .bold)
text("→", 150, 124, 32)
text("京都", 210, 120, 40, .black, .bold)
text("2026年4月12日  9:00発 → 11:15着", 24, 84, 17)
text("8号車 12番 A・B・C席 · 大人3名", 24, 56, 17)
text("¥ 14,170 × 3", 360, 56, 17, .darkGray, .medium)
ctx.endPDFPage()
ctx.closePDF()

// Renders the demo bar chart: chart <out.png>
import AppKit
let W = 1200, H = 760
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .black) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: CGPoint(x: x, y: y))
}
text("p95 latency by region (ms)", 70, CGFloat(H) - 90, 34, .semibold)
text("before vs. after the read-through cache", 70, CGFloat(H) - 130, 22, .regular, .darkGray)
let regions = ["us-east", "eu-west", "ap-south", "sa-east"], before: [CGFloat] = [42, 47, 55, 51], after: [CGFloat] = [17, 19, 23, 21]
let base: CGFloat = 110, scale: CGFloat = 8.2
for (i, r) in regions.enumerated() {
    let x = 110 + CGFloat(i) * 260
    ctx.setFillColor(NSColor(srgbRed: 0.78, green: 0.8, blue: 0.84, alpha: 1).cgColor); ctx.fill(CGRect(x: x, y: base, width: 90, height: before[i] * scale))
    ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.52, blue: 0.95, alpha: 1).cgColor); ctx.fill(CGRect(x: x + 100, y: base, width: 90, height: after[i] * scale))
    text("\(Int(before[i]))", x + 28, base + before[i] * scale + 8, 22, .medium, .darkGray)
    text("\(Int(after[i]))", x + 128, base + after[i] * scale + 8, 22, .semibold, NSColor(srgbRed: 0.04, green: 0.45, blue: 0.85, alpha: 1))
    text(r, x + 45, base - 44, 22, .medium)
}
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

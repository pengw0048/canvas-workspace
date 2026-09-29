import AppKit

/// The app icon, drawn in code so unbundled development builds show it in the Dock too.
enum AppIcon {
    static func png(_ px: Int) -> Data {
        let s = CGFloat(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        let body = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
        NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.35, blue: 0.95, alpha: 1),
                   ending: NSColor(calibratedRed: 0.55, green: 0.3, blue: 0.9, alpha: 1))!.draw(in: body, angle: -60)
        body.addClip()
        // Dot grid: the infinite canvas.
        NSColor.white.withAlphaComponent(0.22).setFill()
        let step = s * 0.075
        var y = tile.minY + step / 2
        while y < tile.maxY {
            var x = tile.minX + step / 2
            while x < tile.maxX { NSBezierPath(ovalIn: NSRect(x: x - s * 0.006, y: y - s * 0.006, width: s * 0.012, height: s * 0.012)).fill(); x += step }
            y += step
        }
        // Windows placed on the canvas.
        func card(_ r: NSRect, _ bar: NSColor) {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: s * 0.025, yRadius: s * 0.025).fill()
            NSGraphicsContext.restoreGraphicsState()
            bar.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.maxY - s * 0.045, width: r.width, height: s * 0.045), xRadius: s * 0.02, yRadius: s * 0.02).fill()
        }
        card(NSRect(x: s * 0.2, y: s * 0.46, width: s * 0.36, height: s * 0.26), NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.2, alpha: 1))
        card(NSRect(x: s * 0.46, y: s * 0.24, width: s * 0.34, height: s * 0.28), NSColor(calibratedRed: 0.2, green: 0.66, blue: 0.33, alpha: 1))
        NSColor(calibratedRed: 1, green: 0.88, blue: 0.45, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.62, y: s * 0.58, width: s * 0.17, height: s * 0.15), xRadius: s * 0.015, yRadius: s * 0.015).fill()
        // A collaborator's cursor.
        let c = NSBezierPath()
        let p = NSPoint(x: s * 0.36, y: s * 0.4)
        c.move(to: p)
        c.line(to: NSPoint(x: p.x, y: p.y - s * 0.16))
        c.line(to: NSPoint(x: p.x + s * 0.045, y: p.y - s * 0.12))
        c.line(to: NSPoint(x: p.x + s * 0.11, y: p.y - s * 0.12))
        c.close()
        NSColor(calibratedRed: 0.13, green: 0.85, blue: 0.95, alpha: 1).setFill()
        c.fill()
        NSColor.white.setStroke()
        c.lineWidth = s * 0.012
        c.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static var image: NSImage { NSImage(data: png(512)) ?? NSImage() }

    /// Writes an .iconset folder for `iconutil` (scripts/build-app.sh).
    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                           ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            try png(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }
}

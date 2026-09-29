// A banner that stays on screen while real-input tests run. Clicks pass through it.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!.visibleFrame
let size = NSSize(width: 640, height: 54)
let panel = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 8, width: size.width, height: size.height),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.ignoresMouseEvents = true
panel.hasShadow = true
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
// Kept out of screenshots and recordings, so demo captures stay clean.
panel.sharingType = .none
let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
bg.material = .hudWindow
bg.state = .active
bg.wantsLayer = true
bg.layer?.cornerRadius = 12
bg.layer?.borderWidth = 2
bg.layer?.borderColor = NSColor.systemOrange.cgColor
let label = NSTextField(labelWithString: "")
label.font = .systemFont(ofSize: 14, weight: .semibold)
label.alignment = .center
label.frame = NSRect(x: 12, y: 16, width: size.width - 24, height: 22)
bg.addSubview(label)
panel.contentView = bg
let start = Date()
func tick() {
    let s = Int(Date().timeIntervalSince(start))
    label.stringValue = "⚠︎ Input test running — please don’t touch the mouse or keyboard  (\(s / 60):\(String(format: "%02d", s % 60)))"
}
tick()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
panel.orderFrontRegardless()
app.run()

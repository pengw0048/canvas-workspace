import AppKit

/// Shows shortcuts and typed text at the bottom of the screen for recordings (`--keycast`), in any app.
final class Keycast {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var text = ""
    private var hide: Timer?
    private var monitor: Any?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let v = NSVisualEffectView(frame: panel.contentView!.bounds)
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
        v.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(v)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 16, y: 11, width: 168, height: 32)
        label.autoresizingMask = [.width]
        v.addSubview(label)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.show(e) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.show(e); return e }
    }

    private func show(_ e: NSEvent) {
        let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let named: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = named[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        if f.subtracting(.shift).isEmpty && named[e.keyCode] == nil {
            // Plain typing accumulates into a line.
            text = String((text + (e.characters ?? "")).suffix(28))
        } else {
            var s = ""
            if f.contains(.control) { s += "⌃" }
            if f.contains(.option) { s += "⌥" }
            if f.contains(.shift) { s += "⇧" }
            if f.contains(.command) { s += "⌘" }
            text = s + key
        }
        label.stringValue = text
        let w = max(90, label.attributedStringValue.size().width + 48)
        guard let sc = NSScreen.main else { return }
        panel.setFrame(NSRect(x: sc.frame.midX - w / 2, y: sc.visibleFrame.minY + 28, width: w, height: 54), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hide?.invalidate()
        hide = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.text = ""
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.panel.animator().alphaValue = 0 }
        }
    }
}

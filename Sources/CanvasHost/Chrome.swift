import AppKit
import CanvasCore

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded translucent panel.
func makePanel() -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .hudWindow
    v.blendingMode = .withinWindow
    v.state = .active
    v.wantsLayer = true
    v.layer?.cornerRadius = 10
    v.layer?.masksToBounds = true
    return v
}

func pill(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector?) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .recessed
    b.controlSize = .regular
    if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); b.imagePosition = .imageLeading }
    b.font = .systemFont(ofSize: 12, weight: .medium)
    return b
}

/// Compact creation/tool strip at the bottom of the canvas.
final class ToolbarView: NSView {
    unowned let canvas: CanvasView
    let panel = makePanel()
    var buttons: [Tool: NSButton] = [:]
    let stack = NSStackView()

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        addSubview(panel)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        panel.addSubview(stack)
        for t in Tool.allCases {
            let b = NSButton(image: NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)!, target: self, action: #selector(pick(_:)))
            b.bezelStyle = .recessed
            b.setButtonType(.pushOnPushOff)
            b.toolTip = t.title
            b.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
            b.setAccessibilityLabel(t.title)
            buttons[t] = b
            stack.addArrangedSubview(b)
        }
        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)
        let imp = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import file or image")!, target: canvas.app, action: #selector(AppController.importFile(_:)))
        imp.bezelStyle = .recessed
        imp.toolTip = "Import file or image…"
        stack.addArrangedSubview(imp)
        let adm = NSButton(image: NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "Bring in an application window")!, target: canvas.app, action: #selector(AppController.admitWindow(_:)))
        adm.bezelStyle = .recessed
        adm.toolTip = "Bring in an application window…"
        stack.addArrangedSubview(adm)
        let web = NSButton(image: NSImage(systemSymbolName: "globe", accessibilityDescription: "Add a web page")!, target: canvas.app, action: #selector(AppController.addWebPage(_:)))
        web.bezelStyle = .recessed
        web.toolTip = "Add a web page…"
        stack.addArrangedSubview(web)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func pick(_ b: NSButton) {
        if let id = b.identifier?.rawValue, let t = Tool(rawValue: id) { canvas.tool = t }
        canvas.window?.makeFirstResponder(canvas)
    }

    func update() {
        for (t, b) in buttons { b.state = t == canvas.tool ? .on : .off }
    }

    var autoHide = false
    var shown = true

    /// In presentation mode the strip appears only while the pointer is near the bottom edge.
    func setAutoHide(_ on: Bool) {
        autoHide = on
        reveal(!on)
    }

    func reveal(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = show ? 1 : 0
        }
    }

    func pointerMoved(_ vp: CGPoint, in bounds: NSRect) {
        guard autoHide else { return }
        reveal(bounds.maxY - vp.y < 110)
    }

    func layoutIn(_ r: NSRect) {
        let size = stack.fittingSize
        frame = NSRect(x: r.midX - size.width / 2, y: r.maxY - size.height - 16, width: size.width, height: size.height)
        panel.frame = bounds
        stack.frame = panel.bounds
    }
}

/// Status, hints, and the workspace menu. Passes clicks through except on its controls.
final class HUDView: NSView {
    unowned let canvas: CanvasView
    let menuButton: NSButton
    let statusPanel = makePanel()
    let statusLabel = NSTextField(labelWithString: "")
    let inputLabel = NSTextField(labelWithString: "")
    let hintPanel = makePanel()
    let hintLabel = NSTextField(labelWithString: "")
    let bannerPanel = makePanel()
    let bannerLabel = NSTextField(labelWithString: "")
    let bannerButton: NSButton
    let emptyHint = NSTextField(wrappingLabelWithString: "")
    var flashTimer: Timer?

    init(canvas: CanvasView) {
        self.canvas = canvas
        menuButton = pill("Workspace", symbol: "square.grid.2x2", target: nil, action: nil)
        bannerButton = pill("Return to canvas", symbol: "arrow.uturn.backward", target: nil, action: nil)
        super.init(frame: .zero)
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        bannerButton.target = self
        bannerButton.action = #selector(bannerAction(_:))
        addSubview(menuButton)
        addSubview(statusPanel)
        for l in [statusLabel, inputLabel, hintLabel, bannerLabel] { l.font = .systemFont(ofSize: 12, weight: .medium); l.lineBreakMode = .byTruncatingTail }
        statusLabel.textColor = .secondaryLabelColor
        statusPanel.addSubview(statusLabel)
        statusPanel.addSubview(inputLabel)
        hintPanel.addSubview(hintLabel)
        hintPanel.isHidden = true
        addSubview(hintPanel)
        bannerPanel.addSubview(bannerLabel)
        bannerPanel.addSubview(bannerButton)
        bannerPanel.isHidden = true
        addSubview(bannerPanel)
        emptyHint.alignment = .center
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.font = .systemFont(ofSize: 15)
        emptyHint.stringValue = "This canvas is empty.\nDouble-click to write · S for a sticky note · ⇧⌘N to bring in an application window · drop files, images, or links anywhere"
        addSubview(emptyHint)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v === self ? nil : v
    }

    override func layout() {
        super.layout()
        menuButton.sizeToFit()
        menuButton.frame.origin = CGPoint(x: 14, y: 12)
        statusLabel.sizeToFit()
        inputLabel.sizeToFit()
        let w = max(statusLabel.frame.width, inputLabel.frame.width) + 20
        statusPanel.frame = NSRect(x: bounds.maxX - w - 14, y: 12, width: w, height: 42)
        inputLabel.frame = NSRect(x: 10, y: 4, width: w - 20, height: 16)
        statusLabel.frame = NSRect(x: 10, y: 21, width: w - 20, height: 16)
        hintLabel.sizeToFit()
        let hw = min(bounds.width - 40, hintLabel.frame.width + 24)
        hintPanel.frame = NSRect(x: bounds.midX - hw / 2, y: bounds.maxY - 110, width: hw, height: 30)
        hintLabel.frame = NSRect(x: 12, y: 7, width: hw - 24, height: 16)
        bannerLabel.sizeToFit()
        bannerButton.sizeToFit()
        let bw = bannerLabel.frame.width + bannerButton.frame.width + 36
        bannerPanel.frame = NSRect(x: bounds.midX - bw / 2, y: 12, width: bw, height: 36)
        bannerLabel.frame = NSRect(x: 12, y: 10, width: bannerLabel.frame.width, height: 16)
        bannerButton.frame.origin = CGPoint(x: bannerLabel.frame.maxX + 12, y: 6)
        emptyHint.frame = NSRect(x: bounds.midX - 280, y: bounds.midY - 30, width: 560, height: 60)
    }

    func update() {
        let app = canvas.app
        var parts = [app.workspace.saveState.label]
        if let c = app.collab?.statusText { parts.append(c) }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        if case .failed = app.workspace.saveState { statusLabel.textColor = .systemRed } else { statusLabel.textColor = .secondaryLabelColor }
        inputLabel.stringValue = app.runtime.inputOwnerText
        emptyHint.isHidden = !app.workspace.live.isEmpty
        // Presentation keeps only failures visible; the workspace menu stays reachable but quiet.
        let failing: Bool = { if case .failed = app.workspace.saveState { return true }; return false }()
        statusPanel.isHidden = app.presenting && !failing
        menuButton.alphaValue = app.presenting ? 0.35 : 1
        if let f = canvas.followUser {
            bannerPanel.isHidden = false
            bannerLabel.stringValue = "Following \(app.collab?.name(of: f) ?? "collaborator") — navigate to stop"
            bannerButton.title = "Stop following"
        } else if canvas.focusReturn != nil && canvas.app.runtime.activeObject == nil {
            bannerPanel.isHidden = false
            bannerLabel.stringValue = "Focus view — Esc returns to the previous view"
            bannerButton.title = "Return"
        } else {
            bannerPanel.isHidden = true
        }
        needsLayout = true
    }

    @objc func bannerAction(_ s: Any?) {
        if canvas.followUser != nil { canvas.stopFollowing() } else { canvas.exitFocusView() }
    }

    func showHint(_ s: String?) {
        guard let s else { if flashTimer == nil { hintPanel.isHidden = true }; return }
        hintLabel.stringValue = s
        hintPanel.isHidden = false
        needsLayout = true
    }

    func flash(_ s: String, seconds: Double = 3) {
        flashTimer?.invalidate()
        showHint(s)
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.flashTimer = nil
            self?.hintPanel.isHidden = true
        }
    }

    @objc func showMenu(_ b: NSButton) {
        let m = canvas.app.workspaceMenu()
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }
}

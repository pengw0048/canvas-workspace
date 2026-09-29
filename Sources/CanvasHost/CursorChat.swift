import AppKit
import CanvasCore

/// Cursor chat: "/" opens a bubble at the pointer; collaborators see the text beside this person's cursor as it is typed.
extension CanvasView: NSTextFieldDelegate {
    static let chatLinger: TimeInterval = 4

    func startChat() {
        guard app.collab?.isConnected == true else { hud.flash("Cursor chat needs a shared workspace"); return }
        chatField?.superview?.removeFromSuperview()
        let p = lastPointerWorld.map { camera.toView($0) } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        // The field sits in a bubble styled like the one collaborators see.
        let bubble = NSView(frame: NSRect(x: p.x + 10, y: p.y + 14, width: 140, height: 30))
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = (app.collab?.myColor ?? .systemPink).cgColor
        bubble.layer?.cornerRadius = 12
        bubble.shadow = NSShadow()
        bubble.layer?.shadowOpacity = 0.25
        bubble.layer?.shadowRadius = 6
        bubble.layer?.shadowOffset = CGSize(width: 0, height: -2)
        let f = NSTextField(string: "")
        f.font = Self.chatFont
        f.placeholderAttributedString = NSAttributedString(string: "Say something", attributes: [.font: Self.chatFont, .foregroundColor: NSColor.white.withAlphaComponent(0.65)])
        f.isBordered = false
        f.focusRingType = .none
        f.drawsBackground = false
        f.textColor = .white
        f.frame = NSRect(x: 10, y: 6, width: 120, height: 18)
        f.delegate = self
        bubble.addSubview(f)
        addSubview(bubble)
        window?.makeFirstResponder(f)
        chatField = f
        setChat("")
    }

    static let chatFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f === chatField, let bubble = f.superview else { return }
        let w = min(280, max(120, NSAttributedString(string: f.stringValue, attributes: [.font: Self.chatFont]).size().width + 12))
        bubble.frame.size.width = w + 20
        f.frame.size.width = w
        setChat(f.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === chatField else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) { endChat(keep: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endChat(keep: false); return true }
        return false
    }

    /// Publishes the current chat text; it clears itself after a pause.
    func setChat(_ text: String?) {
        chatText = text
        chatClear?.invalidate()
        if text != nil {
            chatClear = Timer.scheduledTimer(withTimeInterval: Self.chatLinger, repeats: false) { [weak self] _ in self?.endChat(keep: false) }
        }
        app.collab?.lastPresenceSent = .distantPast
        app.collab?.publishPresence(from: self)
        updatePresence()
    }

    func endChat(keep: Bool) {
        chatField?.superview?.removeFromSuperview()
        chatField = nil
        window?.makeFirstResponder(self)
        if keep, let t = chatText, !t.isEmpty {
            chatClear?.invalidate()
            chatClear = Timer.scheduledTimer(withTimeInterval: Self.chatLinger, repeats: false) { [weak self] _ in self?.setChat(nil) }
            updatePresence()
        } else if chatText != nil {
            chatClear?.invalidate()
            chatText = nil
            app.collab?.lastPresenceSent = .distantPast
            app.collab?.publishPresence(from: self)
            updatePresence()
        }
    }

    /// The standard macOS arrow: black with a white outline.
    func drawSystemArrow(at p: CGPoint) {
        let a = CAShapeLayer()
        let path = CGMutablePath()
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4, 13), (7, 20), (9.5, 19), (6.5, 12.5), (12, 12.5)]
        path.addLines(between: pts.map { CGPoint(x: p.x + $0.0, y: p.y + $0.1) })
        path.closeSubpath()
        a.path = path
        a.fillColor = NSColor.black.cgColor
        a.strokeColor = NSColor.white.cgColor
        a.lineWidth = 1.2
        a.lineJoin = .round
        a.shadowColor = NSColor.black.cgColor
        a.shadowOpacity = 0.3
        a.shadowRadius = 1.5
        a.shadowOffset = CGSize(width: 0, height: 1)
        presenceLayer.addSublayer(a)
    }

    /// A cursor arrow plus a name pill; with chat text the pill grows into a speech bubble.
    /// Your own cursor passes no name: you never see your own name.
    func drawCursor(at p: CGPoint, name: String?, color: NSColor, chat: String?, arrow drawArrow: Bool = true) {
        let arrow = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: p)
        path.addLine(to: CGPoint(x: p.x, y: p.y + 16))
        path.addLine(to: CGPoint(x: p.x + 4.5, y: p.y + 12))
        path.addLine(to: CGPoint(x: p.x + 11, y: p.y + 12))
        path.closeSubpath()
        arrow.path = path
        arrow.fillColor = color.cgColor
        arrow.strokeColor = NSColor.white.cgColor
        arrow.lineWidth = 1
        if drawArrow { presenceLayer.addSublayer(arrow) }
        let chat = chat.flatMap { $0.isEmpty ? nil : $0 }
        guard name != nil || chat != nil else { return }
        let label = TextLayer()
        let text = NSMutableAttributedString(string: name ?? "", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        var size = CGSize(width: text.size().width + 10, height: 17)
        if let chat {
            text.append(NSAttributedString(string: (name == nil ? "" : "\n") + chat, attributes: [.font: Self.chatFont, .foregroundColor: NSColor.white]))
            let r = text.boundingRect(with: CGSize(width: 260, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
            size = CGSize(width: ceil(r.width) + 20, height: ceil(r.height) + 12)
            label.inset = CGSize(width: 10, height: 6)
            label.cornerRadius = 12
            label.shadowColor = NSColor.black.cgColor
            label.shadowOpacity = 0.25
            label.shadowRadius = 6
            label.shadowOffset = CGSize(width: 0, height: 2)
        } else {
            label.inset = CGSize(width: 5, height: 2)
            label.cornerRadius = 4
        }
        label.attributed = text
        label.backgroundColor = color.cgColor
        label.frame = CGRect(origin: CGPoint(x: p.x + 10, y: p.y + 14), size: size)
        label.contentsScale = renderer.backingScale
        label.setNeedsDisplay()
        presenceLayer.addSublayer(label)
    }
}

import AppKit
import CanvasCore

/// Cursor chat: "/" opens a bubble at the pointer; collaborators see the text beside this person's cursor as it is typed.
extension CanvasView: NSTextFieldDelegate {
    static let chatLinger: TimeInterval = 4

    func startChat() {
        guard app.collab?.isConnected == true else { hud.flash("Cursor chat needs a shared workspace"); return }
        chatField?.removeFromSuperview()
        let p = lastPointerWorld.map { camera.toView($0) } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let f = NSTextField(string: "")
        f.placeholderString = "Say something"
        f.font = .systemFont(ofSize: 13, weight: .medium)
        f.isBordered = false
        f.focusRingType = .none
        f.drawsBackground = true
        f.backgroundColor = app.collab?.myColor ?? .systemPink
        f.textColor = .white
        f.wantsLayer = true
        f.layer?.cornerRadius = 10
        f.layer?.masksToBounds = true
        f.frame = NSRect(x: p.x + 14, y: p.y + 14, width: 240, height: 24)
        f.delegate = self
        addSubview(f)
        window?.makeFirstResponder(f)
        chatField = f
        setChat("")
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f === chatField else { return }
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
        chatField?.removeFromSuperview()
        chatField = nil
        window?.makeFirstResponder(self)
        if keep, let t = chatText, !t.isEmpty {
            chatClear?.invalidate()
            chatClear = Timer.scheduledTimer(withTimeInterval: Self.chatLinger, repeats: false) { [weak self] _ in self?.setChat(nil) }
        } else if chatText != nil {
            chatClear?.invalidate()
            chatText = nil
            app.collab?.lastPresenceSent = .distantPast
            app.collab?.publishPresence(from: self)
            updatePresence()
        }
    }

    /// A cursor arrow plus a name pill; with chat text the pill grows into a speech bubble.
    func drawCursor(at p: CGPoint, name: String, color: NSColor, chat: String?, arrow drawArrow: Bool = true) {
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
        let label = TextLayer()
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        var size = CGSize(width: text.size().width + 10, height: 17)
        if let chat, !chat.isEmpty {
            text.append(NSAttributedString(string: "\n" + chat, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]))
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

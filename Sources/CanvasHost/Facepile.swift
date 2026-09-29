import AppKit
import CanvasCore

/// Avatars of everyone in the shared workspace, you last; click someone to follow their view.
final class FacepileView: NSView {
    weak var canvas: CanvasView?
    private var people: [(id: String, name: String, color: NSColor)] = []
    static let side: CGFloat = 28

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Rebuilds from current presence; hidden when nobody else is here.
    func refresh() {
        guard let c = canvas, let collab = c.app.collab else { isHidden = true; return }
        let others = collab.presence.values.filter { $0.userID != collab.me }.sorted { $0.name < $1.name }
        people = others.map { ($0.userID, $0.name, $0.color) } + [(collab.me, c.app.identity.name, collab.myColor)]
        isHidden = others.isEmpty
        let step = Self.side - 6
        frame.size = CGSize(width: step * CGFloat(people.count - 1) + Self.side + 4, height: Self.side + 4)
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (i, p) in people.enumerated() {
            let a = TextLayer()
            a.frame = CGRect(x: 2 + CGFloat(i) * step, y: 2, width: Self.side, height: Self.side)
            a.cornerRadius = Self.side / 2
            a.backgroundColor = p.color.cgColor
            let followed = c.followUser == p.id
            a.borderWidth = followed ? 3 : 2
            a.borderColor = (followed ? Theme.focus : NSColor.white).cgColor
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            a.attributed = NSAttributedString(string: String(p.name.prefix(1)).uppercased(),
                                              attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
            a.verticallyCentered = true
            a.contentsScale = window?.backingScaleFactor ?? 2
            a.setNeedsDisplay()
            layer?.addSublayer(a)
        }
        toolTip = people.map { $0.id == collab.me ? "\($0.name) (you)" : $0.name }.joined(separator: ", ")
    }

    override func mouseDown(with e: NSEvent) {
        guard let c = canvas, let me = c.app.collab?.me else { return }
        let x = convert(e.locationInWindow, from: nil).x
        let i = min(people.count - 1, max(0, Int((x - 2) / (Self.side - 6))))
        guard people.indices.contains(i), people[i].id != me else { return }
        if c.followUser == people[i].id { c.stopFollowing() } else { c.followUser = people[i].id; c.hud.update() }
        refresh()
    }
}

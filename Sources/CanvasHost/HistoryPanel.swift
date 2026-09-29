import AppKit
import CanvasCore

/// Workspace history (§8.5): preview a past arrangement, then restore it as a new undoable command.
final class HistoryPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let app: AppController
    let panel: NSPanel
    let table = NSTableView()
    let preview = NSImageView()
    let info = NSTextField(labelWithString: "")
    let restoreButton = NSButton(title: "Restore This Arrangement", target: nil, action: nil)
    var scope: ScopeID = Scope.privateID
    var entries: [HistoryEntry] = []
    var historic: [ObjectID: CanvasObject] = [:]

    init(app: AppController) {
        self.app = app
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Workspace History"
        panel.isFloatingPanel = true
        let root = NSView(frame: panel.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 300, height: 456))
        scroll.autoresizingMask = [.height]
        scroll.hasVerticalScroller = true
        let col = NSTableColumn(identifier: .init("e"))
        col.width = 290
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        preview.frame = NSRect(x: 324, y: 80, width: 484, height: 388)
        preview.autoresizingMask = [.width, .height]
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        info.frame = NSRect(x: 324, y: 46, width: 484, height: 28)
        info.autoresizingMask = [.width, .maxYMargin]
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byWordWrapping
        restoreButton.frame = NSRect(x: 324, y: 10, width: 220, height: 30)
        restoreButton.autoresizingMask = [.maxYMargin]
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restore)
        restoreButton.isEnabled = false
        for v in [scroll, preview, info, restoreButton] as [NSView] { root.addSubview(v) }
        panel.contentView = root
    }

    func show(scope s: ScopeID) {
        scope = s
        entries = app.workspace.scopes[s]?.history() ?? []
        table.reloadData()
        info.stringValue = "Choose a point in time to preview it. Nothing changes until you restore. Application actions, websites, and external files are not part of this history."
        preview.image = nil
        restoreButton.isEnabled = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let who = e.author == app.identity.id ? "You" : (app.collab?.name(of: e.author) ?? "Collaborator")
        let t = NSTextField(labelWithString: "")
        let a = NSMutableAttributedString(string: e.name + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        a.append(NSAttributedString(string: "\(who) · \(e.time.formatted(date: .abbreviated, time: .standard))",
                                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        t.attributedStringValue = a
        return t
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let i = table.selectedRow
        guard i >= 0, i < entries.count, let doc = app.workspace.scopes[scope] else { return }
        do {
            historic = try doc.state(at: entries[i].hash)
            let temp = Workspace(workspaceID: app.workspace.workspaceID, user: app.identity.id)
            temp.addScope(ScopeDocument(id: scope, doc: try doc.doc.forkAt(heads: [entries[i].hash])))
            let ids = temp.live.map(\.id)
            preview.image = app.pasteboard.renderComposition(ids, scale: 1, background: Theme.canvasBackground, in: temp)
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            let now = app.workspace.live.filter { $0.scope == scope }
            let changed = now.filter { cur in self.historic[cur.id].map { !Field.diff(cur, $0).isEmpty } ?? true }.count
            info.stringValue = "\(temp.live.count) objects at this point; restoring would change \(changed) current object(s). Restore is one undoable command."
            restoreButton.isEnabled = true
        } catch {
            info.stringValue = "This point could not be previewed: \(error)"
            restoreButton.isEnabled = false
        }
    }

    @objc func restore() {
        do {
            let n = try app.workspace.restore(scope: scope, to: historic)
            app.activeCanvas?.hud.flash("Restored the arrangement (\(n) objects changed). ⌘Z undoes it.")
            panel.orderOut(nil)
        } catch { app.report(error) }
    }
}

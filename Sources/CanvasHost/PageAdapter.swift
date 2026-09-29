import AppKit
import CanvasCore
import WebKit

/// Reference-page adapter (§10). Declared scope:
/// - Shared: the page URL, explicit scroll-follow positions, and quotes with return-to-source anchors.
/// - Individual: each person's account session, rendered content, and scroll unless they follow someone.
/// - Failure modes: responsive layouts make scroll-follow approximate; a quote anchor finds nothing if the page text changed.
final class PageScrollReporter: NSObject, WKScriptMessageHandler {
    weak var service: BrowserService?
    init(_ s: BrowserService) { service = s }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let v = m.webView, let s = service, let id = s.id(of: v) else { return }
        s.pageScrolled(id, fraction: body["fy"] as? Double ?? 0)
    }

    /// Reports the vertical scroll position as a fraction of the scrollable height, at most five times a second.
    static let script = WKUserScript(source: """
        (function(){var t=0;addEventListener('scroll',function(){var n=Date.now();if(n-t<200)return;t=n;
        var h=document.documentElement.scrollHeight-innerHeight;
        window.webkit.messageHandlers.canvasScroll.postMessage({fy:h>0?scrollY/h:0});},{passive:true});})();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
}

extension BrowserService {
    /// A reference page this person scrolled: followers get the same URL and approximate position.
    func pageScrolled(_ id: ObjectID, fraction: Double) {
        guard let o = ws.object(id), (o.props.browserMode ?? .reference) == .reference, app.collab?.shares[o.scope] != nil,
              let url = views[id]?.url?.absoluteString else { return }
        app.collab?.sendAll(WireMessage("page-follow", ["o": id, "url": url, "fy": String(format: "%.4f", fraction)]))
    }

    /// Applies a leader's page position, only for people who follow that leader.
    func applyFollow(_ m: WireMessage) {
        guard let id = m["o"], let from = m["from"], app.canvases.contains(where: { $0.followUser == from }),
              let v = webView(for: id), let fy = Double(m["fy"] ?? "") else { return }
        followedBy[id] = from
        let scroll = { [weak self] in
            v.evaluateJavaScript("scrollTo(0,(document.documentElement.scrollHeight-innerHeight)*\(fy))") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refreshSnapshot(id, store: false) }
            }
        }
        if let u = m["url"], v.url?.absoluteString != u, let url = URL(string: u) {
            pendingScroll[id] = scroll
            v.load(URLRequest(url: url))
        } else if v.isLoading {
            pendingScroll[id] = scroll  // a page still loading would jump back to the top
        } else { scroll() }
    }

    /// Quote the page's selected text as a note that remembers where it came from (a text-fragment link).
    func quoteSelection(_ id: ObjectID, in c: CanvasView) {
        guard let v = webView(for: id), let o = ws.object(id) else { return }
        v.evaluateJavaScript("window.getSelection().toString()") { [weak self] r, _ in
            guard let self, let text = (r as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                c.hud.flash("Select text on the page first")
                return
            }
            let base = (v.url?.absoluteString ?? o.props.url ?? "").components(separatedBy: "#").first ?? ""
            let enc = text.prefix(300).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            var q = CanvasObject(kind: .sticky, geom: Geometry(x: o.geom.x + o.geom.w + 40, y: o.geom.y, w: 280, h: 190), text: "“\(text.prefix(300))”")
            q.props.color = "#E6F0FF"
            q.props.url = base + "#:~:text=" + enc
            q.props.name = "Quote · " + (URL(string: base)?.host ?? v.title ?? "page")
            q.parent = o.parent
            q.scope = o.scope
            if let nid = try? self.ws.create(q, name: "Quote selection") {
                c.selection = [nid]
                c.hud.flash("Quoted. Right-click the quote → Go to source to return to this spot.")
            }
        }
    }

    /// Returns to a quote's source: the page on the canvas scrolls to the text, or the default browser opens it.
    func goToSource(_ quote: ObjectID, in c: CanvasView) {
        guard let q = ws.object(quote), let link = q.props.url, let url = URL(string: link) else { return }
        let base = link.components(separatedBy: "#").first ?? link
        if let page = ws.live.first(where: { $0.kind == .browser && ($0.props.url ?? "").components(separatedBy: "#").first == base }) {
            let text = (q.text.trimmingCharacters(in: CharacterSet(charactersIn: "“”"))).prefix(300)
            webView(for: page.id)?.evaluateJavaScript("window.find(\(jsString(String(text))),false,false,true)&&window.getSelection().getRangeAt(0).startContainer.parentElement.scrollIntoView({block:'center'})") { [weak self] _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refreshSnapshot(page.id, store: false) }
            }
            c.reveal(page.id)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

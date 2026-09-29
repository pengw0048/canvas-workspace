import AppKit
import CanvasCore
import CoreMedia
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case permission, windowUnavailable, protectedContent, notConnected, failed(String)
    var description: String {
        switch self {
        case .permission: return "Screen recording is not allowed. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        case .windowUnavailable: return "The window is not available for capture (it may be minimized, closed, or on another Space)."
        case .protectedContent: return "The window's content is protected or blank, so no capture was created."
        case .notConnected: return "The surface is not connected to a running window. Reconnect it first."
        case .failed(let s): return "Capture failed: \(s)"
        }
    }
}

/// Provenance recorded locally for a capture; restricted fields never enter a shared document.
struct CaptureRecord: Codable {
    var id: String
    var assetID: AssetID
    var sourceObjectID: ObjectID?
    var sourceID: SourceID?
    var appName: String?
    var windowTitle: String?
    var documentPath: String?
    var url: String?
    var time: Double
    /// Normalized crop within the source surface.
    var region: [Double]?
    var pixelSize: [Int]
    var origin: String
}

final class LiveStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let objectID: ObjectID
    var stream: SCStream?
    weak var owner: CaptureService?
    let ciContext = CIContext()
    var visible = true

    init(objectID: ObjectID) { self.objectID = objectID }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attach.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let img = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.app.runtime.didReceiveFrame(img, for: self.objectID)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.owner?.streams[self.objectID] = nil
            self.owner?.app.runtime.liveObjects.remove(self.objectID)
            self.owner?.app.runtime.refreshAll(self.objectID)
        }
    }
}

final class CaptureService {
    unowned let app: AppController
    var streams: [ObjectID: LiveStream] = [:]
    var pending: [ObjectID: String] = [:]
    let queue = DispatchQueue(label: "capture.frames")

    init(app: AppController) { self.app = app }

    var ws: Workspace { app.workspace }

    func pendingStatus(_ id: ObjectID) -> SurfaceStatus? {
        pending[id].map { SurfaceStatus(text: $0, tone: .warning) }
    }

    // MARK: Still capture

    func scWindow(_ id: CGWindowID) async throws -> SCWindow {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permission }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw CaptureError.permission }
        guard let w = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowUnavailable }
        return w
    }

    func stillImage(windowID: CGWindowID, _ done: @escaping (Result<CGImage, Error>) -> Void) {
        Task {
            do {
                let w = try await scWindow(windowID)
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                cfg.width = Int(w.frame.width * scale)
                cfg.height = Int(w.frame.height * scale)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                if Self.isBlank(img) { throw CaptureError.protectedContent }
                await MainActor.run { done(.success(img)) }
            } catch {
                await MainActor.run { done(.failure(error)) }
            }
        }
    }

    /// Protected or unavailable windows come back fully black or transparent.
    static func isBlank(_ img: CGImage) -> Bool {
        let w = 32, h = 32
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var maxV: UInt8 = 0
        for i in 0..<(w * h) { maxV = max(maxV, p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) }
        return maxV < 4
    }

    /// Stores a surface's latest preview; replaces the preview reference but never a frozen capture.
    func storePreview(_ img: CGImage, for id: ObjectID) {
        guard let png = pngData(img, maxPixels: 2_400_000) else { return }
        do {
            let a = try app.session.store.stageAsset(png, mime: "image/png", width: img.width, height: img.height)
            app.images.put(a.id, img)
            try ws.perform("Update preview", assets: [a], recordUndo: false) { tx in
                tx.update(id) { $0.props.previewAssetID = a.id; $0.props.previewTime = Date().timeIntervalSince1970 }
            }
        } catch {
            NSLog("Preview store failed: %@", "\(error)")
        }
    }

    /// Captures a whole surface or a normalized region into a new frozen image next to the source.
    func captureObject(_ id: ObjectID, region: CGRect?, in c: CanvasView) {
        guard let o = ws.object(id) else { return }
        if o.kind == .browser {
            app.browsers.snapshot(id) { [weak self] img in
                guard let self else { return }
                guard let img else { c.hud.flash("The page could not be captured"); return }
                self.commitCapture(img, source: o, region: region, in: c, origin: "browser")
            }
            return
        }
        guard let b = app.runtime.verifiedBinding(id) else {
            c.hud.flash(CaptureError.notConnected.description, seconds: 5)
            return
        }
        c.hud.flash("Capturing…", seconds: 1)
        stillImage(windowID: b.windowID) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let img):
                self.app.runtime.frames[id] = img
                self.app.runtime.frameTimes[id] = Date()
                self.commitCapture(img, source: o, region: region, in: c, origin: "window")
            case .failure(let e):
                c.hud.flash("\(e)", seconds: 6)
                if case CaptureError.permission = e { self.app.runtime.requestPermissions() }
            }
        }
    }

    func crop(_ img: CGImage, _ norm: CGRect) -> CGImage? {
        let r = CGRect(x: norm.minX * CGFloat(img.width), y: norm.minY * CGFloat(img.height),
                       width: norm.width * CGFloat(img.width), height: norm.height * CGFloat(img.height)).integral
        return img.cropping(to: r)
    }

    func commitCapture(_ full: CGImage, source o: CanvasObject, region: CGRect?, in c: CanvasView, origin: String) {
        guard let img = region.flatMap({ crop(full, $0) }) ?? (region == nil ? full : nil) else { c.hud.flash("The region could not be captured"); return }
        guard let png = pngData(img, maxPixels: 40_000_000) else { c.hud.flash("Encoding failed"); return }
        let content = app.runtime.contentRect(of: o)
        // World size: the region's size on the canvas at the source's presentation scale.
        let rw = content.w * (region?.width ?? 1), rh = content.h * (region?.height ?? 1)
        let pos = placement(near: o, size: WRect(x: 0, y: 0, w: rw, h: rh), in: c)
        let src = app.session.source(o.props.sourceID)
        let capID = newID()
        do {
            let a = try app.session.store.stageAsset(png, mime: "image/png", width: img.width, height: img.height)
            app.images.put(a.id, img)
            let rec = CaptureRecord(id: capID, assetID: a.id, sourceObjectID: o.id, sourceID: o.props.sourceID, appName: o.props.appName,
                                    windowTitle: o.props.windowTitle, documentPath: src?.documentPath, url: o.props.url,
                                    time: Date().timeIntervalSince1970, region: region.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                    pixelSize: [img.width, img.height], origin: origin)
            try app.session.store.putRecord("capture", capID, rec)
            var n = CanvasObject(kind: .image, geom: Geometry(x: pos.x, y: pos.y, w: rw, h: rh))
            n.props.assetID = a.id
            n.props.captureID = capID
            n.props.sourceID = o.props.sourceID
            n.props.url = o.props.url
            let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            n.props.name = "Capture · \(o.props.appName ?? o.title) · \(t)"
            let nid = try ws.create(n, name: region == nil ? "Capture window" : "Capture region", assets: [a])
            c.selection = [nid]
            if case .failed = ws.saveState { c.hud.flash("Captured, but not saved yet: \(ws.saveState.label)", seconds: 5) }
            else { c.hud.flash(region == nil ? "Captured the window" : "Captured the region") }
        } catch {
            // No object is created without durable bytes; the capture stays in memory for retry.
            c.hud.flash("Capture not saved: \(error). Nothing was added to the canvas.", seconds: 6)
        }
    }

    /// Cropping an existing image creates a new image object; the original stays unchanged.
    func cropImage(_ id: ObjectID, normalized: CGRect, in c: CanvasView) {
        guard let o = ws.object(id), let img = app.images.image(o.props.assetID), let cropped = crop(img, normalized),
              let png = pngData(cropped, maxPixels: 40_000_000) else { return }
        do {
            let a = try app.session.store.stageAsset(png, mime: "image/png", width: cropped.width, height: cropped.height)
            app.images.put(a.id, cropped)
            var n = o
            n.id = newID()
            n.z = ws.nextZ()
            n.props.assetID = a.id
            n.props.name = "Crop of \(o.title)"
            let w = o.geom.w * normalized.width, h = o.geom.h * normalized.height
            let p = placement(near: o, size: WRect(x: 0, y: 0, w: w, h: h), in: c)
            n.geom = Geometry(x: p.x, y: p.y, w: w, h: h)
            let nid = try ws.create(n, name: "Crop image", assets: [a])
            c.selection = [nid]
        } catch { app.report(error) }
    }

    /// Next to the source, inside the current view, avoiding overlap with the source.
    func placement(near o: CanvasObject, size: WRect, in c: CanvasView) -> WPoint {
        let vis = c.camera.visibleWorld
        let gap = 40.0
        let cands = [
            WPoint(x: o.geom.bounds.maxX + gap, y: o.geom.y),
            WPoint(x: o.geom.x - gap - size.w, y: o.geom.y),
            WPoint(x: o.geom.x, y: o.geom.bounds.maxY + gap),
            WPoint(x: o.geom.x, y: o.geom.y - gap - size.h),
        ]
        for p in cands where vis.contains(WRect(x: p.x, y: p.y, w: size.w, h: size.h)) { return p }
        for p in cands where vis.contains(WPoint(x: p.x + min(size.w, 40), y: p.y + min(size.h, 40))) { return p }
        return WPoint(x: vis.center.x - size.w / 2, y: vis.center.y - size.h / 2)
    }

    // MARK: Live view and freeze

    func createLiveView(of id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id) else { return }
        let content = app.runtime.contentRect(of: o)
        let p = placement(near: o, size: WRect(x: 0, y: 0, w: content.w / 2, h: content.h / 2), in: c)
        var n = CanvasObject(kind: .image, geom: Geometry(x: p.x, y: p.y, w: content.w / 2, h: content.h / 2))
        n.props.liveOf = id
        n.props.assetID = o.props.previewAssetID
        n.props.name = "Live view of \(o.title)"
        n.props.sourceID = o.props.sourceID
        do {
            let nid = try ws.create(n, name: "Create live view")
            if o.kind == .app && !app.runtime.isLive(id) { app.runtime.toggleLive(id) }
            c.selection = [nid]
        } catch { app.report(error) }
    }

    /// Freezing a live view creates a separate immutable capture.
    func freeze(_ id: ObjectID, in c: CanvasView) {
        guard let o = ws.object(id), let src = o.props.liveOf, let s = ws.object(src) else { return }
        guard let img = app.runtime.surfaceImage(for: s) else { c.hud.flash("No current frame to freeze"); return }
        commitCapture(img, source: s, region: nil, in: c, origin: "freeze")
    }

    func startLive(_ id: ObjectID, windowID: CGWindowID) {
        Task {
            do {
                let w = try await scWindow(windowID)
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                cfg.width = Int(w.frame.width * scale)
                cfg.height = Int(w.frame.height * scale)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
                cfg.showsCursor = false
                cfg.queueDepth = 3
                let ls = LiveStream(objectID: id)
                ls.owner = self
                let s = SCStream(filter: filter, configuration: cfg, delegate: ls)
                try s.addStreamOutput(ls, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                ls.stream = s
                await MainActor.run { self.streams[id] = ls }
            } catch {
                await MainActor.run {
                    self.app.runtime.liveObjects.remove(id)
                    self.app.runtime.refreshAll(id)
                    self.app.activeCanvas?.hud.flash("Live preview unavailable: \(error)", seconds: 5)
                }
            }
        }
    }

    func stopLive(_ id: ObjectID) {
        guard let ls = streams.removeValue(forKey: id) else { return }
        ls.stream?.stopCapture { _ in }
    }

    /// Offscreen live surfaces drop to 1 fps; the application itself is never paused.
    func setLiveBudget(_ id: ObjectID, visible: Bool) {
        guard let ls = streams[id], ls.visible != visible, let s = ls.stream else { return }
        ls.visible = visible
        let cfg = SCStreamConfiguration()
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: visible ? 15 : 1)
        cfg.showsCursor = false
        s.updateConfiguration(cfg) { _ in }
    }
}

func pngData(_ img: CGImage, maxPixels: Int) -> Data? {
    var src = img
    let px = img.width * img.height
    if px > maxPixels {
        let s = sqrt(Double(maxPixels) / Double(px))
        let w = Int(Double(img.width) * s), h = Int(Double(img.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let s2 = ctx.makeImage() else { return nil }
        src = s2
    }
    return NSBitmapImageRep(cgImage: src).representation(using: .png, properties: [:])
}

/// Bounded decoded-image cache over content-addressed assets.
final class ImageCache {
    let store: Store
    var cache: [AssetID: CGImage] = [:]
    var order: [AssetID] = []
    let limit = 96

    init(store: Store) { self.store = store }

    func image(_ id: AssetID?) -> CGImage? {
        guard let id else { return nil }
        if let i = cache[id] { touch(id); return i }
        guard let src = CGImageSourceCreateWithURL(store.assetURL(id) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        put(id, img)
        return img
    }

    func put(_ id: AssetID, _ img: CGImage) {
        cache[id] = img
        touch(id)
        while order.count > limit { cache[order.removeFirst()] = nil }
    }

    func touch(_ id: AssetID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

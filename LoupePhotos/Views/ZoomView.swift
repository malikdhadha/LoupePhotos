import SwiftUI
import AppKit

/// Shared state between the zoomed view (AppKit scroll view) and the Navigator.
@Observable
final class ZoomController {
    var magnification: CGFloat = 1          // 1 = 100 % (one photo pixel per screen pixel)
    var visible = CGRect(x: 0, y: 0, width: 1, height: 1)   // visible part of the photo, 0–1
    @ObservationIgnored weak var scroll: NSScrollView?
    @ObservationIgnored var fitMagnification: CGFloat = 0.1

    static let levels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    func update() {
        guard let s = scroll, let doc = s.documentView else { return }
        magnification = s.magnification
        let r = s.contentView.documentVisibleRect, b = doc.bounds
        guard b.width > 0, b.height > 0 else { return }
        visible = CGRect(x: max(0, r.minX / b.width), y: max(0, r.minY / b.height), width: min(1, r.width / b.width), height: min(1, r.height / b.height))
    }
    /// Centre the view on a point of the photo (fractions 0–1).
    func center(on f: CGPoint) {
        guard let s = scroll, let doc = s.documentView else { return }
        let b = doc.bounds, r = s.contentView.documentVisibleRect
        s.contentView.scroll(to: NSPoint(x: f.x * b.width - r.width / 2, y: f.y * b.height - r.height / 2))
        s.reflectScrolledClipView(s.contentView); update()
    }
    func setMagnification(_ m: CGFloat) {
        guard let s = scroll else { return }
        let c = CGPoint(x: visible.midX, y: visible.midY)
        s.magnification = max(s.minMagnification, min(s.maxMagnification, m))
        center(on: c)
    }
    func step(_ dir: Int, exit: () -> Void) {
        let cur = magnification
        if dir > 0 { if let n = ZoomController.levels.first(where: { $0 > cur + 0.01 }) { setMagnification(n) } }
        else if let n = ZoomController.levels.last(where: { $0 < cur - 0.01 }), n > fitMagnification * 1.02 { setMagnification(n) } else { exit() }
    }
}

/// An NSScrollView showing the photo at real pixel size; pinch or ⌘-scroll to zoom, drag to move, click to go back to Fit.
struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize           // the photo's full pixel size (so a low-res image can stand in while the full one loads)
    let focus: CGPoint              // point of the photo to put under the pointer (0–1)
    let anchor: CGPoint             // where the pointer was in the view (0–1)
    let startMagnification: CGFloat
    let controller: ZoomController
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let s = NSScrollView()
        s.hasHorizontalScroller = true; s.hasVerticalScroller = true; s.autohidesScrollers = true
        s.scrollerStyle = .overlay
        s.allowsMagnification = true; s.minMagnification = 0.05; s.maxMagnification = 8
        s.backgroundColor = .clear; s.drawsBackground = false
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let doc = PhotoDocView(frame: NSRect(x: 0, y: 0, width: pixelSize.width / scale, height: pixelSize.height / scale))
        doc.image = image; doc.onClick = onClick
        s.documentView = doc
        s.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(s, controller)
        controller.scroll = s
        DispatchQueue.main.async {
            let clip = s.contentView.bounds.size
            controller.fitMagnification = min(clip.width / doc.frame.width, clip.height / doc.frame.height, 1)
            s.magnification = startMagnification
            let r = s.contentView.documentVisibleRect
            s.contentView.scroll(to: NSPoint(x: focus.x * doc.frame.width - anchor.x * r.width, y: focus.y * doc.frame.height - anchor.y * r.height))
            s.reflectScrolledClipView(s.contentView)
            controller.update()
        }
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        if let doc = s.documentView as? PhotoDocView, doc.image !== image { doc.image = image; doc.needsDisplay = true }
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord: NSObject {
        var obs: [NSObjectProtocol] = []
        func observe(_ s: NSScrollView, _ c: ZoomController) {
            let nc = NotificationCenter.default
            obs.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: s.contentView, queue: .main) { _ in c.update() })
            obs.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: s, queue: .main) { _ in c.update() })
        }
        deinit { obs.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

final class PhotoDocView: NSView {
    var image: NSImage?
    var onClick: (() -> Void)?
    private var down: NSPoint?, moved = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: bounds)
    }
    override func mouseDown(with e: NSEvent) { down = e.locationInWindow; moved = false; NSCursor.closedHand.push() }
    override func mouseDragged(with e: NSEvent) {
        guard let s = enclosingScrollView, let d = down else { return }
        let p = e.locationInWindow, m = s.magnification
        if abs(p.x - d.x) + abs(p.y - d.y) > 3 { moved = true }
        var o = s.contentView.bounds.origin
        o.x -= (p.x - d.x) / m; o.y += (p.y - d.y) / m
        s.contentView.scroll(to: o); s.reflectScrolledClipView(s.contentView)
        down = p
    }
    override func mouseUp(with e: NSEvent) { NSCursor.pop(); if !moved { onClick?() }; down = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// Aperture's Navigator: the whole photo with a box around the part you're looking at.
struct NavigatorPanel: View {
    let thumb: NSImage?
    let zoom: ZoomController
    let exit: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            if let thumb {
                GeometryReader { g in
                    let r = zoom.visible
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(width: g.size.width, height: g.size.height)
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: g.size))
                            p.addRect(CGRect(x: r.minX * g.size.width, y: r.minY * g.size.height, width: r.width * g.size.width, height: r.height * g.size.height))
                        }.fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        Rectangle().stroke(.white, lineWidth: 1.5)
                            .frame(width: max(6, r.width * g.size.width), height: max(6, r.height * g.size.height))
                            .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        zoom.center(on: CGPoint(x: min(1, max(0, v.location.x / g.size.width)), y: min(1, max(0, v.location.y / g.size.height))))
                    })
                }
                .aspectRatio(thumb.size.width / max(1, thumb.size.height), contentMode: .fit)
                .frame(width: 180)
            }
            HStack(spacing: 14) {
                Button { zoom.step(-1, exit: exit) } label: { Image(systemName: "arrowtriangle.left.fill").imageScale(.small) }.buttonStyle(.plain)
                Text("\(Int((zoom.magnification * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
                Button { zoom.step(1, exit: exit) } label: { Image(systemName: "arrowtriangle.right.fill").imageScale(.small) }.buttonStyle(.plain)
            }
            .font(.callout)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.black.opacity(0.4)))
        .shadow(radius: 10)
        .environment(\.colorScheme, .dark)
    }
}

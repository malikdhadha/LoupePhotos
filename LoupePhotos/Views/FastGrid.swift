import SwiftUI
import AppKit
import ImageIO

/// All Photos, drawn directly instead of one view per photo (like Apple Photos), so even
/// hundreds of thousands of tiny thumbnails scroll smoothly. Thumbnails come from the previews package.
struct FastGrid: NSViewRepresentable {
    let photos: [Photo]
    let tile: CGFloat
    let square: Bool
    let selection: Set<Int>
    let primary: Int?
    let stamp: Int                       // changes when ratings, flags, rotation… change
    var badges = true                    // H hides the stars / flags / labels on thumbnails
    let scrollTarget: Int?
    let onColumns: (Int) -> Void
    let onScrolled: () -> Void
    let onSelect: (Photo, NSEvent.ModifierFlags) -> Void
    let onOpen: (Photo) -> Void
    let menu: (Photo) -> NSMenu
    var onPinch: (CGFloat, Bool) -> Void = { _, _ in }
    var detailed = false                 // J: Lightroom's expanded cells (name, type, flag, stars, label tint)
    var onRate: (Photo, Int) -> Void = { _, _ in }
    var onFlag: (Photo) -> Void = { _ in }
    var onRotate: (Photo, Int) -> Void = { _, _ in }
    var loupe = false
    var loupeSize: CGFloat = 240
    var loupeMag: CGFloat = 1
    var onLoupeResize: (CGFloat) -> Void = { _ in }
    /// Which photos changed since a stamp, when only their stars/flags/labels did (so just those cells redraw).
    var touched: (Int) -> Set<Int>? = { _ in nil }
    var options = ""                     // View Options (⌘J) — redraw when they change
    var onMap: (Photo) -> Void = { _ in }
    var yearLabels = false               // only in Photos ▸ All Photos, zoomed far out

    func makeNSView(context: Context) -> GridScrollView {
        let s = GridScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = true
        s.backgroundColor = .underPageBackgroundColor
        s.documentView = GridDocView()
        return s
    }

    func updateNSView(_ s: GridScrollView, context: Context) {
        guard let doc = s.documentView as? GridDocView else { return }
        doc.onSelect = onSelect; doc.onOpen = onOpen; doc.menuFor = menu; doc.onColumns = onColumns; doc.onPinch = onPinch
        if doc.badges != badges { doc.badges = badges; doc.needsDisplay = true }
        doc.onLoupeResize = onLoupeResize
        doc.onRate = onRate; doc.onFlag = onFlag; doc.touched = touched; doc.onRotate = onRotate; doc.onMap = onMap
        if doc.optionsStamp != options { doc.optionsStamp = options; doc.needsDisplay = true }
        doc.yearLabels = yearLabels
        if doc.detailed != detailed { doc.detailed = detailed; doc.needsDisplay = true }
        if doc.loupeOn != loupe || doc.loupeSize != loupeSize || doc.loupeMag != loupeMag {
            doc.loupeOn = loupe; doc.loupeSize = loupeSize; doc.loupeMag = loupeMag; doc.refreshLoupe()
        }
        doc.update(photos: photos, tile: tile, square: square, selection: selection, primary: primary, stamp: stamp, width: s.contentView.bounds.width)
        if let t = scrollTarget {
            doc.scrollTo(id: t)
            DispatchQueue.main.async { onScrolled() }
        }
    }
}

final class GridScrollView: NSScrollView {
    /// Year labels down the right edge, like Apple Photos: shown while scrolling or when the pointer is there; click one to jump.
    let rail = YearRail()
    override init(frame: NSRect) { super.init(frame: frame); addSubview(rail) }
    required init?(coder: NSCoder) { super.init(coder: coder); addSubview(rail) }
    override func tile() {
        super.tile()
        rail.frame = NSRect(x: bounds.width - 74, y: 0, width: 58, height: bounds.height)
        rail.doc = documentView as? GridDocView
        rail.needsDisplay = true
    }
    override func reflectScrolledClipView(_ c: NSClipView) {
        super.reflectScrolledClipView(c)
        rail.doc = documentView as? GridDocView
        rail.scrolled()
    }
    /// With the Loupe on, ⇧-scroll changes its size; plain scrolling still scrolls (and the Loupe follows the photo under the pointer).
    override func scrollWheel(with e: NSEvent) {
        if let doc = documentView as? GridDocView, doc.loupeOn, e.modifierFlags.contains(.shift) {
            let raw = e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX
            doc.onLoupeResize?(e.hasPreciseScrollingDeltas ? raw : raw * 12)
            return
        }
        super.scrollWheel(with: e)
        (documentView as? GridDocView)?.refreshLoupe()
    }
    override func layout() {
        super.layout()
        (documentView as? GridDocView)?.relayout(width: contentView.bounds.width)
    }
}

/// Holds a decoded thumbnail in the memory cache.
final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

final class GridDocView: NSView, NSDraggingSource {
    var onSelect: ((Photo, NSEvent.ModifierFlags) -> Void)?
    var onOpen: ((Photo) -> Void)?
    var menuFor: ((Photo) -> NSMenu)?
    var onColumns: ((Int) -> Void)?
    var onPinch: ((CGFloat, Bool) -> Void)?
    /// Trackpad pinch: bigger or smaller thumbnails, keeping the photo under your fingers in place.
    override func magnify(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        let anchor = index(at: pt), clip = enclosingScrollView?.contentView
        let offsetInView = clip.map { pt.y - $0.bounds.minY }
        onPinch?(e.magnification, e.phase == .began)
        // after SwiftUI hands back the new size, scroll so the same photo stays under the pointer
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = anchor, let clip, let off = offsetInView, i < self.photos.count else { return }
            let r = self.rect(i)
            let y = max(0, min(r.midY - off, self.frame.height - clip.bounds.height))
            clip.scroll(to: NSPoint(x: 0, y: y)); self.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    private var photos: [Photo] = []
    /// Photo → its place in the grid. Made when first needed, not on every new list (at 120,000 photos it took
    /// longer than drawing the grid).
    private var indexCache: [Int: Int]?
    private var indexOf: [Int: Int] {
        if let c = indexCache { return c }
        var d = [Int: Int](minimumCapacity: photos.count)
        for (i, p) in photos.enumerated() where d[p.id] == nil { d[p.id] = i }
        indexCache = d
        return d
    }
    private var tile: CGFloat = 170
    private var square = true
    private var selection: Set<Int> = []
    private var primary: Int?
    private var stamp = -1
    private var width: CGFloat = 0
    private(set) var cols = 1
    private var size: CGFloat = 100
    private var gap: CGFloat = 2
    private let margin: CGFloat = 2

    private static let cache: NSCache<NSNumber, CGImageBox> = { let c = NSCache<NSNumber, CGImageBox>(); c.totalCostLimit = 500 << 20; return c }()
    private static let loader: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.75, min: 3, max: 6); q.qualityOfService = .userInitiated; return q }()
    private var inFlight = Set<Int>()
    private var visibleRows = 0..<0
    private var viewMid = 0            // middle row on screen (loads nearest this first)
    private var lastTop: CGFloat = 0   // to tell which way you're scrolling
    // shared with the loading threads without waiting on the main thread
    private let visLock = NSLock()
    private var visShared = 0..<0
    private var pending: [(Photo, Tier, Int, Int)] = []          // photo, size, row, pixels (sized only)
    private var arrived = Set<Int>()                             // photos whose thumbnail came in since the last repaint
    private var prefetchedKey = ""
    private var batchQueued = false
    private var repaintQueued = false
    /// Thumbnail sizes kept in memory: micro (64 px, unpacked from the mini thumbnail) for the tiniest grid.
    enum Tier: Int { case micro = 0, mini = 1, thumb = 2, sized = 3
        var stored: ThumbLevel { self == .thumb ? .thumb : .mini }
    }
    /// Small cells get thumbnails made at exactly their size, already cropped and turned, so drawing one is a plain copy
    /// (hundreds of cells were being shrunk and turned again on every frame — what made the smallest sizes stutter).
    private var sizedPx: Int? {
        guard !showDetail else { return nil }
        let px = Int((size * (window?.backingScaleFactor ?? 2)).rounded(.up))
        return px <= 260 ? (px + 3) / 4 * 4 : nil
    }
    private var lastSizedPx: Int?                 // the size before, shown until the new size is ready
    private var drawnPx: Int?
    private func sizedKey(_ id: Int, _ px: Int, _ rot: Int) -> Int { Self.sizedKey(id, px, rot, square) }
    static func sizedKey(_ id: Int, _ px: Int, _ rot: Int, _ square: Bool) -> Int {
        let q = ((rot % 4) + 4) % 4
        return -(((id * 1024 + px / 4) * 8 + q * 2 + (square ? 1 : 0)) + 1)
    }
    private func cachedSized(_ id: Int, _ px: Int, _ rot: Int) -> CGImage? { Self.cache.object(forKey: NSNumber(value: sizedKey(id, px, rot)))?.image }
    /// Draws a ready-made cell image: centred, at the cell's size (it was made at `px` pixels across the cell).
    private func drawSized(_ img: CGImage, px: Int, in cell: CGRect, _ ctx: CGContext) {
        let k = cell.width / CGFloat(px)
        let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
        ctx.saveGState()
        ctx.translateBy(x: cell.midX, y: cell.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }
    /// Makes a cell image: decoded from the stored thumbnail at about the size needed (JPEG decodes small very quickly),
    /// then cropped (square cells) or fitted, and turned, at exactly `px` pixels.
    static func makeSized(_ p: Photo, px: Int, square: Bool) -> CGImage? {
        var ratio = p.w > 0 && p.h > 0 ? Double(max(p.w, p.h)) / Double(min(p.w, p.h)) : 1.5
        ratio = min(3, max(1, ratio))
        let need = Int((square ? Double(px) * ratio : Double(px)).rounded(.up))
        let level: ThumbLevel = need <= ThumbLevel.mini.pixels + 16 ? .mini : .thumb
        var data = PreviewStore.shared.data(p.id, level)
        if data == nil, ThumbBuilder.shared.buildNow(p) { data = PreviewStore.shared.data(p.id, level) }
        guard let d = data, let src = CGImageSourceCreateWithData(d as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: min(need, level.pixels),
                                                                     kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let q = ((p.rot % 4) + 4) % 4
        var iw = CGFloat(img.width), ih = CGFloat(img.height)
        if q % 2 == 1 { swap(&iw, &ih) }
        let P = CGFloat(px)
        let k = square ? max(P / iw, P / ih) : min(P * 0.86 / iw, P * 0.86 / ih)
        let ow = square ? px : max(1, Int((iw * k).rounded())), oh = square ? px : max(1, Int((ih * k).rounded()))
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        let (w, h) = q % 2 == 1 ? (ih * k, iw * k) : (iw * k, ih * k)
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }
    private var pendingScroll: Int?
    var badges = true
    // hover tooltip: file name, date, camera, size
    private var tipIndex: Int?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseExited(with e: NSEvent) {
        loupeView.isHidden = true
        if let h = hoverIndex, h < photos.count, showDetail && o.hoverOnly { setNeedsDisplay(rect(h)) }
        hoverIndex = nil
    }
    override func mouseMoved(with e: NSEvent) {
        if loupeOn { removeAllToolTips(); tipIndex = nil; refreshLoupe(convert(e.locationInWindow, from: nil)); return }
        let i = index(at: convert(e.locationInWindow, from: nil))
        if showDetail && o.hoverOnly && i != hoverIndex {
            if let h = hoverIndex, h < photos.count { setNeedsDisplay(rect(h)) }
            if let i { setNeedsDisplay(rect(i)) }
        }
        hoverIndex = i
        guard i != tipIndex else { return }
        tipIndex = i
        removeAllToolTips()
        if let i, o.tooltips { addToolTip(rect(i), owner: self, userData: nil) }
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = tipIndex, i < photos.count else { return "" }
        let p = photos[i]
        let size = ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file)
        return [p.fileName, p.captureDate.formatted(date: .abbreviated, time: .shortened), p.camera, "\(p.w) × \(p.h) · \(size)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: the Loupe over the grid (Aperture's): the photo under the pointer at 100%, without opening it
    var detailed = false
    var optionsStamp = ""
    var yearLabels = false
    var onMap: ((Photo) -> Void)?
    private var o: ViewOptions { ViewOptions.shared }
    private var hoverIndex: Int?
    /// The little map pin on photos with a location (bottom-right of the photo).
    private func pinRect(_ cell: CGRect) -> CGRect {
        let a = imageArea(cell)
        return showDetail ? CGRect(x: cell.maxX - 20, y: a.maxY - 16, width: 14, height: 14) : CGRect(x: cell.maxX - 19, y: cell.maxY - 19, width: 14, height: 14)
    }
    private func showsPin(_ p: Photo) -> Bool { o.geotagBadge && showDetail && Library.gps(p) != nil }   // detailed cells only
    private func drawPin(_ cell: CGRect) {
        let r = pinRect(cell)
        NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5)).fill()
        if let img = NSImage(systemSymbolName: "mappin.circle.fill", accessibilityDescription: "Has a location")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [.white, .systemRed]))) { img.draw(in: r) }
    }
    var touched: ((Int) -> Set<Int>?)?
    var onRate: ((Photo, Int) -> Void)?
    var onFlag: ((Photo) -> Void)?
    /// Detailed cells only when there's room for the text.
    private var showDetail: Bool { detailed && size >= 120 }
    private let headH: CGFloat = 32, footH: CGFloat = 24
    var onRotate: ((Photo, Int) -> Void)?
    /// Follows the Mac's Light / Dark setting.
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); resetStrips(); needsDisplay = true }
    private func rotRect(_ cell: CGRect, _ dir: Int) -> CGRect {          // ↺ next to the flag, ↻ next to the label
        dir < 0 ? CGRect(x: cell.minX + 24, y: cell.maxY - footH, width: 18, height: footH)
                : CGRect(x: cell.maxX - 42, y: cell.maxY - footH, width: 18, height: footH)
    }
    private var showRotate: Bool { size >= 170 && ViewOptions.shared.showRotate }
    private func imageArea(_ cell: CGRect) -> CGRect {
        showDetail ? CGRect(x: cell.minX + 10, y: cell.minY + headH + 6, width: cell.width - 20, height: cell.height - headH - footH - 12) : cell
    }
    private func starRect(_ cell: CGRect, _ n: Int) -> CGRect {      // n = 1…5, centred in the footer
        let w: CGFloat = 13, x0 = cell.midX - w * 2.5
        return CGRect(x: x0 + CGFloat(n - 1) * w, y: cell.maxY - footH, width: w, height: footH)
    }
    private func flagRect(_ cell: CGRect) -> CGRect { CGRect(x: cell.minX + 4, y: cell.maxY - footH, width: 20, height: footH) }

    private func drawDetail(_ p: Photo, _ index: Int, _ cell: CGRect, _ ctx: CGContext) {
        // like Lightroom: index number and name on the first line, pixel size and file type on the second
        let small = NSFont.systemFont(ofSize: 10.5)
        let dim = dark ? NSColor(white: 0.74, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        let faint = dark ? NSColor(white: 0.52, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        let controls = !o.hoverOnly || index == hoverIndex     // flag / rotate / empty stars only on mouse-over, if chosen
        var nw: CGFloat = -6
        if o.showIndex {
            let num = NSAttributedString(string: (index + 1).formatted(), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: faint])
            nw = num.size().width
            num.draw(at: NSPoint(x: cell.minX + 6, y: cell.minY + 3))
        }
        let name = NSAttributedString(string: p.fileName.components(separatedBy: ".").dropLast().joined(separator: "."),
                                      attributes: [.font: small, .foregroundColor: dim])
        name.draw(with: NSRect(x: cell.minX + nw + 12, y: cell.minY + 3, width: cell.width - nw - 18, height: 14),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let line2: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: faint]
        if p.w > 0 && o.showDims { NSAttributedString(string: "\(p.rot % 2 == 1 ? p.h : p.w) × \(p.rot % 2 == 1 ? p.w : p.h)", attributes: line2).draw(at: NSPoint(x: cell.minX + 6, y: cell.minY + 17)) }
        let type = NSAttributedString(string: SmartRule.kind(p) == "RAW" ? p.ext.uppercased() : SmartRule.kind(p),
                                      attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: faint])
        if o.showType { type.draw(at: NSPoint(x: cell.maxX - type.size().width - 6, y: cell.minY + 17)) }
        if showRotate && controls {
            for dir in [-1, 1] {
                let r = rotRect(cell, dir)
                if let img = NSImage(systemSymbolName: dir < 0 ? "rotate.left" : "rotate.right", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [faint]))) {
                    img.draw(in: NSRect(x: r.midX - 6, y: r.midY - 6, width: 12, height: 12))
                }
            }
        }
        // flag, stars and label along the bottom
        let fr = flagRect(cell)
        if controls || p.flag || p.rejected {
        let flagSym = p.rejected ? "xmark.circle.fill" : p.flag ? "flag.fill" : "flag"
        let flagCol: NSColor = p.rejected ? .systemRed : p.flag ? .systemOrange : NSColor(white: dark ? 0.55 : 0.5, alpha: 1)
        if let img = NSImage(systemSymbolName: flagSym, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [flagCol]))) {
            img.draw(in: NSRect(x: fr.minX + 4, y: fr.midY - 6, width: 12, height: 12))
        }
        }
        for n in 1...5 where controls || n <= p.rating {
            let r = starRect(cell, n)
            let s = NSAttributedString(string: "★", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                 .foregroundColor: n <= p.rating ? (dark ? NSColor.white : NSColor(white: 0.12, alpha: 1)) : NSColor(white: dark ? 0.38 : 0.72, alpha: 1)])
            let sz = s.size(); s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
        if o.showLabelDot, let l = PhotoLabel.find(p.label) {
            let d = CGRect(x: cell.maxX - 18, y: cell.maxY - footH / 2 - 5, width: 10, height: 10)
            ctx.setFillColor(NSColor(hex: l.hex).cgColor); ctx.fillEllipse(in: d)
        }
    }

    var loupeOn = false
    var loupeSize: CGFloat = 240
    var loupeMag: CGFloat = 1
    var onLoupeResize: ((CGFloat) -> Void)?
    private let loupeView = GridLoupeView()
    private var loupeTask: Task<Void, Never>?
    private var loupeFor: Int?
    private static var big: (id: Int, image: CGImage)?

    func refreshLoupe(_ at: CGPoint? = nil) {
        guard loupeOn, let win = window else { loupeView.isHidden = true; loupeTask?.cancel(); loupeFor = nil; return }
        let pt = at ?? convert(win.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(pt), let i = index(at: pt) else { loupeView.isHidden = true; return }
        let p = photos[i], cell = imageArea(rect(i))
        // where in the photo the pointer is (0–1), matching how the thumbnail is drawn
        var pw = CGFloat(max(1, p.w)), ph = CGFloat(max(1, p.h))
        if (((p.rot % 4) + 4) % 4) % 2 == 1 { swap(&pw, &ph) }
        let k = showDetail ? min(cell.width / pw, cell.height / ph) : square ? max(cell.width / pw, cell.height / ph) : min(cell.width * 0.86 / pw, cell.height * 0.86 / ph)
        let shown = CGRect(x: cell.midX - pw * k / 2, y: cell.midY - ph * k / 2, width: pw * k, height: ph * k)
        let frac = CGPoint(x: min(1, max(0, (pt.x - shown.minX) / shown.width)), y: min(1, max(0, (pt.y - shown.minY) / shown.height)))
        if loupeView.superview !== self { addSubview(loupeView) }
        let d = loupeSize
        loupeView.frame = CGRect(x: pt.x - d / 2, y: pt.y - d / 2, width: d, height: d)
        loupeView.frac = frac; loupeView.pixelSize = CGSize(width: pw, height: ph)
        loupeView.mag = loupeMag; loupeView.scale = win.backingScaleFactor; loupeView.rot = p.rot
        if let b = Self.big, b.id == p.id {
            loupeView.image = b.image
        } else {
            // the thumbnail straight away, the full-size image a moment later
            if loupeView.photoId != p.id { loupeView.image = cached(p.id, .thumb) ?? cached(p.id, .mini) ?? cached(p.id, .micro) }
            if loupeFor != p.id {
                loupeFor = p.id; loupeTask?.cancel()
                loupeTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000)          // don't decode every photo you sweep across
                    guard !Task.isCancelled else { return }
                    let img = await Images.shared.full1to1(p)
                    guard !Task.isCancelled, let self, let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    Self.big = (p.id, cg)
                    self.refreshLoupe()
                }
            }
        }
        loupeView.photoId = p.id
        loupeView.isHidden = false
        loupeView.needsDisplay = true
    }

    static func clearCache() { cache.removeAllObjects(); strips.removeAllObjects() }
    /// One photo's thumbnails were remade (Develop): forget every size kept of it.
    static func forget(_ id: Int) {
        for t in 0..<4 { cache.removeObject(forKey: NSNumber(value: id * 4 + t)) }
        for px in stride(from: 4, through: 264, by: 4) {
            for rot in 0..<4 { for sq in [true, false] { cache.removeObject(forKey: NSNumber(value: sizedKey(id, px, rot, sq))) } }
        }
        strips.removeAllObjects()
        if big?.id == id { big = nil }
    }
    private static let editedBadge: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(.init(paletteColors: [.white]))
        return NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Edited")?.withSymbolConfiguration(cfg)
    }()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    // MARK: data and layout
    func update(photos new: [Photo], tile t: CGFloat, square sq: Bool, selection sel: Set<Int>, primary pr: Int?, stamp st: Int, width w: CGFloat) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let listChanged = new.count != photos.count || !zip(new, photos).allSatisfy { $0 === $1 }
        if listChanged {
            photos = new
            indexCache = nil
            computeYearMarks()
            Timing.note("grid: new list of \(new.count)", since: t0)
        }
        let layoutChanged = listChanged || t != tile || sq != square
        tile = t; square = sq
        if layoutChanged { resetStrips(); relayout(width: w, force: true); needsDisplay = true }
        else if st != stamp {
            // a rating or label changed: redraw just those cells instead of the whole grid
            if let ids = touched?(stamp) { for id in ids { dropStrip(for: id); redraw(id) } } else { resetStrips(); needsDisplay = true }
            for id in sel.symmetricDifference(selection) { redraw(id) }
            if pr != primary { if let a = pr { redraw(a) }; if let b = primary { redraw(b) } }
        } else {
            // only redraw the cells whose selection changed
            for id in sel.symmetricDifference(selection) { redraw(id) }
            if pr != primary { if let a = pr { redraw(a) }; if let b = primary { redraw(b) } }
        }
        if pr != primary, let a = pr { scrollTo(id: a) }   // keep the arrow-key selection in view
        selection = sel; primary = pr; stamp = st
    }

    func relayout(width w: CGFloat, force: Bool = false) {
        guard w > 0, force || abs(w - width) > 0.5 else { return }
        let oldWidth = width, oldCols = cols, oldSize = size
        width = w
        gap = tile < 60 ? 1 : 2
        let inner = w - margin * 2
        cols = max(1, Int((inner + gap) / (tile + gap)))
        size = floor((inner - CGFloat(cols - 1) * gap) / CGFloat(cols))
        // the rows only need putting together again when they actually look different
        if cols != oldCols || size != oldSize || force { resetStrips() }
        if size != oldSize && oldWidth > 0 && !photos.isEmpty { startResizing() }      // (not the first layout at launch)
        let rows = (photos.count + cols - 1) / cols
        let h = CGFloat(rows) * (size + gap) + margin + 40
        let minH = enclosingScrollView?.contentView.bounds.height ?? 0
        setFrameSize(NSSize(width: w, height: max(h, minH)))
        needsDisplay = true
        let c = cols
        DispatchQueue.main.async { [weak self] in
            self?.onColumns?(c)
            if let t = self?.pendingScroll { self?.pendingScroll = nil; self?.scrollTo(id: t) }
        }
    }

    // MARK: resizing (window, pinch, slider)
    /// While the cells are changing size, the thumbnails already in memory are drawn scaled, and nothing new is
    /// decoded — every few points of a resize used to start hundreds of decodes for sizes gone a moment later.
    private var resizing = false
    private var resizeEnd: DispatchWorkItem?
    private func startResizing() {
        resizing = true
        resizeEnd?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.endResizing() }
        resizeEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (inLiveResize ? 0.6 : 0.22), execute: w)
    }
    private func endResizing() {
        guard !inLiveResize else { startResizing(); return }
        resizing = false; resizeEnd = nil
        prefetchedKey = ""; stripPrefetched = ""
        needsDisplay = true                       // now fetch the right size
    }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); if resizing { startResizing() } }

    /// Where each year starts in the list (only when the photos are in date order).
    private(set) var yearMarks: [(year: Int, index: Int)] = []
    private func computeYearMarks() {
        var marks: [(year: Int, index: Int)] = [], last = Int.min
        for (i, p) in photos.enumerated() where !p.quickNoDate {
            let y = p.ymd.y
            if y != last { marks.append((y, i)); last = y; if marks.count > 300 { yearMarks = []; return } }
        }
        // in date order the years only go one way; anything else (sorted by name…) gets no labels
        let ys = marks.map(\.year)
        let up = zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 }, down = zip(ys, ys.dropFirst()).allSatisfy { $0 > $1 }
        yearMarks = (up || down) && marks.count > 1 ? marks : []
        (enclosingScrollView as? GridScrollView)?.rail.needsDisplay = true
    }
    func scrollToRow(of i: Int) {
        guard let clip = enclosingScrollView?.contentView, i < photos.count else { return }
        let y = max(0, min(rect(i).minY - margin, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y)); enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func rect(_ i: Int) -> CGRect {
        let r = i / cols, c = i % cols
        return CGRect(x: margin + CGFloat(c) * (size + gap), y: margin + CGFloat(r) * (size + gap), width: size, height: size)
    }
    func index(at p: CGPoint) -> Int? {
        let c = Int((p.x - margin) / (size + gap)), r = Int((p.y - margin) / (size + gap))
        guard c >= 0, c < cols, r >= 0 else { return nil }
        let i = r * cols + c
        guard i < photos.count, rect(i).contains(p) else { return nil }
        return i
    }
    private func redraw(_ id: Int) { if let i = indexOf[id] { setNeedsDisplay(rect(i).insetBy(dx: -3, dy: -3)) } }

    func scrollTo(id: Int) {
        guard width > 0, frame.height > 0 else { pendingScroll = id; return }
        guard let i = indexOf[id], let clip = enclosingScrollView?.contentView else { return }
        let r = rect(i)
        if clip.documentVisibleRect.contains(r) { return }
        let y = max(0, min(r.midY - clip.bounds.height / 2, frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: drawing
    private var tier: Tier {
        let px = size * (window?.backingScaleFactor ?? 2)
        return px <= 72 ? .micro : px <= CGFloat(ThumbLevel.mini.pixels) * 1.15 ? .mini : .thumb
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(dirty)
        guard !photos.isEmpty, size > 0 else { return }
        let r0 = max(0, Int((dirty.minY - margin) / (size + gap)))
        let r1 = Int((dirty.maxY - margin) / (size + gap))
        let lvl = tier
        let spx = sizedPx
        // while resizing, the size last drawn properly stays the one thumbnails are taken from
        if !resizing, let spx, spx != drawnPx { lastSizedPx = drawnPx; drawnPx = spx }
        ctx.interpolationQuality = spx != nil ? .low : size < 80 ? .low : .medium
        let isDark = dark
        let empty = NSColor(white: isDark ? (square ? 0.16 : 0.2) : (square ? 0.86 : 0.9), alpha: 1).cgColor
        let base = NSColor(white: isDark ? 0.17 : 0.88, alpha: 1)
        if let vis = enclosingScrollView?.contentView.documentVisibleRect {
            // keep loading a screenful ahead in the direction you're scrolling
            let rowH = size + gap
            let first = max(0, Int((vis.minY - margin) / rowH)), last = Int((vis.maxY - margin) / rowH)
            let span = max(1, last - first + 1)
            let down = vis.minY >= lastTop; lastTop = vis.minY
            visibleRows = max(0, first - (down ? 2 : span)) ..< last + (down ? span : 2) + 1
            viewMid = (first + last) / 2
            visLock.lock(); visShared = visibleRows; visLock.unlock()
        }
        defer { Timing.drawn() }
        if stripMode, let spx, !resizing { drawStrips(r0, r1, spx, empty, ctx); return }
        for row in r0...max(r0, r1) {
            for c in 0..<cols {
                let i = row * cols + c
                guard i < photos.count else { break }
                let p = photos[i], cell = rect(i)
                guard needsToDraw(cell) else { continue }      // only the cells that changed, not everything in the dirty area
                if showDetail {
                    // the cell takes on the colour label's tint, like Lightroom's expanded cells
                    let pct = CGFloat(o.tintPercent) / 100 * (isDark ? 0.95 : 1.25)
                    let tint = o.tintLabels ? PhotoLabel.find(p.label).map { NSColor(hex: $0.hex).blended(withFraction: 1 - pct, of: isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)) ?? base } : nil
                    ctx.setFillColor((tint ?? base).cgColor)
                } else { ctx.setFillColor(empty) }
                ctx.fill(cell)
                let area = imageArea(cell)
                if let spx {
                    let use = resizing ? (drawnPx ?? spx) : spx
                    if let img = cachedSized(p.id, use, p.rot) { drawSized(img, px: use, in: area, ctx) }
                    else {
                        if let old = lastSizedPx, let img = cachedSized(p.id, old, p.rot) { drawSized(img, px: old, in: area, ctx) }
                        else if let alt = cached(p.id, .mini) ?? cached(p.id, .micro) ?? cached(p.id, .thumb) { drawImage(alt, p.rot, in: area, ctx) }
                        if !resizing { load(p, .sized, row: row, px: spx) }
                    }
                } else if let img = cached(p.id, lvl) {
                    drawImage(img, p.rot, in: area, ctx)
                } else {
                    // something to show straight away (any size we already have), and fetch the right one
                    if let alt = cached(p.id, lvl == .thumb ? .mini : .micro) ?? cached(p.id, lvl == .micro ? .mini : .thumb) { drawImage(alt, p.rot, in: area, ctx) }
                    load(p, lvl, row: row)
                }
                if showDetail { drawDetail(p, i, cell, ctx) }
                if showsPin(p) { drawPin(cell) }
                if selection.contains(p.id) {
                    let w: CGFloat = size < 60 ? 2 : (primary == p.id ? 4 : 3)
                    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(w)
                    ctx.stroke(cell.insetBy(dx: w / 2, dy: w / 2))
                    if primary != p.id { ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.fill(cell) }
                }
                if size >= 60 && badges && !showDetail { drawBadges(p, cell) }
            }
        }
        // fetch the rows just off screen, so they're ready when they scroll in (once per scroll position, not on every redraw)
        guard !resizing else { return }
        let pk = "\(visibleRows)|\(lvl)|\(spx ?? 0)|\(square)|\(photos.count)"
        guard pk != prefetchedKey else { return }
        prefetchedKey = pk
        for row in visibleRows where row < r0 || row > r1 {
            for c in 0..<cols {
                let i = row * cols + c
                guard i < photos.count else { break }
                let p = photos[i]
                if let spx { if cachedSized(p.id, spx, p.rot) == nil { load(p, .sized, row: row, px: spx) } }
                else if cached(p.id, lvl) == nil { load(p, lvl, row: row) }
            }
        }
    }

    private func drawImage(_ img: CGImage, _ rot: Int, in cell: CGRect, _ ctx: CGContext) {
        let q = ((rot % 4) + 4) % 4
        var iw = CGFloat(img.width), ih = CGFloat(img.height)
        if q % 2 == 1 { swap(&iw, &ih) }
        let k = showDetail ? min(cell.width / iw, cell.height / ih) : square ? max(cell.width / iw, cell.height / ih) : min(cell.width * 0.86 / iw, cell.height * 0.86 / ih)
        let dw = iw * k, dh = ih * k
        ctx.saveGState()
        ctx.clip(to: cell)
        // flipped view: move to the cell centre, undo the flip for the image, then turn it
        ctx.translateBy(x: cell.midX, y: cell.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        let (w, h) = q % 2 == 1 ? (dh, dw) : (dw, dh)
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    private func drawBadges(_ p: Photo, _ cell: CGRect) {
        var x = cell.minX + 5
        let y = cell.maxY - 5
        let fs = max(9, min(12, size / 14))
        if let l = PhotoLabel.find(p.label) {
            let d = CGRect(x: x, y: y - 9, width: 9, height: 9)
            NSColor(hex: l.hex).setFill(); NSBezierPath(ovalIn: d).fill()
            NSColor.white.withAlphaComponent(0.8).setStroke(); NSBezierPath(ovalIn: d).stroke()
            x += 13
        }
        // edited in Develop: a small mark in the bottom-right corner
        if UserDefaults.standard.object(forKey: "develop.badge") as? Bool ?? true, DevelopStore.shared.isEdited(p.id), let b = Self.editedBadge {
            let r = CGRect(x: cell.maxX - 19, y: cell.maxY - 17, width: 15, height: 13)
            NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            b.draw(in: CGRect(x: r.midX - b.size.width / 2, y: r.midY - b.size.height / 2, width: b.size.width, height: b.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var s = ""
        if p.flag { s += "⚑ " }
        if p.rating > 0 { s += String(repeating: "★", count: p.rating) }
        guard !s.isEmpty else { return }
        let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.8); sh.shadowBlurRadius = 2
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: fs), .foregroundColor: p.flag && p.rating == 0 ? NSColor.orange : NSColor.white, .shadow: sh])
        a.draw(at: NSPoint(x: x, y: y - a.size().height + 1))
    }

    // MARK: the tiniest sizes: a whole row as one picture
    /// With a thousand or more thumbnails on screen, drawing each one was the lag. Each row is put together once,
    /// in the background, and then drawn as a single picture (as Apple Photos does zoomed far out).
    private var stripMode: Bool { (sizedPx ?? 999) <= 88 }        // cells up to about 44 points
    private var stripGen = 0
    private var stripInFlight = Set<Int>()
    private var stripPrefetched = ""
    private static let strips: NSCache<NSNumber, CGImageBox> = { let c = NSCache<NSNumber, CGImageBox>(); c.totalCostLimit = 160 << 20; return c }()
    private static let stripQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.5, min: 2, max: 4); q.qualityOfService = .userInitiated; return q }()
    private func stripKey(_ row: Int) -> NSNumber { NSNumber(value: (stripGen << 24) | row) }
    private func rowRect(_ row: Int) -> CGRect { CGRect(x: 0, y: margin + CGFloat(row) * (size + gap), width: width, height: size) }
    /// Rows must be put together again (new list, size, columns, look).
    private func resetStrips() { stripGen += 1; stripInFlight = []; stripPrefetched = ""; Self.strips.removeAllObjects() }
    private func dropStrip(for id: Int) { if let i = indexOf[id] { Self.strips.removeObject(forKey: stripKey(i / cols)) } }

    private func drawStrips(_ r0: Int, _ r1: Int, _ px: Int, _ empty: CGColor, _ ctx: CGContext) {
        for row in r0...max(r0, r1) {
            let rr = rowRect(row)
            guard needsToDraw(rr), row * cols < photos.count else { continue }
            if let img = Self.strips.object(forKey: stripKey(row))?.image {
                ctx.saveGState()
                ctx.translateBy(x: rr.midX, y: rr.midY); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: -rr.width / 2, y: -rr.height / 2, width: rr.width, height: rr.height))
                ctx.restoreGState()
            } else {
                // not ready yet: what's already in memory, cell by cell, and put the row together
                for c in 0..<cols {
                    let i = row * cols + c
                    guard i < photos.count else { break }
                    let p = photos[i], cell = rect(i)
                    ctx.setFillColor(empty); ctx.fill(cell)
                    if let img = cachedSized(p.id, px, p.rot) { drawSized(img, px: px, in: cell, ctx) }
                }
                requestStrip(row, px)
            }
            // the selection on top
            for c in 0..<cols {
                let i = row * cols + c
                guard i < photos.count else { break }
                let p = photos[i]
                guard selection.contains(p.id) else { continue }
                let cell = rect(i)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(2)
                ctx.stroke(cell.insetBy(dx: 1, dy: 1))
                if primary != p.id { ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.fill(cell) }
            }
        }
        // the rows just off screen, ready before they scroll in
        let pk = "\(visibleRows)|\(px)|\(stripGen)"
        guard pk != stripPrefetched else { return }
        stripPrefetched = pk
        for row in visibleRows where (row < r0 || row > r1) && row * cols < photos.count {
            if Self.strips.object(forKey: stripKey(row)) == nil { requestStrip(row, px) }
        }
    }

    private func requestStrip(_ row: Int, _ px: Int) {
        guard !stripInFlight.contains(row) else { return }
        let start = row * cols, end = min(photos.count, start + cols)
        guard start < end else { return }
        stripInFlight.insert(row)
        let ps = Array(photos[start..<end]), gen = stripGen, key = stripKey(row)
        let scale = window?.backingScaleFactor ?? 2, sq = square
        let size = self.size, gap = self.gap, margin = self.margin, width = self.width
        var bg = NSColor.black.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.underPageBackgroundColor.cgColor }
        let empty = NSColor(white: dark ? (sq ? 0.16 : 0.2) : (sq ? 0.86 : 0.9), alpha: 1).cgColor
        Self.stripQueue.addOperation { [weak self] in
            guard let self else { return }
            self.visLock.lock(); let still = self.visShared.contains(row); self.visLock.unlock()
            let img: CGImage? = still ? autoreleasepool {
                Self.makeStrip(ps, px: px, square: sq, scale: scale, size: size, gap: gap, margin: margin, width: width, bg: bg, empty: empty)
            } : nil
            DispatchQueue.main.async {
                guard gen == self.stripGen else { return }
                self.stripInFlight.remove(row)
                guard let img else { return }
                Self.strips.setObject(CGImageBox(img), forKey: key, cost: img.width * img.height * 4)
                self.setNeedsDisplay(self.rowRect(row))
            }
        }
    }

    /// One row: the background, then each photo at exactly its cell's size (made now if it isn't in memory yet).
    static func makeStrip(_ ps: [Photo], px: Int, square: Bool, scale: CGFloat, size: CGFloat, gap: CGFloat, margin: CGFloat, width: CGFloat,
                          bg: CGColor, empty: CGColor) -> CGImage? {
        let W = Int((width * scale).rounded()), H = Int((size * scale).rounded())
        guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .medium
        let cw = size * scale
        for (c, p) in ps.enumerated() {
            let x = (margin + CGFloat(c) * (size + gap)) * scale
            ctx.setFillColor(empty); ctx.fill(CGRect(x: x, y: 0, width: cw, height: CGFloat(H)))
            let key = NSNumber(value: sizedKey(p.id, px, p.rot, square))
            var im = cache.object(forKey: key)?.image
            if im == nil, let m = makeSized(p, px: px, square: square) { cache.setObject(CGImageBox(m), forKey: key, cost: m.width * m.height * 4); im = m }
            guard let im else { continue }
            let k = cw / CGFloat(px), w = CGFloat(im.width) * k, h = CGFloat(im.height) * k
            ctx.draw(im, in: CGRect(x: x + (cw - w) / 2, y: (CGFloat(H) - h) / 2, width: w, height: h))
        }
        return ctx.makeImage()
    }

    // MARK: loading thumbnails
    private func key(_ id: Int, _ t: Tier) -> NSNumber { NSNumber(value: id * 4 + t.rawValue) }
    private func cached(_ id: Int, _ t: Tier) -> CGImage? { Self.cache.object(forKey: key(id, t))?.image }

    /// Missing thumbnails are fetched in batches (not one task per photo), skipping any that have scrolled away.
    private func load(_ p: Photo, _ t: Tier, row: Int, px: Int = 0) {
        let k = t == .sized ? sizedKey(p.id, px, p.rot) : p.id * 4 + t.rawValue
        guard !inFlight.contains(k) else { return }
        inFlight.insert(k)
        pending.append((p, t, row, px))
        guard !batchQueued else { return }
        batchQueued = true
        DispatchQueue.main.async { [weak self] in self?.sendBatches() }
    }
    private func sendBatches() {
        batchQueued = false
        let all = pending; pending = []
        // nearest rows first
        let mid = viewMid
        let sorted = all.sorted { abs($0.2 - mid) < abs($1.2 - mid) }
        let sq = square
        for chunk in stride(from: 0, to: sorted.count, by: 48).map({ Array(sorted[$0 ..< min($0 + 48, sorted.count)]) }) {
            Self.loader.addOperation { [weak self] in
                guard let self else { return }
                var got: [(Int, Int, CGImage?)] = []                  // photo, cache key, image
                for (p, t, row, px) in chunk {
                    self.visLock.lock(); let still = self.visShared.contains(row); self.visLock.unlock()
                    let k = t == .sized ? Self.sizedKey(p.id, px, p.rot, sq) : p.id * 4 + t.rawValue
                    let img = still ? autoreleasepool { t == .sized ? Self.makeSized(p, px: px, square: sq) : Self.makeImage(p, t) } : nil
                    got.append((p.id, k, img))
                }
                DispatchQueue.main.async {
                    for (id, k, img) in got {
                        self.inFlight.remove(k)
                        if let img { Self.cache.setObject(CGImageBox(img), forKey: NSNumber(value: k), cost: img.width * img.height * 4); self.arrived.insert(id) }
                    }
                    self.repaintSoon()
                }
            }
        }
    }
    /// One repaint per frame, however many thumbnails arrive.
    private func repaintSoon() {
        guard !repaintQueued else { return }
        repaintQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.repaintQueued = false
            // just the cells whose thumbnails arrived (a whole screen of small cells redrawn 30 times a second was the stutter)
            let ids = self.arrived; self.arrived = []
            if ids.count > 600, let vis = self.enclosingScrollView?.contentView.documentVisibleRect { self.setNeedsDisplay(vis); return }
            for id in ids { if let i = self.indexOf[id] { self.setNeedsDisplay(self.rect(i)) } }
        }
    }
    static func makeImage(_ p: Photo, _ t: Tier) -> CGImage? {
        guard t == .micro else { return ThumbBuilder.shared.image(p, t.stored) }
        // micro: unpack the mini thumbnail straight to 64 px (JPEG can decode at a fraction of its size — very fast)
        var data = PreviewStore.shared.data(p.id, .mini)
        if data == nil, ThumbBuilder.shared.buildNow(p) { data = PreviewStore.shared.data(p.id, .mini) }
        guard let d = data, let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                                                           kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: mouse
    private var downAt: CGPoint?
    private var downIndex: Int?
    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        downAt = pt; downIndex = index(at: pt)
        guard let i = downIndex else { return }
        let p = photos[i]
        if e.clickCount == 1, showsPin(p), pinRect(rect(i)).insetBy(dx: -2, dy: -2).contains(pt) { onMap?(p); downIndex = nil; return }
        if showDetail, e.clickCount == 1, e.modifierFlags.intersection([.shift, .command]).isEmpty {
            let cell = rect(i)
            if flagRect(cell).contains(pt) { onFlag?(p); downIndex = nil; return }
            if showRotate, let dir = [-1, 1].first(where: { rotRect(cell, $0).contains(pt) }) { onRotate?(p, dir); downIndex = nil; return }
            if let n = (1...5).first(where: { starRect(cell, $0).contains(pt) }) { onRate?(p, n == p.rating ? 0 : n); downIndex = nil; return }
        }
        if e.clickCount >= 2 { onOpen?(p); return }
        // clicking inside an existing selection keeps it, so the whole selection can be dragged
        if selection.contains(p.id) && selection.count > 1 && e.modifierFlags.intersection([.shift, .command]).isEmpty { return }
        onSelect?(p, e.modifierFlags)
    }
    override func mouseUp(with e: NSEvent) {
        // a plain click (no drag) inside a multi-selection selects just that photo
        if let i = downIndex, let a = downAt, hypot(convert(e.locationInWindow, from: nil).x - a.x, convert(e.locationInWindow, from: nil).y - a.y) < 4,
           selection.count > 1, selection.contains(photos[i].id), e.modifierFlags.intersection([.shift, .command]).isEmpty, e.clickCount == 1 {
            onSelect?(photos[i], [])
        }
        downAt = nil; downIndex = nil
    }
    /// Dragging photos: onto a sidebar folder moves them there; into Finder or another app copies them.
    override func mouseDragged(with e: NSEvent) {
        guard let a = downAt, let i = downIndex else { return }
        let pt = convert(e.locationInWindow, from: nil)
        guard hypot(pt.x - a.x, pt.y - a.y) > 4 else { return }
        downAt = nil
        let p = photos[i]
        let ids = selection.contains(p.id) ? selection : [p.id]
        let dragged = ids.compactMap { indexOf[$0] }.sorted().map { photos[$0] }
        let picture = cached(p.id, .mini) ?? cached(p.id, .thumb) ?? cached(p.id, .micro) ?? drawnPx.flatMap { cachedSized(p.id, $0, p.rot) }
        let r = rect(i)
        var items: [NSDraggingItem] = []
        for (n, ph) in dragged.enumerated() {
            let it = NSDraggingItem(pasteboardWriter: ph.url as NSURL)
            let f = CGRect(x: r.minX + CGFloat(min(n, 4)) * 4, y: r.minY + CGFloat(min(n, 4)) * 4, width: min(r.width, 120), height: min(r.height, 120))
            it.setDraggingFrame(f, contents: n < 5 ? picture.map { NSImage(cgImage: $0, size: f.size) } : nil)
            items.append(it)
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: e, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }
    override func menu(for e: NSEvent) -> NSMenu? {
        let pt = convert(e.locationInWindow, from: nil)
        guard let i = index(at: pt) else { return nil }
        let p = photos[i]
        if !selection.contains(p.id) { onSelect?(p, []) }
        return menuFor?(p)
    }
}

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}

/// The right-click menu for the fast grid (the same choices as the SwiftUI one).
enum GridMenu {
    static func make(_ photo: Photo, lib: Library, ui: UIState) -> NSMenu {
        let t = ui.selection.contains(photo.id) ? ui.targets(lib) : [photo]
        let m = NSMenu()
        let rating = NSMenu()
        for n in 0...5 { rating.addItem(ActionItem(n == 0 ? "None" : String(repeating: "★", count: n)) { lib.setRating(t, n) }) }
        let r = NSMenuItem(title: "Rating", action: nil, keyEquivalent: ""); r.submenu = rating; m.addItem(r)
        m.addItem(ActionItem(photo.flag ? "Unflag" : "Flag") { lib.toggleFlag(t) })
        m.addItem(ActionItem(photo.rejected ? "Not Rejected" : "Reject") { lib.toggleReject(t) })
        let labels = NSMenu()
        for l in PhotoLabel.all { labels.addItem(ActionItem(l.name) { lib.setLabel(t, l.id) }) }
        labels.addItem(.separator()); labels.addItem(ActionItem("None") { lib.setLabel(t, nil) })
        let li = NSMenuItem(title: "Color Label", action: nil, keyEquivalent: ""); li.submenu = labels; m.addItem(li)
        m.addItem(.separator())
        m.addItem(ActionItem("Rotate Left") { lib.rotate(t, -1) })
        m.addItem(ActionItem("Rotate Right") { lib.rotate(t, 1) })
        m.addItem(.separator())
        let albums = lib.albums.filter { $0.type == "album" }.sorted { (lib.collectionPath($0) + $0.name).localizedStandardCompare(lib.collectionPath($1) + $1.name) == .orderedAscending }
        if !albums.isEmpty {
            let am = NSMenu()
            for a in albums { let p = lib.collectionPath(a); am.addItem(ActionItem(p.isEmpty ? a.name : p + " › " + a.name) { lib.addToAlbum(a.id, t) }) }
            let ai = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: ""); ai.submenu = am; m.addItem(ai)
        }
        if case .album(let id) = ui.source, let c = lib.collection(id), c.type == "album" {
            m.addItem(ActionItem("Remove from “\(c.name)”") { lib.removeFromCollection(id, t) })
        }
        m.addItem(ActionItem("New Collection with \(t.count == 1 ? "This Photo" : "\(t.count) Photos")…") { ui.selection = Set(t.map(\.id)); ui.newAlbum(lib) })
        m.addItem(.separator())
        let apps = Outside.apps(for: photo.url)
        if !apps.isEmpty {
            let om = NSMenu()
            for a in apps.prefix(12) {
                let it = ActionItem(Outside.name(a)) { Outside.open(t, with: a) }
                it.image = NSWorkspace.shared.icon(forFile: a.path); it.image?.size = NSSize(width: 16, height: 16)
                om.addItem(it)
            }
            let oi = NSMenuItem(title: "Open With", action: nil, keyEquivalent: ""); oi.submenu = om; m.addItem(oi)
        }
        m.addItem(ActionItem("Set as Desktop Picture") { Outside.setDesktop(photo, lib: lib) })
        m.addItem(.separator())
        if case .person(let pid) = ui.source, let who = FaceIndex.shared.people[pid] {
            let ids = Set(t.map(\.id))
            // Apple Photos' "Make Key Photo": this photo's face becomes their circle in People
            if t.count == 1, let face = FaceIndex.shared.faces(inPhoto: photo.id).filter({ $0.person == pid && $0.rect != .zero }).max(by: { $0.quality < $1.quality }) {
                m.addItem(ActionItem("Make Key Photo") { FaceIndex.shared.setKeyFace(face.id, lib: lib) })
            }
            m.addItem(ActionItem(t.count > 1 ? "These \(t.count) Aren't \(who.name)" : "This Isn't \(who.name)") {
                FaceIndex.shared.remove(photos: ids, from: pid, lib: lib); ui.selection = []
            })
            m.addItem(.separator())
        }
        m.addItem(ActionItem("Go to Folder") { ui.goToFolder(photo) })
        if Library.gps(photo) != nil {
            m.addItem(ActionItem("Show on Map") { ui.showOnMap(photo) })
            m.addItem(ActionItem("Copy Location") { ui.primary = photo.id; ui.copyLocation(lib) })
        }
        if ui.copiedLocation != nil { m.addItem(ActionItem(t.count > 1 ? "Paste Location to \(t.count) Photos" : "Paste Location") { ui.pasteLocation(lib) }) }
        m.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(t.map(\.url)) })
        m.addItem(.separator())
        m.addItem(ActionItem(t.count > 1 ? "Delete \(t.count) Photos…" : "Delete…") { ui.deleteTargets(lib) })
        return m
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}


/// The round magnifier drawn over the grid.
final class GridLoupeView: NSView {
    var image: CGImage?
    var photoId: Int?
    var frac = CGPoint(x: 0.5, y: 0.5)
    var pixelSize = CGSize(width: 1, height: 1)
    var mag: CGFloat = 1
    var scale: CGFloat = 2
    var rot = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.6; layer?.shadowRadius = 12; layer?.shadowOffset = .zero
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go through to the grid
    override func layout() { super.layout(); layer?.shadowPath = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil) }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds, circle = b.insetBy(dx: 2, dy: 2)
        ctx.saveGState()
        ctx.addEllipse(in: circle); ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(b)
        if let img = image {
            // the whole photo at 100% (or 200%), placed so the spot under the pointer sits in the middle
            let w = pixelSize.width / scale * mag, h = pixelSize.height / scale * mag
            let dest = CGRect(x: b.midX - frac.x * w, y: b.midY - frac.y * h, width: w, height: h)
            let q = ((rot % 4) + 4) % 4
            ctx.interpolationQuality = .high
            ctx.translateBy(x: dest.midX, y: dest.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.rotate(by: -CGFloat(q) * .pi / 2)
            let (dw, dh) = q % 2 == 1 ? (h, w) : (w, h)
            ctx.draw(img, in: CGRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh))
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: b.insetBy(dx: 0.5, dy: 0.5))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(3); ctx.strokeEllipse(in: circle.insetBy(dx: 1.5, dy: 1.5))
    }
}


/// The year labels along the right edge of the grid.
final class YearRail: NSView {
    weak var doc: GridDocView?
    private var labels: [(rect: CGRect, index: Int)] = []
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); alphaValue = 0 }
    required init?(coder: NSCoder) { fatalError() }

    private var worthShowing: Bool {
        guard let d = doc, let clip = d.enclosingScrollView?.contentView else { return false }
        return d.yearLabels && d.yearMarks.count > 1 && d.frame.height > clip.bounds.height * 2.5
    }
    func scrolled() {
        guard worthShowing else { if alphaValue > 0 { alphaValue = 0 }; return }
        needsDisplay = true
        show(true)
        if !hovering { hideSoon() }
    }
    private func show(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { c in c.duration = on ? 0.12 : 0.4; animator().alphaValue = on ? 1 : 0 }
    }
    private func hideSoon() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in guard let self, !self.hovering else { return }; self.show(false) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { guard worthShowing else { return }; hovering = true; hideWork?.cancel(); needsDisplay = true; show(true) }
    override func mouseExited(with e: NSEvent) { hovering = false; hideSoon() }
    /// Only the labels take clicks; everything else goes to the photos underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.3 else { return nil }
        let p = convert(point, from: superview)
        return labels.contains { $0.rect.contains(p) } ? self : nil
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let l = labels.first(where: { $0.rect.contains(p) }) { doc?.scrollToRow(of: l.index) }
    }
    override func draw(_ dirty: NSRect) {
        labels = []
        guard let d = doc, d.frame.height > 0 else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        var lastBottom: CGFloat = -100
        for m in d.yearMarks {
            let y = d.rect(m.index).minY / d.frame.height * (bounds.height - 22) + 4
            guard y >= lastBottom + 3 else { continue }          // keep labels from overlapping
            let s = NSAttributedString(string: String(m.year), attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = s.size()
            let r = CGRect(x: bounds.width - sz.width - 16, y: y, width: sz.width + 12, height: sz.height + 4)
            NSColor.black.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 2))
            labels.append((r, m.index))
            lastBottom = r.maxY
        }
    }
}

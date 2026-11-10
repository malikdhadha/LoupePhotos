import AppKit
import ImageIO

/// Thumbnails and viewer images. Thumbnails are shared with the Electron version (Previews/thumbs/<id>.jpg);
/// missing ones are made with Quick Look and saved there. A small memory cache keeps scrolling smooth.
final class Images {
    static let shared = Images()
    private let thumbs = NSCache<NSNumber, NSImage>()
    private let big = NSCache<NSNumber, NSImage>()
    private let gate = AsyncGate(limit: 6)
    /// The thumbnail cache fits the Mac: about 1/24 of its memory (≈340 MB on 8 GB, ≈680 MB on 16 GB), 256–800 MB.
    init() {
        let mb = Int(ProcessInfo.processInfo.physicalMemory >> 20) / 24
        let limit = min(800, max(256, mb))
        thumbs.totalCostLimit = limit << 20
        thumbs.countLimit = limit * 14                 // ~70 KB a thumbnail on average
        big.countLimit = ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 20 : 12
        // when the Mac runs short of memory, give back what can be made again (big images first, then thumbnails)
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            let critical = self.pressure.data.contains(.critical)
            self.big.removeAllObjects(); self.cgCache.removeAllObjects()
            MatchCache.shared.clear()
            if critical { self.thumbs.removeAllObjects() }
        }
        pressure.resume()
    }
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    private let prefetchLock = NSLock()
    private var prefetching = Set<Int>()
    /// A screen-sized image already in memory (no waiting).
    func cachedFull(_ id: Int, minPixel: Int) -> NSImage? {
        guard let i = big.object(forKey: id as NSNumber), Int(max(i.size.width, i.size.height)) >= minPixel * 9 / 10 else { return nil }
        return i
    }
    /// Loads the next photos in the background so stepping to them is instant. Keeps going if you move on.
    func prefetch(_ ps: [Photo], lib: Library, maxPixel: Int) {
        for p in ps where cachedFull(p.id, minPixel: maxPixel) == nil {
            let fresh = prefetchLock.withLock { prefetching.insert(p.id).inserted }
            guard fresh else { continue }
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.full(p, lib: lib, maxPixel: maxPixel)
                self?.done(p.id)
            }
        }
    }

    private func done(_ id: Int) { prefetchLock.withLock { _ = prefetching.remove(id) } }

    func cachedThumb(_ id: Int) -> NSImage? { thumbs.object(forKey: id as NSNumber) }

    /// A thumbnail from the previews package (built on the spot if it is missing).
    func thumb(_ p: Photo, lib: Library) async -> NSImage? {
        if let i = thumbs.object(forKey: p.id as NSNumber) { return i }
        await gate.enter(); defer { Task { await gate.leave() } }
        if let i = thumbs.object(forKey: p.id as NSNumber) { return i }
        guard let cg = await Task.detached(priority: .userInitiated, operation: { ThumbBuilder.shared.image(p, .thumb) }).value else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs.setObject(img, forKey: p.id as NSNumber, cost: cg.width * cg.height * 4)
        return img
    }

    /// A screen-sized image for the viewer: the Standard preview if there is one, else decoded from the original.
    func full(_ p: Photo, lib: Library, maxPixel: Int) async -> NSImage? {
        if let i = big.object(forKey: p.id as NSNumber), Int(max(i.size.width, i.size.height)) >= maxPixel * 9 / 10 { return i }
        let legacy = lib.previews.appendingPathComponent("standard/\(p.id).jpg")
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            func ns(_ c: CGImage) -> NSImage { NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height)) }
            let want = min(maxPixel, PreviewSettings.shared.standardPixels) * 9 / 10
            if let c = BigPreviews.load(p.id, .standard, minPixels: want, max: maxPixel) { return ns(c) }   // the Standard preview
            if let c = BigPreviews.load(p.id, .full, minPixels: want, max: maxPixel) { return ns(c) }       // or a 1:1
            if let c = BigPreviews.build(p, .standard) {                                                   // make it now, like Lightroom
                return max(c.width, c.height) > maxPixel ? (Images.decodeCG(BigPreviews.url(p.id, .standard)!, max: maxPixel).map(ns) ?? ns(c)) : ns(c)
            }
            if FileManager.default.fileExists(atPath: legacy.path), let i = Images.decode(legacy, max: maxPixel) { return i }   // original offline
            return nil
        }.value
        if let img { big.setObject(img, forKey: p.id as NSNumber) }
        return img
    }
    func full1to1(_ p: Photo) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            if let c = BigPreviews.load(p.id, .full, minPixels: 1, max: 20000) { return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height)) }
            guard let c = BigPreviews.render(p, .full) else { return nil }
            // RAW: keep it as a 1:1 preview (written after showing, so zooming isn't held up). JPEG and the like: the original is it.
            if p.isRaw, let u = BigPreviews.url(p.id, .full) { Task.detached(priority: .background) { BigPreviews.write(c, to: u) } }
            return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
        }.value
    }

    static func decodeCG(_ url: URL, max: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
    static func decode(_ url: URL, max: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max, kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    /// A thumbnail as a ready-to-draw CGImage, turned for the photo's rotation (for the Calendar and cards).
    private let cgCache: NSCache<NSString, CGImageBox> = { let c = NSCache<NSString, CGImageBox>(); c.totalCostLimit = 300 << 20; return c }()
    func cg(_ p: Photo, _ l: ThumbLevel) async -> CGImage? {
        let k = "\(p.id)-\(l.rawValue)-\(p.rot)" as NSString
        if let c = cgCache.object(forKey: k) { return c.image }
        let rot = p.rot
        let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let c = ThumbBuilder.shared.image(p, l) else { return nil }
            let q = ((rot % 4) + 4) % 4
            if q == 0 { return c }
            return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height)).rotated(q).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }.value
        if let img { cgCache.setObject(CGImageBox(img), forKey: k, cost: img.width * img.height * 4) }
        return img
    }
    func forgetAll() { cgCache.removeAllObjects(); thumbs.removeAllObjects(); big.removeAllObjects() }
    func forget(_ id: Int) {
        thumbs.removeObject(forKey: id as NSNumber); big.removeObject(forKey: id as NSNumber)
        for l in [ThumbLevel.mini, .thumb] { for r in 0..<4 { cgCache.removeObject(forKey: "\(id)-\(l.rawValue)-\(r)" as NSString) } }
    }
}

/// Lets only a few slow jobs (Quick Look, decoding) run at once.
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func enter() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if !waiting.isEmpty { waiting.removeFirst().resume() } else { running -= 1 }
    }
}

extension NSImage {
    func jpegData(_ q: Double) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: q])
    }
}

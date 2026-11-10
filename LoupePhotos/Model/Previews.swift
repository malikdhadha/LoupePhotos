import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Thumbnail sizes kept for every photo. Mini is for the tiny grid and small cards, Thumb for everything bigger.
enum ThumbLevel: Int { case mini = 0, thumb = 1
    var pixels: Int { self == .mini ? 192 : 512 }
}

/// The previews package, "<Catalog> Previews.appreviews", beside the catalog.
/// Finder shows it as one item, and it holds every thumbnail in a few large pack files plus a small index,
/// so a library folder copied to another Mac opens with all its thumbnails ready, like Lightroom Classic.
final class PreviewStore: @unchecked Sendable {
    static let shared = PreviewStore()

    /// One index record per photo id: where its JPEG sits in which pack file. 16 bytes.
    struct Entry { var offset: UInt64 = 0; var length: UInt32 = 0; var pack: UInt16 = 0; var flags: UInt16 = 0 }

    private(set) var url: URL?
    private(set) var legacyThumbs: URL?            // Previews/thumbs/<id>.jpg from the Electron version, used as a fast source
    private let lock = NSLock()
    private var index: [[Entry]] = [[], []]
    private var readFDs: [Int32] = []
    private var writer: FileHandle?
    private var writeOffset: UInt64 = 0
    private var dirty = false
    private let packLimit: UInt64 = 1 << 30      // 1 GB per pack file
    private static let magic = Data("APIDX001".utf8)

    private var thumbsDir: URL? { url?.appendingPathComponent("Thumbnails", isDirectory: true) }
    private func packURL(_ n: Int) -> URL? { thumbsDir?.appendingPathComponent(String(format: "pack-%04d.bin", n)) }
    private func indexURL(_ l: ThumbLevel) -> URL? { thumbsDir?.appendingPathComponent(l == .mini ? "mini.index" : "thumb.index") }

    // MARK: open / close
    func open(libraryDir: URL, catalogName: String, legacyPreviews: URL) {
        close()
        lock.lock(); defer { lock.unlock() }
        let pkg = libraryDir.appendingPathComponent("\(catalogName) Previews.appreviews", isDirectory: true)
        url = pkg
        legacyThumbs = legacyPreviews.appendingPathComponent("thumbs", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: pkg.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        markAsPackage(pkg)
        let formatFile = pkg.appendingPathComponent("Format")
        if (try? String(contentsOf: formatFile, encoding: .utf8)) != "2" {
            for sub in ["Thumbnails", "Standard", "1-1"] { try? fm.removeItem(at: pkg.appendingPathComponent(sub)) }
            try? fm.createDirectory(at: pkg.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
            try? "2".write(to: formatFile, atomically: true, encoding: .utf8)
        }
        for l in [ThumbLevel.mini, .thumb] { index[l.rawValue] = loadIndex(l); indexOnDisk[l.rawValue] = !index[l.rawValue].isEmpty; dirtyIds[l.rawValue] = [] }
        var n = 0
        while let u = packURL(n), fm.fileExists(atPath: u.path) { readFDs.append(Darwin.open(u.path, O_RDONLY)); n += 1 }
        if readFDs.isEmpty { startPack(0) } else { resumeWriting(readFDs.count - 1) }
    }
    func close() {
        save()
        lock.lock(); defer { lock.unlock() }
        try? writer?.close(); writer = nil
        for fd in readFDs where fd >= 0 { Darwin.close(fd) }
        readFDs = []; index = [[], []]; url = nil
    }
    /// Shows the folder as a single item in Finder (the "package" bit), like Lightroom's .lrdata.
    private func markAsPackage(_ u: URL) {
        var v = URLResourceValues(); v.isPackage = true
        var m = u; try? m.setResourceValues(v)
    }

    // MARK: index
    private func loadIndex(_ l: ThumbLevel) -> [Entry] {
        guard let u = indexURL(l), let d = try? Data(contentsOf: u), d.count >= 8, d.prefix(8) == Self.magic else { return [] }
        let body = d.dropFirst(8)
        let n = body.count / MemoryLayout<Entry>.stride
        var out = [Entry](repeating: Entry(), count: n)
        out.withUnsafeMutableBytes { dst in body.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<(n * MemoryLayout<Entry>.stride)])) } }
        return out
    }
    /// Writes the index. Only the entries that changed are written, in place (16 bytes each), instead of the
    /// whole index (over 1 MB per size at 70,000 photos) every hundred thumbnails; and the grid isn't kept waiting.
    func save() {
        saveLock.lock(); defer { saveLock.unlock() }          // one save at a time, so writes land in order
        lock.lock()
        guard dirty, url != nil else { lock.unlock(); return }
        try? writer?.synchronize()
        var work: [(url: URL, full: Data?, entries: [(Int, Entry)])] = []
        for l in [ThumbLevel.mini, .thumb] {
            guard let u = indexURL(l) else { continue }
            let k = l.rawValue
            if indexOnDisk[k] {
                work.append((u, nil, dirtyIds[k].map { ($0, index[k][$0]) }))
            } else {
                var d = Self.magic
                index[k].withUnsafeBytes { d.append(contentsOf: $0) }
                work.append((u, d, []))
            }
            dirtyIds[k] = []
        }
        dirty = false
        lock.unlock()
        for (i, w) in work.enumerated() {
            if let d = w.full {
                if (try? d.write(to: w.url, options: .atomic)) != nil { lock.withLock { indexOnDisk[i] = true } }
                continue
            }
            guard !w.entries.isEmpty else { continue }
            let fd = Darwin.open(w.url.path, O_WRONLY)
            guard fd >= 0 else { lock.withLock { indexOnDisk[i] = false; dirty = true }; continue }
            let size = MemoryLayout<Entry>.stride
            for (id, e) in w.entries {
                var e = e
                _ = withUnsafeBytes(of: &e) { pwrite(fd, $0.baseAddress, size, off_t(8 + id * size)) }
            }
            Darwin.close(fd)
        }
    }
    private let saveLock = NSLock()
    private var dirtyIds: [Set<Int>] = [[], []]
    private var indexOnDisk = [false, false]           // a good index file is there to write into

    // MARK: packs
    private func startPack(_ n: Int) {
        guard let u = packURL(n) else { return }
        FileManager.default.createFile(atPath: u.path, contents: nil)
        try? writer?.close()
        writer = try? FileHandle(forWritingTo: u)
        writeOffset = 0
        if readFDs.count <= n { readFDs.append(Darwin.open(u.path, O_RDONLY)) }
    }
    private func resumeWriting(_ n: Int) {
        guard let u = packURL(n) else { return }
        writer = try? FileHandle(forWritingTo: u)
        writeOffset = (try? writer?.seekToEnd()) ?? 0
    }

    // MARK: reading and writing thumbnails
    func has(_ id: Int, _ l: ThumbLevel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = l.rawValue                                   // read in place (holding a copy would make the next save copy it all)
        return id >= 0 && id < index[k].count && index[k][id].flags & 1 == 1
    }
    /// The stored JPEG bytes, read straight from the pack (safe from any thread).
    func data(_ id: Int, _ l: ThumbLevel) -> Data? {
        lock.lock()
        let k = l.rawValue
        guard id >= 0, id < index[k].count, index[k][id].flags & 1 == 1, Int(index[k][id].pack) < readFDs.count else { lock.unlock(); return nil }
        let e = index[k][id], fd = readFDs[Int(e.pack)]
        lock.unlock()
        var d = Data(count: Int(e.length))
        let got = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(e.length), off_t(e.offset)) }
        return got == Int(e.length) ? d : nil
    }
    /// A decoded image, ready to draw (decoding happens here, not while drawing).
    func image(_ id: Int, _ l: ThumbLevel) -> CGImage? {
        guard let d = data(id, l), let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    func put(_ id: Int, _ l: ThumbLevel, _ jpeg: Data) {
        lock.lock(); defer { lock.unlock() }
        guard url != nil else { return }
        if writer == nil || writeOffset + UInt64(jpeg.count) > packLimit { startPack(readFDs.count) }
        guard let w = writer else { return }
        let packNo = readFDs.count - 1
        do { try w.write(contentsOf: jpeg) } catch { return }
        // changed in place: copying the index out and back (as before) copied every photo's entry for each thumbnail —
        // nothing at 1,000 photos, about 1 MB a thumbnail at 70,000, all while the grid waited for this lock
        let k = l.rawValue
        if id >= index[k].count { index[k].append(contentsOf: [Entry](repeating: Entry(), count: id - index[k].count + 1 + 4096)) }
        index[k][id] = Entry(offset: writeOffset, length: UInt32(jpeg.count), pack: UInt16(packNo), flags: 1)
        dirtyIds[k].insert(id)
        writeOffset += UInt64(jpeg.count)
        dirty = true
    }

    /// Throws every thumbnail away (Library ▸ Previews ▸ Discard Thumbnails); they are rebuilt as needed.
    func discardAll() {
        guard let pkg = url, let base = legacyThumbs?.deletingLastPathComponent() else { return }
        let lib = pkg.deletingLastPathComponent(), name = pkg.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " Previews", with: "")
        lock.lock(); dirty = false; lock.unlock()
        close()
        try? FileManager.default.removeItem(at: pkg.appendingPathComponent("Thumbnails"))
        open(libraryDir: lib, catalogName: name, legacyPreviews: base)
    }
    var bytesOnDisk: Int64 {
        guard let d = thumbsDir, let items = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Makes thumbnails: straight from the RAW's embedded JPEG when it is big enough (fast), else decoded from the image.
enum ThumbMaker {
    static func make(_ p: Photo) -> (mini: Data, thumb: Data)? {
        var base: CGImage?
        // edited in Develop: the thumbnail shows the edit
        if !p.missing, let r = DevelopStore.shared.recipe(p.id) { base = DevelopEngine.shared.render(DevelopEngine.Source(p), r, maxPixel: 512) }
        if base == nil, !p.missing {
            // RAW: the camera's own embedded JPEG (its look, and fast); other files: decoded directly
            if p.isRaw { base = Embedded.image(p.url, max: 512, minLong: 360) }
            if base == nil { base = decode(p.url, max: 512, always: true) }
        }
        if base == nil, let legacy = PreviewStore.shared.legacyThumbs?.appendingPathComponent("\(p.id).jpg"),
           FileManager.default.fileExists(atPath: legacy.path) { base = decode(legacy, max: 512, always: false) }   // original offline
        guard let b = base, let thumb = jpeg(b, q: 0.8), let small = scaled(b, max: ThumbLevel.mini.pixels), let mini = jpeg(small, q: 0.75) else { return nil }
        return (mini, thumb)
    }
    static func decode(_ url: URL, max: Int, always: Bool) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
    static func scaled(_ img: CGImage, max m: Int) -> CGImage? {
        let k = Double(m) / Double(Swift.max(img.width, img.height))
        if k >= 1 { return img }
        let w = Swift.max(1, Int(Double(img.width) * k)), h = Swift.max(1, Int(Double(img.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    static func jpeg(_ img: CGImage, q: Double) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

/// Builds missing thumbnails: right away for photos on screen, and quietly in the background for the rest.
final class ThumbBuilder: @unchecked Sendable {
    static let shared = ThumbBuilder()
    private let now = OperationQueue()
    private let background = OperationQueue()
    private let lock = NSLock()
    private var generation = 0
    init() {
        now.maxConcurrentOperationCount = Machine.workers(0.75, min: 3, max: 6); now.qualityOfService = .userInitiated
        background.maxConcurrentOperationCount = Machine.workers(0.5, min: 2, max: 5); background.qualityOfService = .utility
    }

    /// Makes and stores both sizes for one photo now (called off the main thread).
    @discardableResult
    func buildNow(_ p: Photo) -> Bool {
        guard let t = autoreleasepool(invoking: { ThumbMaker.make(p) }) else { return false }
        PreviewStore.shared.put(p.id, .mini, t.mini)
        PreviewStore.shared.put(p.id, .thumb, t.thumb)
        return true
    }
    /// The image for a photo at a size, building it first if it is missing.
    func image(_ p: Photo, _ l: ThumbLevel) -> CGImage? {
        if let i = PreviewStore.shared.image(p.id, l) { return i }
        guard buildNow(p) else { return nil }
        return PreviewStore.shared.image(p.id, l)
    }

    /// Walks the library and fills in every missing thumbnail, a few at a time, at low priority.
    func buildMissing(_ photos: [Photo], status: @escaping (String) -> Void) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        background.cancelAllOperations()
        let todo = photos.filter { !PreviewStore.shared.has($0.id, .thumb) && !$0.missing }
        guard !todo.isEmpty else { return }
        let total = todo.count
        let done = ManagedCounter()
        let pause: (Bool) -> Void = { [weak self] on in guard let self else { return }; self.userPaused = on; self.background.isSuspended = on || self.held }
        Activity.shared.report("thumbs", "Building thumbnails", done: 0, total: total, pause: pause)
        for p in todo {
            background.addOperation { [weak self] in
                guard let self else { return }
                self.lock.lock(); let live = gen == self.generation; self.lock.unlock()
                guard live else { return }
                if !PreviewStore.shared.has(p.id, .thumb) { self.buildNow(p) }
                let n = done.increment()
                if n % 50 == 0 || n == total {
                    if n % 100 == 0 || n == total { PreviewStore.shared.save() }
                    Activity.shared.report("thumbs", "Building thumbnails", done: n, total: total, pause: pause)
                }
            }
        }
    }
    func stop() { lock.lock(); generation += 1; lock.unlock(); background.cancelAllOperations(); userPaused = false; background.isSuspended = held; Activity.shared.finish("thumbs") }
    private var userPaused = false, held = false
    func hold(_ on: Bool) { guard held != on else { return }; held = on; background.isSuspended = userPaused || held }
}

final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

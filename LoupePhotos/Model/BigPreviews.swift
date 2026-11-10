import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Preview choices, kept in the catalog (like Lightroom's Catalog Settings ▸ File Handling).
@Observable
final class PreviewSettings {
    static let shared = PreviewSettings()
    enum Quality: String, CaseIterable, Identifiable { case low = "Low", medium = "Medium", high = "High"
        var id: String { rawValue }
        var heic: Double { self == .low ? 0.5 : self == .medium ? 0.65 : 0.8 }
    }
    enum OnImport: String, CaseIterable, Identifiable { case thumbnails = "Thumbnails Only", standard = "Standard", full = "1:1"; var id: String { rawValue } }
    static let sizes = [0, 1440, 1680, 2048, 2560, 2880, 3840]          // 0 = Auto (fits this Mac's screen)
    static let discardDays = [1, 7, 30, 0]                               // 0 = Never

    var standardSize = 0 { didSet { save() } }
    var quality: Quality = .medium { didSet { save() } }
    var discardFullAfter = 30 { didSet { save() } }
    /// What's built when photos come in, for JPEG, HEIC, PNG… (thumbnails are enough on a fast disk) …
    var onImport: OnImport = .thumbnails { didSet { save() } }
    /// … and for RAW files, which are slow to open, so a Standard preview is worth making up front.
    var onImportRaw: OnImport = .standard { didSet { save() } }
    /// Starts the previews chosen for newly added photos: RAW and the rest each by their own setting.
    func buildForNew(_ photos: [Photo], raw: OnImport? = nil, other: OnImport? = nil) {
        let r = photos.filter(\.isRaw), o = photos.filter { !$0.isRaw }
        for (ps, level) in [(r, raw ?? onImportRaw), (o, other ?? onImport)] where !ps.isEmpty {
            switch level {
            case .standard: PreviewJobs.shared.build(ps, .standard)
            case .full: PreviewJobs.shared.build(ps, .full)
            case .thumbnails: break
            }
        }
    }
    @ObservationIgnored private var loading = false

    /// The long edge Standard previews are made at.
    var standardPixels: Int {
        if standardSize > 0 { return standardSize }
        let s = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2880
        return PreviewSettings.sizes.dropFirst().first { CGFloat($0) >= s } ?? 3840
    }

    func load(_ lib: Library) {
        loading = true; defer { loading = false }
        let d = ((lib.lib["settings"] as? [String: Any])?["previews"] as? [String: Any]) ?? [:]
        standardSize = d["standardSize"] as? Int ?? 0
        quality = Quality(rawValue: d["quality"] as? String ?? "") ?? .medium
        discardFullAfter = d["discardFullAfter"] as? Int ?? 30
        onImport = OnImport(rawValue: d["onImport"] as? String ?? "") ?? .thumbnails
        onImportRaw = OnImport(rawValue: d["onImportRaw"] as? String ?? "") ?? .standard
    }
    private func save() {
        guard !loading else { return }
        let lib = Library.shared
        var s = lib.lib["settings"] as? [String: Any] ?? [:]
        s["previews"] = ["standardSize": standardSize, "quality": quality.rawValue, "discardFullAfter": discardFullAfter, "onImport": onImport.rawValue, "onImportRaw": onImportRaw.rawValue]
        lib.lib["settings"] = s
        lib.libChanged()
    }
}

/// Standard and 1:1 previews: one HEIC per photo inside the previews package
/// (Standard/ and 1-1/, spread over 256 sub-folders). HEIC is about half the size of Lightroom's JPEG previews.
enum BigPreviews {
    enum Kind: String { case standard = "Standard", full = "1-1" }

    static func url(_ id: Int, _ k: Kind) -> URL? {
        PreviewStore.shared.url?.appendingPathComponent(k.rawValue, isDirectory: true)
            .appendingPathComponent(String(format: "%02x", id & 0xff), isDirectory: true)
            .appendingPathComponent("\(id).heic")
    }
    static func exists(_ id: Int, _ k: Kind) -> Bool { url(id, k).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Reads a stored preview if it is at least `minPixels` on its long edge.
    static func load(_ id: Int, _ k: Kind, minPixels: Int, max: Int) -> CGImage? {
        guard let u = url(id, k), let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard Swift.max(w, h) >= minPixels else { return nil }
        if k == .full { touch(u) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Renders from the original and stores it. Returns the image so the caller can show it straight away.
    @discardableResult
    static func build(_ p: Photo, _ k: Kind) -> CGImage? {
        guard !p.missing, let u = url(p.id, k) else { return nil }
        guard let img = render(p, k) else { return nil }
        write(img, to: u)
        return img
    }
    /// Standard uses the camera's embedded JPEG when it is at least 1600 px; 1:1 when it is (nearly) full size.
    static func render(_ p: Photo, _ k: Kind) -> CGImage? {
        // edited in Develop: previews show the edit
        if !p.missing, let r = DevelopStore.shared.recipe(p.id) {
            return DevelopEngine.shared.render(DevelopEngine.Source(p), r, maxPixel: k == .standard ? PreviewSettings.shared.standardPixels : nil)
        }
        if k == .standard {
            let px = PreviewSettings.shared.standardPixels
            return Embedded.render(p, max: px, minLong: min(px, 1600))
        }
        let full = max(p.w, p.h)
        return Embedded.render(p, max: 20000, minLong: full > 0 ? full * 9 / 10 : 3000)
    }
    static func write(_ img: CGImage, to u: URL) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = u.appendingPathExtension("tmp")
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: PreviewSettings.shared.quality.heic] as CFDictionary)
        if CGImageDestinationFinalize(dst) { _ = try? FileManager.default.replaceItemAt(u, withItemAt: tmp) } else { try? FileManager.default.removeItem(at: tmp) }
    }
    private static func touch(_ u: URL) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path) }

    static func discard(_ ids: [Int], _ k: Kind) { for id in ids { if let u = url(id, k) { try? FileManager.default.removeItem(at: u) } } }
    static func discardAll(_ k: Kind) {
        guard let d = PreviewStore.shared.url?.appendingPathComponent(k.rawValue) else { return }
        try? FileManager.default.removeItem(at: d)
    }
    /// 1:1 previews not looked at for the chosen number of days are thrown away (run when the library opens).
    static func discardOldFull() {
        let days = PreviewSettings.shared.discardFullAfter
        guard days > 0, let d = PreviewStore.shared.url?.appendingPathComponent(Kind.full.rawValue) else { return }
        DispatchQueue.global(qos: .background).async {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let en = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.contentModificationDateKey])
            while let u = en?.nextObject() as? URL {
                if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff, u.pathExtension == "heic" {
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
    }
    static func bytes(_ k: Kind) -> Int64 {
        guard let d = PreviewStore.shared.url?.appendingPathComponent(k.rawValue) else { return 0 }
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey])
        while let u = en?.nextObject() as? URL { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

/// Library ▸ Previews jobs: build Standard or 1:1 for many photos in the background, with progress and Stop.
@Observable
final class PreviewJobs {
    static let shared = PreviewJobs()
    var running = false
    var title = ""
    var done = 0
    var total = 0
    @ObservationIgnored private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.4, min: 2, max: 4); q.qualityOfService = .utility; return q }()

    func build(_ photos: [Photo], _ k: BigPreviews.Kind) {
        stop()
        // 1:1 is only worth making for RAW files: a JPEG, HEIC or PNG already is full size, and zooming reads it directly
        let todo = photos.filter { !$0.missing && (k == .standard || $0.isRaw) && !BigPreviews.exists($0.id, k) }
        guard !todo.isEmpty else {
            Library.shared.status = k == .full && !photos.contains(where: \.isRaw) ? "1:1 previews are only made for RAW files — these photos are already full size."
                : "All \(photos.count.formatted()) photos already have \(k == .standard ? "Standard" : "1:1") previews."
            return
        }
        title = k == .standard ? "Building Standard previews" : "Building 1:1 previews"
        total = todo.count; done = 0; running = true
        let pause: (Bool) -> Void = { [weak self] on in self?.queue.isSuspended = on }
        Activity.shared.report("previews", title, done: 0, total: total, pause: pause)
        for p in todo {
            queue.addOperation { [weak self] in
                autoreleasepool { _ = BigPreviews.build(p, k) }
                DispatchQueue.main.async {
                    guard let self, self.running else { return }
                    self.done += 1
                    Activity.shared.report("previews", self.title, done: self.done, total: self.total)
                    if self.done >= self.total { self.running = false; Library.shared.status = "\(self.title.replacingOccurrences(of: "Building", with: "Built")) for \(self.total.formatted()) photos." }
                }
            }
        }
    }
    func stop() {
        queue.cancelAllOperations(); queue.isSuspended = false
        Activity.shared.finish("previews")
        if running { Library.shared.status = "Stopped after \(done.formatted()) of \(total.formatted())." }
        running = false
    }
}

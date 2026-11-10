import AppKit
import Observation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// File ▸ Export ▸ Photos… (⇧⌘E): JPEG, HEIC, TIFF, PNG or the originals, at any size, with your choice of names,
/// metadata (all, copyright only, none — location and people removable) and an optional copyright watermark.
/// Runs in Background Tasks. Until editing arrives, the originals are converted (RAW with Apple's own RAW engine).
struct ExportSettings: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = "Full-size JPEG"
    enum Format: String, Codable, CaseIterable, Identifiable { case jpeg = "JPEG", heic = "HEIC", tiff = "TIFF", png = "PNG", original = "Original"; var id: String { rawValue } }
    enum Size: String, Codable, CaseIterable, Identifiable { case full = "Full size", longEdge = "Long edge", megapixels = "Megapixels", percent = "Percentage"; var id: String { rawValue } }
    enum Space: String, Codable, CaseIterable, Identifiable { case srgb = "sRGB", p3 = "Display P3", adobe = "Adobe RGB (1998)"; var id: String { rawValue } }
    enum Meta: String, Codable, CaseIterable, Identifiable { case all = "All metadata", copyright = "Copyright only", none = "None"; var id: String { rawValue } }
    enum Folder: String, Codable, CaseIterable, Identifiable { case none = "Right in the folder", date = "In a folder per day", same = "In a folder named like the photo's folder"; var id: String { rawValue } }
    var format: Format = .jpeg
    var quality = 0.9
    var size: Size = .full
    var sizeValue = 2048.0
    var space: Space = .srgb
    var sharpen = false
    var rename = false
    var template = "{date} {name}"
    var meta: Meta = .all
    var removeLocation = false
    var removePeople = false
    var watermark = false
    var watermarkText = ""
    var sidecars = true              // originals: their .xmp travels with them
    var destination = ""
    var subfolder: Folder = .none
    var reveal = true

    static let builtIn: [ExportSettings] = [
        ExportSettings(id: "full", name: "Full-size JPEG"),
        ExportSettings(id: "web", name: "Web (2048 px, no location)", quality: 0.82, size: .longEdge, sizeValue: 2048, sharpen: true, removeLocation: true, removePeople: true),
        ExportSettings(id: "email", name: "Email (1280 px)", quality: 0.78, size: .longEdge, sizeValue: 1280, sharpen: true),
        ExportSettings(id: "heic", name: "Full-size HEIC", format: .heic, quality: 0.85),
        ExportSettings(id: "originals", name: "Originals", format: .original),
    ]
}

@Observable
final class Exporter {
    static let shared = Exporter()
    private(set) var presets: [ExportSettings] = []
    var current = ExportSettings() { didSet { store() } }
    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "export.presets"), let p = try? JSONDecoder().decode([ExportSettings].self, from: data) { presets = p }
        if let data = d.data(forKey: "export.current"), let c = try? JSONDecoder().decode(ExportSettings.self, from: data) { current = c }
        if current.destination.isEmpty { current.destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Exports").path }
    }
    var all: [ExportSettings] { ExportSettings.builtIn + presets }
    func savePreset(_ name: String) { var p = current; p.id = UUID().uuidString; p.name = name; presets.append(p); storePresets() }
    func deletePreset(_ id: String) { presets.removeAll { $0.id == id }; storePresets() }
    func use(_ p: ExportSettings) { let dest = current.destination; current = p; if current.destination.isEmpty { current.destination = dest } }
    private func store() { if let d = try? JSONEncoder().encode(current) { UserDefaults.standard.set(d, forKey: "export.current") } }
    private func storePresets() { if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: "export.presets") } }

    // MARK: running
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.4, min: 2, max: 4); q.qualityOfService = .userInitiated; return q }()

    /// Exports photos with settings `s` into `folder` (default: the settings' destination). `done` gets the files made.
    func export(_ ps: [Photo], _ s: ExportSettings, into folder: URL? = nil, quiet: Bool = false, done: (([URL]) -> Void)? = nil) {
        let root = folder ?? URL(fileURLWithPath: s.destination)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobs = ps.filter { !$0.missing }.enumerated().map { (n, p) in Job(p, s, seq: n + 1) }
        guard !jobs.isEmpty else { done?([]); return }
        let total = jobs.count, counter = ManagedCounter(), made = OutputList()
        let id = "export-" + UUID().uuidString.prefix(6)
        if !quiet { Activity.shared.report(String(id), "Exporting \(total.formatted()) photo\(total == 1 ? "" : "s")", done: 0, total: total, pause: { [weak self] on in self?.queue.isSuspended = on }) }
        for j in jobs {
            queue.addOperation {
                autoreleasepool { if let u = Exporter.run(j, s, root) { made.add(u) } }
                let n = counter.increment()
                if !quiet { Activity.shared.report(String(id), "Exporting \(total.formatted()) photo\(total == 1 ? "" : "s")", done: n, total: total) }
                if n == total {
                    DispatchQueue.main.async {
                        let urls = made.all
                        if !quiet {
                            Library.shared.status = urls.count == total ? "Exported \(total.formatted()) photo\(total == 1 ? "" : "s") to “\(root.lastPathComponent)”."
                                : "Exported \(urls.count.formatted()) of \(total.formatted()) — some couldn't be read (offline or damaged)."
                            if s.reveal, !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(200))) }
                        }
                        done?(urls)
                    }
                }
            }
        }
    }
    final class OutputList: @unchecked Sendable {
        private let lock = NSLock(); private var urls: [URL] = []
        func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    /// One photo's details, copied on the main thread.
    struct Job {
        let url: URL, ext: String, isRaw: Bool, rot: Int, name: String, title: String, date: Date, dateKnown: Bool, folder: String
        let caption: String, keywords: [String], iptc: [String: String], camera: String, seq: Int, xmp: XMPSync.Snap
        let develop: Recipe?
        let photoId: Int
        init(_ p: Photo, _ s: ExportSettings, seq: Int) {
            url = p.url; ext = p.ext; isRaw = p.isRaw; rot = p.rot; name = (p.fileName as NSString).deletingPathExtension
            title = p.iptc(.title); date = p.captureDate; dateKnown = !p.dateFromFile; folder = (p.dir as NSString).lastPathComponent
            caption = p.caption; iptc = p.iptc; camera = p.camera; self.seq = seq
            keywords = s.removePeople ? p.keywords.filter { !$0.hasPrefix("People/") } : p.keywords
            xmp = XMPSync.Snap(p)
            develop = DevelopStore.shared.recipe(p.id); photoId = p.id
        }
    }

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// The file name from the template: {name} {title} {date} {time} {seq} {camera}.
    static func fileName(_ j: Job, _ s: ExportSettings) -> String {
        guard s.rename else { return j.name }
        var t = s.template
        let parts: [String: String] = ["{name}": j.name, "{title}": j.title.isEmpty ? j.name : j.title, "{date}": day.string(from: j.date),
                                       "{time}": time.string(from: j.date), "{seq}": String(format: "%03d", j.seq), "{camera}": j.camera]
        for (k, v) in parts { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? j.name : t
    }
    static func uniqueURL(_ dir: URL, _ base: String, _ ext: String) -> URL {
        var u = dir.appendingPathComponent(base).appendingPathExtension(ext), n = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext); n += 1 }
        return u
    }

    /// Exports one photo. Returns the file made.
    static func run(_ j: Job, _ s: ExportSettings, _ root: URL) -> URL? {
        var dir = root
        switch s.subfolder {
        case .date: dir = root.appendingPathComponent(day.string(from: j.date))
        case .same: dir = root.appendingPathComponent(j.folder)
        case .none: break
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = fileName(j, s)

        // the original file, untouched (and its .xmp, made from the catalog if there isn't one)
        if s.format == .original {
            let out = uniqueURL(dir, base, j.ext)
            guard (try? FileManager.default.copyItem(at: j.url, to: out)) != nil else { return nil }
            if s.sidecars, s.meta != .none {
                let side = XMPSync.sidecar(for: j.url), outSide = out.deletingPathExtension().appendingPathExtension("xmp")
                if FileManager.default.fileExists(atPath: side.path) { try? FileManager.default.copyItem(at: side, to: outSide) }
                else if let d = XMPSync.packet(j.xmp).data(using: .utf8) { try? d.write(to: outSide) }
            }
            return out
        }

        // read the photo (RAW too) at the size wanted, turned the right way up
        guard let src = CGImageSourceCreateWithURL(j.url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let long = max(w, h, 1)
        var target: Int
        switch s.size {
        case .full: target = long
        case .longEdge: target = min(long, Int(s.sizeValue))
        case .megapixels: target = min(long, Int((Double(long) * sqrt(s.sizeValue * 1_000_000 / Double(max(1, w * h)))).rounded()))
        case .percent: target = max(1, Int(Double(long) * s.sizeValue / 100))
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(1, target), kCGImageSourceShouldCacheImmediately: true]
        // edited in Develop: exported with the edits (and the crop)
        var img: CGImage
        if let r = j.develop, let e = DevelopEngine.shared.render(DevelopEngine.Source(url: j.url, isRaw: j.isRaw, id: j.photoId, model: j.camera), r, maxPixel: s.size == .full ? nil : max(1, target)) { img = e }
        else {
            guard let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            img = t
        }
        if ((j.rot % 4) + 4) % 4 != 0, let r = rotate(img, j.rot) { img = r }

        // colour space, light sharpening for screens, and the watermark
        let space: CGColorSpace = {
            switch s.space {
            case .srgb: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .p3: return CGColorSpace(name: CGColorSpace.displayP3)!
            case .adobe: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            }
        }()
        var ci = CIImage(cgImage: img)
        if s.sharpen && target < long {
            let f = CIFilter(name: "CISharpenLuminance")!; f.setValue(ci, forKey: kCIInputImageKey); f.setValue(0.35, forKey: kCIInputSharpnessKey)
            if let o = f.outputImage { ci = o.cropped(to: ci.extent) }
        }
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        guard var out = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space) else { return nil }
        if s.watermark, let wm = watermark(out, text: s.watermarkText.isEmpty ? Identity.value(.copyright) : s.watermarkText, space: space) { out = wm }

        // write it, with the metadata chosen
        let (ext, type): (String, UTType) = {
            switch s.format {
            case .jpeg: return ("jpg", .jpeg)
            case .heic: return ("heic", .heic)
            case .tiff: return ("tif", .tiff)
            case .png: return ("png", .png)
            case .original: return (j.ext, .jpeg)
            }
        }()
        let file = uniqueURL(dir, base, ext)
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        var p: [CFString: Any] = [:]
        if s.meta == .all {
            for k in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary] { if let v = props[k] { p[k] = v } }
            if !s.removeLocation, let g = props[kCGImagePropertyGPSDictionary] { p[kCGImagePropertyGPSDictionary] = g }
        }
        if s.meta != .none {
            var iptc: [CFString: Any] = [:]
            let i = j.iptc
            func put(_ k: CFString, _ v: String?) { if let v, !v.isEmpty { iptc[k] = v } }
            put(kCGImagePropertyIPTCCopyrightNotice, i["copyright"]); put(kCGImagePropertyIPTCByline, i["creator"])
            if s.meta == .all {
                put(kCGImagePropertyIPTCObjectName, i["title"]); put(kCGImagePropertyIPTCCaptionAbstract, j.caption)
                put(kCGImagePropertyIPTCHeadline, i["headline"]); put(kCGImagePropertyIPTCCredit, i["credit"]); put(kCGImagePropertyIPTCSource, i["source"])
                put(kCGImagePropertyIPTCSpecialInstructions, i["instructions"])
                if !s.removeLocation {
                    put(kCGImagePropertyIPTCCity, i["city"]); put(kCGImagePropertyIPTCProvinceState, i["state"])
                    put(kCGImagePropertyIPTCCountryPrimaryLocationName, i["country"]); put(kCGImagePropertyIPTCSubLocation, i["location"])
                }
                let kws = j.keywords.compactMap { $0.split(separator: "/").last.map(String.init) }
                if !kws.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = kws }
            }
            if !iptc.isEmpty { p[kCGImagePropertyIPTCDictionary] = iptc }
            var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if let c = i["copyright"], !c.isEmpty { tiff[kCGImagePropertyTIFFCopyright] = c }
            if let a = i["creator"], !a.isEmpty { tiff[kCGImagePropertyTIFFArtist] = a }
            if !tiff.isEmpty { tiff[kCGImagePropertyTIFFOrientation] = 1; p[kCGImagePropertyTIFFDictionary] = tiff }
        }
        p[kCGImagePropertyOrientation] = 1                    // already turned the right way up
        if s.format == .jpeg || s.format == .heic { p[kCGImageDestinationLossyCompressionQuality] = s.quality }
        CGImageDestinationAddImage(dest, out, p as CFDictionary)
        return CGImageDestinationFinalize(dest) ? file : nil
    }

    static func rotate(_ img: CGImage, _ rot: Int) -> CGImage? {
        let q = ((rot % 4) + 4) % 4
        let w = q % 2 == 1 ? img.height : img.width, h = q % 2 == 1 ? img.width : img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
        return ctx.makeImage()
    }

    /// Your copyright in the bottom-right corner, white with a soft shadow, sized to the photo.
    static func watermark(_ img: CGImage, text: String, space: CGColorSpace) -> CGImage? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let size = max(12, CGFloat(min(img.width, img.height)) * 0.028)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pad = size * 0.9
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.25, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.textPosition = CGPoint(x: CGFloat(img.width) - bounds.width - pad, y: pad)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    // MARK: Share
    /// The Share button: quick JPEGs (2048 px) made in the background, then the Share menu (AirDrop, Mail, Messages…).
    func share(_ ps: [Photo], from view: NSView?) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Loupe Photos Share/" + UUID().uuidString.prefix(8))
        var s = ExportSettings(id: "share", name: "Share", quality: 0.85, size: .longEdge, sizeValue: 2048, sharpen: true)
        s.reveal = false
        Library.shared.status = "Getting \(ps.count.formatted()) photo\(ps.count == 1 ? "" : "s") ready to share…"
        export(Array(ps.prefix(200)), s, into: tmp, quiet: true) { urls in
            Library.shared.status = ""
            guard !urls.isEmpty, let v = view ?? NSApp.keyWindow?.contentView else { return }
            let picker = NSSharingServicePicker(items: urls)
            let r = CGRect(x: v.bounds.maxX - 60, y: v.bounds.maxY - 10, width: 1, height: 1)
            picker.show(relativeTo: r, of: v, preferredEdge: .minY)
        }
    }
}

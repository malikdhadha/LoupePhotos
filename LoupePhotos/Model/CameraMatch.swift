import AppKit
import simd
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Camera Match: makes Apple's neutral RAW rendering look like the camera's own JPEG (what the LCD showed).
/// A colour table (3D LUT) is fitted from the RAW's render to the JPEG stored inside it.
///
/// This file currently holds the fitting maths and a TEST (Test ▸ Camera Match Test): for every RAW in
/// Documents/RAW it writes comparison pictures and numbers to Documents/RAW/Camera Match test. It changes nothing in the library.
struct CameraLUT {
    static let n = 17
    /// n³ RGB entries, red fastest (Core Image's colour-cube order), values 0–1, sRGB-encoded.
    var table: [SIMD3<Float>]

    /// Fits a table that turns `src` colours into `dst` colours (both sRGB 0–1, same pixels).
    static func fit(_ src: [SIMD3<Float>], _ dst: [SIMD3<Float>]) -> CameraLUT {
        // 1. a tone curve per channel (most of a picture style is contrast and brightness)
        let bins = 64
        var curves = [[Float]](repeating: [Float](repeating: 0, count: bins), count: 3)
        for c in 0..<3 {
            var sum = [Float](repeating: 0, count: bins), cnt = [Float](repeating: 0, count: bins)
            for i in src.indices { let b = min(bins - 1, Int(src[i][c] * Float(bins))); sum[b] += dst[i][c]; cnt[b] += 1 }
            var curve = [Float](repeating: -1, count: bins)
            for b in 0..<bins where cnt[b] >= 3 { curve[b] = sum[b] / cnt[b] }
            // fill gaps by straight lines (ends: towards 0 and 1)
            let known = (0..<bins).filter { curve[$0] >= 0 }
            if known.isEmpty { for b in 0..<bins { curve[b] = (Float(b) + 0.5) / Float(bins) } }
            else {
                let first = known.first!, last = known.last!
                for b in 0..<first { let t = Float(b + 1) / Float(first + 1); curve[b] = curve[first] * t }
                for b in (last + 1)..<bins { let t = Float(b - last) / Float(bins - last); curve[b] = curve[last] + (1 - curve[last]) * t }
                for k in 0..<(known.count - 1) {
                    let a = known[k], z = known[k + 1]
                    if z > a + 1 { for b in (a + 1)..<z { let t = Float(b - a) / Float(z - a); curve[b] = curve[a] + (curve[z] - curve[a]) * t } }
                }
            }
            // never going down: neighbouring levels that disagree are averaged together, weighted by how many
            // pixels back them (taking a running maximum let one stray bright level flatten a whole low-contrast photo)
            var blocks: [(v: Float, w: Float, n: Int)] = []
            for b in 0..<bins {
                blocks.append((curve[b], max(cnt[b], 0.5), 1))
                while blocks.count > 1, blocks[blocks.count - 2].v > blocks[blocks.count - 1].v {
                    let y = blocks.removeLast(), x = blocks.removeLast()
                    blocks.append(((x.v * x.w + y.v * y.w) / (x.w + y.w), x.w + y.w, x.n + y.n))
                }
            }
            var mono: [Float] = []
            for bl in blocks { mono += [Float](repeating: bl.v, count: bl.n) }
            var sm = mono
            for b in 0..<bins { let lo = max(0, b - 2), hi = min(bins - 1, b + 2); sm[b] = mono[lo...hi].reduce(0, +) / Float(hi - lo + 1) }
            curves[c] = sm
        }
        let cv = curves
        func curve(_ v: SIMD3<Float>) -> SIMD3<Float> {
            var o = SIMD3<Float>()
            for c in 0..<3 {
                let x = min(max(v[c], 0), 1) * Float(bins) - 0.5
                let i = Int(max(0, min(Float(bins - 2), floor(x)))), t = min(max(x - Float(i), 0), 1)
                o[c] = cv[c][i] + (cv[c][i + 1] - cv[c][i]) * t
            }
            return o
        }
        // 2. what's left (colour: saturation and hue shifts), smoothly over the colour cube
        let curved = src.map(curve)
        let n = CameraLUT.n, sigma: Float = 0.075, inv = 1 / (2 * sigma * sigma)
        // each slice of the cube is worked out on its own core, into its own part of one buffer
        let buf = UnsafeMutablePointer<SIMD3<Float>>.allocate(capacity: n * n * n)
        defer { buf.deallocate() }
        let resid = zip(curved, dst).map { $1 - $0 }
        DispatchQueue.concurrentPerform(iterations: n) { bz in
            for g in 0..<n { for r in 0..<n {
                let node = SIMD3<Float>(Float(r), Float(g), Float(bz)) / Float(n - 1)
                var ws: Float = 0, acc = SIMD3<Float>()
                for i in curved.indices {
                    let d = curved[i] - node, d2 = (d * d).sum()
                    if d2 > 9 * sigma * sigma { continue }
                    let w = exp(-d2 * inv); ws += w; acc += resid[i] * w
                }
                let delta = acc / (ws + 0.5)                 // little data nearby → little change
                buf[bz * n * n + g * n + r] = simd_clamp(curve(node) + delta, SIMD3(repeating: 0), SIMD3(repeating: 1))
            } }
        }
        return CameraLUT(table: Array(UnsafeBufferPointer(start: buf, count: n * n * n)))
    }

    func apply(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let n = CameraLUT.n, m = Float(n - 1)
        let p = simd_clamp(v, SIMD3(repeating: 0), SIMD3(repeating: 1)) * m
        let i0 = SIMD3<Int>(Int(min(p.x, m - 0.0001)), Int(min(p.y, m - 0.0001)), Int(min(p.z, m - 0.0001)))
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> { table[b * n * n + g * n + r] }
        let c00 = at(i0.x, i0.y, i0.z) * (1 - f.x) + at(i0.x + 1, i0.y, i0.z) * f.x
        let c10 = at(i0.x, i0.y + 1, i0.z) * (1 - f.x) + at(i0.x + 1, i0.y + 1, i0.z) * f.x
        let c01 = at(i0.x, i0.y, i0.z + 1) * (1 - f.x) + at(i0.x + 1, i0.y, i0.z + 1) * f.x
        let c11 = at(i0.x, i0.y + 1, i0.z + 1) * (1 - f.x) + at(i0.x + 1, i0.y + 1, i0.z + 1) * f.x
        let c0 = c00 * (1 - f.y) + c10 * f.y, c1 = c01 * (1 - f.y) + c11 * f.y
        return c0 * (1 - f.z) + c1 * f.z
    }
}

enum CameraMatchTest {
    struct Pic { var w: Int; var h: Int; var px: [SIMD3<Float>] }

    static func pixels(_ cg: CGImage, w: Int, h: Int) -> Pic? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let d = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = d.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out = [SIMD3<Float>](); out.reserveCapacity(w * h)
        for i in 0..<(w * h) { out.append(SIMD3(Float(p[i * 4]), Float(p[i * 4 + 1]), Float(p[i * 4 + 2])) / 255) }
        return Pic(w: w, h: h, px: out)
    }
    static func image(_ pic: Pic) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: pic.w * pic.h * 4)
        for (i, v) in pic.px.enumerated() {
            let c = simd_clamp(v, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255
            bytes[i * 4] = UInt8(c.x.rounded()); bytes[i * 4 + 1] = UInt8(c.y.rounded()); bytes[i * 4 + 2] = UInt8(c.z.rounded())
        }
        guard let prov = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pic.w, height: pic.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pic.w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    /// Average difference, in 0–255 levels.
    static func error(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        var s: Float = 0
        for i in a.indices { s += simd_abs(a[i] - b[i]).sum() / 3 }
        return s / Float(max(1, a.count)) * 255
    }
    static func samples(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], max: Int) -> ([SIMD3<Float>], [SIMD3<Float>]) {
        var s: [SIMD3<Float>] = [], d: [SIMD3<Float>] = []
        let step = Swift.max(1, a.count / max)
        var i = 0
        while i < a.count {
            if a[i].max() < 0.985 && b[i].max() < 0.985 { s.append(a[i]); d.append(b[i]) }   // clipped: no information
            i += step
        }
        return (s, d)
    }

    struct Item { let url: URL; let camera: String; let ext: String; let ref: Pic; let raw: Pic }

    static func model(_ url: URL) -> String {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return "?" }
        return ((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String) ?? "?"
    }

    /// Test ▸ Camera Match Test
    static func run(_ lib: Library) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/RAW")
        let out = dir.appendingPathComponent("Camera Match test")
        lib.status = "Camera Match test: reading the RAW files…"
        DispatchQueue.global(qos: .userInitiated).async {
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let files = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                .filter { ["nef", "dng"].contains($0.pathExtension.lowercased()) && !$0.path.contains("Camera Match test") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var report = "Camera Match test — \(Date())\nError = average difference from the camera's / Lightroom's JPEG, in levels (0–255). Lower is closer.\n\n"
            var items: [Item] = []
            var decoders: [String: String] = [:]
            for (k, url) in files.enumerated() {
                autoreleasepool {
                    guard let refCG = Embedded.image(url, max: 400, minLong: 300) else { report += "no usable embedded JPEG: \(url.lastPathComponent)\n"; return }
                    let src = DevelopEngine.Source(url: url, isRaw: true)
                    guard let rawCG = DevelopEngine.shared.render(src, Recipe(), maxPixel: 400) else { report += "RAW could not be developed: \(url.lastPathComponent)\n"; return }
                    let w = refCG.width, h = refCG.height
                    let ra = Double(rawCG.width) / Double(rawCG.height), pa = Double(w) / Double(h)
                    if abs(ra - pa) / pa > 0.02 { report += "preview is a different shape (cropped or turned in Lightroom), skipped: \(url.lastPathComponent)\n"; return }
                    guard let ref = pixels(refCG, w: w, h: h), let raw = pixels(rawCG, w: w, h: h) else { return }
                    let cam = model(url)
                    if decoders[cam] == nil, let f = CIRAWFilter(imageURL: url) { decoders[cam] = f.supportedDecoderVersions.map(\.rawValue).joined(separator: ", ") }
                    items.append(Item(url: url, camera: cam, ext: url.pathExtension.lowercased(), ref: ref, raw: raw))
                }
                if k % 10 == 0 { DispatchQueue.main.async { lib.status = "Camera Match test: \(k + 1) of \(files.count)…" } }
            }
            report += "RAW engine versions each camera supports here:\n" + decoders.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n"

            // per camera: a profile learned from half its NEFs, checked on the other half and on its DNGs
            let cameras = Set(items.map(\.camera)).sorted()
            var profiles: [String: CameraLUT] = [:]
            for cam in cameras {
                let nefs = items.filter { $0.camera == cam && $0.ext == "nef" }
                let train = nefs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                guard !train.isEmpty else { continue }
                var s: [SIMD3<Float>] = [], d: [SIMD3<Float>] = []
                for it in train { let (a, b) = samples(it.raw.px, it.ref.px, max: 2500); s += a; d += b }
                profiles[cam] = CameraLUT.fit(s, d)
            }
            var rows: [(String, String, String, Float, Float, Float?)] = []
            for (k, it) in items.enumerated() {
                autoreleasepool {
                    let (s, d) = samples(it.raw.px, it.ref.px, max: 8000)
                    let own = CameraLUT.fit(s, d)
                    let matched = it.raw.px.map(own.apply)
                    let prof = profiles[it.camera].map { p in it.raw.px.map(p.apply) }
                    let e0 = error(it.raw.px, it.ref.px), e1 = error(matched, it.ref.px), e2 = prof.map { error($0, it.ref.px) }
                    rows.append((it.camera, it.ext, it.url.lastPathComponent, e0, e1, e2))
                    // comparison picture: camera JPEG | Apple's render | Camera Match (this photo) | camera profile
                    var panels = [it.ref, it.raw, Pic(w: it.ref.w, h: it.ref.h, px: matched)]
                    if let prof { panels.append(Pic(w: it.ref.w, h: it.ref.h, px: prof)) }
                    let W = panels.reduce(0) { $0 + $1.w } + 8 * (panels.count - 1), H = it.ref.h
                    if let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.setFillColor(gray: 0.15, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                        var x = 0
                        for p in panels { if let im = image(p) { ctx.draw(im, in: CGRect(x: x, y: 0, width: p.w, height: p.h)) }; x += p.w + 8 }
                        if let cg = ctx.makeImage() {
                            let name = "\(it.camera.replacingOccurrences(of: " ", with: "_"))-\(it.ext)-\(it.url.deletingPathExtension().lastPathComponent).jpg"
                            if let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                                CGImageDestinationFinalize(dest)
                            }
                        }
                    }
                }
                if k % 10 == 0 { DispatchQueue.main.async { lib.status = "Camera Match test: comparing \(k + 1) of \(items.count)…" } }
            }
            // summary
            func f1(_ v: Float) -> String { v.isNaN ? "–" : String(format: "%.1f", v) }
            report += "camera\ttype\tApple\tmatch\tcamera\n"
            for cam in cameras {
                for ext in ["nef", "dng"] {
                    let r = rows.filter { $0.0 == cam && $0.1 == ext }
                    guard !r.isEmpty else { continue }
                    let a = r.map(\.3).reduce(0, +) / Float(r.count), b = r.map(\.4).reduce(0, +) / Float(r.count)
                    let cs = r.compactMap(\.5), c = cs.isEmpty ? Float.nan : cs.reduce(0, +) / Float(cs.count)
                    report += "\(cam)\t\(ext)\t\(f1(a))\t\(f1(b))\t\(f1(c))\t(average of \(r.count))\n"
                }
            }
            report += "\nEach file:\n"
            for r in rows { report += "\(r.0)\t\(r.1)\t\(f1(r.3))\t\(f1(r.4))\t\(f1(r.5 ?? .nan))\t\(r.2)\n" }
            report += "\nColumns: Apple = Apple's RAW render as is · match = Camera Match fitted to that photo · camera = profile learned from half of that camera's NEFs (the other half and all DNGs are a fair test).\n"
            try? report.write(to: out.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
            DispatchQueue.main.async { lib.status = "Camera Match test finished — see Documents/RAW/Camera Match test." }
        }
    }
}

// MARK: - Camera Match in the app

/// Which starting look a RAW is developed from (Develop ▸ Profile).
enum RawProfile: String, CaseIterable, Identifiable {
    case match, camera, neutral
    var id: String { rawValue }
    var title: String {
        switch self {
        case .match: return "Camera Match (LCD)"
        case .camera: return "Camera Standard"
        case .neutral: return "Apple Neutral"
        }
    }
    static var defaultChoice: RawProfile { RawProfile(rawValue: UserDefaults.standard.string(forKey: "develop.profile") ?? "") ?? .match }
}

/// The colour tables: one per RAW (fitted to the JPEG the camera stored in it — what the LCD showed) and one per
/// camera (learned from many of its photos, for files whose own JPEG can't be used, like DNGs edited in Lightroom).
/// Kept as small files in the library's "Camera Match" folder. Safe from any thread.
final class CameraMatchStore: @unchecked Sendable {
    static let shared = CameraMatchStore()
    enum Status { case unknown, matched, noReference }
    private let lock = NSLock()
    private var photos: [Int: CameraLUT?] = [:]              // nil inside = checked, no usable reference
    private var cameras: [String: CameraLUT?] = [:]
    private var cubes: [String: Data] = [:]                  // ready for Core Image, by key

    var folder: URL { Library.shared.dbURL.deletingLastPathComponent().appendingPathComponent("Camera Match", isDirectory: true) }
    private func photoFile(_ id: Int) -> URL { folder.appendingPathComponent("\(id).lut") }
    private func cameraFile(_ model: String) -> URL {
        folder.appendingPathComponent("camera-" + model.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_") + ".lut")
    }

    // MARK: files (17³ × RGB as 16-bit numbers; an empty file means "checked, nothing usable")
    private static func encode(_ l: CameraLUT) -> Data {
        var d = Data(capacity: l.table.count * 6)
        for v in l.table { for c in 0..<3 { var x = UInt16(max(0, min(65535, (v[c] * 65535).rounded()))).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } } }
        return d
    }
    private static func decode(_ d: Data) -> CameraLUT? {
        let n = CameraLUT.n * CameraLUT.n * CameraLUT.n
        guard d.count == n * 6 else { return nil }
        var t = [SIMD3<Float>](repeating: .zero, count: n)
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let r = b.loadUnaligned(fromByteOffset: i * 6, as: UInt16.self).littleEndian
                let g = b.loadUnaligned(fromByteOffset: i * 6 + 2, as: UInt16.self).littleEndian
                let bl = b.loadUnaligned(fromByteOffset: i * 6 + 4, as: UInt16.self).littleEndian
                t[i] = SIMD3(Float(r), Float(g), Float(bl)) / 65535
            }
        }
        return CameraLUT(table: t)
    }

    func status(_ id: Int) -> Status {
        lock.lock(); let c = photos[id]; lock.unlock()
        if let c { return c == nil ? .noReference : .matched }
        guard let d = try? Data(contentsOf: photoFile(id)) else { return .unknown }
        let l = d.isEmpty ? nil : Self.decode(d)
        lock.lock(); photos[id] = .some(l); lock.unlock()
        return l == nil ? .noReference : .matched
    }
    func photoLUT(_ id: Int) -> CameraLUT? {
        guard status(id) == .matched else { return nil }
        lock.lock(); defer { lock.unlock() }
        return photos[id] ?? nil
    }
    func cameraLUT(_ model: String) -> CameraLUT? {
        guard !model.isEmpty else { return nil }
        lock.lock(); let c = cameras[model]; lock.unlock()
        if let c { return c }
        let l = (try? Data(contentsOf: cameraFile(model))).flatMap(Self.decode)
        lock.lock(); cameras[model] = .some(l); lock.unlock()
        return l
    }
    /// The table for a RAW and the profile chosen for it (nil = Apple's own look).
    func lut(id: Int?, model: String, profile: RawProfile) -> (key: String, lut: CameraLUT)? {
        switch profile {
        case .neutral: return nil
        case .camera: return cameraLUT(model).map { ("c" + model, $0) }
        case .match:
            if let id, let l = photoLUT(id) { return ("p\(id)", l) }
            return cameraLUT(model).map { ("c" + model, $0) }
        }
    }
    /// Core Image's colour cube data (RGBA floats), made once per table.
    func cube(_ key: String, _ l: CameraLUT) -> Data {
        lock.lock(); if let d = cubes[key] { lock.unlock(); return d }; lock.unlock()
        var f = [Float](); f.reserveCapacity(l.table.count * 4)
        for v in l.table { f += [v.x, v.y, v.z, 1] }
        let d = f.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); if cubes.count > 64 { cubes.removeAll() }; cubes[key] = d; lock.unlock()
        return d
    }

    // MARK: fitting
    struct Fit { let lut: CameraLUT; let samples: ([SIMD3<Float>], [SIMD3<Float>]) }
    /// Compares Apple's neutral render of a RAW with the JPEG inside it. Nil when that JPEG can't be trusted as
    /// "what the camera showed": missing, a different shape (cropped or turned in Lightroom), much less colourful
    /// (made black & white), or so different that no colour table explains it (edited).
    static func fit(_ url: URL) -> Fit? {
        guard let refCG = Embedded.image(url, max: 400, minLong: 300) else { return nil }
        var r = Recipe(); r.s["profile"] = RawProfile.neutral.rawValue
        guard let rawCG = DevelopEngine.shared.render(DevelopEngine.Source(url: url, isRaw: true), r, maxPixel: 400) else { return nil }
        let w = refCG.width, h = refCG.height
        let ra = Double(rawCG.width) / Double(rawCG.height), pa = Double(w) / Double(h)
        guard abs(ra - pa) / pa < 0.02,
              let ref = CameraMatchTest.pixels(refCG, w: w, h: h), let raw = CameraMatchTest.pixels(rawCG, w: w, h: h) else { return nil }
        func chroma(_ px: [SIMD3<Float>]) -> Float { px.reduce(0) { $0 + ($1.max() - $1.min()) } / Float(max(1, px.count)) }
        let cr = chroma(raw.px)
        if cr > 0.04 && chroma(ref.px) < cr * 0.4 { return nil }               // black & white (or nearly) in Lightroom
        let s = CameraMatchTest.samples(raw.px, ref.px, max: 8000)
        guard s.0.count > 500 else { return nil }
        let lut = CameraLUT.fit(s.0, s.1)
        let err = CameraMatchTest.error(raw.px.map(lut.apply), ref.px)
        guard err < 10 else { return nil }                                       // the JPEG isn't this RAW as shot
        return Fit(lut: lut, samples: CameraMatchTest.samples(raw.px, ref.px, max: 2500))
    }
    /// Fits one RAW (if not done before) and remembers the answer. Returns its samples when it matched.
    @discardableResult
    func ensure(id: Int, url: URL) -> Fit? {
        guard status(id) == .unknown else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = Self.fit(url)
        try? (f.map { Self.encode($0.lut) } ?? Data()).write(to: photoFile(id), options: .atomic)
        lock.lock(); photos[id] = .some(f?.lut); lock.unlock()
        return f
    }
    func saveCamera(_ model: String, _ l: CameraLUT) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Self.encode(l).write(to: cameraFile(model), options: .atomic)
        lock.lock(); cameras[model] = .some(l); cubes = cubes.filter { !$0.key.hasPrefix("c") }; lock.unlock()
    }
}

/// Matches new RAWs in the background (Settings ▸ Develop ▸ "Camera Match new RAW files"), and learns each
/// camera's profile from the ones that matched. Waits while you're scrolling or thumbnails are being made.
final class CameraMatchJob: @unchecked Sendable {
    static let shared = CameraMatchJob()
    private let q = DispatchQueue(label: "camera.match", qos: .utility)
    private var running = false
    private let lock = NSLock()
    private var held = false, paused = false
    func hold(_ on: Bool) { lock.lock(); held = on; lock.unlock() }
    private var waiting: Bool { lock.lock(); defer { lock.unlock() }; return held || paused }

    func run(_ all: [Photo]) {
        guard UserDefaults.standard.object(forKey: "develop.matchOnImport") as? Bool ?? true else { return }
        let todo = all.filter { $0.isRaw && !$0.missing && CameraMatchStore.shared.status($0.id) == .unknown }
            .map { (id: $0.id, url: $0.url, model: $0.camera) }
        guard !todo.isEmpty, !running else { return }
        running = true
        q.async { [self] in
            var learned: [String: ([SIMD3<Float>], [SIMD3<Float>], Int)] = [:]
            for (i, t) in todo.enumerated() {
                while waiting { Thread.sleep(forTimeInterval: 0.5) }
                Activity.shared.report("cameramatch", "Matching camera look", done: i, total: todo.count) { [weak self] p in
                    guard let self else { return }; self.lock.lock(); self.paused = p; self.lock.unlock()
                }
                autoreleasepool {
                    if let f = CameraMatchStore.shared.ensure(id: t.id, url: t.url), !t.model.isEmpty {
                        var e = learned[t.model] ?? ([], [], 0)
                        if e.2 < 60 { e.0 += f.samples.0; e.1 += f.samples.1; e.2 += 1 }
                        learned[t.model] = e
                    }
                }
            }
            Activity.shared.finish("cameramatch")
            // each camera's own profile, from up to 60 of its photos (only made again when there's more to learn from)
            for (model, e) in learned where e.2 >= 3 {
                let had = UserDefaults.standard.integer(forKey: "cameramatch.n." + model)
                guard e.2 > had || CameraMatchStore.shared.cameraLUT(model) == nil else { continue }
                CameraMatchStore.shared.saveCamera(model, CameraLUT.fit(e.0, e.1))
                UserDefaults.standard.set(max(had, e.2), forKey: "cameramatch.n." + model)
            }
            DispatchQueue.main.async { self.running = false }
        }
    }
}

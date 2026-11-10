import AppKit
import CoreImage
import ImageIO
import Vision

// MARK: - The adjustments

/// One section of the Develop panel (Aperture called them "bricks").
enum Brick: String, CaseIterable, Identifiable {
    case raw, wb, exposure, enhance, hs, crop, sharpen, nr, vignette, bw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .raw: return "RAW Fine Tuning"
        case .wb: return "White Balance"
        case .exposure: return "Exposure"
        case .enhance: return "Enhance"
        case .hs: return "Highlights & Shadows"
        case .crop: return "Crop & Straighten"
        case .sharpen: return "Sharpen"
        case .nr: return "Noise Reduction"
        case .vignette: return "Vignette"
        case .bw: return "Black & White"
        }
    }
    var keys: [K] { K.allCases.filter { $0.brick == self } }
    /// Shown even before they're used (the others come from Add Adjustment).
    var standard: Bool { [.raw, .wb, .exposure, .enhance, .hs].contains(self) }
    var hasAuto: Bool { [.wb, .exposure, .enhance, .hs].contains(self) }
}

/// Every slider. Values are stored only once they've been changed; until then the default (or the camera's) applies.
enum K: String, CaseIterable, Identifiable {
    case boost, boostShadow, rawSharp, moire, lens
    case temp, tint
    case exposure, recovery, blackPoint, brightness
    case contrast, definition, saturation, vibrancy
    case highlights, shadows
    case angle, cropX, cropY, cropW, cropH
    case sharpen, sharpRadius
    case nrLum, nrColor
    case vignette, vigRadius
    case bwR, bwG, bwB
    var id: String { rawValue }

    var brick: Brick {
        switch self {
        case .boost, .boostShadow, .rawSharp, .moire, .lens: return .raw
        case .temp, .tint: return .wb
        case .exposure, .recovery, .blackPoint, .brightness: return .exposure
        case .contrast, .definition, .saturation, .vibrancy: return .enhance
        case .highlights, .shadows: return .hs
        case .angle, .cropX, .cropY, .cropW, .cropH: return .crop
        case .sharpen, .sharpRadius: return .sharpen
        case .nrLum, .nrColor: return .nr
        case .vignette, .vigRadius: return .vignette
        case .bwR, .bwG, .bwB: return .bw
        }
    }
    var label: String {
        switch self {
        case .boost: return "Boost"
        case .boostShadow: return "Shadow Boost"
        case .rawSharp: return "Sharpening"
        case .moire: return "Moiré"
        case .lens: return "Lens Correction"
        case .temp: return "Temperature"
        case .tint: return "Tint"
        case .exposure: return "Exposure"
        case .recovery: return "Recovery"
        case .blackPoint: return "Black Point"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .definition: return "Definition"
        case .saturation: return "Saturation"
        case .vibrancy: return "Vibrancy"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .angle: return "Straighten"
        case .cropX, .cropY, .cropW, .cropH: return "Crop"
        case .sharpen: return "Intensity"
        case .sharpRadius: return "Radius"
        case .nrLum: return "Luminance"
        case .nrColor: return "Colour"
        case .vignette: return "Intensity"
        case .vigRadius: return "Radius"
        case .bwR: return "Red"
        case .bwG: return "Green"
        case .bwB: return "Blue"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .boost, .rawSharp, .moire, .recovery, .definition, .highlights, .shadows, .sharpen, .nrLum, .nrColor: return 0...1
        case .boostShadow: return 0...2
        case .lens: return 0...1
        case .temp: return 2000...12000
        case .tint: return -150...150
        case .exposure: return -4...4
        case .blackPoint: return -0.5...1
        case .brightness, .contrast, .vibrancy, .vignette: return -1...1
        case .saturation, .vigRadius: return 0...2
        case .angle: return -45...45
        case .cropX, .cropY, .cropW, .cropH: return 0...1
        case .sharpRadius: return 0.5...4
        case .bwR, .bwG, .bwB: return -1...2
        }
    }
    var def: Double {
        switch self {
        case .boost: return 1
        case .boostShadow: return 1
        case .lens: return 1
        case .saturation: return 1
        case .cropW, .cropH: return 1
        case .sharpen: return 0.5
        case .sharpRadius: return 1.5
        case .nrLum: return 0.5
        case .nrColor: return 0.5
        case .vignette: return 0.5
        case .vigRadius: return 1
        case .bwR: return 0.3
        case .bwG: return 0.59
        case .bwB: return 0.11
        default: return 0
        }
    }
    var digits: Int { self == .temp || self == .tint ? 0 : self == .angle ? 1 : 2 }
}

/// A photo's adjustments: what Develop changed, nothing else. Stored in the catalog (raw["develop"]); the file is never touched.
struct Recipe: Equatable {
    var n: [String: Double] = [:]
    var s: [String: String] = [:]
    init() {}
    init?(_ any: Any?) {
        guard let d = any as? [String: Any] else { return nil }
        for (k, v) in d["n"] as? [String: Any] ?? [:] {
            if let x = v as? Double { n[k] = x } else if let x = v as? NSNumber { n[k] = x.doubleValue }
        }
        s = d["s"] as? [String: String] ?? [:]
    }
    var dict: [String: Any] { ["v": 1, "n": n, "s": s] }

    func has(_ k: K) -> Bool { n[k.rawValue] != nil }
    func v(_ k: K) -> Double { n[k.rawValue] ?? k.def }
    mutating func set(_ k: K, _ x: Double?) { n[k.rawValue] = x }
    func on(_ b: Brick) -> Bool { n["on." + b.rawValue] == 1 }
    mutating func setOn(_ b: Brick, _ on: Bool) { n["on." + b.rawValue] = on ? 1 : nil }
    /// Turns a section off and puts its sliders back.
    mutating func clear(_ b: Brick) {
        for k in b.keys { n[k.rawValue] = nil }
        setOn(b, false)
        if b == .exposure { curve = nil }
        if b == .crop { s["aspect"] = nil }
    }
    /// The RAW engine version the photo was edited with ("9", "8"…), so a macOS update never changes a finished photo.
    var decoder: String? { get { s["decoder"] } set { s["decoder"] = newValue } }
    var aspect: String { get { s["aspect"] ?? "Free" } set { s["aspect"] = newValue == "Free" ? nil : newValue } }
    /// Auto's tone curve (five points), part of Exposure.
    var curve: [CGPoint]? {
        get {
            guard let t = s["curve"] else { return nil }
            let pts = t.split(separator: ";").compactMap { pair -> CGPoint? in
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
            }
            return pts.count == 5 ? pts : nil
        }
        set { s["curve"] = newValue.map { $0.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: ";") } }
    }
    /// The crop, as fractions of the photo the right way up (before your own rotation), top-left origin.
    var crop: CGRect {
        get { CGRect(x: v(.cropX), y: v(.cropY), width: v(.cropW), height: v(.cropH)) }
        set { set(.cropX, newValue.minX); set(.cropY, newValue.minY); set(.cropW, newValue.width); set(.cropH, newValue.height) }
    }
    var isEdited: Bool { Brick.allCases.contains { on($0) } || s["profile"] != nil }
    var activeCrop: CGRect? {
        guard on(.crop) else { return nil }
        let c = crop
        return c.width < 0.999 || c.height < 0.999 ? c : nil
    }
}

/// The camera's own starting values for a RAW file, read when it's opened in Develop.
struct RawInfo {
    var versions: [String]
    var decoder: String
    var temp: Double, tint: Double
    var boost: Double, boostShadow: Double
    var sharp: Double?, moire: Double?, lens: Bool?
    var nrLum: Double?, nrColor: Double?
}

// MARK: - The engine

/// Draws a photo with its adjustments, with Apple's Core Image on the graphics chip (RAW files through Apple's RAW engine).
/// Used by Develop, and to make edited photos' thumbnails, previews and exports. Safe to call from any thread.
final class DevelopEngine: @unchecked Sendable {
    static let shared = DevelopEngine()
    let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false, .name: "Develop"])
    /// For measuring single colours (white balance), where the graphics chip's round trip would cost more than the work.
    private let tiny = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .useSoftwareRenderer: true])
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    struct Source: Sendable {
        let url: URL, isRaw: Bool
        /// For Camera Match: which photo (its own colour table) and camera (its learned profile).
        var id: Int? = nil, model = ""
        init(_ p: Photo) { url = p.url; isRaw = p.isRaw; id = p.id; model = p.camera }
        init(url: URL, isRaw: Bool, id: Int? = nil, model: String = "") { self.url = url; self.isRaw = isRaw; self.id = id; self.model = model }
    }

    // MARK: RAW engine versions
    static func number(_ raw: String) -> Double {
        let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Double(String(digits)) ?? 0
    }
    static func label(_ raw: String) -> String { number(raw) > 0 ? "RAW \(Int(number(raw)))" : raw }
    /// The version to use: the photo's own, else Settings ▸ Develop's choice, else the newest this Mac has.
    static func decoder(for f: CIRAWFilter, _ r: Recipe) -> CIRAWDecoderVersion {
        let sup = f.supportedDecoderVersions.filter { number($0.rawValue) > 0 }
        if let want = r.decoder, let v = sup.first(where: { $0.rawValue == want }) { return v }
        let pref = UserDefaults.standard.string(forKey: "develop.decoder") ?? "latest"
        if pref != "latest", let n = Double(pref), let v = sup.first(where: { number($0.rawValue) == n }) { return v }
        return sup.max { number($0.rawValue) < number($1.rawValue) } ?? f.decoderVersion
    }
    func rawInfo(_ src: Source, _ r: Recipe) -> RawInfo? {
        guard let f = CIRAWFilter(imageURL: src.url) else { return nil }
        f.decoderVersion = Self.decoder(for: f, r)
        let versions = f.supportedDecoderVersions.map(\.rawValue).filter { Self.number($0) > 0 }
        return RawInfo(versions: versions.sorted { Self.number($0) > Self.number($1) }, decoder: f.decoderVersion.rawValue,
                       temp: Double(f.neutralTemperature), tint: Double(f.neutralTint),
                       boost: Double(f.boostAmount), boostShadow: Double(f.boostShadowAmount),
                       sharp: f.isSharpnessSupported ? Double(f.sharpnessAmount) : nil,
                       moire: f.isMoireReductionSupported ? Double(f.moireReductionAmount) : nil,
                       lens: f.isLensCorrectionSupported ? f.isLensCorrectionEnabled : nil,
                       nrLum: f.isLuminanceNoiseReductionSupported ? Double(f.luminanceNoiseReductionAmount) : nil,
                       nrColor: f.isColorNoiseReductionSupported ? Double(f.colorNoiseReductionAmount) : nil)
    }
    /// What the RAW engine itself does: version, fine tuning, white balance, exposure and noise reduction.
    private func configure(_ f: CIRAWFilter, _ r: Recipe) {
        f.decoderVersion = Self.decoder(for: f, r)
        if r.on(.raw) {
            if r.has(.boost) { f.boostAmount = Float(r.v(.boost)) }
            if r.has(.boostShadow) { f.boostShadowAmount = Float(r.v(.boostShadow)) }
            if r.has(.rawSharp), f.isSharpnessSupported { f.sharpnessAmount = Float(r.v(.rawSharp)) }
            if r.has(.moire), f.isMoireReductionSupported { f.moireReductionAmount = Float(r.v(.moire)) }
            if r.has(.lens), f.isLensCorrectionSupported { f.isLensCorrectionEnabled = r.v(.lens) > 0.5 }
        }
        if r.on(.wb) {
            if r.has(.temp) { f.neutralTemperature = Float(r.v(.temp)) }
            if r.has(.tint) { f.neutralTint = Float(r.v(.tint)) }
        }
        if r.on(.exposure), r.v(.exposure) != 0 { f.exposure = Float(r.v(.exposure)) }
        if r.on(.nr) {
            if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = Float(r.v(.nrLum)) }
            if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = Float(r.v(.nrColor)) }
        }
    }

    // MARK: the starting image
    /// The long edge the output will have at full size (after the crop).
    private func outputLong(_ size: CGSize, _ r: Recipe, cropped: Bool) -> Double {
        if cropped, let c = r.activeCrop { return max(size.width * c.width, size.height * c.height) }
        return max(size.width, size.height)
    }
    /// A RAW file developed by Apple's RAW engine, scaled so the output is about `maxPixel` (nil = full size).
    func rawBase(_ src: Source, _ r: Recipe, maxPixel: Int?, cropped: Bool = true) -> (CIImage, Double)? {
        guard let f = CIRAWFilter(imageURL: src.url) else { return nil }
        configure(f, r)
        guard let full = f.outputImage?.extent, full.width > 0 else { return nil }
        var s = 1.0
        if let m = maxPixel { s = min(1, Double(m) / outputLong(full.size, r, cropped: cropped)) }
        if s < 0.999 { f.scaleFactor = Float(s) }
        guard let o = f.outputImage else { return nil }
        // the starting look: what the camera's LCD showed (Camera Match), the camera's learned profile, or Apple's own
        let prof = RawProfile(rawValue: r.s["profile"] ?? "") ?? RawProfile.defaultChoice
        if let (key, lut) = CameraMatchStore.shared.lut(id: src.id, model: src.model, profile: prof) {
            let out = o.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": CameraLUT.n, "inputCubeData": CameraMatchStore.shared.cube(key, lut),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
            return (out, s)
        }
        return (o, s)
    }
    /// A JPEG, HEIC, PNG or TIFF read at about `maxPixel` on its long edge (nil = full size), the right way up.
    func decode(_ src: Source, maxPixel: Int?) -> (CIImage, Double)? {
        guard let s = CGImageSourceCreateWithURL(src.url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let long = max(w, h, 1)
        if let m = maxPixel, m < long {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: m, kCGImageSourceShouldCacheImmediately: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return nil }
            return (CIImage(cgImage: cg), Double(max(cg.width, cg.height)) / Double(long))
        }
        guard let ci = CIImage(contentsOf: src.url, options: [.applyOrientationProperty: true]) else { return nil }
        return (ci, 1)
    }
    func base(_ src: Source, _ r: Recipe, maxPixel: Int?) -> (CIImage, Double)? {
        if src.isRaw { return rawBase(src, r, maxPixel: maxPixel) }
        let need = maxPixel.map { m -> Int in
            guard let c = r.activeCrop else { return m }
            return Int((Double(m) / max(0.05, max(c.width, c.height))).rounded(.up))
        }
        return decode(src, maxPixel: need)
    }

    // MARK: the adjustments
    /// Exposure and white balance for files the RAW engine didn't develop.
    private func preAdjust(_ im: CIImage, _ r: Recipe, isRaw: Bool, wb: Bool = true) -> CIImage {
        guard !isRaw else { return im }
        var im = im
        if r.on(.exposure), r.v(.exposure) != 0 { im = im.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.v(.exposure)]) }
        if wb, r.on(.wb), r.has(.temp) || r.has(.tint) {
            let t = r.has(.temp) ? r.v(.temp) : 6500
            im = im.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: t, y: r.v(.tint)), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        return im
    }

    /// Everything after the starting image, in Aperture's order. `scale` is how small the image is compared with full size.
    func adjust(_ input: CIImage, _ r: Recipe, isRaw: Bool, scale: Double, skipCrop: Bool) -> CIImage {
        let E0 = input.extent
        let long = max(E0.width, E0.height)
        var im = preAdjust(input, r, isRaw: isRaw)
        /// Filters that blur look at pixels past the edge: let them see the edge repeated, then trim back.
        func edged(_ f: (CIImage) -> CIImage) { im = f(im.clampedToExtent()).cropped(to: E0) }

        if r.on(.exposure) {
            let rec = r.v(.recovery)
            if rec > 0 { edged { $0.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 - 0.8 * rec, "inputShadowAmount": 0]) } }
            let bp = r.v(.blackPoint)
            if bp != 0 {
                let b = (bp < 0 ? -1 : 1) * pow(abs(bp) * 0.25, 2.2)
                let k = 1 / (1 - b)
                im = im.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                                                                     "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputBiasVector": CIVector(x: -b * k, y: -b * k, z: -b * k, w: 0)])
            }
            let br = r.v(.brightness)
            if br != 0 { im = clamp(im, max: 64).applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -br * 0.8)]) }
            if let c = r.curve {
                im = clamp(im, max: 1)
                var p: [String: Any] = [:]
                for (i, pt) in c.enumerated() { p["inputPoint\(i)"] = CIVector(x: pt.x, y: pt.y) }
                im = im.applyingFilter("CIToneCurve", parameters: p)
            }
        }
        if r.on(.enhance) {
            let c = r.v(.contrast)
            if c != 0 {
                im = clamp(im, max: 1).applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25 - 0.09 * c),
                                                                   "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.09 * c),
                                                                   "inputPoint4": CIVector(x: 1, y: 1)])
            }
            let d = r.v(.definition)
            if d > 0 { edged { $0.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.02 * long, kCIInputIntensityKey: d * 0.6]) } }
            let sat = r.v(.saturation)
            if sat != 1 { im = im.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: sat]) }
            let vib = r.v(.vibrancy)
            if vib != 0 { im = im.applyingFilter("CIVibrance", parameters: ["inputAmount": vib]) }
        }
        if r.on(.hs) {
            let h = r.v(.highlights), s = r.v(.shadows)
            if h > 0 || s > 0 { edged { $0.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 - h, "inputShadowAmount": s]) } }
        }
        if !isRaw, r.on(.nr), r.v(.nrLum) > 0 {
            edged { $0.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.04 * r.v(.nrLum), "inputSharpness": 0.4]) }
        }
        // straighten (turned and enlarged to fill the frame, so no corners show) and crop
        var E = E0
        if r.on(.crop) {
            let a = r.v(.angle) * .pi / 180
            if a != 0 {
                let w = E0.width, h = E0.height, ca = abs(cos(a)), sa = abs(sin(a))
                let s = max((w * ca + h * sa) / w, (w * sa + h * ca) / h)
                let t = CGAffineTransform(translationX: E0.midX, y: E0.midY).rotated(by: -a).scaledBy(x: s, y: s).translatedBy(x: -E0.midX, y: -E0.midY)
                im = im.clampedToExtent().transformed(by: t).cropped(to: E0)
            }
            if !skipCrop, let c = r.activeCrop {
                E = CGRect(x: E0.minX + c.minX * E0.width, y: E0.minY + (1 - c.maxY) * E0.height, width: c.width * E0.width, height: c.height * E0.height)
                im = im.cropped(to: E)
            }
        }
        if r.on(.sharpen) {
            let rad = r.v(.sharpRadius) * max(0.3, scale)
            let crop = E
            im = im.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: r.v(.sharpen), kCIInputRadiusKey: rad]).cropped(to: crop)
        }
        if r.on(.bw) {
            var w = [r.v(.bwR), r.v(.bwG), r.v(.bwB)]
            let sum = w.reduce(0, +)
            if abs(sum) > 0.01 { w = w.map { $0 / sum } }
            let v = CIVector(x: w[0], y: w[1], z: w[2], w: 0)
            im = im.applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": v, "inputBVector": v])
        }
        if r.on(.vignette) {
            let i = r.v(.vignette), rad = 0.5 * hypot(E.width, E.height) * (0.35 + 0.45 * r.v(.vigRadius))
            if i != 0 {
                im = im.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: E.midX, y: E.midY), kCIInputRadiusKey: rad,
                                                                        kCIInputIntensityKey: i, "inputFalloff": 0.6])
            }
        }
        return im.cropped(to: E)
    }

    /// Keeps colours in range before curves (a curve bends wildly outside 0–1: bright skies turned cyan).
    private func clamp(_ im: CIImage, max: Double) -> CIImage {
        im.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: max, y: max, z: max, w: 1)])
    }

    // MARK: making pictures
    private func inner(_ r: CGRect) -> CGRect {
        let x0 = ceil(r.minX - 0.001), y0 = ceil(r.minY - 0.001), x1 = floor(r.maxX + 0.001), y1 = floor(r.maxY + 0.001)
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }
    func cg(_ im: CIImage) -> CGImage? { ctx.createCGImage(im, from: inner(im.extent), format: .RGBA8, colorSpace: space) }

    /// A photo with its adjustments at about `maxPixel` on the long edge (nil = full size), unturned by your rotation —
    /// for thumbnails, previews and exports.
    func render(_ src: Source, _ r: Recipe, maxPixel: Int?) -> CGImage? {
        guard let (im, s) = base(src, r, maxPixel: maxPixel) else { return nil }
        var out = adjust(im, r, isRaw: src.isRaw, scale: s, skipCrop: false)
        if let m = maxPixel {
            let l = max(out.extent.width, out.extent.height)
            if l > Double(m) * 1.02 { out = out.transformed(by: CGAffineTransform(scaleX: Double(m) / l, y: Double(m) / l)) }
        }
        return cg(out)
    }
    /// For the Develop page: turned by your rotation, uncropped while cropping. `base` is the image already read (not RAW).
    func display(_ src: Source, _ r: Recipe, base: (CIImage, Double)?, maxPixel: Int, skipCrop: Bool, rot: Int) -> CGImage? {
        let b: (CIImage, Double)?
        if src.isRaw { b = rawBase(src, r, maxPixel: maxPixel, cropped: !skipCrop) } else { b = base ?? decode(src, maxPixel: maxPixel) }
        guard let (im, s) = b else { return nil }
        var out = adjust(im, r, isRaw: src.isRaw, scale: s, skipCrop: skipCrop)
        let q = ((rot % 4) + 4) % 4
        if q != 0 {
            out = out.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(q) * .pi / 2))
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        }
        return cg(out)
    }

    // MARK: Auto
    struct AutoValues { var curve: [CGPoint]?; var vibrancy: Double?; var shadows: Double?; var highlights: Double?; var wb: (Double, Double)? }
    /// Apple's own Auto Enhance, read as slider values (so they can be changed afterwards).
    func autoValues(_ src: Source, _ r: Recipe, base: (CIImage, Double)?) -> AutoValues {
        var out = AutoValues()
        let b = src.isRaw ? rawBase(src, r, maxPixel: 1200, cropped: false) : base
        guard let (im0, _) = b else { return out }
        let im = preAdjust(im0, r, isRaw: src.isRaw)
        for f in im.autoAdjustmentFilters(options: [.redEye: false]) {
            switch f.name {
            case "CIToneCurve":
                let pts = (0..<5).compactMap { (f.value(forKey: "inputPoint\($0)") as? CIVector).map { CGPoint(x: $0.x, y: $0.y) } }
                if pts.count == 5 { out.curve = pts }
            case "CIVibrance": out.vibrancy = (f.value(forKey: "inputAmount") as? NSNumber)?.doubleValue
            case "CIHighlightShadowAdjust":
                out.shadows = (f.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue
                out.highlights = (f.value(forKey: "inputHighlightAmount") as? NSNumber).map { 1 - $0.doubleValue }
            default: break
            }
        }
        return out
    }

    // MARK: white balance from a colour
    /// The average colour (linear) at a point of the photo (fractions, top-left origin, before the crop) or of the whole photo.
    func sample(_ src: Source, _ r: Recipe, base: (CIImage, Double)?, at pt: CGPoint?, applyWB: Bool) -> SIMD3<Double>? {
        let b = src.isRaw ? rawBase(src, r, maxPixel: 1600, cropped: false) : base
        guard let (im0, _) = b else { return nil }
        let im = preAdjust(im0, r, isRaw: src.isRaw, wb: applyWB)
        let E = im.extent
        var rect = E
        if let pt {
            let side = max(4, 0.012 * max(E.width, E.height))
            rect = CGRect(x: E.minX + pt.x * E.width - side / 2, y: E.minY + (1 - pt.y) * E.height - side / 2, width: side, height: side).intersection(E)
            guard !rect.isNull, rect.width >= 1 else { return nil }
        }
        let avg = im.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: avg.extent.minX, y: avg.extent.minY, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return SIMD3(Double(px[0]), Double(px[1]), Double(px[2]))
    }
    private func chroma(_ c: SIMD3<Double>) -> Double {
        let m = (c.x + c.y + c.z) / 3
        guard m > 1e-5 else { return 0 }
        let d = c - SIMD3(repeating: m)
        return ((d * d).sum() / 3).squareRoot() / m
    }
    /// What Core Image's temperature-and-tint does to one colour.
    private func tt(_ c: SIMD3<Double>, _ temp: Double, _ tint: Double) -> SIMD3<Double> {
        let col = CIColor(red: CGFloat(max(0, c.x)), green: CGFloat(max(0, c.y)), blue: CGFloat(max(0, c.z)), alpha: 1, colorSpace: linear) ?? CIColor(red: 0.5, green: 0.5, blue: 0.5)
        let im = CIImage(color: col).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: temp, y: tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        var px = [Float](repeating: 0, count: 4)
        tiny.render(im, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return SIMD3(Double(px[0]), Double(px[1]), Double(px[2]))
    }
    /// The temperature and tint that turn this colour grey (searched in mireds, the way colour temperature behaves).
    private func neutralizing(_ c: SIMD3<Double>) -> (temp: Double, tint: Double) {
        var mired = 1e6 / 6500, tint = 0.0, sm = 40.0, st = 20.0
        var best = chroma(tt(c, 1e6 / mired, tint))
        var n = 0
        while (sm > 0.5 || st > 0.25) && n < 400 {
            var improved = false
            for (dm, dt) in [(sm, 0.0), (-sm, 0.0), (0.0, st), (0.0, -st)] {
                let m2 = min(500, max(70, mired + dm)), t2 = min(150, max(-150, tint + dt))
                n += 1
                let c2 = chroma(tt(c, 1e6 / m2, t2))
                if c2 < best - 1e-9 { best = c2; mired = m2; tint = t2; improved = true }
            }
            if !improved { sm /= 2; st /= 2 }
        }
        return (1e6 / mired, tint)
    }
    /// White balance that makes the point (or, with nil, the photo as a whole) neutral.
    func whiteBalance(_ src: Source, _ r: Recipe, base: (CIImage, Double)?, at pt: CGPoint?, info: RawInfo?, limit: Double? = nil) -> (temp: Double, tint: Double)? {
        guard let wb = measureWB(src, r, base: base, at: pt, info: info) else { return nil }
        guard let limit else { return wb }
        // at most `limit` mireds warmer or cooler than where it started (and a matching limit on tint)
        let t0 = r.has(.temp) ? r.v(.temp) : (src.isRaw ? (info?.temp ?? 5500) : 6500)
        let ti0 = r.has(.tint) ? r.v(.tint) : (src.isRaw ? (info?.tint ?? 0) : 0)
        let m = min(1e6 / t0 + limit, max(1e6 / t0 - limit, 1e6 / wb.temp))
        return (1e6 / m, min(ti0 + limit / 2, max(ti0 - limit / 2, wb.tint)))
    }
    private func measureWB(_ src: Source, _ r: Recipe, base: (CIImage, Double)?, at pt: CGPoint?, info: RawInfo?) -> (temp: Double, tint: Double)? {
        if !src.isRaw {
            guard let c = sample(src, r, base: base, at: pt, applyWB: false) else { return nil }
            return neutralizing(c)
        }
        // RAW: measure as the photo is now, estimate the change, and check it (the tint scale can run the other way)
        var r = r
        r.setOn(.wb, true)
        var temp = r.has(.temp) ? r.v(.temp) : (info?.temp ?? 5500)
        var tint = r.has(.tint) ? r.v(.tint) : (info?.tint ?? 0)
        var sign = 1.0
        for pass in 0..<3 {
            r.set(.temp, temp); r.set(.tint, tint)
            guard let c = sample(src, r, base: nil, at: pt, applyWB: true) else { return nil }
            let before = chroma(c)
            if before < 0.004 { break }
            let (t2, ti2) = neutralizing(c)
            var nt = 1e6 / (1e6 / temp + (1e6 / t2 - 1e6 / 6500)), nti = tint + sign * ti2
            nt = min(50000, max(2000, nt)); nti = min(150, max(-150, nti))
            if pass == 0 {
                // check the direction of tint once
                var test = r; test.set(.temp, nt); test.set(.tint, nti)
                if let c2 = sample(src, test, base: nil, at: pt, applyWB: true), chroma(c2) > before * 0.85, abs(ti2) > 2 {
                    sign = -1; nti = min(150, max(-150, tint - ti2))
                }
            }
            temp = nt; tint = nti
        }
        return (temp, tint)
    }
}

// MARK: - Where adjustments are kept

/// Every photo's adjustments, readable from any thread (thumbnails and previews are made in the background),
/// and the job of remaking a photo's thumbnail and preview after it's been edited.
@Observable
final class DevelopStore: @unchecked Sendable {
    static let shared = DevelopStore()
    /// Goes up for a photo each time its thumbnail and preview have been remade (views showing it reload).
    var stamps: [Int: Int] = [:]
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var recipes: [Int: Recipe] = [:]
    @ObservationIgnored private var pending = Set<Int>()
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.4, min: 2, max: 4); q.qualityOfService = .userInitiated; return q }()

    func load(_ photos: [Photo]) {
        var m: [Int: Recipe] = [:]
        for p in photos { if let r = Recipe(p.raw["develop"]), r.isEdited { m[p.id] = r } }
        lock.withLock { recipes = m }
    }
    func recipe(_ id: Int) -> Recipe? { lock.withLock { recipes[id] } }
    func isEdited(_ id: Int) -> Bool { lock.withLock { recipes[id] != nil } }
    var editedCount: Int { lock.withLock { recipes.count } }

    /// Keeps a photo's adjustments in the catalog (nil or nothing switched on = the original) and remakes its
    /// thumbnail and preview a moment later (so dragging a slider doesn't remake them over and over).
    func save(_ p: Photo, _ r: Recipe?, lib: Library, after: Double = 1.0) {
        let keep = r.flatMap { $0.isEdited ? $0 : nil }
        let had = recipe(p.id)
        if had == keep { return }
        if let keep { p.raw["develop"] = keep.dict } else { p.raw.removeValue(forKey: "develop") }
        lock.withLock { recipes[p.id] = keep }
        lib.changed([p], ["develop"])
        schedule([p.id], after: after)
    }
    func schedule(_ ids: [Int], after: Double) {
        pending.formUnion(ids)
        timer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.flush() }
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: t)
    }
    /// Remakes the thumbnails and previews waiting to be remade, now.
    func flush() {
        timer?.cancel(); timer = nil
        let ids = pending; pending = []
        for id in ids {
            guard let p = Library.shared.byId[id] else { continue }
            queue.addOperation { [weak self] in
                autoreleasepool {
                    ThumbBuilder.shared.buildNow(p)
                    BigPreviews.discard([p.id], .full)
                    BigPreviews.build(p, .standard)
                }
                DispatchQueue.main.async { self?.refreshed(p.id) }
            }
        }
        if !ids.isEmpty { queue.addBarrierBlock { PreviewStore.shared.save() } }
    }
    private func refreshed(_ id: Int) {
        GridDocView.forget(id)
        Images.shared.forget(id)
        stamps[id, default: 0] += 1
        Library.shared.lookChanged([id])
    }
}

// MARK: - The photo being developed

/// The Develop page's state: the photo, its adjustments as you change them, and the picture drawn from them.
/// Pictures are drawn on a queue of their own, always from the newest settings, never piling up.
@Observable
final class DevelopModel {
    static let shared = DevelopModel()
    var photoId: Int?
    var isRaw = false
    var rot = 0
    var recipe = Recipe()
    var image: NSImage?
    var before: NSImage?
    var showBefore = false { didSet { if showBefore && before == nil { renderBefore() } } }
    var histogram: [[Float]] = []
    var busy = false
    var info: RawInfo?
    var cropping = false { didSet { if cropping != oldValue { picking = false; requestRender() } } }
    var picking = false
    var zoomed = false { didSet { if zoomed != oldValue { if zoomed { renderZoom() } else { zoomImage = nil } } } }
    var zoomImage: NSImage?
    var added: Set<Brick> = []
    var canUndo = false
    var canRedo = false
    var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "develop.expanded") ?? Brick.allCases.map(\.rawValue)) {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: "develop.expanded") }
    }

    @ObservationIgnored private(set) var src: DevelopEngine.Source?
    @ObservationIgnored private weak var photo: Photo?
    @ObservationIgnored private var undoStack: [Recipe] = []
    @ObservationIgnored private var redoStack: [Recipe] = []
    @ObservationIgnored private var gestureStart: Recipe?
    @ObservationIgnored private let q = DispatchQueue(label: "develop.render", qos: .userInitiated)
    @ObservationIgnored private var rendering = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var draft = false
    @ObservationIgnored private var gen = 0
    // read and written only on the render queue
    @ObservationIgnored private var qBase: (CIImage, Double)?
    @ObservationIgnored private var qBaseId = -1

    /// Big enough for this Mac's screen, but not bigger than needed.
    var displayPx: Int {
        let s = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2880
        return min(3200, max(1600, Int(s * 0.8)))
    }

    // MARK: opening a photo
    func load(_ p: Photo) {
        if photoId == p.id && rot == p.rot { return }
        if gestureStart != nil { commit() }
        DevelopStore.shared.flush()
        photo = p; photoId = p.id; isRaw = p.isRaw; rot = p.rot
        let s = DevelopEngine.Source(p); src = s
        recipe = DevelopStore.shared.recipe(p.id) ?? Recipe()
        undoStack = []; redoStack = []; gestureStart = nil; canUndo = false; canRedo = false
        before = nil; showBefore = false; picking = false; zoomed = false; info = nil; histogram = []
        if cropping { cropping = false }
        // something to look at straight away, while the photo is developed
        image = (Images.shared.cachedFull(p.id, minPixel: 800) ?? Images.shared.cachedThumb(p.id))?.rotated(p.rot)
        gen += 1
        let g = gen, id = p.id, r = recipe, px = displayPx
        busy = true
        q.async {
            var inf: RawInfo?
            if s.isRaw {
                self.qBase = nil
                CameraMatchStore.shared.ensure(id: id, url: s.url)      // its own camera look, the first time (about a second)
                inf = DevelopEngine.shared.rawInfo(s, r)
            }
            else { self.qBase = DevelopEngine.shared.decode(s, maxPixel: px) }
            self.qBaseId = id
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                self.info = inf
                self.requestRender()
            }
        }
    }
    /// Leaving Develop: finish the change in progress and remake the thumbnails now.
    func leave() {
        if gestureStart != nil { commit() }
        cropping = false; picking = false; zoomed = false; showBefore = false
        DevelopStore.shared.flush()
    }
    /// Another part of the app changed this photo's adjustments (Paste, Revert from the menu).
    func reloadIfShowing(_ id: Int) {
        guard id == photoId else { return }
        recipe = DevelopStore.shared.recipe(id) ?? Recipe()
        requestRender()
    }

    // MARK: drawing
    func requestRender() {
        if rendering { dirty = true; return }
        startRender()
    }
    private func startRender() {
        guard let src, let id = photoId else { return }
        rendering = true; dirty = false; busy = true
        let r = recipe, px = draft ? displayPx * 6 / 10 : displayPx, skip = cropping, rot = self.rot, g = gen
        q.async {
            let base = self.qBaseId == id ? self.qBase : nil
            let cg = DevelopEngine.shared.display(src, r, base: base, maxPixel: px, skipCrop: skip, rot: rot)
            let hist = cg.map(Histogram.make) ?? []
            DispatchQueue.main.async {
                self.rendering = false
                if g == self.gen, let cg {
                    self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.histogram = hist
                }
                if self.dirty { self.startRender() } else { self.busy = false }
            }
        }
    }
    private func renderBefore() {
        guard let src, let id = photoId else { return }
        var r = Recipe(); r.decoder = recipe.decoder; r.s["profile"] = recipe.s["profile"]
        let px = displayPx, rot = self.rot, g = gen
        q.async {
            let base = self.qBaseId == id ? self.qBase : nil
            let cg = DevelopEngine.shared.display(src, r, base: base, maxPixel: px, skipCrop: true, rot: rot)
            DispatchQueue.main.async { if g == self.gen, let cg { self.before = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } }
        }
    }
    /// Full size, for judging sharpening and noise (made when zoomed, and again after each change).
    private func renderZoom() {
        guard zoomed, let src else { return }
        let r = recipe, rot = self.rot, g = gen
        busy = true
        q.async {
            var cg = DevelopEngine.shared.render(src, r, maxPixel: nil)
            if let c = cg, ((rot % 4) + 4) % 4 != 0 { cg = Exporter.rotate(c, rot) }
            DispatchQueue.main.async {
                if g == self.gen, self.zoomed, let cg { self.zoomImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                if !self.rendering { self.busy = false }
            }
        }
    }

    // MARK: changing things
    /// What a slider shows: the photo's value, or the camera's own until it's changed.
    func value(_ k: K) -> Double {
        if recipe.has(k) { return recipe.v(k) }
        switch k {
        case .temp: return info?.temp ?? 6500
        case .tint: return info?.tint ?? 0
        case .boost: return info?.boost ?? k.def
        case .boostShadow: return info?.boostShadow ?? k.def
        case .rawSharp: return info?.sharp ?? k.def
        case .moire: return info?.moire ?? k.def
        case .lens: return (info?.lens ?? true) ? 1 : 0
        case .nrLum: return isRaw ? (info?.nrLum ?? k.def) : k.def
        case .nrColor: return isRaw ? (info?.nrColor ?? k.def) : k.def
        default: return k.def
        }
    }
    private func begin() { if gestureStart == nil { gestureStart = recipe } }
    /// A slider moving: drawn quickly at a smaller size while it moves.
    func set(_ k: K, _ v: Double) {
        begin()
        recipe.set(k, v)
        recipe.setOn(k.brick, true)
        draft = true
        requestRender()
    }
    /// The slider let go (or a value typed): kept, can be undone, and drawn at full quality.
    func end() { draft = false; commit() }
    private func commit() {
        draft = false
        guard let start = gestureStart else { requestRender(); return }
        gestureStart = nil
        if start != recipe {
            undoStack.append(start); if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack = []
            save()
        }
        requestRender()
        if zoomed { renderZoom() }
    }
    private func save() {
        guard let p = photo, p.id == photoId else { return }
        if isRaw, recipe.decoder == nil, let d = info?.decoder { recipe.decoder = d }
        if !recipe.isEdited { recipe.decoder = nil }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
        DevelopStore.shared.save(p, recipe, lib: Library.shared)
    }
    func change(_ f: (inout Recipe) -> Void) { begin(); f(&recipe); commit() }
    func toggle(_ b: Brick) { change { $0.setOn(b, !$0.on(b)) } }
    func reset(_ b: Brick) { change { $0.clear(b) } }
    func resetKey(_ k: K) { change { $0.set(k, nil) } }
    func revert() { change { $0 = Recipe() }; added = []; before = nil }
    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(recipe); recipe = last; save(); requestRender(); if zoomed { renderZoom() }
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe); recipe = next; save(); requestRender(); if zoomed { renderZoom() }
    }
    var profile: RawProfile { RawProfile(rawValue: recipe.s["profile"] ?? "") ?? RawProfile.defaultChoice }
    func setProfile(_ p: RawProfile) {
        change { $0.s["profile"] = p == RawProfile.defaultChoice ? nil : p.rawValue }
        before = nil
    }
    func setDecoder(_ v: String) {
        guard let src else { return }
        change { $0.decoder = v; $0.setOn(.raw, true) }
        before = nil
        let r = recipe, g = gen
        q.async {
            let inf = DevelopEngine.shared.rawInfo(src, r)
            DispatchQueue.main.async { if g == self.gen { self.info = inf } }
        }
    }
    /// Esc: out of zoom, crop, the eyedropper or Before first. Returns false when there was nothing to leave.
    func escape() -> Bool {
        if zoomed { zoomed = false; return true }
        if ruling { ruling = false; return true }
        if cropping { cropping = false; return true }
        if picking { picking = false; return true }
        if showBefore { showBefore = false; return true }
        return false
    }

    // MARK: Auto and the eyedropper
    /// Auto for one section, or (nil) Auto Enhance for all of them.
    func auto(_ which: Brick?) {
        guard let src, let id = photoId else { return }
        let r = recipe, g = gen, inf = info
        busy = true
        q.async {
            let base = self.qBaseId == id ? self.qBase : nil
            let a = DevelopEngine.shared.autoValues(src, r, base: base)
            // white balance only from its own Auto, and only a moderate change (a sunset is meant to be orange)
            let wb = which == .wb ? DevelopEngine.shared.whiteBalance(src, r, base: base, at: nil, info: inf, limit: 40) : nil
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                self.change { r in
                    if which == nil || which == .exposure { r.curve = a.curve ?? r.curve; if a.curve != nil { r.setOn(.exposure, true) } }
                    if which == nil || which == .enhance, let v = a.vibrancy { r.set(.vibrancy, max(-1, min(1, v))); r.setOn(.enhance, true) }
                    if which == nil || which == .hs {
                        if let s = a.shadows { r.set(.shadows, max(0, min(1, s))) }
                        if let h = a.highlights { r.set(.highlights, max(0, min(1, h))) }
                        if a.shadows != nil || a.highlights != nil { r.setOn(.hs, true) }
                    }
                    if let wb { r.set(.temp, wb.temp); r.set(.tint, wb.tint); r.setOn(.wb, true) }
                }
                if !self.rendering { self.busy = false }
                if which != nil && a.curve == nil && a.vibrancy == nil && a.shadows == nil && wb == nil { Library.shared.status = "Auto found nothing to change in this photo." }
            }
        }
    }
    /// The eyedropper: `pt` is where you clicked on the picture shown (fractions, top-left origin).
    func pick(_ pt: CGPoint) {
        picking = false
        guard let src, let id = photoId else { return }
        // back to the photo the right way up, then out of the crop
        var p = pt
        for _ in 0..<(((rot % 4) + 4) % 4) { p = CGPoint(x: p.y, y: 1 - p.x) }
        if !cropping, let c = recipe.activeCrop { p = CGPoint(x: c.minX + p.x * c.width, y: c.minY + p.y * c.height) }
        let r = recipe, g = gen, inf = info
        busy = true
        q.async {
            let base = self.qBaseId == id ? self.qBase : nil
            let wb = DevelopEngine.shared.whiteBalance(src, r, base: base, at: p, info: inf)
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                if let wb { self.change { $0.set(.temp, wb.temp); $0.set(.tint, wb.tint); $0.setOn(.wb, true) } }
                if !self.rendering { self.busy = false }
            }
        }
    }

    // MARK: crop
    /// Your rotation, applied to a crop kept the photo's way up (and back).
    static func toDisplay(_ r: CGRect, _ rot: Int) -> CGRect {
        var r = r
        for _ in 0..<(((rot % 4) + 4) % 4) { r = CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width) }
        return r
    }
    static func toStored(_ r: CGRect, _ rot: Int) -> CGRect {
        var r = r
        for _ in 0..<(((rot % 4) + 4) % 4) { r = CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width) }
        return r
    }
    var displayCrop: CGRect { Self.toDisplay(recipe.on(.crop) ? recipe.crop : CGRect(x: 0, y: 0, width: 1, height: 1), rot) }
    func setCrop(display r: CGRect) {
        let c = Self.toStored(r, rot)
        change { $0.crop = c; $0.setOn(.crop, true) }
    }
    static let aspects = ["Free", "Original", "Square", "3 × 2", "2 × 3", "4 × 3", "3 × 4", "5 × 4", "4 × 5", "7 × 5", "5 × 7", "16 × 9", "9 × 16"]
    /// Width ÷ height (in pixels, as shown) for an aspect, given the shown photo's own width ÷ height.
    static func ratio(_ a: String, photo: Double) -> Double? {
        switch a {
        case "Free": return nil
        case "Original": return photo
        case "Square": return 1
        default:
            if let v = Double(a), v > 0 { return v }                   // a shape kept with the lock (width ÷ height)
            let n = a.split(separator: "×").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return n.count == 2 && n[1] > 0 ? n[0] / n[1] : nil
        }
    }
    // MARK: crop tools
    var guide = CropGuide(rawValue: UserDefaults.standard.integer(forKey: "crop.guide")) ?? .thirds {
        didSet { UserDefaults.standard.set(guide.rawValue, forKey: "crop.guide") }
    }
    var guideTurn = 0
    var guideShow = UserDefaults.standard.integer(forKey: "crop.show") { didSet { UserDefaults.standard.set(guideShow, forKey: "crop.show") } }
    var ruling = false
    func nextGuide() { guide = CropGuide(rawValue: (guide.rawValue + 1) % CropGuide.allCases.count) ?? .thirds; guideTurn = 0 }

    /// The lock: keep the crop's present shape while resizing (or, unlocked, any shape).
    func lockAspect(photoRatio: Double) {
        if recipe.aspect != "Free" { change { $0.aspect = "Free" }; return }
        let c = displayCrop
        let k = c.width * photoRatio / max(0.0001, c.height)
        change { $0.aspect = String(format: "%.4f", k); $0.setOn(.crop, true) }
    }
    /// X: the crop turned between landscape and portrait, the same shape the other way, around the same centre.
    func flipAspect(photoRatio: Double) {
        let c = displayCrop
        let curK = DevelopModel.ratio(recipe.aspect, photo: photoRatio) ?? (c.width * photoRatio / max(0.0001, c.height))
        let k = 1 / max(0.0001, curK)
        // same area (in photo heights), the new shape, kept inside the photo
        let area = c.width * photoRatio * c.height
        var hh = (area / k).squareRoot(), ww = hh * k / photoRatio
        let f = min(1, 1 / max(ww, 0.0001), 1 / max(hh, 0.0001))
        ww *= f; hh *= f
        let x = min(max(0, c.midX - ww / 2), 1 - ww), y = min(max(0, c.midY - hh / 2), 1 - hh)
        let a = recipe.aspect
        let parts = a.split(separator: "×").map { $0.trimmingCharacters(in: .whitespaces) }
        let newAspect = parts.count == 2 ? "\(parts[1]) × \(parts[0])" : (a == "Free" ? "Free" : String(format: "%.4f", k))
        let stored = Self.toStored(CGRect(x: x, y: y, width: ww, height: hh), rot)
        change { $0.aspect = newAspect; $0.crop = stored; $0.setOn(.crop, true) }
    }
    /// The ruler: a line drawn along something level (or upright) — the photo turns so it is.
    func level(from a: CGPoint, to b: CGPoint) {
        ruling = false
        var t = atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi          // screen degrees, down-right positive
        if t > 90 { t -= 180 } else if t <= -90 { t += 180 }
        let tilt = abs(t) <= 45 ? t : (t > 0 ? t - 90 : t + 90)
        let new = max(-45, min(45, value(.angle) - tilt))
        change { $0.set(.angle, (new * 10).rounded() / 10); $0.setOn(.crop, true) }
    }
    /// Auto: levels the horizon Apple's Vision finds (nothing happens if it finds none).
    func autoStraighten() {
        guard let img = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let current = value(.angle), g = gen
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNDetectHorizonRequest()
            try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
            let found = (req.results?.first).map { Double($0.angle) * 180 / .pi }
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                guard let found, abs(found) > 0.05 else { Library.shared.status = "Auto: the horizon already looks level (or none was found)."; return }
                let new = max(-45, min(45, current + found))
                self.change { $0.set(.angle, (new * 10).rounded() / 10); $0.setOn(.crop, true) }
            }
        }
    }

    /// Picking an aspect: the largest crop of that shape inside the current one, centred.
    func setAspect(_ a: String, photoRatio: Double) {
        var c = displayCrop
        if let k = Self.ratio(a, photo: photoRatio) {
            let w = c.width * photoRatio, h = c.height              // in "photo heights"
            if w / h > k { let nw = h * k / photoRatio; c = CGRect(x: c.midX - nw / 2, y: c.minY, width: nw, height: c.height) }
            else { let nh = w / k; c = CGRect(x: c.minX, y: c.midY - nh / 2, width: c.width, height: nh) }
        }
        let stored = Self.toStored(c, rot)
        change { $0.aspect = a; $0.crop = stored; $0.setOn(.crop, true) }
    }
}

/// The histogram over the Develop panel: red, green and blue, 128 levels each.
enum Histogram {
    static func make(_ cg: CGImage) -> [[Float]] {
        let w = min(320, cg.width), h = max(1, cg.height * w / max(1, cg.width))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 128), count: 3)
        for i in 0..<(w * h) {
            bins[0][Int(p[i * 4]) >> 1] += 1
            bins[1][Int(p[i * 4 + 1]) >> 1] += 1
            bins[2][Int(p[i * 4 + 2]) >> 1] += 1
        }
        // scaled to the tallest level, leaving out the very ends (pure black and white would flatten the rest)
        let top = bins.map { $0[1..<127].max() ?? 1 }.max() ?? 1
        return bins.map { $0.map { min(1, ($0 / max(1, top)).squareRoot()) } }
    }
}

import Foundation
import ImageIO
import CoreGraphics

/// The camera's own JPEG hidden inside a RAW file — the punchy look you saw on the camera's screen,
/// which Lightroom calls "Embedded & Sidecar". Previews use it whenever it is big enough,
/// so they look like the camera made them rather than a flat, unedited RAW render.
enum Embedded {
    /// The largest embedded JPEG: its bytes start at `offset`, and it is `w`×`h` pixels (unrotated).
    struct Found { let offset: Int; let w: Int; let h: Int }

    static func largest(in data: Data) -> Found? {
        var best: Found?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var i = 0
            while i < n - 4 {
                guard let hit = memchr(base + i, 0xFF, n - i - 3) else { break }
                let at = base.distance(to: UnsafeRawPointer(hit))
                let p = raw.bindMemory(to: UInt8.self)
                if p[at + 1] == 0xD8 && p[at + 2] == 0xFF {
                    // read just the header to learn the size (ImageIO stops after the frame header)
                    let slice = data[data.startIndex + at ..< data.startIndex + min(n, at + 262144)]
                    if let src = CGImageSourceCreateWithData(slice as CFData, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                       let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                       w * h > (best.map { $0.w * $0.h } ?? 0) {
                        best = Found(offset: at, w: w, h: h)
                    }
                }
                i = at + 1
            }
        }
        return best
    }

    /// The embedded JPEG, turned the right way up and scaled to at most `max` pixels — if its long edge is at least `minLong`.
    static func image(_ url: URL, max: Int, minLong: Int) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let f = largest(in: data), Swift.max(f.w, f.h) >= minLong else { return nil }
        let jpeg = data[(data.startIndex + f.offset)...]
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max,
                                     kCGImageSourceCreateThumbnailWithTransform: false, kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // the embedded JPEG is stored as the sensor saw it; the RAW says which way up it goes
        let rawSrc = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = rawSrc.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let o = props?[kCGImagePropertyOrientation] as? Int ?? 1
        return orient(img, o)
    }

    /// Applies an EXIF orientation (1–8).
    static func orient(_ img: CGImage, _ o: Int) -> CGImage {
        guard o > 1, o <= 8 else { return img }
        let w = img.width, h = img.height
        let swap = o >= 5
        let nw = swap ? h : w, nh = swap ? w : h
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let W = CGFloat(nw), H = CGFloat(nh)
        switch o {   // transforms in CoreGraphics' bottom-left coordinates
        case 2: ctx.translateBy(x: W, y: 0); ctx.scaleBy(x: -1, y: 1)
        case 3: ctx.translateBy(x: W, y: H); ctx.rotate(by: .pi)
        case 4: ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
        case 5: ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: W, ty: H))   // transpose
        case 6: ctx.translateBy(x: 0, y: H); ctx.rotate(by: -.pi / 2)
        case 7: ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))     // transverse
        case 8: ctx.translateBy(x: W, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// A rendering of any photo: for RAW files the camera's embedded JPEG when it is big enough, otherwise the image itself.
    static func render(_ p: Photo, max: Int, minLong: Int) -> CGImage? {
        if p.isRaw, let e = image(p.url, max: max, minLong: minLong) { return e }
        return Images.decodeCG(p.url, max: max)
    }
}

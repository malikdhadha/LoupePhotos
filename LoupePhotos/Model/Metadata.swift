import Foundation
import ImageIO

/// Reads capture date, camera, lens, exposure and size with Apple's ImageIO (handles RAW too).
enum Metadata {
    static let exifDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; return f
    }()
    static func read(into p: Photo) {
        guard let src = CGImageSourceCreateWithURL(p.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] else {
            p.date = p.mtime > 0 ? p.mtime : p.added; p.dateFromFile = true; return
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        p.w = w; p.h = h
        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String, let d = exifDate.date(from: s) {
            p.date = d.timeIntervalSince1970 * 1000; p.dateFromFile = false
        } else { p.date = p.mtime > 0 ? p.mtime : p.added; p.dateFromFile = true }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { p.camera = model.lowercased().hasPrefix((make.split(separator: " ").first ?? "").lowercased()) ? model : "\(make) \(model)".trimmingCharacters(in: .whitespaces) }
        p.lens = exif[kCGImagePropertyExifLensModel] as? String ?? aux["LensModel" as CFString] as? String ?? ""
        var parts: [String] = []
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 { parts.append(t >= 1 ? "\(Double(round(t * 10) / 10)) s" : "1/\(Int((1 / t).rounded())) s") }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { parts.append("f/\(f.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(f)) : String(format: "%.1f", f))") }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(fl.rounded())) mm") }
        p.exposure = parts.joined(separator: " · ")
        if let g = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], var lat = g[kCGImagePropertyGPSLatitude] as? Double, var lng = g[kCGImagePropertyGPSLongitude] as? Double {
            if (g[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (g[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lng = -lng }
            p.raw["gps"] = ["lat": (lat * 1e6).rounded() / 1e6, "lng": (lng * 1e6).rounded() / 1e6]
        }
    }
}

import Foundation
import AppKit
import Observation

/// What the Viewer's info overlay (I) can show, one field per line.
enum InfoField: String, CaseIterable, Identifiable {
    case name = "File Name", date = "Capture Date & Time", dimensions = "Pixel Size", exposure = "Exposure",
         focal = "Focal Length", camera = "Camera", lens = "Lens", cameraLens = "Camera + Lens",
         place = "Place", rating = "Rating & Label", keywords = "Keywords", folder = "Folder", fileSize = "File Size", none = "—"
    var id: String { rawValue }

    func text(_ p: Photo) -> String {
        let parts = p.exposure.components(separatedBy: " · ")
        switch self {
        case .name: return p.fileName
        case .date: return p.dateFromFile ? "" : p.captureDate.formatted(date: .abbreviated, time: .standard)
        case .dimensions: return p.w > 0 ? "\(p.rot % 2 == 1 ? p.h : p.w) × \(p.rot % 2 == 1 ? p.w : p.h)" : ""
        case .exposure: return parts.filter { !$0.hasSuffix("mm") }.joined(separator: "  ")
        case .focal: return parts.first { $0.hasSuffix("mm") } ?? ""
        case .camera: return p.camera
        case .lens: return p.lens
        case .cameraLens:
            let f = parts.first { $0.hasSuffix("mm") }
            return [f, p.camera.isEmpty ? nil : (p.lens.isEmpty ? p.camera : "\(p.camera) · \(p.lens)")].compactMap { $0 }.joined(separator: "  ")
        case .place: return p.placeLabel
        case .rating:
            let stars = p.rating > 0 ? String(repeating: "★", count: p.rating) : ""
            return [stars, PhotoLabel.find(p.label)?.name ?? "", p.flag ? "Picked" : p.rejected ? "Rejected" : ""].filter { !$0.isEmpty }.joined(separator: "  ")
        case .keywords: return p.keywords.joined(separator: ", ")
        case .folder: return (p.dir as NSString).lastPathComponent
        case .fileSize: return ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file)
        case .none: return ""
        }
    }
}

/// View ▸ View Options… (⌘J), modelled on Lightroom Classic's Library View Options. Everything is remembered.
@Observable
final class ViewOptions {
    static let shared = ViewOptions()
    private static let d = UserDefaults.standard
    private static func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: "vo." + k) as? Bool ?? def }

    // Grid
    var tintLabels = ViewOptions.b("tint", true) { didSet { ViewOptions.d.set(tintLabels, forKey: "vo.tint") } }
    var tintPercent = ViewOptions.d.object(forKey: "vo.tintPct") as? Int ?? 30 { didSet { ViewOptions.d.set(tintPercent, forKey: "vo.tintPct") } }
    var hoverOnly = ViewOptions.b("hoverOnly", false) { didSet { ViewOptions.d.set(hoverOnly, forKey: "vo.hoverOnly") } }
    var tooltips = ViewOptions.b("tooltips", true) { didSet { ViewOptions.d.set(tooltips, forKey: "vo.tooltips") } }
    var geotagBadge = ViewOptions.b("geotag", true) { didSet { ViewOptions.d.set(geotagBadge, forKey: "vo.geotag") } }
    var showIndex = ViewOptions.b("index", true) { didSet { ViewOptions.d.set(showIndex, forKey: "vo.index") } }
    var showDims = ViewOptions.b("dims", true) { didSet { ViewOptions.d.set(showDims, forKey: "vo.dims") } }
    var showType = ViewOptions.b("type", true) { didSet { ViewOptions.d.set(showType, forKey: "vo.type") } }
    var showRotate = ViewOptions.b("rotate", true) { didSet { ViewOptions.d.set(showRotate, forKey: "vo.rotate") } }
    var showLabelDot = ViewOptions.b("labelDot", true) { didSet { ViewOptions.d.set(showLabelDot, forKey: "vo.labelDot") } }

    // Viewer
    var info1: [InfoField] = ViewOptions.fields("info1", [.name, .date, .dimensions]) { didSet { ViewOptions.d.set(info1.map(\.rawValue), forKey: "vo.info1") } }
    var info2: [InfoField] = ViewOptions.fields("info2", [.name, .exposure, .cameraLens]) { didSet { ViewOptions.d.set(info2.map(\.rawValue), forKey: "vo.info2") } }
    var background = ViewOptions.d.string(forKey: "vo.bg") ?? "Black" { didSet { ViewOptions.d.set(background, forKey: "vo.bg") } }

    static let backgrounds: [(String, Double)] = [("White", 1), ("Light Gray", 0.78), ("Medium Gray", 0.5), ("Dark Gray", 0.24), ("Darker Gray", 0.13), ("Black", 0.04)]
    var backgroundWhite: Double { ViewOptions.white(background) }
    static func white(_ name: String) -> Double { backgrounds.first { $0.0 == name }?.1 ?? 0.04 }
    private static func fields(_ k: String, _ def: [InfoField]) -> [InfoField] {
        (d.stringArray(forKey: "vo." + k)?.compactMap(InfoField.init(rawValue:))).flatMap { $0.count == 3 ? $0 : nil } ?? def
    }
    /// A number that changes whenever a grid option changes (so the grid redraws).
    var gridStamp: String { "\(tintLabels)\(tintPercent)\(hoverOnly)\(tooltips)\(geotagBadge)\(showIndex)\(showDims)\(showType)\(showRotate)\(showLabelDot)" }
}

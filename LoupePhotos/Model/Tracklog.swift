import Foundation
import CoreLocation
import AppKit
import UniformTypeIdentifiers

/// GPX tracklogs (Map ▸ Tracklog), like Lightroom Classic: load a track from a GPS logger or phone app,
/// see it on the map, and give photos a location by matching their capture time to the track.
@Observable
final class Tracklogs {
    static let shared = Tracklogs()
    struct Point { let t: Double; let lat: Double; let lng: Double }   // t = seconds since 1970 (UTC)

    private(set) var name = ""
    private(set) var points: [Point] = []
    var version = 0
    /// Hours to add to the camera's clock (if it was set to a different time zone, or was off).
    var offsetHours: Double = UserDefaults.standard.double(forKey: "trackOffset") { didSet { UserDefaults.standard.set(offsetHours, forKey: "trackOffset") } }
    var recent: [String] { UserDefaults.standard.stringArray(forKey: "recentTracklogs") ?? [] }

    var coordinates: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) } }
    var timeRange: ClosedRange<Double>? { points.isEmpty ? nil : points.first!.t...points.last!.t }

    func choose() {
        let p = NSOpenPanel()
        p.message = "Choose a GPX tracklog"
        p.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { load(u) }
    }
    @discardableResult
    func load(_ url: URL) -> Bool {
        guard let pts = GPXReader.read(url), !pts.isEmpty else {
            Library.shared.fail("“\(url.lastPathComponent)” has no timed track points.")
            return false
        }
        points = pts.sorted { $0.t < $1.t }
        name = url.deletingPathExtension().lastPathComponent
        version += 1
        var r = recent.filter { $0 != url.path }; r.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(8)), forKey: "recentTracklogs")
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        Library.shared.status = "Loaded “\(name)”: \(points.count.formatted()) points, \(f.string(from: Date(timeIntervalSince1970: points.first!.t))) – \(f.string(from: Date(timeIntervalSince1970: points.last!.t)))."
        return true
    }
    func close() { points = []; name = ""; version += 1 }

    /// Where the track was when the photo was taken: between the two nearest points, if they're close in time.
    func location(at date: Date) -> CLLocationCoordinate2D? {
        guard !points.isEmpty else { return nil }
        let t = date.timeIntervalSince1970 + offsetHours * 3600
        var lo = 0, hi = points.count - 1
        if t < points[0].t - 300 || t > points[hi].t + 300 { return nil }      // more than 5 minutes outside the track
        while hi - lo > 1 { let m = (lo + hi) / 2; if points[m].t <= t { lo = m } else { hi = m } }
        let a = points[lo], b = points[hi]
        if t <= a.t { return CLLocationCoordinate2D(latitude: a.lat, longitude: a.lng) }
        if t >= b.t { return CLLocationCoordinate2D(latitude: b.lat, longitude: b.lng) }
        guard b.t - a.t <= 600 else {                                            // a gap of over 10 minutes: use the nearer end if within 2 minutes
            let n = t - a.t < b.t - t ? a : b
            return abs(n.t - t) <= 120 ? CLLocationCoordinate2D(latitude: n.lat, longitude: n.lng) : nil
        }
        let k = (t - a.t) / (b.t - a.t)
        return CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * k, longitude: a.lng + (b.lng - a.lng) * k)
    }

    /// Auto-Tag: photos without a location (or all of `ps` if `replace`) get one from the track.
    func tag(_ ps: [Photo], lib: Library, replace: Bool = false) {
        var done: [(Photo, CLLocationCoordinate2D)] = []
        for p in ps where !p.dateFromFile && (replace || Library.gps(p) == nil) {
            if let c = location(at: p.captureDate) { done.append((p, c)) }
        }
        for (p, c) in done { lib.setLocation([p], c) }
        if !done.isEmpty { PlaceNamer.shared.nameMissing(lib) }
        lib.status = done.isEmpty ? "No photos matched the track’s times. Check Set Time Offset… if the camera clock was off." :
            "Tagged \(done.count.formatted()) photo\(done.count == 1 ? "" : "s") from “\(name)”."
    }
    func askOffset() {
        let v = Library.ask("Tracklog Time Offset", "Hours to add to the cameras’ clocks to match the track (for example −1 or 5.5). Use 0 when the camera was set to this Mac’s time zone.",
                            value: offsetHours == 0 ? "0" : String(offsetHours), ok: "Set")
        if let v, let h = Double(v.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "+", with: "")) { offsetHours = h }
    }
}

/// Reads <trkpt>, <rtept> and <wpt> points that have a <time>.
final class GPXReader: NSObject, XMLParserDelegate {
    private var out: [Tracklogs.Point] = []
    private var lat = 0.0, lng = 0.0, inPoint = false, text = "", time: Double?
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    static func read(_ url: URL) -> [Tracklogs.Point]? {
        guard let p = XMLParser(contentsOf: url) else { return nil }
        let r = GPXReader(); p.delegate = r
        return p.parse() || !r.out.isEmpty ? r.out : nil
    }
    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        let n = el.lowercased()
        if n == "trkpt" || n == "rtept" || n == "wpt" {
            inPoint = true; time = nil
            lat = Double(a["lat"] ?? "") ?? .nan; lng = Double(a["lon"] ?? "") ?? .nan
        }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let n = el.lowercased()
        if inPoint && n == "time" {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            time = (GPXReader.isoFrac.date(from: s) ?? GPXReader.iso.date(from: s))?.timeIntervalSince1970
        }
        if n == "trkpt" || n == "rtept" || n == "wpt" {
            inPoint = false
            if let t = time, !lat.isNaN, !lng.isNaN { out.append(.init(t: t, lat: lat, lng: lng)) }
        }
    }
}

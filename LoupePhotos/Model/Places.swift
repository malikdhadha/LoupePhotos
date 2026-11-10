import Foundation
import CoreLocation

/// Place names for photos with GPS: town, region and country ({t, r, c}, the same shape the Electron version stored).
/// Looked up with Apple's geocoder a little at a time in the background, and remembered per ~2 km square
/// in the previews package, so each spot is only ever looked up once.
final class PlaceNamer {
    static let shared = PlaceNamer()
    private let geocoder = CLGeocoder()
    private var cache: [String: [String: String]] = [:]
    private var loaded = false
    private var running = false
    private var queue: [String] = []
    private var waiting: [String: [Photo]] = [:]
    private var paused = false
    private var looked = 0
    /// Settings ▸ Library ▸ "Look up place names".
    static var enabled: Bool { UserDefaults.standard.object(forKey: "places.enabled") as? Bool ?? true }
    /// Held back by BackgroundWork until thumbnails are done.
    private var held = false
    func hold(_ on: Bool) { guard held != on else { return }; held = on; if !on { next(Library.shared) } }

    private var cacheURL: URL? { PreviewStore.shared.url?.appendingPathComponent("Places.json") }
    static func cell(_ lat: Double, _ lng: Double) -> String { String(format: "%.2f,%.2f", (lat * 50).rounded() / 50, (lng * 50).rounded() / 50) }

    private func load() {
        guard !loaded, let u = cacheURL else { return }
        loaded = true
        if let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] { cache = o }
    }
    private func save() {
        guard let u = cacheURL, let d = try? JSONSerialization.data(withJSONObject: cache) else { return }
        try? d.write(to: u, options: .atomic)
    }

    /// Names every photo that has GPS but no place yet.
    func nameMissing(_ lib: Library) {
        guard PlaceNamer.enabled else { return }
        load()
        var fromCache: [Photo] = []
        for p in lib.photos where p.place == nil || ((p.place?["t"] as? String)?.contains("Ocean") ?? false) {
            guard let g = Library.gps(p) else { continue }
            let k = PlaceNamer.cell(g.latitude, g.longitude)
            if let pl = cache[k], !(pl["t"]?.contains("Ocean") ?? false) {
                var v = pl; v.removeValue(forKey: "v"); p.raw["place"] = v; fromCache.append(p)
            } else if let pl = cache[k], pl["v"] == "2" {
                if p.place == nil { var v = pl; v.removeValue(forKey: "v"); p.raw["place"] = v; fromCache.append(p) }
                continue                       // looked up already with today's naming: still only sea there, so don't ask again every launch
            } else { if waiting[k] == nil { queue.append(k) }; waiting[k, default: []].append(p) }
        }
        if !fromCache.isEmpty { lib.changed(fromCache, ["place"]) }
        next(lib)
    }

    private func next(_ lib: Library) {
        guard !running, !paused, !held, PlaceNamer.enabled, !queue.isEmpty else { return }
        Activity.shared.report("places", "Looking up place names", done: looked, total: looked + queue.count,
                               pause: { [weak self] on in self?.paused = on; if !on { self?.next(lib) } })
        running = true
        let k = queue.removeFirst()
        let parts = k.split(separator: ",").compactMap { Double($0) }
        geocoder.reverseGeocodeLocation(CLLocation(latitude: parts[0], longitude: parts[1])) { [weak self] marks, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let m = marks?.first {
                    var pl: [String: String] = [:]
                    // town; on islands with no town (the Maldives, say) the island, then the atoll — never just the ocean
                    let sea = [m.ocean, m.inlandWater].compactMap { $0 }
                    let name = m.name.flatMap { n in sea.contains(n) || n.contains("Ocean") ? nil : n }
                    if let t = m.locality ?? m.subLocality ?? m.areasOfInterest?.first ?? name ?? m.subAdministrativeArea ?? m.administrativeArea { pl["t"] = t }
                    if let r = m.administrativeArea { pl["r"] = r }
                    if let c = m.country { pl["c"] = c }
                    var stored = pl; stored["v"] = "2"
                    self.cache[k] = stored
                    let ps = self.waiting.removeValue(forKey: k) ?? []
                    for p in ps { p.raw["place"] = pl }
                    if !ps.isEmpty { lib.changed(ps, ["place"]) }
                    if self.cache.count % 20 == 0 { self.save() }
                } else if (error as? CLError)?.code == .network {
                    self.queue.append(k)                              // offline: try again later
                } else {
                    self.waiting.removeValue(forKey: k)
                }
                self.looked += 1
                if self.queue.isEmpty { self.save(); self.looked = 0; Activity.shared.finish("places") }
                // Apple asks apps to keep geocoding gentle: about one lookup a second
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.running = false; self.next(lib) }
            }
        }
    }
}

extension Library {
    static func gps(_ p: Photo) -> CLLocationCoordinate2D? {
        guard let g = p.raw["gps"] as? [String: Any], let lat = Photo.dbl(g["lat"]), let lng = Photo.dbl(g["lng"]), lat != 0 || lng != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
    /// Puts photos on the map at a spot (Map ▸ drag photos onto the map). Kept in the catalog.
    func setLocation(_ ps: [Photo], _ c: CLLocationCoordinate2D) {
        for p in ps {
            p.raw["gps"] = ["lat": (c.latitude * 1e6).rounded() / 1e6, "lng": (c.longitude * 1e6).rounded() / 1e6]
            p.raw["gpsManual"] = true
            p.raw.removeValue(forKey: "place")
        }
        changed(ps, ["gps", "gpsManual", "place"])
        PlaceNamer.shared.nameMissing(self)
    }
    func clearLocation(_ ps: [Photo]) {
        for p in ps { p.raw.removeValue(forKey: "gps"); p.raw.removeValue(forKey: "place"); p.raw["gpsManual"] = true }
        changed(ps, ["gps", "gpsManual", "place"])
    }
}

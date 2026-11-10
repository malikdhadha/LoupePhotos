import Foundation
import Observation

/// One photo in the catalog. Typed fields for what the app uses; everything else in `raw`
/// is kept untouched so the Electron version of Loupe Photos can keep reading the same catalog.
@Observable
final class Photo: Identifiable, Hashable {
    let id: Int
    var path: String
    var fid: String
    var ext: String
    var size: Int
    var mtime: Double
    var added: Double
    var date: Double            // milliseconds since 1970, like the JavaScript version
    var dateFromFile: Bool
    var w: Int
    var h: Int
    var camera: String
    var lens: String
    var exposure: String
    var rating: Int
    var flag: Bool
    var label: String?
    var rejected: Bool
    var keywords: [String]
    var caption: String
    var name: String
    var rot: Int
    var deleted: Double?
    var missing: Bool
    @ObservationIgnored var raw: [String: Any]

    init(id: Int, path: String, fid: String) {
        self.id = id; self.path = path; self.fid = fid
        ext = (path as NSString).pathExtension.lowercased()
        let now = Date().timeIntervalSince1970 * 1000
        size = 0; mtime = 0; added = now; date = now; dateFromFile = true
        w = 0; h = 0; camera = ""; lens = ""; exposure = ""
        rating = 0; flag = false; label = nil; rejected = false; keywords = []; caption = ""; name = ""; rot = 0
        deleted = nil; missing = false; raw = [:]
    }

    /// Every field at once (the fast catalog copy, CatalogSnapshot).
    init(id: Int, path: String, fid: String, ext: String, size: Int, mtime: Double, added: Double, date: Double, dateFromFile: Bool,
         w: Int, h: Int, camera: String, lens: String, exposure: String, rating: Int, flag: Bool, label: String?, rejected: Bool,
         keywords: [String], caption: String, name: String, rot: Int, deleted: Double?, missing: Bool, raw: [String: Any]) {
        self.id = id; self.path = path; self.fid = fid; self.ext = ext; self.size = size; self.mtime = mtime; self.added = added
        self.date = date; self.dateFromFile = dateFromFile; self.w = w; self.h = h; self.camera = camera; self.lens = lens
        self.exposure = exposure; self.rating = rating; self.flag = flag; self.label = label; self.rejected = rejected
        self.keywords = keywords; self.caption = caption; self.name = name; self.rot = rot; self.deleted = deleted
        self.missing = missing; self.raw = raw
    }
    init?(dict d: [String: Any]) {
        guard let id = Photo.int(d["id"]), let path = d["path"] as? String else { return nil }
        self.id = id; self.path = path
        fid = d["fid"] as? String ?? ""
        ext = (d["ext"] as? String) ?? (path as NSString).pathExtension.lowercased()
        size = Photo.int(d["size"]) ?? 0
        mtime = Photo.dbl(d["mtime"]) ?? 0
        added = Photo.dbl(d["added"]) ?? 0
        date = Photo.dbl(d["date"]) ?? 0
        dateFromFile = (d["dateSrc"] as? String) == "file"
        w = Photo.int(d["w"]) ?? 0; h = Photo.int(d["h"]) ?? 0
        camera = d["camera"] as? String ?? ""; lens = d["lens"] as? String ?? ""; exposure = d["exposure"] as? String ?? ""
        rating = Photo.int(d["rating"]) ?? 0
        flag = d["flag"] as? Bool ?? false
        label = d["label"] as? String
        rejected = d["rejected"] as? Bool ?? false
        keywords = d["keywords"] as? [String] ?? []
        caption = d["caption"] as? String ?? ""
        name = d["name"] as? String ?? ""
        rot = Photo.int(d["rot"]) ?? 0
        deleted = Photo.dbl(d["deleted"]).flatMap { $0 > 0 ? $0 : nil }
        missing = d["missing"] as? Bool ?? false
        // keep only what the typed fields above don't hold (they're put back by dict() when saving):
        // at 120,000 photos this saves a copy of every photo's whole record in memory
        var r = d
        for k in Photo.typedKeys { r.removeValue(forKey: k) }
        raw = r
    }
    static let typedKeys = ["id", "path", "fid", "ext", "size", "mtime", "added", "date", "dateSrc", "w", "h", "camera", "lens", "exposure",
                            "rating", "flag", "label", "rejected", "keywords", "caption", "name", "rot", "deleted", "missing"]

    /// The record as the catalog stores it (unknown fields preserved).
    func dict() -> [String: Any] {
        var d = raw
        d["id"] = id; d["path"] = path; d["fid"] = fid; d["ext"] = ext; d["size"] = size; d["mtime"] = mtime; d["added"] = added
        d["date"] = date; d["dateSrc"] = dateFromFile ? "file" : "exif"; d["w"] = w; d["h"] = h
        d["camera"] = camera; d["lens"] = lens; d["exposure"] = exposure
        d["rating"] = rating; d["flag"] = flag; d["label"] = label ?? NSNull(); d["rejected"] = rejected
        d["keywords"] = keywords; d["caption"] = caption; d["name"] = name; d["rot"] = rot
        if let deleted { d["deleted"] = deleted } else { d.removeValue(forKey: "deleted") }
        if missing { d["missing"] = true } else { d.removeValue(forKey: "missing") }
        return d
    }

    // MARK: derived
    var url: URL { URL(fileURLWithPath: path) }
    var fileName: String { (path as NSString).lastPathComponent }
    var displayName: String { name.isEmpty ? (fileName as NSString).deletingPathExtension : name }
    var dir: String { (path as NSString).deletingLastPathComponent }
    var captureDate: Date { Date(timeIntervalSince1970: date / 1000) }
    var place: [String: Any]? { raw["place"] as? [String: Any] }
    var placeLabel: String {
        guard let pl = place else { return "" }
        let t = pl["t"] as? String ?? "", r = pl["r"] as? String ?? "", c = pl["c"] as? String ?? ""
        return [t, r != t ? r : "", c].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var isRaw: Bool { Photo.rawExt.contains(ext) }
    // Quick reads for listing tens of thousands of photos. A list is rebuilt whenever the library changes anyway,
    // so these skip SwiftUI's per-photo change tracking (which cost more than the listing itself at 100,000+ photos).
    var quickLive: Bool { _deleted == nil && !_rejected }
    var quickDeleted: Bool { _deleted != nil }
    var quickRejected: Bool { _rejected }
    var quickRating: Int { _rating }
    var quickFlag: Bool { _flag }
    var quickNoDate: Bool { _dateFromFile }
    var quickAdded: Double { _added }
    var quickDate: Double { _date }
    var quickPath: String { _path }
    var quickLabel: String? { _label }
    var quickKeywords: [String] { _keywords }
    var quickCamera: String { _camera }
    var quickLens: String { _lens }
    var quickCaption: String { _caption }
    var quickName: String { _name }
    var quickExt: String { _ext }
    var quickW: Int { _w }
    var quickH: Int { _h }
    var quickRot: Int { _rot }
    var quickSize: Int { _size }
    var quickFileName: String { (_path as NSString).lastPathComponent }
    var quickDir: String { (_path as NSString).deletingLastPathComponent }
    /// Year, month (1–12) and day of the capture date, in this Mac's time zone. Worked out with plain arithmetic
    /// (about 50 times quicker than asking Calendar, which took most of a second for 120,000 photos at launch),
    /// and nothing is stored, so it's safe to read from any thread.
    var ymd: (y: Int, m: Int, d: Int) { CivilDate.ymd(ms: _date) }
    var aspect: CGFloat {
        guard w > 0, h > 0 else { return 1.5 }
        return rot % 2 == 1 ? CGFloat(h) / CGFloat(w) : CGFloat(w) / CGFloat(h)
    }
    /// Lower-case text searched by the search field — built once, then kept until this photo's details change
    /// (Library.changed clears it), instead of being rebuilt for every photo on every keystroke.
    @ObservationIgnored private var _searchText: String?
    var searchText: String {
        if let t = _searchText { return t }
        let t = [displayName, fileName, keywords.joined(separator: " "), caption, placeLabel, camera, lens, dir].joined(separator: " ").lowercased()
        _searchText = t
        return t
    }
    func detailsChanged() { _searchText = nil }

    static func == (a: Photo, b: Photo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let rawExt: Set<String> = ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mos", "mrw", "rwl"]
    static let imageExt: Set<String> = rawExt.union(["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "tif", "tiff", "bmp"])

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
    static func dbl(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// Colour labels, same ids as the JavaScript version.
struct PhotoLabel: Identifiable {
    let id: String, name: String, hex: UInt32
    static let all: [PhotoLabel] = [
        .init(id: "red", name: "Red", hex: 0xE0564F), .init(id: "orange", name: "Orange", hex: 0xEF8A35),
        .init(id: "yellow", name: "Yellow", hex: 0xE7C845), .init(id: "green", name: "Green", hex: 0x5BBF62),
        .init(id: "blue", name: "Blue", hex: 0x4D8CE6), .init(id: "purple", name: "Purple", hex: 0xA46AD8),
        .init(id: "gray", name: "Gray", hex: 0x8F959C),
    ]
    static func find(_ id: String?) -> PhotoLabel? { all.first { $0.id == id } }
}

struct Folder: Identifiable, Hashable {
    let id: String
    var path: String
    var name: String
    var offline: Bool
}

struct Album: Identifiable, Hashable {
    let id: String
    var type: String       // album, smart, light, folder
    var name: String
    var parent: String?
    var ids: [Int]
    var match: String = "all"          // smart collections: "all" or "any" of the rules
    var rules: [SmartRule] = []
}


/// Dates without Calendar: the time zone's offset (remembered for each hour, so summer time is right) and
/// Howard Hinnant's days-to-date arithmetic. Falls back to Calendar if this Mac uses a non-Gregorian calendar.
enum CivilDate {
    private static let lock = NSLock()
    private static var offsets: [Int: Int] = [:]          // hours since 1970 (UTC) → seconds east of UTC
    private static let gregorian = Calendar.current.identifier == .gregorian
    private static let watch: NSObjectProtocol = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { _ in
        NSTimeZone.resetSystemTimeZone(); CivilDate.reset()
    }
    static func offset(forHour h: Int) -> Int {
        _ = watch
        lock.lock(); defer { lock.unlock() }
        if let o = offsets[h] { return o }
        if offsets.count > 400_000 { offsets.removeAll() }
        let o = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(h) * 3600))
        offsets[h] = o
        return o
    }
    /// Forget remembered offsets (the Mac's time zone changed).
    static func reset() { lock.lock(); offsets.removeAll(); lock.unlock() }
    static func ymd(ms: Double) -> (y: Int, m: Int, d: Int) {
        guard ms.isFinite, abs(ms) < 1e15 else { return (1970, 1, 1) }     // (a broken date can't crash it)
        let secs = Int((ms / 1000).rounded(.down))
        if !gregorian {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(secs)))
            return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        let hour = secs >= 0 ? secs / 3600 : (secs - 3599) / 3600
        let local = secs + offset(forHour: hour)
        let days = local >= 0 ? local / 86400 : (local - 86399) / 86400
        return civil(days)
    }
    /// The local day a moment falls on, as days since 1 January 1970 (for grouping by day or week without Calendar).
    static func localDay(ms: Double) -> Int {
        guard ms.isFinite, abs(ms) < 1e15 else { return 0 }
        let secs = Int((ms / 1000).rounded(.down))
        let hour = secs >= 0 ? secs / 3600 : (secs - 3599) / 3600
        let local = secs + offset(forHour: hour)
        return local >= 0 ? local / 86400 : (local - 86399) / 86400
    }
    /// The first day of the week a local day is in, by this Mac's first weekday (Sunday, Monday…).
    static func weekStart(_ day: Int) -> Int {
        let first = Calendar.current.firstWeekday - 1                    // 0 = Sunday
        let wd = ((day + 4) % 7 + 7) % 7                                  // 1 January 1970 was a Thursday
        return day - ((wd - first) % 7 + 7) % 7
    }
    /// Days since 1 January 1970 → year, month, day.
    static func civil(_ days: Int) -> (y: Int, m: Int, d: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

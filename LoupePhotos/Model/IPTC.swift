import Foundation
import Observation

/// IPTC fields — the standard "who, what, where, rights" a photo carries (Aperture's Info tab, Lightroom's IPTC panel).
/// Kept in the catalog with each photo (`raw["iptc"]`); written into the files too only if you turn on XMP in Settings.
enum IPTCField: String, CaseIterable, Identifiable {
    case title, headline, creator, creatorJob, email, phone, website
    case copyright, usageTerms, credit, source, instructions, jobId
    case location, city, state, country, countryCode
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Title"
        case .headline: return "Headline"
        case .creator: return "Creator"
        case .creatorJob: return "Job Title"
        case .email: return "Email"
        case .phone: return "Phone"
        case .website: return "Website"
        case .copyright: return "Copyright"
        case .usageTerms: return "Usage Terms"
        case .credit: return "Credit Line"
        case .source: return "Source"
        case .instructions: return "Instructions"
        case .jobId: return "Job Identifier"
        case .location: return "Sublocation"
        case .city: return "City"
        case .state: return "State / Province"
        case .country: return "Country"
        case .countryCode: return "Country Code"
        }
    }
    enum Group: String, CaseIterable { case contact = "Contact", content = "Content", location = "Location", status = "Rights & Status" }
    var group: Group {
        switch self {
        case .creator, .creatorJob, .email, .phone, .website: return .contact
        case .title, .headline: return .content
        case .location, .city, .state, .country, .countryCode: return .location
        default: return .status
        }
    }
    /// Fields that come from Settings ▸ Metadata ▸ Identity.
    static let identity: [IPTCField] = [.creator, .creatorJob, .email, .phone, .website, .copyright]
}

extension Photo {
    var iptc: [String: String] { raw["iptc"] as? [String: String] ?? [:] }
    func iptc(_ f: IPTCField) -> String { iptc[f.rawValue] ?? "" }
}

extension Library {
    /// Sets IPTC fields (and optionally caption / keywords) on photos. Append: only fills fields that are empty.
    /// Replace: sets every field given (an empty value clears it).
    func setIPTC(_ ps: [Photo], _ values: [String: String], replace: Bool = true) {
        guard !ps.isEmpty, !values.isEmpty else { return }
        var fields: Set<String> = []
        for p in ps {
            var d = p.iptc
            for (k, v) in values {
                let v = v.trimmingCharacters(in: .whitespacesAndNewlines)
                switch k {
                case "caption":
                    if replace || p.caption.isEmpty, !(v.isEmpty && !replace) { p.caption = v; fields.insert("caption") }
                case "keywords":
                    for kw in v.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) where !p.keywords.contains(kw) {
                        p.keywords.append(kw); fields.insert("keywords")
                    }
                default:
                    guard IPTCField(rawValue: k) != nil else { continue }
                    if replace { if v.isEmpty { d.removeValue(forKey: k) } else { d[k] = v } }
                    else if (d[k] ?? "").isEmpty, !v.isEmpty { d[k] = v }
                    fields.insert("iptc")
                }
            }
            if d.isEmpty { p.raw.removeValue(forKey: "iptc") } else { p.raw["iptc"] = d }
        }
        if !fields.isEmpty { changed(ps, Array(fields)) }
    }
    /// Metadata ▸ Clear IPTC Metadata.
    func clearIPTC(_ ps: [Photo]) {
        for p in ps { p.raw.removeValue(forKey: "iptc") }
        changed(ps, ["iptc"])
    }
    /// Batch Change: moves capture times by `seconds` (a camera clock that was wrong, or another time zone).
    func shiftDates(_ ps: [Photo], by seconds: Double) {
        guard seconds != 0 else { return }
        for p in ps { p.date += seconds * 1000; p.dateFromFile = false }
        changed(ps, ["date"])
    }
}

/// Settings ▸ Metadata ▸ Identity: who you are, filled into presets and imports.
enum Identity {
    static func value(_ f: IPTCField) -> String { UserDefaults.standard.string(forKey: "identity." + f.rawValue) ?? "" }
    static func set(_ f: IPTCField, _ v: String) { UserDefaults.standard.set(v, forKey: "identity." + f.rawValue) }
    static var values: [String: String] {
        var d: [String: String] = [:]
        for f in IPTCField.identity { let v = value(f); if !v.isEmpty { d[f.rawValue] = v } }
        return d
    }
}

/// Metadata presets (Aperture's "Basic Info"): a named set of fields applied in one go — from the Metadata menu,
/// Batch Change, or while importing.
@Observable
final class MetadataPresets {
    static let shared = MetadataPresets()
    struct Preset: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var name: String
        var values: [String: String]
    }
    /// "My Identity" comes from Settings ▸ Metadata, so it's always up to date.
    static let identityId = "identity"
    private(set) var presets: [Preset] = []
    init() {
        if let d = UserDefaults.standard.data(forKey: "meta.presets"), let p = try? JSONDecoder().decode([Preset].self, from: d) { presets = p }
    }
    var all: [Preset] {
        let id = Identity.values
        return (id.isEmpty ? [] : [Preset(id: Self.identityId, name: "My Identity (from Settings)", values: id)]) + presets
    }
    func preset(_ id: String) -> Preset? { all.first { $0.id == id } }
    func save(_ p: Preset) {
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        store()
    }
    func delete(_ id: String) { presets.removeAll { $0.id == id }; store() }
    private func store() { if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: "meta.presets") } }
    /// A preset from a photo's own IPTC fields and caption.
    func fromPhoto(_ p: Photo, name: String) -> Preset {
        var v = p.iptc
        if !p.caption.isEmpty { v["caption"] = p.caption }
        let pr = Preset(name: name, values: v)
        save(pr)
        return pr
    }
}

/// What the Inspector's Info section shows (Aperture's metadata views): a few built in, plus your own.
enum MetadataView: String, CaseIterable, Identifiable {
    case basic = "Basic", contact = "IPTC Contact", content = "IPTC Content & Location", iptc = "IPTC (all fields)", exif = "EXIF", custom = "Custom"
    var id: String { rawValue }
    var fields: [IPTCField] {
        switch self {
        case .basic: return [.title, .copyright]
        case .contact: return [.creator, .creatorJob, .email, .phone, .website, .copyright, .usageTerms]
        case .content: return [.title, .headline, .location, .city, .state, .country, .countryCode]
        case .iptc: return IPTCField.allCases
        case .exif: return []
        case .custom: return MetadataView.customFields
        }
    }
    static var customFields: [IPTCField] {
        get { (UserDefaults.standard.stringArray(forKey: "meta.custom") ?? ["title", "copyright"]).compactMap(IPTCField.init) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "meta.custom") }
    }
}

/// Lift & Stamp (Aperture): copy rating, label, keywords, caption, IPTC and location from one photo, stamp them onto others.
struct LiftedMetadata {
    var rating: Int, label: String?, keywords: [String], caption: String, iptc: [String: String], gps: Any?, place: Any?
    init(_ p: Photo) {
        rating = p.rating; label = p.label; keywords = p.keywords; caption = p.caption; iptc = p.iptc
        gps = p.raw["gps"]; place = p.raw["place"]
    }
    func stamp(_ ps: [Photo], lib: Library) {
        for p in ps {
            p.rating = rating; p.label = label; p.caption = caption
            for k in keywords where !p.keywords.contains(k) { p.keywords.append(k) }
            var d = p.iptc; for (k, v) in iptc { d[k] = v }
            if d.isEmpty { p.raw.removeValue(forKey: "iptc") } else { p.raw["iptc"] = d }
            if let gps { p.raw["gps"] = gps; p.raw["gpsManual"] = true; if let place { p.raw["place"] = place } else { p.raw.removeValue(forKey: "place") } }
        }
        lib.changed(ps, ["rating", "label", "keywords", "caption", "iptc", "gps", "place"])
    }
}

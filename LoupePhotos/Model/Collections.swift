import Foundation

/// One rule of a smart collection. Stored exactly as the Electron version stored it ({f, op, v}),
/// so a catalog opened in either app keeps its smart collections.
struct SmartRule: Hashable, Identifiable {
    var id = UUID()
    var f: String
    var op: String
    var v: String

    init(f: String, op: String, v: String) { self.f = f; self.op = op; self.v = v }
    init?(_ d: [String: Any]) {
        guard let f = d["f"] as? String else { return nil }
        self.f = f; op = d["op"] as? String ?? ""
        v = (d["v"] as? String) ?? (d["v"].map { "\($0)" } ?? "")
    }
    var dict: [String: Any] { ["f": f, "op": op, "v": v] }

    /// The fields a rule can test, with their operators (key, label), in menu order.
    static let fields: [(key: String, name: String, ops: [(String, String)])] = [
        ("rating", "Rating", [(">=", "is at least"), ("<=", "is at most"), ("=", "is")]),
        ("flag", "Flag", [("is", "is flagged"), ("not", "is not flagged")]),
        ("label", "Color Label", [("is", "is"), ("not", "is not"), ("any", "has any label"), ("none", "has no label")]),
        ("date", "Capture Date", [("last", "is in the last"), ("year", "is in year"), ("month", "is in month"), ("after", "is on or after"), ("before", "is before")]),
        ("keyword", "Keyword", [("has", "includes"), ("not", "doesn't include")]),
        ("place", "Place", [("has", "contains"), ("not", "doesn't contain")]),
        ("camera", "Camera", [("has", "contains")]),
        ("lens", "Lens", [("has", "contains")]),
        ("folder", "Folder", [("has", "contains")]),
        ("type", "File Type", [("is", "is")]),
        ("gps", "GPS Location", [("has", "is present"), ("not", "is missing")]),
        ("text", "Name or Caption", [("has", "contains")]),
        ("album", "Collection", [("in", "is in"), ("out", "is not in")]),
        ("rejected", "Rejected", [("is", "is rejected"), ("not", "is not rejected")]),
        ("person", "Person", [("is", "is"), ("not", "is not"), ("any", "has a named person"), ("none", "has no named people")]),
        ("search", "Search", [("finds", "finds close matches for"), ("finds1", "finds more matches for"), ("finds2", "finds even more for"), ("finds3", "finds the most for")]),
    ]
    static func make(_ f: String, firstCollection: String? = nil) -> SmartRule {
        let op = fields.first { $0.key == f }?.ops.first?.0 ?? ""
        let v: String
        switch f {
        case "rating": v = "3"
        case "label": v = "red"
        case "type": v = "RAW"
        case "date": v = "30"
        case "album": v = firstCollection ?? ""
        default: v = ""
        }
        return SmartRule(f: f, op: op, v: v)
    }

    func matches(_ p: Photo, _ lib: Library, _ pre: SmartPre? = nil) -> Bool {
        let s = v.lowercased()
        switch f {
        case "rating": let n = Int(v) ?? 0; return op == ">=" ? p.rating >= n : op == "<=" ? p.rating <= n : p.rating == n
        case "flag": return op == "is" ? p.flag : !p.flag
        case "rejected": return op == "is" ? p.rejected : !p.rejected
        case "label":
            switch op { case "is": return p.label == v; case "not": return p.label != v; case "any": return p.label != nil; default: return p.label == nil }
        case "date":
            let cal = Calendar.current
            switch op {
            case "last": return p.captureDate >= Date().addingTimeInterval(-Double(Int(v) ?? 0) * 86400)
            case "year": return cal.component(.year, from: p.captureDate) == Int(v)
            case "month": return cal.component(.month, from: p.captureDate) == Int(v)
            default:
                guard let t = SmartRule.dayFormat.date(from: v) else { return true }
                return op == "before" ? p.captureDate < t : p.captureDate >= t
            }
        case "keyword":
            let has = p.keywords.contains { k in let l = k.lowercased(); return l == s || l.hasPrefix(s + "/") || l.split(separator: "/").contains { $0 == s } }
            return op == "has" ? has : !has
        case "place": let has = p.placeLabel.lowercased().contains(s); return op == "has" ? has : !has
        case "camera": return p.camera.lowercased().contains(s)
        case "lens": return p.lens.lowercased().contains(s)
        case "folder": return p.path.lowercased().contains(s)
        case "type": return SmartRule.kind(p) == v || (v == "Other" && !["RAW", "HEIC", "JPEG", "PNG"].contains(SmartRule.kind(p)))
        case "gps": let has = p.raw["gps"] != nil; return op == "has" ? has : !has
        case "text": return (p.displayName + " " + p.caption).lowercased().contains(s)
        case "album": let has = lib.albums.first { $0.id == v }?.ids.contains(p.id) ?? false; return op == "in" ? has : !has
        case "person":
            if let pre {
                switch op {
                case "any": return pre.anyPerson?.contains(p.id) ?? false
                case "none": return !(pre.anyPerson?.contains(p.id) ?? false)
                default: let has = pre.person[v]?.contains(p.id) ?? false; return op == "not" ? !has : has
                }
            }
            let fi = FaceIndex.shared, here = fi.peopleIn(p.id)
            switch op {
            case "any": return !here.isEmpty
            case "none": return here.isEmpty
            default:
                let has = fi.person(named: v).map { here.contains($0.id) } ?? false
                return op == "not" ? !has : has
            }
        case "search":
            if let set = pre?.search[op + "|" + v] { return set.contains(p.id) }
            return NaturalSearch.shared.matchSet(v, loose: Int(op.dropFirst(5)) ?? 0, lib: lib).contains(p.id)
        default: return true
        }
    }
    /// The rule made ready once — numbers, dates and lower-cased text worked out before looking at any photo
    /// (a date rule parsed its date again for every one of 120,000 photos: seconds per smart collection).
    func compiled(_ lib: Library, _ pre: SmartPre?) -> (Photo) -> Bool {
        let v = self.v, op = self.op
        let s = v.lowercased()
        func has(_ text: String) -> Bool { s.isEmpty || text.range(of: s, options: .caseInsensitive) != nil }
        switch f {
        case "rating":
            let n = Int(v) ?? 0
            switch op { case ">=": return { $0.quickRating >= n }; case "<=": return { $0.quickRating <= n }; default: return { $0.quickRating == n } }
        case "flag": let want = op == "is"; return { $0.quickFlag == want }
        case "rejected": let want = op == "is"; return { $0.quickRejected == want }
        case "label":
            switch op { case "is": return { $0.quickLabel == v }; case "not": return { $0.quickLabel != v }; case "any": return { $0.quickLabel != nil }; default: return { $0.quickLabel == nil } }
        case "date":
            switch op {
            case "last": let cut = (Date().timeIntervalSince1970 - Double(Int(v) ?? 0) * 86400) * 1000; return { $0.quickDate >= cut }
            case "year": let y = Int(v); return { $0.ymd.y == y }
            case "month": let m = Int(v); return { $0.ymd.m == m }
            default:
                guard let t = SmartRule.dayFormat.date(from: v) else { return { _ in true } }
                let ms = t.timeIntervalSince1970 * 1000
                return op == "before" ? { $0.quickDate < ms } : { $0.quickDate >= ms }
            }
        case "keyword":
            let slash = s + "/", want = op == "has"
            return { p in
                let found = p.quickKeywords.contains { k in let l = k.lowercased(); return l == s || l.hasPrefix(slash) || l.split(separator: "/").contains { $0 == s } }
                return found == want
            }
        case "place": let want = op == "has"; return { p in has(p.placeLabel) == want }
        case "camera": return { has($0.quickCamera) }
        case "lens": return { has($0.quickLens) }
        case "folder": return { has($0.quickPath) }
        case "type": return { p in let k = SmartRule.kind(ext: p.quickExt); return k == v || (v == "Other" && k == "Other") }
        case "gps": let want = op == "has"; return { ($0.raw["gps"] != nil) == want }
        case "text":
            return { p in
                let n = p.quickName.isEmpty ? (p.quickFileName as NSString).deletingPathExtension : p.quickName
                return has(n) || has(p.quickCaption) || (s.contains(" ") && has(n + " " + p.quickCaption))
            }
        case "album":
            let ids = Set(lib.albums.first { $0.id == v }?.ids ?? []), want = op == "in"
            return { ids.contains($0.id) == want }
        default:
            // people and search: from the answers worked out beforehand (or, without them, the slow way)
            let rule = self
            return { rule.matches($0, lib, pre) }
        }
    }
    static func kind(ext: String) -> String {
        if Photo.rawExt.contains(ext) { return "RAW" }
        switch ext { case "heic", "heif": return "HEIC"; case "jpg", "jpeg": return "JPEG"; case "png": return "PNG"; default: return "Other" }
    }
    static func kind(_ p: Photo) -> String {
        if p.isRaw { return "RAW" }
        switch p.ext { case "heic", "heif": return "HEIC"; case "jpg", "jpeg": return "JPEG"; case "png": return "PNG"; default: return "Other" }
    }
    static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
}

/// Lightroom-style collections: Collection Sets (which only hold other collections), Collections and Smart Collections.
/// Stored as the catalog's "albums" (type "folder" = set, "album" = collection, "smart" = smart collection).
extension Library {
    func collection(_ id: String) -> Album? { albums.first { $0.id == id } }
    func children(of id: String?) -> [Album] {
        albums.filter { $0.parent == id && $0.id != Library.quickID }.sorted { a, b in
            // sets first, then collections, each alphabetical (like Lightroom)
            let ka = a.type == "folder" ? 0 : 1, kb = b.type == "folder" ? 0 : 1
            return ka != kb ? ka < kb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    /// "Albarracin › Best" — where a collection sits.
    func collectionPath(_ a: Album) -> String {
        var parts: [String] = [], p = a.parent
        while let id = p, let s = collection(id) { parts.insert(s.name, at: 0); p = s.parent }
        return parts.joined(separator: " › ")
    }
    /// A collection's rules made ready once, for testing many photos (safe off the main thread when the
    /// collection has no search or people rules, or when `pre` already holds their answers).
    func smartTest(_ a: Album, _ pre: SmartPre? = nil) -> (Photo) -> Bool {
        guard !a.rules.isEmpty else { return { _ in true } }
        let tests = a.rules.map { $0.compiled(self, pre) }
        if a.match == "any" { return { p in tests.contains { $0(p) } } }
        if tests.count == 1 { return tests[0] }
        return { p in tests.allSatisfy { $0(p) } }
    }
    func smartMatches(_ a: Album, _ p: Photo, _ pre: SmartPre? = nil) -> Bool {
        guard !a.rules.isEmpty else { return true }
        return a.match == "any" ? a.rules.contains { $0.matches(p, self, pre) } : a.rules.allSatisfy { $0.matches(p, self, pre) }
    }
    /// A collection's photos. Search and person rules are worked out once for the whole collection, not once per photo
    /// (a saved search was being looked up 120,000 times).
    func smartPhotos(_ a: Album) -> [Photo] {
        let pre = smartPre(a)
        let test = smartTest(a, pre)
        return photos.filter { $0.quickLive && test($0) }
    }
    /// Main thread only: search and people answers for this collection's rules.
    func smartPre(_ a: Album) -> SmartPre {
        var pre = SmartPre()
        for r in a.rules {
            switch r.f {
            case "search": pre.search[r.op + "|" + r.v] = NaturalSearch.shared.matchSet(r.v, loose: Int(r.op.dropFirst(5)) ?? 0, lib: self)
            case "person":
                let fi = FaceIndex.shared
                if r.op == "any" || r.op == "none" {
                    if pre.anyPerson == nil { pre.anyPerson = Set(fi.named.flatMap { fi.photoIds(person: $0.id) }) }
                } else { pre.person[r.v] = fi.person(named: r.v).map { fi.photoIds(person: $0.id) } ?? [] }
            default: break
            }
        }
        return pre
    }
    /// Does this collection need the main thread (search or people rules)?
    static func smartNeedsMain(_ a: Album) -> Bool { a.rules.contains { $0.f == "search" || $0.f == "person" } }

    @discardableResult
    func newCollection(type: String, name: String, parent: String?, ids: [Int] = [], rules: [SmartRule] = [], match: String = "all") -> Album {
        let a = Album(id: "a" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 1000...9999)),
                      type: type, name: name, parent: parent, ids: ids, match: match, rules: rules)
        albums.append(a); libChanged(); return a
    }
    func updateCollection(_ a: Album) {
        guard let i = albums.firstIndex(where: { $0.id == a.id }) else { return }
        albums[i] = a; libChanged()
    }
    func renameCollection(_ id: String, _ name: String) {
        guard let i = albums.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        albums[i].name = name.trimmingCharacters(in: .whitespaces); libChanged()
    }
    /// Deleting a set deletes everything inside it. Photos are never touched.
    func deleteCollection(_ id: String) {
        var gone = Set([id]), grew = true
        while grew { let n = gone.count; for a in albums where a.parent.map(gone.contains) == true { gone.insert(a.id) }; grew = gone.count > n }
        albums.removeAll { gone.contains($0.id) }; libChanged()
    }
    /// Moves a collection or set into a set (nil = top level). A set can't go inside itself.
    func moveCollection(_ id: String, into parent: String?) {
        guard let i = albums.firstIndex(where: { $0.id == id }), parent != id else { return }
        var p = parent
        while let x = p { if x == id { return }; p = collection(x)?.parent }
        albums[i].parent = parent; libChanged()
    }
    func removeFromCollection(_ id: String, _ ps: [Photo]) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        let gone = Set(ps.map(\.id))
        albums[i].ids.removeAll { gone.contains($0) }; libChanged()
    }
}

/// Answers for search and person rules, worked out once per collection.
struct SmartPre {
    var search: [String: Set<Int>] = [:]
    var person: [String: Set<Int>] = [:]
    var anyPerson: Set<Int>?
}

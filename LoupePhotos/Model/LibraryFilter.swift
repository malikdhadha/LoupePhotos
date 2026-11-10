import Foundation

/// Lightroom Classic's Library Filter: Text, Attribute and Metadata columns that narrow each other.
enum FilterTab: String, CaseIterable, Identifiable { case text = "Text", attribute = "Attribute", metadata = "Metadata"; var id: String { rawValue } }

enum MetaColumn: String, CaseIterable, Identifiable {
    case date = "Date", camera = "Camera", lens = "Lens", label = "Label", rating = "Rating", flag = "Pick Flag", keyword = "Keyword", fileType = "File Type", folder = "Folder", country = "Country", city = "City", people = "People"
    var id: String { rawValue }
}

struct LibraryFilter: Hashable {
    var tabs: Set<FilterTab> = []
    var text = ""
    var minRating = 0
    var flagged = false
    var labels: Set<String> = []
    var columns: [MetaColumn] = [.date, .camera, .lens, .label]
    var picks: [Set<String>] = [[], [], [], []]

    var isOn: Bool { !tabs.isEmpty }
    var isActive: Bool {
        (tabs.contains(.text) && !text.trimmingCharacters(in: .whitespaces).isEmpty) ||
        (tabs.contains(.attribute) && (minRating > 0 || flagged || !labels.isEmpty)) ||
        (tabs.contains(.metadata) && picks.contains { !$0.isEmpty })
    }

    static let none = "\u{0}none"
    static func values(_ c: MetaColumn, _ p: Photo) -> [String] {
        func one(_ s: String) -> [String] { s.isEmpty ? [none] : [s] }
        switch c {
        case .date:
            if p.quickNoDate { return ["nodate"] }
            let d = p.ymd; return ["y\(d.y)", "m\(d.y)-\(d.m)", "d\(d.y)-\(d.m)-\(d.d)"]
        case .camera: return one(p.quickCamera)
        case .lens: return one(p.quickLens)
        case .label: return one(PhotoLabel.find(p.quickLabel)?.name ?? "")
        case .rating: return [p.quickRating > 0 ? String(repeating: "★", count: p.quickRating) : none]
        case .flag: return [p.quickRejected ? "Rejected" : p.quickFlag ? "Flagged" : "Unflagged"]
        case .keyword: let k = p.quickKeywords; return k.isEmpty ? [none] : k.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        case .fileType: let e = p.quickExt; return [Photo.rawExt.contains(e) ? "RAW (\(e.uppercased()))" : e.uppercased()]
        case .folder: return [(p.quickDir as NSString).lastPathComponent]
        case .country: return one(p.place?["c"] as? String ?? "")
        case .city: return one(p.place?["t"] as? String ?? "")
        case .people:
            let fi = FaceIndex.shared
            let n = fi.peopleIn(p.id).compactMap { fi.people[$0]?.name }
            return n.isEmpty ? [none] : n
        }
    }
    static func noneName(_ c: MetaColumn) -> String {
        switch c { case .label: return "No Label"; case .rating: return "Unrated"; case .keyword: return "No Keywords"; case .country, .city: return "No Location"; case .people: return "No People"; default: return "Unknown" }
    }

    func textMatch(_ p: Photo) -> Bool { textMatch(p, words: textWords) }
    /// The filter's words, split once per pass rather than once per photo.
    var textWords: [String] { text.lowercased().split(separator: " ").map(String.init) }
    func textMatch(_ p: Photo, words: [String]) -> Bool {
        if words.isEmpty { return true }
        let t = p.searchText
        return words.allSatisfy { w in w.hasPrefix("!") ? !t.contains(w.dropFirst()) : t.contains(w) }
    }
    func attrMatch(_ p: Photo) -> Bool {
        if minRating > 0 && p.quickRating < minRating { return false }
        if flagged && !p.quickFlag { return false }
        if !labels.isEmpty && !labels.contains(p.quickLabel ?? "none") { return false }
        return true
    }
    func pickMatch(_ i: Int, _ p: Photo) -> Bool {
        guard i < picks.count, !picks[i].isEmpty else { return true }
        return !picks[i].isDisjoint(with: LibraryFilter.values(columns[i], p))
    }

    /// Photos before the metadata columns are applied.
    func base(_ l: [Photo]) -> [Photo] {
        guard isOn else { return l }
        let useText = tabs.contains(.text), useAttr = tabs.contains(.attribute), words = textWords
        return l.filter { (!useText || textMatch($0, words: words)) && (!useAttr || attrMatch($0)) }
    }
    func apply(_ l: [Photo]) -> [Photo] {
        guard isOn else { return l }
        let b = base(l)
        guard tabs.contains(.metadata) else { return b }
        return b.filter { p in columns.indices.allSatisfy { pickMatch($0, p) } }
    }
}

struct FilterRow: Identifiable { let id: String; let title: String; let count: Int; let level: Int; let expandable: Bool }

extension LibraryFilter {
    /// Rows for column i, counted from the photos left after the columns to its left.
    func rows(_ i: Int, from base: [Photo], expanded: Set<String>) -> (rows: [FilterRow], total: Int, distinct: Int) {
        var list = base
        for j in 0..<i { list = list.filter { pickMatch(j, $0) } }
        let col = columns[i]
        var counts: [String: Int] = [:]
        for p in list { for v in Set(LibraryFilter.values(col, p)) { counts[v, default: 0] += 1 } }
        for s in picks[i] where counts[s] == nil { counts[s] = 0 }
        if col == .date {
            let months = Calendar.current.monthSymbols
            var rows: [FilterRow] = []
            let years = counts.keys.filter { $0.hasPrefix("y") }.compactMap { Int($0.dropFirst()) }.sorted(by: >)
            for y in years {
                let yk = "y\(y)"
                rows.append(FilterRow(id: yk, title: String(y), count: counts[yk] ?? 0, level: 0, expandable: true))
                guard expanded.contains(yk) || picks[i].contains(where: { $0.hasPrefix("m\(y)-") || $0.hasPrefix("d\(y)-") }) else { continue }
                let ms = counts.keys.filter { $0.hasPrefix("m\(y)-") }.compactMap { Int($0.split(separator: "-").last ?? "") }.sorted()
                for m in ms {
                    let mk = "m\(y)-\(m)"
                    rows.append(FilterRow(id: mk, title: months[max(0, min(11, m - 1))], count: counts[mk] ?? 0, level: 1, expandable: true))
                    guard expanded.contains(mk) || picks[i].contains(where: { $0.hasPrefix("d\(y)-\(m)-") }) else { continue }
                    let ds = counts.keys.filter { $0.hasPrefix("d\(y)-\(m)-") }.compactMap { Int($0.split(separator: "-").last ?? "") }.sorted()
                    for d in ds {
                        let date = Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
                        rows.append(FilterRow(id: "d\(y)-\(m)-\(d)", title: "\(d) – \(date.formatted(.dateTime.weekday(.wide)))", count: counts["d\(y)-\(m)-\(d)"] ?? 0, level: 2, expandable: false))
                    }
                }
            }
            if let n = counts["nodate"] { rows.append(FilterRow(id: "nodate", title: "No Date", count: n, level: 0, expandable: false)) }
            return (rows, list.count, years.count)
        }
        let keys = counts.keys.filter { $0 != LibraryFilter.none }.sorted { a, b in
            if col == .rating { return a.count > b.count }
            if col == .label { return (PhotoLabel.all.firstIndex { $0.name == a } ?? 99) < (PhotoLabel.all.firstIndex { $0.name == b } ?? 99) }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        var rows = keys.map { FilterRow(id: $0, title: $0, count: counts[$0] ?? 0, level: 0, expandable: false) }
        if let n = counts[LibraryFilter.none] { rows.append(FilterRow(id: LibraryFilter.none, title: LibraryFilter.noneName(col), count: n, level: 0, expandable: false)) }
        return (rows, list.count, rows.count)
    }
}

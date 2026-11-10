import Foundation
import CoreLocation

/// Remembers where you were (source, view, current photo) so the app reopens there.
extension Source {
    var saved: String {
        switch self {
        case .all: return "all"
        case .flagged: return "flagged"
        case .recent: return "recent"
        case .rejected: return "rejected"
        case .days: return "days"
        case .noDate: return "noDate"
        case .onThisDay: return "onThisDay"
        case .unflagged: return "unflagged"
        case .folder(let p): return "folder:" + p
        case .album(let id): return "album:" + id
        case .decade(let d): return "decade:\(d)"
        case .date(let y, let m, let d): return "date:\(y),\(m ?? -1),\(d ?? -1)"
        case .place(let c, let t): return "place:" + c + "|" + (t ?? "")
        case .label(let id): return "label:" + id
        case .rating(let n): return "rating:\(n)"
        case .keyword(let k): return "keyword:" + k
        case .people: return "people"
        case .person(let id): return "person:\(id)"
        case .faceGroup(let g): return "faceGroup:\(g)"
        case .together(let k): return "together:" + k
        }
    }
    init?(saved s: String) {
        let (kind, rest) = s.firstIndex(of: ":").map { (String(s[..<$0]), String(s[s.index(after: $0)...])) } ?? (s, "")
        switch kind {
        case "all": self = .all
        case "flagged": self = .flagged
        case "recent": self = .recent
        case "rejected": self = .rejected
        case "days": self = .days
        case "noDate": self = .noDate
        case "onThisDay": self = .onThisDay
        case "unflagged": self = .unflagged
        case "folder": self = .folder(rest)
        case "album": self = .album(rest)
        case "decade": guard let d = Int(rest) else { return nil }; self = .decade(d)
        case "date":
            let n = rest.split(separator: ",").compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            self = .date(n[0], n[1] < 0 ? nil : n[1], n[2] < 0 ? nil : n[2])
        case "place":
            let p = rest.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            self = .place(p.first ?? "", p.count > 1 && !p[1].isEmpty ? p[1] : nil)
        case "label": self = .label(rest)
        case "rating": guard let n = Int(rest) else { return nil }; self = .rating(n)
        case "keyword": self = .keyword(rest)
        case "people": self = .people
        case "person": guard let n = Int(rest) else { return nil }; self = .person(n)
        case "faceGroup": guard let n = Int(rest) else { return nil }; self = .faceGroup(n)
        case "together": self = .together(rest)
        default: return nil
        }
    }
}

extension UIState {
    func rememberPlace() {
        let d = UserDefaults.standard
        d.set((source ?? .all).saved, forKey: "last.source")
        d.set(mode == .viewer && fullScreen ? ViewMode.viewer.rawValue : mode.rawValue, forKey: "last.mode")
        if let p = primary { d.set(p, forKey: "last.photo") }
    }
    /// Back to where you were last time — only if that folder, collection or photo still exists.
    func restorePlace(_ lib: Library) {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "last.source"), let src = Source(saved: s) {
            switch src {
            case .folder(let p): if lib.dirs.contains(p) || lib.isRoot(p) { source = src }
            case .album(let id): if lib.collection(id) != nil { source = src }
            default: source = src
            }
        }
        if let m = d.string(forKey: "last.mode").flatMap(ViewMode.init(rawValue:)) { mode = m }
        let id = d.integer(forKey: "last.photo")
        if id > 0, lib.byId[id] != nil, visible(lib).contains(where: { $0.id == id }) {
            primary = id; selection = [id]; scrollTarget = id
        }
    }

    /// Right-click ▸ Go to Folder: the photo's folder in the sidebar, with the photo picked.
    func goToFolder(_ p: Photo) {
        source = .folder(p.dir); mode = .browser; browse = .all
        primary = p.id; selection = [p.id]; scrollTarget = p.id
    }
    /// Right-click ▸ Show on Map.
    func showOnMap(_ p: Photo) {
        guard let c = Library.gps(p) else { return }
        primary = p.id; selection = [p.id]; mapPicks = [p.id]; mapUnplaced = false
        mapFocus = MapFocus(lat: c.latitude, lng: c.longitude, token: (mapFocus?.token ?? 0) + 1)
        mode = .map
    }
}

struct MapFocus: Equatable { let lat: Double; let lng: Double; let token: Int }

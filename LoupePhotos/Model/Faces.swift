import Foundation
import AppKit
import Vision
import CoreML
import CoreVideo
import Accelerate
import Observation

// MARK: - People: faces and the people they belong to

struct Face {
    let id: Int
    let photo: Int
    let rect: CGRect          // 0–1, top-left origin, in the photo as it was turned (`rot`) when scanned
    let rot: Int
    let quality: Float
    /// The fingerprint: 512 numbers, length 1 — similar faces have a dot product near 1. Kept at half precision
    /// (half the memory on a big library; matching is unchanged), widened when compared.
    let emb16: [Float16]
    var person: Int?
    var group: Int?           // an unnamed group (−1 = "not this person", left alone)
    var hasEmb: Bool { emb16.count == 512 }
    var emb: [Float] { emb16.map(Float.init) }
    init(id: Int, photo: Int, rect: CGRect, rot: Int, quality: Float, emb: [Float], person: Int? = nil, group: Int? = nil) {
        self.init(id: id, photo: photo, rect: rect, rot: rot, quality: quality, emb16: emb.map(Float16.init), person: person, group: group)
    }
    init(id: Int, photo: Int, rect: CGRect, rot: Int, quality: Float, emb16: [Float16], person: Int? = nil, group: Int? = nil) {
        self.id = id; self.photo = photo; self.rect = rect; self.rot = rot; self.quality = quality; self.emb16 = emb16; self.person = person; self.group = group
    }
}
struct Person: Identifiable, Hashable {
    let id: Int
    var name: String
    var keyFace: Int?
    var favorite = false
    var hidden = false
}

/// Everything known about faces, loaded from the catalog database, plus naming / merging.
@Observable
final class FaceIndex {
    static let shared = FaceIndex()
    private(set) var faces: [Int: Face] = [:]
    private(set) var people: [Int: Person] = [:]
    var version = 0
    @ObservationIgnored private(set) var byPhoto: [Int: [Int]] = [:]
    /// Each person's faces and each unnamed group's faces, kept up to date as faces move — so counts, key faces and
    /// photo lists don't have to look through every face in the library.
    @ObservationIgnored private(set) var byPerson: [Int: Set<Int>] = [:]
    @ObservationIgnored private(set) var byGroup: [Int: Set<Int>] = [:]
    private func index(_ f: Face, _ on: Bool) {
        if let p = f.person { if on { byPerson[p, default: []].insert(f.id) } else { byPerson[p]?.remove(f.id) } }
        else if let g = f.group { if on { byGroup[g, default: []].insert(f.id) } else { byGroup[g]?.remove(f.id) } }
    }
    private func reindex() { byPerson = [:]; byGroup = [:]; for f in faces.values { index(f, true) } }
    @ObservationIgnored var scanned = Set<Int>()
    @ObservationIgnored var notPerson: [Int: Set<Int>] = [:]      // face → people it isn't
    @ObservationIgnored var nextFaceId = 1
    @ObservationIgnored var nextPersonId = 1
    @ObservationIgnored var nextGroupId = 1
    /// Faces you've hidden (strangers, posters, crowds) — never offered for naming.
    var hiddenFaces = Set<Int>()
    /// Faces put with someone automatically (face → person), until you check them.
    var autoFaces: [Int: Int] = [:]
    @ObservationIgnored var autoScores: [Int: Float] = [:]      // how sure it was (very sure ones become examples)
    /// People ▸ View ▸ Show Background Faces: small, blurry or turned-away faces are left out of Unnamed and suggestions unless this is on.
    var showBackground = UserDefaults.standard.bool(forKey: "faces.showBackground") { didSet { UserDefaults.standard.set(showBackground, forKey: "faces.showBackground"); version += 1 } }
    /// How many suggestions each person has (worked out in the background).
    var suggestionCounts: [Int: Int] = [:]
    @ObservationIgnored var countKey: [Int: Int] = [:]
    @ObservationIgnored var allCountsKey = -1
    @ObservationIgnored var countsBusy = false
    @ObservationIgnored var countsAt: Date?
    @ObservationIgnored var countsQueued = false
    @ObservationIgnored var autoKey = ""                 // what the automatic naming last compared against
    @ObservationIgnored var autoCounts: [Int: Int] = [:] // how many examples each person had then
    @ObservationIgnored var autoHidden = 0               // and how many faces were hidden
    @ObservationIgnored var dateCache: (n: Int, at: Date, d: [Int: Double])?   // photo → when it was taken (for matching off the main thread)
    @ObservationIgnored var autoSeen = Set<Int>()        // faces already compared with those examples
    @ObservationIgnored var autoWork: DispatchWorkItem?
    @ObservationIgnored var autoDue: Date?
    @ObservationIgnored var autoBusy = false
    @ObservationIgnored var autoAgain = false

    static let groupThreshold: Float = 0.45      // join an unnamed group
    static let personThreshold: Float = 0.50     // be put with someone you've named
    static let minGroupSize = 3                  // smaller groups aren't offered as "Unnamed"

    func load(_ db: CatalogDB) {
        var fs: [Int: Face] = [:], bp: [Int: [Int]] = [:]
        var maxF = 0, maxG = 0
        for r in db.readFaces() {
            let emb = r.emb.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            guard emb.count == 512 || emb.isEmpty else { continue }      // empty = a name added by hand
            fs[r.id] = Face(id: r.id, photo: r.photo, rect: CGRect(x: r.x, y: r.y, width: r.w, height: r.h), rot: r.rot, quality: Float(r.q), emb16: emb, person: r.person, group: r.grp)
            bp[r.photo, default: []].append(r.id)
            maxF = max(maxF, r.id); maxG = max(maxG, r.grp ?? 0)
        }
        var ps: [Int: Person] = [:]
        for p in db.readPeople() { ps[p.id] = Person(id: p.id, name: p.name, keyFace: p.key, favorite: p.fav, hidden: p.hidden) }
        let sc = db.readScanned(), np = db.readNotPerson(), hf = db.readHiddenFaces(), af = db.readAutoFaces()
        DispatchQueue.main.async {
            let t0 = CFAbsoluteTimeGetCurrent()
            defer { Timing.note("faces loaded (main thread): \(fs.count) faces", since: t0, always: true) }
            self.faces = fs; self.byPhoto = bp; self.people = ps; self.scanned = sc; self.notPerson = np
            self.reindex()
            Timing.note("  faces: indexes", since: t0)
            self.hiddenFaces = hf
            let live = af.filter { fs[$0.key]?.person == $0.value.person }
            self.autoFaces = live.mapValues { $0.person }; self.autoScores = live.mapValues { $0.score }
            self.nextFaceId = maxF + 1; self.nextGroupId = maxG + 1; self.nextPersonId = (ps.keys.max() ?? 0) + 1
            let t1 = CFAbsoluteTimeGetCurrent()
            Clusterer.shared.rebuild(fs.values.map { $0 })
            Timing.note("  faces: groups", since: t1)
            self.version += 1
            let t2 = CFAbsoluteTimeGetCurrent()
            FaceScanner.shared.start(Library.shared)               // then look at any photos not scanned yet
            Timing.note("  faces: scanner start", since: t2)
            self.scheduleAuto(Library.shared)
        }
    }
    func reset() { faces = [:]; byPhoto = [:]; byPerson = [:]; byGroup = [:]; people = [:]; scanned = []; hiddenFaces = []; autoFaces = [:]; suggestionCounts = [:]; countKey = [:]; version += 1 }

    /// New faces from the scanner (main thread).
    func add(_ new: [Face], scannedPhotos: [Int]) {
        for f in new { faces[f.id] = f; byPhoto[f.photo, default: []].append(f.id); index(f, true) }
        scanned.formUnion(scannedPhotos)
    }
    func apply(_ a: [(id: Int, person: Int?, grp: Int?)]) {
        let patch = ppKey == version                  // who's-in-each-photo is up to date: fix just these photos
        var touched = Set<Int>()
        for x in a {
            guard let old = faces[x.id] else { continue }
            index(old, false)
            faces[x.id]?.person = x.person; faces[x.id]?.group = x.grp
            if let f = faces[x.id] { index(f, true) }
            touched.insert(old.photo)
        }
        version += 1
        if patch {
            for ph in touched {
                let ps = Set((byPhoto[ph] ?? []).compactMap { faces[$0]?.person })
                if ps.isEmpty { ppCache.removeValue(forKey: ph) } else { ppCache[ph] = ps }
            }
            ppKey = version
        }
    }

    // MARK: what the views show
    func photoIds(person: Int) -> Set<Int> { Set((byPerson[person] ?? []).compactMap { faces[$0]?.photo }) }
    func photoIds(group: Int) -> Set<Int> { Set((byGroup[group] ?? []).compactMap { faces[$0] }.filter { !self.isQuiet($0) }.map(\.photo)) }
    func faceIds(person: Int) -> [Int] { (byPerson[person] ?? []).compactMap { faces[$0] }.sorted { $0.quality > $1.quality }.map(\.id) }
    func faceIds(group: Int) -> [Int] { (byGroup[group] ?? []).compactMap { faces[$0] }.filter { !isQuiet($0) }.sorted { $0.quality > $1.quality }.map(\.id) }
    /// All the faces of one person (no sorting), for the matching.
    func faces(ofPerson p: Int) -> [Face] { (byPerson[p] ?? []).compactMap { faces[$0] } }
    /// Named people, favourites first, then A–Z.
    var named: [Person] { sorted(people.values.filter { !$0.hidden }) }
    var hiddenPeople: [Person] { sorted(people.values.filter(\.hidden)) }
    /// People ▸ Sort: by Name, by Number of Photos, or your own Custom Order (drag to the side of someone to place before/after).
    var sortMode: String = UserDefaults.standard.string(forKey: "people.sort") ?? "name" { didSet { UserDefaults.standard.set(sortMode, forKey: "people.sort") } }
    var customOrder: [Int] = UserDefaults.standard.array(forKey: "people.order") as? [Int] ?? [] { didSet { UserDefaults.standard.set(customOrder, forKey: "people.order") } }
    private func sorted(_ ps: [Person]) -> [Person] {
        switch sortMode {
        case "count":
            let n = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, count(person: $0.id)) })
            return ps.sorted { (n[$0.id] ?? 0, $1.name.lowercased()) > (n[$1.id] ?? 0, $0.name.lowercased()) }
        case "custom":
            let pos = Dictionary(customOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return ps.sorted { (pos[$0.id] ?? Int.max, $0.name.lowercased()) < (pos[$1.id] ?? Int.max, $1.name.lowercased()) }
        default: return ps.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
    /// Custom order: put `id` just before (or after) `target`.
    func move(_ id: Int, nextTo target: Int, after: Bool) {
        var order = sorted(people.values.filter { !$0.hidden }).map(\.id)
        order.removeAll { $0 == id }
        let i = (order.firstIndex(of: target) ?? order.count) + (after ? 1 : 0)
        order.insert(id, at: min(i, order.count))
        customOrder = order; sortMode = "custom"; version += 1
    }
    /// Unnamed groups worth offering, biggest first: (group, face count, best face).
    var unnamed: [(group: Int, count: Int, face: Int)] {
        var by: [Int: (Int, Int, Float)] = [:]
        for (g, ids) in byGroup where g > 0 && ids.count >= FaceIndex.minGroupSize {
            for id in ids {
                guard let f = faces[id], f.person == nil, !isQuiet(f) else { continue }
                let cur = by[g] ?? (0, f.id, -1)
                by[g] = (cur.0 + 1, f.quality > cur.2 ? f.id : cur.1, max(cur.2, f.quality))
            }
        }
        return by.filter { $0.value.0 >= FaceIndex.minGroupSize }.map { (group: $0.key, count: $0.value.0, face: $0.value.1) }.sorted { $0.count > $1.count }
    }
    func count(person: Int) -> Int { photoIds(person: person).count }
    func keyFace(_ p: Person) -> Int? { p.keyFace.flatMap { faces[$0] != nil ? $0 : nil } ?? faceIds(person: p.id).first }
    func person(named n: String) -> Person? { people.values.first { $0.name.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } }

    // MARK: naming, merging, fixing
    /// Names an unnamed group. If someone already has that name, the group joins them.
    @discardableResult
    func name(group g: Int, as raw: String, lib: Library) -> Int? {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        let pid: Int
        if let existing = person(named: n) { pid = existing.id }
        else {
            pid = nextPersonId; nextPersonId += 1
            people[pid] = Person(id: pid, name: n, keyFace: faceIds(group: g).first)
            save(people[pid]!, lib)
        }
        let a = (byGroup[g] ?? []).compactMap { faces[$0] }.filter { $0.person == nil }.map { (id: $0.id, person: Optional(pid), grp: Optional<Int>.none) }
        commit(a, lib)
        return pid
    }
    func rename(_ id: Int, to raw: String, lib: Library) {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, var p = people[id] else { return }
        if let other = person(named: n), other.id != id { merge(id, into: other.id, lib: lib); return }
        p.name = n; people[id] = p; save(p, lib); version += 1
        syncKeywords(lib, only: photoIds(person: id))
    }
    /// Everyone in `a` becomes `b` (drag one person onto another, or give two people the same name).
    func merge(_ a: Int, into b: Int, lib: Library) {
        guard a != b, people[b] != nil else { return }
        let moves = self.faces(ofPerson: a).map { (id: $0.id, person: Optional(b), grp: Optional<Int>.none) }
        people.removeValue(forKey: a)
        lib.dbWrite { $0.deletePerson(a) }
        commit(moves, lib)
    }
    /// "This isn't them": the faces in these photos leave the person and aren't put back automatically.
    func remove(photos: Set<Int>, from person: Int, lib: Library) {
        let a = self.faces(ofPerson: person).filter { photos.contains($0.photo) }.map { (id: $0.id, person: Optional<Int>.none, grp: Optional(-1)) }
        rejectFaces(a.map(\.id), from: person, lib: lib)
        let wasCounted = countKey[person] == version
        commit(a, lib)
        // taking faces off someone can't give them more suggestions (those faces are now "not them"), so their
        // "Review N" number stays right without comparing every unnamed face again — the lag after "This isn't"
        if wasCounted { countKey[person] = version }
    }
    /// Remembers that these faces aren't this person, so they're never suggested again.
    func rejectFaces(_ ids: [Int], from person: Int, lib: Library) {
        for f in ids { notPerson[f, default: []].insert(person) }
        let pairs = ids.map { (face: $0, person: person) }
        lib.dbWrite { $0.addNotPerson(pairs) }
    }

    // MARK: merging groups and people together
    /// Unnamed groups and people dropped onto a person all become that person.
    func merge(keys: [String], into pid: Int, lib: Library) {
        var a: [(id: Int, person: Int?, grp: Int?)] = []
        for k in keys {
            if k.hasPrefix("g"), let g = Int(k.dropFirst()) {
                a += (byGroup[g] ?? []).compactMap { faces[$0] }.filter { $0.person == nil }.map { (id: $0.id, person: Optional(pid), grp: Optional<Int>.none) }
            } else if k.hasPrefix("p"), let p = Int(k.dropFirst()), p != pid {
                a += self.faces(ofPerson: p).map { (id: $0.id, person: Optional(pid), grp: Optional<Int>.none) }
                people.removeValue(forKey: p)
                lib.dbWrite { $0.deletePerson(p) }
            }
        }
        commit(a, lib)
    }
    /// Unnamed groups dropped onto another unnamed group join it.
    func mergeGroups(_ keys: [String], into g: Int, lib: Library) {
        var a: [(id: Int, person: Int?, grp: Int?)] = []
        for k in keys where k.hasPrefix("g") { if let x = Int(k.dropFirst()), x != g { a += (byGroup[x] ?? []).compactMap { faces[$0] }.filter { $0.person == nil }.map { (id: $0.id, person: Optional<Int>.none, grp: Optional(g)) } } }
        commit(a, lib)
    }
    /// Names several groups (and people) at once.
    @discardableResult
    func name(keys: [String], as raw: String, lib: Library) -> Int? {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !keys.isEmpty else { return nil }
        let pid: Int
        if let existing = person(named: n) { pid = existing.id }
        else if let first = keys.first(where: { $0.hasPrefix("p") }), let p = Int(first.dropFirst()), var pp = people[p] {
            pid = p; pp.name = n; people[p] = pp; save(pp, lib)
        } else {
            pid = nextPersonId; nextPersonId += 1
            let firstGroup = keys.first { $0.hasPrefix("g") }.flatMap { Int($0.dropFirst()) }
            people[pid] = Person(id: pid, name: n, keyFace: firstGroup.flatMap { faceIds(group: $0).first })
            save(people[pid]!, lib)
        }
        merge(keys: keys, into: pid, lib: lib)
        return pid
    }
    /// Names already used, best matches first (for the suggestions under a name box).
    func names(matching t: String) -> [String] {
        let q = t.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let all = people.values.map(\.name)
        let starts = all.filter { $0.lowercased().hasPrefix(q) || $0.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } }
        let has = all.filter { $0.lowercased().contains(q) && !starts.contains($0) }
        return Array((starts.sorted() + has.sorted()).prefix(6))
    }

    // MARK: who's in each photo
    @ObservationIgnored var keywordPhotos = Set<Int>()
    @ObservationIgnored var keywordWork: DispatchWorkItem?
    @ObservationIgnored private var ppKey = -1
    @ObservationIgnored private var ppCache: [Int: Set<Int>] = [:]
    /// Named people in a photo.
    func peopleIn(_ photo: Int) -> Set<Int> {
        if ppKey != version {
            var c: [Int: Set<Int>] = [:]
            for f in faces.values { if let p = f.person { c[f.photo, default: []].insert(p) } }
            ppCache = c; ppKey = version
        }
        return ppCache[photo] ?? []
    }
    func nameText(_ photo: Int) -> String { peopleIn(photo).compactMap { people[$0]?.name }.joined(separator: " ").lowercased() }
    func faces(inPhoto id: Int) -> [Face] { (byPhoto[id] ?? []).compactMap { faces[$0] } }

    /// Groups (like Apple Photos): the same two to four named people together in several photos.
    var groups: [(people: [Int], count: Int, cover: Int)] {
        var count: [[Int]: (Int, Int, Float)] = [:]
        _ = peopleIn(-1)
        for (photo, ps) in ppCache where ps.count >= 2 && ps.count <= 4 {
            let key = ps.sorted()
            guard key.allSatisfy({ !(people[$0]?.hidden ?? true) }) else { continue }
            let q = faces(inPhoto: photo).filter { $0.person != nil }.map(\.quality).reduce(0, +)
            let cur = count[key] ?? (0, photo, -1)
            count[key] = (cur.0 + 1, q > cur.2 ? photo : cur.1, max(cur.2, q))
        }
        return count.filter { $0.value.0 >= 3 }.map { (people: $0.key, count: $0.value.0, cover: $0.value.1) }.sorted { $0.count > $1.count }
    }
    func photoIds(together ps: [Int]) -> Set<Int> {
        _ = peopleIn(-1)
        let want = Set(ps)
        return Set(ppCache.filter { want.isSubset(of: $0.value) }.keys)
    }
    func groupName(_ ps: [Int]) -> String {
        let n = ps.compactMap { people[$0]?.name.split(separator: " ").first.map(String.init) }
        return n.count <= 2 ? n.joined(separator: " and ") : n.dropLast().joined(separator: ", ") + " and " + (n.last ?? "")
    }

    /// Puts a name on one face (from the Inspector or the Viewer's face boxes).
    func setFace(_ fid: Int, toName raw: String, lib: Library) {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let pid = personId(for: n, keyFace: fid, lib: lib)
        commit([(id: fid, person: Optional(pid), grp: Optional<Int>.none)], lib)
    }
    /// The + in the Inspector: says someone is in a photo even where no face was found.
    func addManual(_ raw: String, photo: Photo, lib: Library) {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let pid = personId(for: n, keyFace: nil, lib: lib)
        if peopleIn(photo.id).contains(pid) { return }
        let f = Face(id: nextFaceId, photo: photo.id, rect: .zero, rot: photo.rot, quality: 0, emb: [], person: pid, group: nil)
        nextFaceId += 1
        faces[f.id] = f; byPhoto[photo.id, default: []].append(f.id); index(f, true)
        lib.dbWrite { $0.saveScan([.init(id: f.id, photo: f.photo, x: 0, y: 0, w: 0, h: 0, rot: f.rot, q: 0, emb: Data(), person: pid, grp: nil)], photos: []) }
        version += 1; lib.facesChanged([photo.id])
        syncKeywords(lib, only: [photo.id])
    }
    private func personId(for n: String, keyFace: Int?, lib: Library) -> Int {
        if let p = person(named: n) { return p.id }
        let pid = nextPersonId; nextPersonId += 1
        people[pid] = Person(id: pid, name: n, keyFace: keyFace)
        save(people[pid]!, lib)
        return pid
    }

    // MARK: names as keywords (People › Name), so Lightroom and other apps see them
    static var keywordsOn: Bool { UserDefaults.standard.object(forKey: "faces.keywords") as? Bool ?? true }
    /// Brings every photo's "People/…" keywords in line with who's in it. Only touches names Loupe Photos manages.
    func syncKeywords(_ lib: Library, only: Set<Int>? = nil) {
        guard FaceIndex.keywordsOn else { return }
        var managed = Set(UserDefaults.standard.stringArray(forKey: "faces.managedNames") ?? [])
        let current = Set(people.values.map(\.name))
        managed.formUnion(current)
        UserDefaults.standard.set(Array(managed), forKey: "faces.managedNames")
        var touched: [Photo] = []
        let which: [Photo] = only.map { $0.compactMap { lib.byId[$0] } } ?? lib.photos     // just the photos that changed, when known
        for p in which {
            let want = Set(peopleIn(p.id).compactMap { people[$0].map { "People/" + $0.name } })
            let have = Set(p.keywords.filter { $0.hasPrefix("People/") && managed.contains(String($0.dropFirst(7))) })
            guard want != have else { continue }
            p.keywords.removeAll { have.contains($0) && !want.contains($0) }
            for k in want.subtracting(have).sorted() { p.keywords.append(k) }
            touched.append(p)
        }
        if !touched.isEmpty { lib.changed(touched, ["keywords"]); lib.markAutomatic() }
    }

    // MARK: Summary — a person's best photos across the years (like Apple Photos)
    func summaryPhotoIds(person pid: Int, lib: Library, limit: Int = 60) -> Set<Int> {
        let fs = self.faces(ofPerson: pid)
        guard fs.count > limit else { return Set(fs.map(\.photo)) }
        // best face per photo, bucketed by month, then taken round-robin so every period is represented
        var best: [Int: Float] = [:]
        for f in fs { best[f.photo] = max(best[f.photo] ?? 0, f.quality) }
        var buckets: [Int: [(Int, Float)]] = [:]
        for (p, q) in best {
            guard let ph = lib.byId[p], !ph.rejected else { continue }
            let d = ph.ymd; buckets[d.y * 100 + d.m, default: []].append((p, q + Float(ph.rating) * 0.05 + (ph.flag ? 0.1 : 0)))
        }
        var lists = buckets.keys.sorted().map { buckets[$0]!.sorted { $0.1 > $1.1 } }
        var out = Set<Int>(), i = 0
        while out.count < limit && lists.contains(where: { !$0.isEmpty }) {
            for k in lists.indices where !lists[k].isEmpty && out.count < limit {
                if i < lists[k].count { out.insert(lists[k][i].0) }
            }
            i += 1
            if lists.allSatisfy({ i >= $0.count }) { break }
        }
        lists.removeAll()
        return out
    }
    func forget(_ id: Int, lib: Library) {      // Remove name: the faces go back to being an unnamed group
        let g = nextGroupId; nextGroupId += 1
        let a = self.faces(ofPerson: id).map { (id: $0.id, person: Optional<Int>.none, grp: Optional(g)) }
        people.removeValue(forKey: id)
        lib.dbWrite { $0.deletePerson(id) }
        commit(a, lib)
    }
    func setFavorite(_ id: Int, _ on: Bool, lib: Library) { guard var p = people[id] else { return }; p.favorite = on; people[id] = p; save(p, lib); version += 1 }
    func setHidden(_ id: Int, _ on: Bool, lib: Library) { guard var p = people[id] else { return }; p.hidden = on; people[id] = p; save(p, lib); version += 1 }
    func setKeyFace(_ face: Int, lib: Library) {
        guard let pid = faces[face]?.person, var p = people[pid] else { return }
        p.keyFace = face; people[pid] = p; save(p, lib); version += 1
    }

    private func save(_ p: Person, _ lib: Library) { lib.dbWrite { $0.savePerson(id: p.id, name: p.name, key: p.keyFace, fav: p.favorite, hidden: p.hidden) } }
    func commit(_ a: [(id: Int, person: Int?, grp: Int?)], _ lib: Library, auto: Bool = false) {
        if !auto {
            // your own decisions: no longer "added automatically"
            let cleared = a.map(\.id).filter { autoFaces[$0] != nil }
            if !cleared.isEmpty { for f in cleared { autoFaces.removeValue(forKey: f); autoScores.removeValue(forKey: f) }; lib.dbWrite { $0.removeAutoFaces(cleared) } }
        }
        // the unnamed groups' running fingerprints follow the faces that moved (no full rebuild)
        let moves: [(emb: [Float], from: Int?, to: Int?)] = a.compactMap { x in
            guard let f = faces[x.id], f.hasEmb else { return nil }
            let from = f.person == nil ? f.group : nil, to = x.person == nil ? x.grp : nil
            return from == to ? nil : (f.emb, from, to)
        }
        apply(a)
        Clusterer.shared.move(moves)
        lib.dbWrite { $0.setAssignments(a) }
        let photos = Set(a.compactMap { faces[$0.id]?.photo })
        lib.facesChanged(photos)                             // lists showing people refresh; the sidebar and folders don't
        // the People › Name keywords follow a moment later, all at once (so a quick run of answers stays quick)
        keywordPhotos.formUnion(photos)
        keywordWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.keywordPhotos; self.keywordPhotos = []
            self.syncKeywords(lib, only: ids)
        }
        keywordWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        if !auto { scheduleAuto(lib) }                       // what you decided may let more faces be named
    }
}

// MARK: - Grouping

/// Puts each new face with the named person or unnamed group it's most like — or starts a new group.
/// Keeps one running average fingerprint per person and per group, so it stays quick as the library grows.
final class Clusterer {
    static let shared = Clusterer()
    private let q = DispatchQueue(label: "faces.cluster")
    private var keys: [(isPerson: Bool, id: Int)] = []
    private var sums: [[Float]] = []
    private var counts: [Int] = []
    private var index: [String: Int] = [:]

    /// From scratch (when the library opens): one running fingerprint per unnamed group. Named people are matched
    /// against their own photos instead (FaceIndex.autoAssign), so they aren't kept here.
    func rebuild(_ all: [Face]) {
        let groups = all.compactMap { f -> ([Float16], Int)? in guard f.person == nil, let g = f.group, g > 0, f.hasEmb else { return nil }; return (f.emb16, g) }
        q.async {
            self.keys = []; self.sums = []; self.counts = []; self.index = [:]
            for (e, g) in groups { self.add(e.map(Float.init), false, g) }
        }
    }
    /// Faces moving between groups (or to / from people): adjusts just those groups' running fingerprints.
    func move(_ moves: [(emb: [Float], from: Int?, to: Int?)]) {
        guard !moves.isEmpty else { return }
        q.async {
            for m in moves {
                if let g = m.from, g > 0, let i = self.index["g\(g)"] { vDSP.subtract(self.sums[i], m.emb, result: &self.sums[i]); self.counts[i] -= 1 }
                if let g = m.to, g > 0 { self.add(m.emb, false, g) }
            }
        }
    }
    private func add(_ e: [Float], _ isPerson: Bool, _ id: Int) {
        guard e.count == 512 else { return }
        let k = "\(isPerson ? "p" : "g")\(id)"
        if let i = index[k] { vDSP.add(sums[i], e, result: &sums[i]); counts[i] += 1 }
        else { index[k] = keys.count; keys.append((isPerson, id)); sums.append(e); counts.append(1) }
    }
    /// Returns who each face goes to. `nextGroup` hands out new group numbers.
    func assign(_ fs: [Face], nextGroup: @escaping () -> Int, done: @escaping ([(id: Int, person: Int?, grp: Int?)]) -> Void) {
        q.async {
            var out: [(id: Int, person: Int?, grp: Int?)] = []
            for f in fs {
                var bestP: (Int, Float) = (-1, -2), bestG: (Int, Float) = (-1, -2)
                for (i, k) in self.keys.enumerated() where self.counts[i] > 0 {
                    let n = sqrt(vDSP.sumOfSquares(self.sums[i]))
                    let s = vDSP.dot(f.emb, self.sums[i]) / max(n, 1e-6)
                    if k.isPerson { if s > bestP.1 { bestP = (k.id, s) } } else if s > bestG.1 { bestG = (k.id, s) }
                }
                _ = bestP          // named people: FaceIndex.autoAssign compares with their own photos instead
                if bestG.1 >= FaceIndex.groupThreshold { out.append((f.id, nil, bestG.0)); self.add(f.emb, false, bestG.0) }
                else { let g = DispatchQueue.main.sync { nextGroup() }; out.append((f.id, nil, g)); self.add(f.emb, false, g) }
            }
            DispatchQueue.main.async { done(out) }
        }
    }
}

// MARK: - Finding faces

/// Looks for faces in every photo once (in the background, pausable), using Apple's Vision to find them
/// and AuraFace (on the Neural Engine) to fingerprint them. Works from the camera's preview, never the RAW itself.
final class FaceScanner {
    static let shared = FaceScanner()
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.375, min: 2, max: 3); q.qualityOfService = .utility; return q }()
    private let lock = NSLock()
    private var generation = 0
    /// Which face-recognition model fingerprints faces (Settings ▸ People). Changing it means starting over,
    /// because fingerprints from different models can't be compared.
    ///   "AuraFace"  — Apache-2.0 licence, fine to share the app with anyone.
    ///   "Glint100"  — InsightFace glintr100: more accurate (especially across ages), personal / non-commercial use.
    static var modelName: String { UserDefaults.standard.string(forKey: "faces.model") ?? "AuraFace" }
    static func available(_ name: String) -> Bool { Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil }
    private var models: [String: MLModel] = [:]
    private let modelLock = NSLock()
    private func model(_ name: String) -> MLModel? {          // call with modelLock held
        if let m = models[name] { return m }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { NSLog("\(name) model missing"); return nil }
        let c = MLModelConfiguration(); c.computeUnits = .all
        let m = try? MLModel(contentsOf: url, configuration: c)
        models[name] = m
        return m
    }

    /// Scans every photo not looked at yet.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "faces.enabled") as? Bool ?? true }
    func start(_ lib: Library) {
        guard lib.db != nil, FaceScanner.enabled else { return }
        let idx = FaceIndex.shared
        let todo = lib.photos.filter { $0.deleted == nil && !$0.missing && !idx.scanned.contains($0.id) }
        guard !todo.isEmpty else { return }
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        queue.cancelAllOperations()
        let total = todo.count, done = ManagedCounter()
        let pause: (Bool) -> Void = { [weak self] on in guard let self else { return }; self.userPaused = on; self.queue.isSuspended = on || self.held }
        Activity.shared.report("faces", "Finding faces", done: 0, total: total, pause: pause)
        // work in small batches so results reach the People view as they come
        for chunk in stride(from: 0, to: todo.count, by: 12).map({ Array(todo[$0..<min(todo.count, $0 + 12)]) }) {
            let shots = chunk.map { (id: $0.id, rot: $0.rot, p: $0) }
            queue.addOperation { [weak self] in
                guard let self else { return }
                self.lock.lock(); let live = gen == self.generation; self.lock.unlock()
                guard live else { return }
                var found: [(Int, Int, [(CGRect, Float, [Float])])] = []
                for s in shots { autoreleasepool { found.append((s.id, s.rot, self.faces(in: s.p, rot: s.rot))) } }
                DispatchQueue.main.async {
                    let idx = FaceIndex.shared
                    var new: [Face] = [], rows: [CatalogDB.FaceRow] = []
                    for (pid, rot, fs) in found {
                        for (r, q, e) in fs {
                            let f = Face(id: idx.nextFaceId, photo: pid, rect: r, rot: rot, quality: q, emb: e)
                            idx.nextFaceId += 1
                            new.append(f)
                            let half = e.map { Float16($0) }
                            rows.append(.init(id: f.id, photo: pid, x: r.minX, y: r.minY, w: r.width, h: r.height, rot: rot, q: Double(q),
                                              emb: half.withUnsafeBufferPointer { Data(buffer: $0) }, person: nil, grp: nil))
                        }
                    }
                    let scannedIds = found.map { ($0.0, $0.2.count) }
                    idx.add(new, scannedPhotos: scannedIds.map(\.0))
                    lib.dbWrite { $0.saveScan(rows, photos: scannedIds) }
                    if !new.isEmpty {
                        Clusterer.shared.assign(new, nextGroup: { let g = idx.nextGroupId; idx.nextGroupId += 1; return g }) { a in
                            idx.apply(a)
                            lib.dbWrite { $0.setAssignments(a) }
                            idx.scheduleAuto(lib, delay: 30, throttle: true)   // while scanning: name every 30 s, in bigger batches
                        }
                    }
                    let n = done.add(shots.count)
                    Activity.shared.report("faces", "Finding faces", done: n, total: total, pause: pause)
                    // let the People view catch up now and then — as a faces change, so the grid, sidebar and lists aren't rebuilt
                    if n >= total { lib.status = "Found faces in your photos — see People in the sidebar." ; lib.facesChanged(Set(scannedIds.map(\.0))); idx.scheduleAuto(lib, delay: 2) }
                    else if n % 240 < 12 { lib.facesChanged(Set(scannedIds.map(\.0))) }
                }
            }
        }
    }
    func stop() { lock.lock(); generation += 1; lock.unlock(); queue.cancelAllOperations(); userPaused = false; queue.isSuspended = held; Activity.shared.finish("faces") }
    /// Held back by BackgroundWork (thumbnails first, and not while you're scrolling). Your own Pause stays as you set it.
    private var userPaused = false, held = false
    func hold(_ on: Bool) { guard held != on else { return }; held = on; queue.isSuspended = userPaused || held }

    /// The faces in one photo: where (0–1, top-left), how good, and the fingerprint.
    func faces(in p: Photo, rot: Int) -> [(CGRect, Float, [Float])] {
        guard let d = detect(p, rot: rot) else { return [] }
        let name = FaceScanner.modelName
        return d.faces.compactMap { f in embed(d.image, f.points, model: name).map { (f.rect, f.quality, $0) } }
    }

    /// The faces Vision finds in one photo: where (0–1, top-left), how good, and the five points used to straighten them.
    func detect(_ p: Photo, rot: Int) -> (image: CGImage, faces: [(rect: CGRect, quality: Float, points: [CGPoint])])? {
        guard var img = Embedded.render(p, max: 1600, minLong: 900) else { return nil }
        if rot % 4 != 0, let r = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)).rotated(rot).cgImage(forProposedRect: nil, context: nil, hints: nil) { img = r }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let marks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        guard (try? handler.perform([marks])) != nil, let obs = marks.results, !obs.isEmpty else { return (img, []) }
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = obs
        try? handler.perform([quality])
        let qs = quality.results ?? []
        var out: [(rect: CGRect, quality: Float, points: [CGPoint])] = []
        for (i, o) in obs.enumerated() {
            let b = o.boundingBox
            guard b.height * H >= 36 else { continue }                          // too small to recognise
            let q = (i < qs.count ? qs[i].faceCaptureQuality : nil) ?? 0.3
            guard q >= 0.12, let lm = o.landmarks, let pts = fivePoints(lm, W, H) else { continue }
            out.append((CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), q, pts))
        }
        return (img, out)
    }

    /// Eyes, nose and mouth corners in image pixels (top-left origin), as AuraFace's alignment expects.
    private func fivePoints(_ lm: VNFaceLandmarks2D, _ W: CGFloat, _ H: CGFloat) -> [CGPoint]? {
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let r, r.pointCount > 0 else { return nil }
            return r.pointsInImage(imageSize: CGSize(width: W, height: H)).map { CGPoint(x: $0.x, y: H - $0.y) }
        }
        func mid(_ p: [CGPoint]) -> CGPoint { CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count)) }
        guard let le = pts(lm.leftEye), let re = pts(lm.rightEye), let lips = pts(lm.outerLips) else { return nil }
        let nosePts = pts(lm.nose) ?? pts(lm.noseCrest)
        guard let nosePts else { return nil }
        var e1 = mid(le), e2 = mid(re)
        if e1.x > e2.x { swap(&e1, &e2) }                                     // image-left eye first
        let ax = CGPoint(x: e2.x - e1.x, y: e2.y - e1.y)
        let proj = lips.map { ($0, $0.x * ax.x + $0.y * ax.y) }
        guard let m1 = proj.min(by: { $0.1 < $1.1 })?.0, let m2 = proj.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return [e1, e2, mid(nosePts), m1, m2]
    }

    /// The 112×112 face, straightened to AuraFace's template, through the model → a length-1 fingerprint.
    private static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
                                              CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)]
    func embed(_ img: CGImage, _ src: [CGPoint], model name: String) -> [Float]? {
        // best-fit rotation + scale + shift (a similarity transform) from the face's points to the template
        let dst = FaceScanner.template
        let n = CGFloat(src.count)
        let mx = src.map(\.x).reduce(0, +) / n, my = src.map(\.y).reduce(0, +) / n
        let mu = dst.map(\.x).reduce(0, +) / n, mv = dst.map(\.y).reduce(0, +) / n
        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let xs = s.x - mx, ys = s.y - my, us = d.x - mu, vs = d.y - mv
            num1 += xs * us + ys * vs; num2 += xs * vs - ys * us; den += xs * xs + ys * ys
        }
        guard den > 0 else { return nil }
        let a = num1 / den, b = num2 / den
        let t = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: mu - (a * mx - b * my), ty: mv - (b * mx + a * my))

        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: 112); ctx.scaleBy(x: 1, y: -1)               // work top-left, like the points
            ctx.concatenate(t)
            ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        modelLock.lock(); defer { modelLock.unlock() }
        guard let net = self.model(name), let input = try? MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: pb)]),
              let out = try? net.prediction(from: input), let arr = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: arr.count)
        for i in 0..<arr.count { v[i] = arr[i].floatValue }
        let norm = sqrt(vDSP.sumOfSquares(v))
        guard norm > 0, v.count == 512 else { return nil }
        return vDSP.divide(v, norm)
    }
}

extension ManagedCounter {
    func add(_ k: Int) -> Int { var n = 0; for _ in 0..<k { n = increment() }; return n }
}

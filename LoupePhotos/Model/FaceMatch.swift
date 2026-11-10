import Foundation
import Accelerate

/// Matching faces to people by comparing with *their own photos* (the closest few), not one average face —
/// so a child at 2 and at 8 are both recognised. Confident matches are named automatically (and listed
/// under "Added Automatically" to check); the unsure ones come to Review, grouped so one click answers many.
extension FaceIndex {
    static let suggestFloor: Float = 0.30       // worth asking about
    static let autoThreshold: Float = 0.55      // sure enough to name without asking…
    static let autoMargin: Float = 0.08         // …and clearly more like this person than anyone else
    static let maxExamples = 160                // per person, spread across the years

    // MARK: background faces and hidden faces
    /// Small, blurry or turned-away faces (people in the background).
    static func isBackground(_ f: Face) -> Bool {
        guard f.hasEmb else { return false }
        return f.quality < 0.22 || max(f.rect.width, f.rect.height) < 0.04
    }
    /// Left out of Unnamed and suggestions: hidden by you, or a background face (unless Show Background Faces is on).
    func isQuiet(_ f: Face) -> Bool { hiddenFaces.contains(f.id) || (!showBackground && FaceIndex.isBackground(f)) }

    func hide(faces ids: [Int], _ on: Bool, lib: Library) {
        guard !ids.isEmpty else { return }
        if on { hiddenFaces.formUnion(ids) } else { hiddenFaces.subtract(ids) }
        lib.dbWrite { $0.setHiddenFaces(ids, on) }
        version += 1
        lib.facesChanged(Set(ids.compactMap { faces[$0]?.photo }))
    }
    func hide(group g: Int, lib: Library) { hide(faces: (byGroup[g] ?? []).filter { faces[$0]?.person == nil }.sorted(), true, lib: lib) }

    // MARK: a copy of what matching needs, so it runs off the main thread
    /// Everything the matching reads, copied on the main thread (cheap — Swift shares it until something changes)
    /// so preparing and scoring never hold up the window.
    struct Snap {
        let faces: [Int: Face], byPerson: [Int: Set<Int>], auto: [Int: Int], autoScores: [Int: Float]
        let hidden: Set<Int>, notPerson: [Int: Set<Int>], dates: [Int: Double], showBackground: Bool, model: String
        func quiet(_ f: Face) -> Bool { hidden.contains(f.id) || (!showBackground && FaceIndex.isBackground(f)) }
        func date(_ photo: Int) -> Double { dates[photo] ?? .nan }
        func of(_ pid: Int) -> [Face] { (byPerson[pid] ?? []).compactMap { faces[$0] } }
    }
    func snap() -> Snap {
        let lib = Library.shared
        // made again only when photos come or go, or a capture date is changed (Library.changed clears it)
        if dateCache == nil || dateCache!.n != lib.photos.count {
            var d: [Int: Double] = [:]; d.reserveCapacity(lib.photos.count)
            for p in lib.photos where !p.quickNoDate { d[p.id] = p.quickDate }
            dateCache = (lib.photos.count, Date(), d)
        }
        return Snap(faces: faces, byPerson: byPerson, auto: autoFaces, autoScores: autoScores, hidden: hiddenFaces,
                    notPerson: notPerson, dates: dateCache!.d, showBackground: showBackground, model: FaceScanner.modelName)
    }

    // MARK: examples of each person
    static let strongAuto: Float = 0.68         // automatic matches this sure also become examples (it learns as you shoot)
    /// Up to `maxExamples` faces of someone, spread across time: the ones you've confirmed,
    /// plus (up to as many again) automatic matches it was very sure of. Kept until their faces change.
    static func examples(_ s: Snap, _ pid: Int) -> (key: String, ex: [(emb: [Float], date: Double)]) {
        let all = s.of(pid).filter { $0.hasEmb && !s.hidden.contains($0.id) }
        let mine = all.filter { s.auto[$0.id] == nil }
        let strong = all.filter { s.auto[$0.id] != nil && (s.autoScores[$0.id] ?? 0) >= strongAuto }
        func sig(_ fs: [Face]) -> String { "\(fs.count).\(fs.reduce(0) { $0 &+ $1.id &* 2_654_435_761 })" }
        let key = "\(pid):\(s.model):\(sig(mine)):\(sig(strong))"
        return (key, MatchCache.shared.examples(pid, key) {
            // evenly through time within a group
            func even(_ fs: [Face], _ n: Int) -> [Face] {
                guard fs.count > n else { return fs }
                let byTime = fs.map { ($0, s.dates[$0.photo] ?? 0) }.sorted { $0.1 < $1.1 }.map(\.0)
                let step = Double(byTime.count) / Double(n)
                return (0..<n).map { byTime[Int(Double($0) * step)] }
            }
            /// Year by year: every year of someone's life gets its share of examples, not just the years with the most
            /// photos (a child's baby years were outnumbered by recent ones, so baby faces had little to compare with).
            func spread(_ fs: [Face], _ n: Int) -> [Face] {
                guard fs.count > n else { return fs }
                let year = 365.25 * 86_400_000.0
                var byYear: [Int: [Face]] = [:]
                for f in fs { let d = s.dates[f.photo]; byYear[d.map { Int($0 / year) } ?? Int.min, default: []].append(f) }
                // share the places out equally; years with fewer photos give their spare places to the others
                var left = n, open = byYear.keys.sorted(), quota: [Int: Int] = [:]
                while left > 0 && !open.isEmpty {
                    let each = max(1, left / open.count)
                    var still: [Int] = []
                    for y in open {
                        let want = byYear[y]!.count - (quota[y] ?? 0)
                        let give = min(want, each, left)
                        quota[y, default: 0] += give; left -= give
                        if byYear[y]!.count > quota[y]! { still.append(y) }
                        if left == 0 { break }
                    }
                    open = still
                }
                return byYear.flatMap { even($0.value, quota[$0.key] ?? 0) }
            }
            let a = spread(mine, FaceIndex.maxExamples)
            let b = spread(strong, min(a.count, FaceIndex.maxExamples - a.count / 2))
            return (a + b).map { (emb: $0.emb, date: s.date($0.photo)) }
        })
    }

    /// Everyone's examples as one matrix (512 × E, a column per example), whose each column is, and when it was taken.
    struct Bank { var t: [Float]; var owner: [Int]; var date: [Double]; var count: Int; var key = "" }
    static func bank(_ s: Snap, _ pids: [Int]) -> Bank {
        var cols: [[Float]] = [], owner: [Int] = [], dates: [Double] = [], keys: [String] = []
        for p in pids.sorted() { let (k, ex) = examples(s, p); keys.append(k); cols += ex.map { $0.emb }; dates += ex.map { $0.date }; owner += Array(repeating: p, count: ex.count) }
        let E = cols.count
        var t = [Float](repeating: 0, count: 512 * E)
        t.withUnsafeMutableBufferPointer { tp in
            for (j, c) in cols.enumerated() { for i in 0..<512 { tp[i * E + j] = c[i] } }
        }
        return Bank(t: t, owner: owner, date: dates, count: E, key: keys.joined(separator: ","))
    }

    /// For each face: every person's score — the average of its two closest examples of them, where examples taken
    /// near the same time count a little more (children change; their face last year matters more than as a baby).
    static func scores(_ embs: [[Float]], dates: [Double], _ bank: Bank) -> [[Int: Float]] {
        let E = bank.count
        guard E > 0, !embs.isEmpty else { return embs.map { _ in [:] } }
        // each person gets a slot 0..<P, so the two best per person live in plain arrays (a dictionary update for
        // every face × example pair was most of the time: seconds of CPU each pass with a big library)
        var slotOf: [Int: Int] = [:], persons: [Int] = []
        let slot: [Int] = bank.owner.map { p in
            if let s = slotOf[p] { return s }
            slotOf[p] = persons.count; persons.append(p); return persons.count - 1
        }
        let P = persons.count
        var out: [[Int: Float]] = []; out.reserveCapacity(embs.count)
        let chunk = 256, invYear = 1 / (365.25 * 86_400_000.0)
        var a = [Float](repeating: 0, count: chunk * 512)
        var c = [Float](repeating: 0, count: chunk * E)
        var b1 = [Float](repeating: -2, count: P), b2 = [Float](repeating: -2, count: P)
        var start = 0
        while start < embs.count {
            let m = min(chunk, embs.count - start)
            a.withUnsafeMutableBufferPointer { ap in
                for r in 0..<m { embs[start + r].withUnsafeBufferPointer { e in for i in 0..<min(512, e.count) { ap[r * 512 + i] = e[i] } } }
            }
            vDSP_mmul(a, 1, bank.t, 1, &c, 1, vDSP_Length(m), vDSP_Length(E), 512)
            c.withUnsafeBufferPointer { cp in
                bank.date.withUnsafeBufferPointer { dp in
                    slot.withUnsafeBufferPointer { sp in
                        b1.withUnsafeMutableBufferPointer { t1 in
                            b2.withUnsafeMutableBufferPointer { t2 in
                                for r in 0..<m {
                                    let d = dates[start + r], hasD = !d.isNaN
                                    for k in 0..<P { t1[k] = -2; t2[k] = -2 }
                                    let row = r * E
                                    for j in 0..<E {
                                        var s = cp[row + j]
                                        let dj = dp[j]
                                        if hasD && !dj.isNaN {                    // up to +0.08 for an example from the same time, fading over two years
                                            let gap = abs(d - dj) * invYear       // (a child's face at the same age matters most)
                                            if gap < 2 { s += Float(0.08 * (1 - gap / 2)) }
                                        }
                                        let k = sp[j]
                                        if s > t1[k] { t2[k] = t1[k]; t1[k] = s } else if s > t2[k] { t2[k] = s }
                                    }
                                    var o = [Int: Float](minimumCapacity: P)
                                    for k in 0..<P where t1[k] > -2 { o[persons[k]] = t2[k] > -2 ? (t1[k] + t2[k]) / 2 : t1[k] }
                                    out.append(o)
                                }
                            }
                        }
                    }
                }
            }
            start += m
        }
        return out
    }

    /// The context around each face, gathered on the main thread so the matching can run in the background.
    struct MatchJob {
        let ids: [Int], embs: [[Float]], dates: [Double], photos: [Int]
        let alreadyIn: [Int: Set<Int>]          // photo → people already named in it (no one is in a photo twice)
        let times: [Int: [Double]]              // person → when their photos were taken, sorted
        let bank: Bank
        /// Scores with the same-shoot boost: if someone is already in several photos taken within three hours, a face
        /// in that shoot that looks like them gets up to +0.06. Someone already named in the same photo is left out.
        func run() -> [[Int: Float]] {
            let raw = FaceIndex.scores(embs, dates: dates, bank)
            let window = 3 * 3_600_000.0
            return raw.enumerated().map { i, sc in
                var out: [Int: Float] = [:]
                let here = alreadyIn[photos[i]] ?? []
                for (p, v) in sc where !here.contains(p) {
                    var boost: Float = 0
                    if !dates[i].isNaN, let ts = times[p], !ts.isEmpty {
                        let n = FaceIndex.countWithin(ts, dates[i] - window, dates[i] + window)
                        boost = n >= 10 ? 0.06 : n >= 3 ? 0.04 : n >= 1 ? 0.02 : 0
                    }
                    out[p] = v + boost
                }
                return out
            }
        }
    }
    static func countWithin(_ sorted: [Double], _ lo: Double, _ hi: Double) -> Int {
        func lower(_ x: Double) -> Int { var a = 0, b = sorted.count; while a < b { let m = (a + b) / 2; if sorted[m] < x { a = m + 1 } else { b = m } }; return a }
        return lower(hi.nextUp) - lower(lo)
    }
    static func job(_ s: Snap, _ cands: [Face], people pids: [Int]) -> MatchJob {
        var times: [Int: [Double]] = [:]
        var inPhoto: [Int: Set<Int>] = [:]
        let candPhotos = Set(cands.map(\.photo))
        for p in pids {
            for id in s.byPerson[p] ?? [] {
                guard let f = s.faces[id] else { continue }
                if candPhotos.contains(f.photo) { inPhoto[f.photo, default: []].insert(p) }
                if let d = s.dates[f.photo] { times[p, default: []].append(d) }
            }
        }
        for k in times.keys { times[k]!.sort() }
        return MatchJob(ids: cands.map(\.id), embs: cands.map(\.emb), dates: cands.map { s.date($0.photo) }, photos: cands.map(\.photo),
                        alreadyIn: inPhoto, times: times, bank: bank(s, pids))
    }

    /// Learned from your own people (E1): how sure it must be to name each person automatically, and how alike a face
    /// must be to be worth asking about. Comes from how much each person's examples look like everyone else you've
    /// named (siblings need more, someone distinctive less) and from the faces you've said aren't them.
    struct Calibration {
        var limits: [Int: Float]; var floor: Float
        /// People whose face changed a lot over the years (children): when their photos begin, and the stricter
        /// level for faces from their first four years (baby faces look alike, siblings most of all).
        var young: [Int: (start: Double, limit: Float)] = [:]
    }
    static let youngYears = 4.0
    static let youngMargin: Float = 0.12
    static func calibrate(_ s: Snap, _ bank: Bank, _ pids: [Int]) -> Calibration {
        // faces you've turned down, per person (the clearest sign of where look-alikes score)
        var rejected: [Int: [Int]] = [:]
        let want = Set(pids)
        for (f, ps) in s.notPerson { for p in ps where want.contains(p) { rejected[p, default: []].append(f) } }
        let rkey = rejected.keys.sorted().map { "\($0):\(rejected[$0]!.count)" }.joined(separator: ",")
        return MatchCache.shared.calibration(bank.key + "|" + rkey) { thresholds(bank, rejected: rejected, s) }
    }
    static func thresholds(_ bank: Bank, rejected: [Int: [Int]], _ s: Snap) -> Calibration {
        let E = bank.count
        var out: [Int: Float] = [:]
        guard E > 1 else { for p in Set(bank.owner) { out[p] = autoThreshold }; return Calibration(limits: out, floor: suggestFloor) }
        // examples as rows (E × 512) from the column matrix
        var rows = [Float](repeating: 0, count: E * 512)
        for j in 0..<E { for i in 0..<512 { rows[j * 512 + i] = bank.t[i * E + j] } }
        var impostor: [Int: [Float]] = [:]
        var everyone: [Float] = []; everyone.reserveCapacity(E)
        // dense person slots (as in scores) instead of a dictionary update per pair
        var slotOf: [Int: Int] = [:]
        let slot: [Int] = bank.owner.map { p in if let s = slotOf[p] { return s }; let s = slotOf.count; slotOf[p] = s; return s }
        let P = slotOf.count
        var b1 = [Float](repeating: -2, count: P), b2 = [Float](repeating: -2, count: P)
        let chunk = 256
        var c = [Float](repeating: 0, count: chunk * E)
        var start = 0
        while start < E {
            let m = min(chunk, E - start)
            rows.withUnsafeBufferPointer { r in
                vDSP_mmul(r.baseAddress! + start * 512, 1, bank.t, 1, &c, 1, vDSP_Length(m), vDSP_Length(E), 512)
            }
            for r in 0..<m {
                let me = slot[start + r]
                for k in 0..<P { b1[k] = -2; b2[k] = -2 }
                let row = r * E
                for j in 0..<E {
                    let k = slot[j]
                    if k == me { continue }
                    let v = c[row + j]
                    if v > b1[k] { b2[k] = b1[k]; b1[k] = v } else if v > b2[k] { b2[k] = v }
                }
                var worst: Float = -.infinity, any = false
                for k in 0..<P where b1[k] > -2 { any = true; worst = max(worst, b2[k] > -2 ? (b1[k] + b2[k]) / 2 : b1[k]) }
                if !any { worst = 0 }
                let me0 = bank.owner[start + r]
                impostor[me0, default: []].append(worst)
                everyone.append(worst)
            }
            start += m
        }
        func pct(_ v: [Float], _ q: Double) -> Float { v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count) * q))] }
        everyone.sort()
        // never surer than the model's own spread allows: above nearly every look-alike among the people you've named
        let lowest = min(0.62, max(0.50, pct(everyone, 0.99) + 0.02))
        // who changed a lot with age: their earliest year's examples look little like their latest year's
        let year = 365.25 * 86_400_000.0
        var firstSeen: [Int: Double] = [:]
        for p in Set(bank.owner) {
            let cols = (0..<E).filter { bank.owner[$0] == p && !bank.date[$0].isNaN }
            guard let lo = cols.map({ bank.date[$0] }).min(), let hi = cols.map({ bank.date[$0] }).max(), hi - lo >= 3 * year else { continue }
            let early = cols.filter { bank.date[$0] < lo + year }.prefix(40), late = cols.filter { bank.date[$0] > hi - year }.prefix(40)
            guard !early.isEmpty, !late.isEmpty else { continue }
            var sum: Float = 0, n = 0
            for a in early { for b in late { var d: Float = 0; for i in 0..<512 { d += bank.t[i * E + a] * bank.t[i * E + b] }; sum += d; n += 1 } }
            if sum / Float(n) < 0.45 { firstSeen[p] = lo }
        }
        // faces you said aren't someone: how much they looked like that person (for children, young and older apart)
        var rejectedScore: [Int: Float] = [:], rejectedYoung: [Int: Float] = [:]
        for (p, ids) in rejected {
            let fs = Array(ids.compactMap { s.faces[$0] }.filter(\.hasEmb).prefix(2000))
            guard fs.count >= 3 else { continue }
            let ds = fs.map { s.date($0.photo) }
            let sc = scores(fs.map(\.emb), dates: ds, bank)
            var old: [Float] = [], young: [Float] = []
            for (i, x) in sc.enumerated() {
                guard let v = x[p] else { continue }
                if let st = firstSeen[p], !ds[i].isNaN, ds[i] - st < youngYears * year { young.append(v) } else { old.append(v) }
            }
            if old.count >= 3 { rejectedScore[p] = pct(old.sorted(), 0.9) }
            if young.count >= 3 { rejectedYoung[p] = pct(young.sorted(), 0.9) }
        }
        var young: [Int: (start: Double, limit: Float)] = [:]
        for p in Set(bank.owner) {
            let v = (impostor[p] ?? []).sorted()
            var t = min(0.65, max(lowest, pct(v, 0.9) + 0.10))
            if let r = rejectedScore[p] { t = max(t, min(0.75, r + 0.03)) }
            out[p] = t
            if let st = firstSeen[p] {
                var y = min(0.78, t + 0.03)
                if let r = rejectedYoung[p] { y = max(y, min(0.80, r + 0.03)) }
                young[p] = (st, y)
            }
        }
        // worth asking about: at least as alike as a typical look-alike (never looser than 0.30, never stricter than 0.42)
        let floor = min(0.42, max(suggestFloor, pct(everyone, 0.5)))
        return Calibration(limits: out, floor: floor, young: young)
    }
    /// The learned "worth asking about" level for the current model (0.30 until it has learned one).
    static var floorNow: Float {
        let v = UserDefaults.standard.float(forKey: "faces.floor." + FaceScanner.modelName)
        return v > 0 ? v : suggestFloor
    }

    // MARK: Review — unsure faces for one person, best first
    /// Faces that might be this person, with how alike they are (closest first). `done` runs on the main thread.
    func loadSuggestions(for pid: Int, limit: Int = 150, done: @escaping ([(face: Int, score: Float)]) -> Void) {
        let s = snap()
        DispatchQueue.global(qos: .userInitiated).async {
            let cands = s.faces.values.filter { $0.person == nil && $0.hasEmb && !s.quiet($0) && !(s.notPerson[$0.id]?.contains(pid) ?? false) }
            let j = FaceIndex.job(s, cands, people: [pid])
            let sc = j.run(), floor = FaceIndex.floorNow
            var out: [(face: Int, score: Float)] = []
            for (i, x) in sc.enumerated() { if let v = x[pid], v >= floor { out.append((j.ids[i], v)) } }
            out.sort { $0.score > $1.score }
            let total = out.count
            DispatchQueue.main.async {
                // anything you answered while it was working stays answered
                let fresh = out.filter { self.faces[$0.face]?.person == nil && !(self.notPerson[$0.face]?.contains(pid) ?? false) }
                self.suggestionCounts[pid] = total - (out.count - fresh.count)
                done(Array(fresh.prefix(limit)))
            }
        }
    }
    /// Keeps the "Review N Suggestions" number up to date (cheap to call often).
    func refreshCount(_ pid: Int) {
        guard countKey[pid] != version else { return }
        countKey[pid] = version
        loadSuggestions(for: pid, limit: 0) { _ in }
    }
    /// Everyone's "to review" numbers in one pass (for People ▸ Review All).
    func refreshAllCounts() {
        guard allCountsKey != version else { return }
        // during a face scan, recount at most every 20 seconds (it changes after every batch)
        if Activity.shared.jobs.contains(where: { $0.id == "faces" }), let t = countsAt, Date().timeIntervalSince(t) < 20 {
            if !countsQueued {
                countsQueued = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 20 - Date().timeIntervalSince(t)) { [weak self] in self?.countsQueued = false; self?.refreshAllCounts() }
            }
            return
        }
        countsAt = Date()
        if countsBusy { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshAllCounts() }; return }
        let pids = named.map(\.id)
        guard !pids.isEmpty else { return }
        allCountsKey = version
        countsBusy = true
        let v = version
        let s = snap()
        DispatchQueue.global(qos: .utility).async {
            let cands = s.faces.values.filter { $0.person == nil && $0.hasEmb && !s.quiet($0) }
            var counts: [Int: Int] = [:]
            if !cands.isEmpty {
                let j = FaceIndex.job(s, cands, people: pids)
                let sc = j.run(), floor = FaceIndex.floorNow
                for (i, x) in sc.enumerated() {
                    for (p, val) in x where val >= floor && !(s.notPerson[j.ids[i]]?.contains(p) ?? false) { counts[p, default: 0] += 1 }
                }
            }
            DispatchQueue.main.async {
                self.countsBusy = false
                for p in pids where self.suggestionCounts[p] != (counts[p] ?? 0) { self.suggestionCounts[p] = counts[p] ?? 0 }
                for p in pids { self.countKey[p] = v }
            }
        }
    }
    func autoFaceIds(person pid: Int) -> [Int] { autoFaces.filter { $0.value == pid }.map(\.key).sorted { (faces[$0]?.quality ?? 0) > (faces[$1]?.quality ?? 0) } }

    /// The answers from Review: yes → them, no → never suggest them again, hide → out of People.
    /// When checking automatic ones, "no" also takes the face back off them.
    func review(yes: [Int], no: [Int], hide: [Int], person pid: Int, checkingAuto: Bool, lib: Library) {
        rejectFaces(no, from: pid, lib: lib)
        var a = yes.filter { faces[$0]?.person == nil || faces[$0]?.person == pid }.map { (id: $0, person: Optional(pid), grp: Optional<Int>.none) }
        if checkingAuto { a += no.map { (id: $0, person: Optional<Int>.none, grp: Optional(-1)) } }
        a += hide.filter { faces[$0]?.person == pid }.map { (id: $0, person: Optional<Int>.none, grp: Optional(-1)) }
        self.hide(faces: hide, true, lib: lib)
        commit(a, lib)
    }

    /// Like-looking faces together (each row of Review), keeping the closest-first order.
    static func rows(_ list: [(face: Int, score: Float)], _ faces: [Int: Face]) -> [[Int]] {
        var leaders: [[Float]] = [], rows: [[Int]] = []
        for (f, _) in list {
            guard let e = faces[f]?.emb, e.count == 512 else { continue }
            var best = -1, bs: Float = 0.45
            for (i, l) in leaders.enumerated() { let s = vDSP.dot(l, e); if s > bs { bs = s; best = i } }
            if best >= 0 { rows[best].append(f) } else { leaders.append(e); rows.append([f]) }
        }
        // faces with no look-alikes share one last row, so the window isn't a long list of single faces
        let singles = rows.filter { $0.count == 1 }.flatMap { $0 }
        var out = rows.filter { $0.count > 1 }
        if !singles.isEmpty { out.append(singles) }
        return out
    }

    // MARK: naming automatically
    /// Looks again soon (several changes in a row are handled once).
    /// `throttle`: if a run is already due, leave it be (so a stream of calls runs every `delay`, not never).
    func scheduleAuto(_ lib: Library, delay: Double = 1, throttle: Bool = false) {
        if throttle, let due = autoDue, due > Date() { return }
        autoWork?.cancel()
        autoDue = Date().addingTimeInterval(delay)
        let w = DispatchWorkItem { [weak self] in self?.autoDue = nil; self?.autoAssign(lib) }
        autoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    /// Names every face that's clearly one of your people. They're listed under the person as "Added Automatically" to check.
    func autoAssign(_ lib: Library) {
        guard FaceScanner.enabled, lib.db != nil else { return }
        if autoBusy { autoAgain = true; return }
        // who has examples, and how many
        var counts: [Int: Int] = [:]
        for pid in people.keys {
            let n = (byPerson[pid] ?? []).reduce(0) { $0 + ((faces[$1]?.hasEmb ?? false) && (autoFaces[$1] == nil || (autoScores[$1] ?? 0) >= FaceIndex.strongAuto) ? 1 : 0) }
            if n > 0 { counts[pid] = n }
        }
        let pids = Array(counts.keys)
        guard !pids.isEmpty else { return }
        // Compare every face again only when someone gained examples (or the model, background setting or hidden faces
        // changed back). Taking faces off someone ("This isn't them") can't make other faces look more like them,
        // so then only faces it hasn't compared yet are looked at.
        let ctx = "\(showBackground)|\(FaceScanner.modelName)"
        let grew = ctx != autoKey || hiddenFaces.count < autoHidden || counts.contains { $0.value > (autoCounts[$0.key] ?? 0) }
        if grew { autoSeen = [] }
        autoKey = ctx; autoCounts = counts; autoHidden = hiddenFaces.count
        let seen = autoSeen
        let s = snap()
        autoBusy = true
        DispatchQueue.global(qos: .utility).async {
            let cands = s.faces.values.filter { $0.person == nil && $0.hasEmb && !s.quiet($0) && !seen.contains($0.id) }
            var picks: [(face: Int, person: Int, score: Float)] = []
            var floor: Float?
            if !cands.isEmpty {
                let j = FaceIndex.job(s, cands, people: pids)
                let cal = FaceIndex.calibrate(s, j.bank, pids)
                floor = cal.floor
                let sc = j.run()
                var taken: [Int: Set<Int>] = [:]                 // photo → people named in it this round
                let order = sc.indices.sorted { (sc[$0].values.max() ?? 0) > (sc[$1].values.max() ?? 0) }
                for i in order {
                    let ranked = sc[i].sorted { $0.value > $1.value }
                    guard let top = ranked.first else { continue }
                    // a child's first years: a closer match and a clearer lead are needed (unsure ones go to Review)
                    var limit = cal.limits[top.key] ?? FaceIndex.autoThreshold, margin = FaceIndex.autoMargin
                    if let y = cal.young[top.key], !j.dates[i].isNaN, j.dates[i] - y.start < FaceIndex.youngYears * 365.25 * 86_400_000.0 {
                        limit = y.limit; margin = FaceIndex.youngMargin
                    }
                    guard top.value >= limit else { continue }
                    let second = ranked.count > 1 ? ranked[1].value : 0
                    guard top.value - second >= margin, !(s.notPerson[j.ids[i]]?.contains(top.key) ?? false),
                          !(taken[j.photos[i]]?.contains(top.key) ?? false) else { continue }
                    taken[j.photos[i], default: []].insert(top.key)
                    picks.append((j.ids[i], top.key, top.value))
                }
            }
            DispatchQueue.main.async {
                self.autoBusy = false
                self.autoSeen.formUnion(cands.map(\.id))
                if let floor, abs(floor - FaceIndex.floorNow) > 0.005 {
                    UserDefaults.standard.set(floor, forKey: "faces.floor." + s.model)
                    self.allCountsKey = -1; self.countKey = [:]           // the Review numbers follow the new level
                    self.refreshAllCounts()
                }
                // anything you answered while it was working stays as you left it
                let still = picks.filter { self.faces[$0.face]?.person == nil && !(self.notPerson[$0.face]?.contains($0.person) ?? false) }
                if !still.isEmpty {
                    for p in still { self.autoFaces[p.face] = p.person; self.autoScores[p.face] = p.score }
                    let rows = still.map { (face: $0.face, person: $0.person, score: $0.score) }
                    lib.dbWrite { $0.addAutoFaces(rows) }
                    self.commit(still.map { (id: $0.face, person: Optional($0.person), grp: Optional<Int>.none) }, lib, auto: true)
                    AwayReport.shared.named += still.count
                    let n = Set(still.compactMap { self.faces[$0.face]?.photo }).count
                    lib.status = "Named \(still.count.formatted()) face\(still.count == 1 ? "" : "s") in \(n.formatted()) photo\(n == 1 ? "" : "s") automatically."
                    // sure matches teach it more: look again with them as examples
                    if still.contains(where: { $0.score >= FaceIndex.strongAuto }) { self.autoAgain = true }
                }
                if self.autoAgain { self.autoAgain = false; self.scheduleAuto(lib, delay: 2) }
            }
        }
    }
}

/// Each person's examples and the learned levels, kept between runs so a small change doesn't redo everything.
final class MatchCache {
    static let shared = MatchCache()
    private let lock = NSLock()
    private var ex: [Int: (key: String, ex: [(emb: [Float], date: Double)])] = [:]
    private var cal: (key: String, value: FaceIndex.Calibration)?
    func examples(_ pid: Int, _ key: String, make: () -> [(emb: [Float], date: Double)]) -> [(emb: [Float], date: Double)] {
        if let c = lock.withLock({ ex[pid] }), c.key == key { return c.ex }
        let v = make()
        lock.withLock { ex[pid] = (key, v) }
        return v
    }
    func calibration(_ key: String, make: () -> FaceIndex.Calibration) -> FaceIndex.Calibration {
        if let c = lock.withLock({ cal }), c.key == key { return c.value }
        let v = make()
        lock.withLock { cal = (key, v) }
        return v
    }
    func clear() { lock.withLock { ex = [:]; cal = nil } }
}

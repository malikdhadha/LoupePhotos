import Foundation
import AppKit
import Accelerate
import Observation

/// Settings ▸ People ▸ Compare on My Photos: both recognition models look at the faces you've confirmed,
/// and say how often each would pick the right person — and how often it would be sure enough to name them by itself.
@Observable
final class ModelCompare {
    static let shared = ModelCompare()
    struct Score { let model: String; let right: Double; let sure: Double; let gap: Double; let typical: Double }
    var running = false
    var progress = 0.0
    var faces = 0
    var results: [Score] = []
    var note = ""

    func run(_ lib: Library) {
        guard !running else { return }
        let idx = FaceIndex.shared
        // faces you named or confirmed yourself (not automatic ones, which would favour the model that made them)
        var byPerson: [Int: [Face]] = [:]
        for f in idx.faces.values where f.rect != .zero && f.person != nil && idx.autoFaces[f.id] == nil { byPerson[f.person!, default: []].append(f) }
        byPerson = byPerson.filter { $0.value.count >= 2 }
        guard byPerson.count >= 2 else { note = "Name at least two people (with a few photos each) first."; return }
        // up to 80 photos per person, spread out, so it takes a minute or two rather than an hour
        var want: [Int: [(rect: CGRect, person: Int)]] = [:], rotOf: [Int: Int] = [:]
        for (pid, fs) in byPerson {
            let pick = fs.count <= 80 ? fs : stride(from: 0, to: fs.count, by: max(1, fs.count / 80)).map { fs[$0] }
            for f in pick { want[f.photo, default: []].append((f.rect, pid)); rotOf[f.photo] = f.rot }
        }
        let shots = want.compactMap { k, v in lib.byId[k].map { (photo: $0, rot: rotOf[k] ?? 0, known: v) } }
        let models = ["AuraFace", "Glint100"].filter(FaceScanner.available)
        guard models.count == 2 else { note = "Both models need to be built into the app."; return }
        running = true; progress = 0; results = []; note = ""
        DispatchQueue.global(qos: .userInitiated).async {
            var labels: [Int] = [], embs: [[[Float]]] = [[], []]
            for (k, s) in shots.enumerated() {
                autoreleasepool {
                    guard let d = FaceScanner.shared.detect(s.photo, rot: s.rot) else { return }
                    for known in s.known {
                        // the face Vision finds again in the same place
                        guard let hit = d.faces.max(by: { ModelCompare.overlap($0.rect, known.rect) < ModelCompare.overlap($1.rect, known.rect) }),
                              ModelCompare.overlap(hit.rect, known.rect) > 0.4,
                              let a = FaceScanner.shared.embed(d.image, hit.points, model: models[0]),
                              let b = FaceScanner.shared.embed(d.image, hit.points, model: models[1]) else { continue }
                        labels.append(known.person); embs[0].append(a); embs[1].append(b)
                    }
                }
                if k % 8 == 0 { let p = Double(k) / Double(shots.count); DispatchQueue.main.async { self.progress = p } }
            }
            let scores = models.indices.map { i -> Score in
                let m = ModelCompare.measure(embs[i], labels)
                return Score(model: models[i] == "Glint100" ? "InsightFace glintr100" : "AuraFace", right: m.right, sure: m.sure, gap: m.gap, typical: m.typical)
            }
            DispatchQueue.main.async { self.results = scores; self.faces = labels.count; self.running = false; self.progress = 1 }
        }
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b); guard !i.isNull else { return 0 }
        let u = a.width * a.height + b.width * b.height - i.width * i.height
        return u > 0 ? i.width * i.height / u : 0
    }
    /// For every face: its own person's closest two (leaving itself out) against the closest other person.
    /// "Sure" uses a bar set from each model's own scores between *different* people (the 99th percentile), so models
    /// whose numbers run higher or lower are judged fairly; "gap" is the separation in those same units (d′).
    static func measure(_ e: [[Float]], _ labels: [Int]) -> (right: Double, sure: Double, gap: Double, typical: Double) {
        let n = e.count
        guard n > 2 else { return (0, 0, 0, 0) }
        var mineAll: [Float] = [], otherAll: [Float] = []
        for i in 0..<n {
            var top: [Int: (Float, Float)] = [:]
            for j in 0..<n where j != i {
                let s = vDSP.dot(e[i], e[j]), p = labels[j], t = top[p] ?? (-2, -2)
                if s > t.0 { top[p] = (s, t.0) } else if s > t.1 { top[p] = (t.0, s) }
            }
            let score = top.mapValues { $0.1 > -2 ? ($0.0 + $0.1) / 2 : $0.0 }
            guard let mine = score[labels[i]] else { continue }
            mineAll.append(mine); otherAll.append(score.filter { $0.key != labels[i] }.values.max() ?? 0)
        }
        guard !mineAll.isEmpty else { return (0, 0, 0, 0) }
        let bar = otherAll.sorted()[min(otherAll.count - 1, Int(Double(otherAll.count) * 0.99))]
        var right = 0, sure = 0
        for (m, o) in zip(mineAll, otherAll) { if m > o { right += 1 }; if m > bar && m - o >= FaceIndex.autoMargin { sure += 1 } }
        func mv(_ v: [Float]) -> (Float, Float) { let m = v.reduce(0, +) / Float(v.count); return (m, v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(v.count)) }
        let g = mv(mineAll), o = mv(otherAll)
        let dprime = (g.0 - o.0) / max(1e-6, sqrt((g.1 + o.1) / 2))
        let typical = mineAll.sorted()[mineAll.count / 2]
        let c = Double(mineAll.count)
        return (Double(right) / c, Double(sure) / c, Double(dprime), Double(typical))
    }
}

extension FaceIndex {
    /// Settings ▸ People ▸ Start Over: forgets every face, name and answer, then looks at every photo again with `model`.
    /// Photos, stars, keywords you typed and collections are untouched; only the People › Name keywords Loupe Photos added go.
    func startOver(model: String, lib: Library) {
        FaceScanner.shared.stop()
        UserDefaults.standard.set(model, forKey: "faces.model")
        lib.dbWrite { $0.resetFaces() }
        reset()
        nextFaceId = 1; nextGroupId = 1; nextPersonId = 1
        notPerson = [:]
        MatchCache.shared.clear(); autoSeen = []; autoCounts = [:]
        UserDefaults.standard.removeObject(forKey: "faces.floor." + model)
        Clusterer.shared.rebuild([])
        syncKeywords(lib)                 // no one is named now, so the People › … keywords it added come off
        lib.version += 1
        lib.status = "Starting over: finding faces in every photo again."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { FaceScanner.shared.start(lib) }
    }
}

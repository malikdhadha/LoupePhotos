import AppKit
import CoreML
import Vision
import Accelerate
import IOKit.ps

/// Settings ▸ Search.
enum SearchSettings {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "search.enabled") as? Bool ?? true }
    static var readText: Bool { UserDefaults.standard.object(forKey: "search.ocr") as? Bool ?? true }
    static var waitOnBattery: Bool { UserDefaults.standard.object(forKey: "search.battery") as? Bool ?? false }
}

/// What's in each photo, for searching in plain words ("dog on the beach", "red car", "birthday cake"):
/// a MobileCLIP fingerprint of the picture, any text Vision can read in it, and Apple's own scene labels.
/// Everything is worked out on this Mac and kept in the catalog (the `clip` table) — nothing leaves the computer.
@Observable
final class SearchIndex {
    static let shared = SearchIndex()
    static let dim = 512

    /// How many photos are ready to search (for Settings and the results bar).
    private(set) var count = 0
    /// Bumped as photos are added, so open results refresh now and then.
    private(set) var version = 0

    @ObservationIgnored private var row: [Int: Int] = [:]        // photo id → row in `embs`
    @ObservationIgnored private var ids: [Int] = []              // row → photo id (-1 = removed)
    @ObservationIgnored private var embs: [Float16] = []         // rows × 512, each row length 1
    @ObservationIgnored private(set) var words: [Int: String] = [:]     // text read from the photo + scene labels, lowercased
    @ObservationIgnored private(set) var labels: [Int: [String]] = [:]  // Smart Keywords (scene labels)
    @ObservationIgnored private var stats: (mean: Float, sd: Float)?

    var rows: Int { ids.count }
    func has(_ id: Int) -> Bool { row[id] != nil || words[id] != nil }
    func reset() { row = [:]; ids = []; embs = []; words = [:]; labels = [:]; stats = nil; count = 0; version += 1 }

    /// Reads the saved index (call on the catalog's own queue). Everything is unpacked there, off the main thread,
    /// then handed over in one step — so a big library opens without a pause.
    func load(_ db: CatalogDB) {
        let rows = db.readClip()
        var ids: [Int] = [], embs: [Float16] = [], row: [Int: Int] = [:], words: [Int: String] = [:], labels: [Int: [String]] = [:]
        ids.reserveCapacity(rows.count); embs.reserveCapacity(rows.count * SearchIndex.dim)
        for r in rows {
            if r.emb.count == SearchIndex.dim * 2 {
                row[r.photo] = ids.count; ids.append(r.photo)
                r.emb.withUnsafeBytes { embs.append(contentsOf: $0.bindMemory(to: Float16.self)) }
            }
            words[r.photo] = (r.words + " " + r.labels).lowercased().trimmingCharacters(in: .whitespaces)
            let l = r.labels.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !l.isEmpty { labels[r.photo] = l }
        }
        DispatchQueue.main.async { [self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            defer { Timing.note("search index loaded (main thread)", since: t0, always: true) }
            self.ids = ids; self.embs = embs; self.row = row; self.words = words; self.labels = labels
            stats = nil; count = words.count; version += 1
            SearchScanner.shared.start(Library.shared)              // then look at any photos not indexed yet
        }
    }

    func add(_ items: [(id: Int, emb: [Float16], words: String, labels: String)], bump: Bool) {
        for it in items {
            if it.emb.count == SearchIndex.dim {
                if let r = row[it.id] {
                    embs.replaceSubrange(r * SearchIndex.dim ..< (r + 1) * SearchIndex.dim, with: it.emb)
                } else {
                    row[it.id] = ids.count; ids.append(it.id); embs.append(contentsOf: it.emb)
                }
            }
            let w = (it.words + " " + it.labels).lowercased().trimmingCharacters(in: .whitespaces)
            words[it.id] = w
            let l = it.labels.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !l.isEmpty { labels[it.id] = l } else { labels.removeValue(forKey: it.id) }
        }
        stats = nil
        count = words.count
        if bump { version += 1 }
    }
    func remove(_ gone: Set<Int>) {
        for id in gone {
            if let r = row.removeValue(forKey: id) { ids[r] = -1 }
            words.removeValue(forKey: id); labels.removeValue(forKey: id)
        }
        stats = nil; count = words.count; version += 1
    }

    /// How alike the phrase is to every photo (cosine similarity), by photo id.
    func scores(_ q: [Float]) -> [Int: Float] {
        let n = ids.count, d = SearchIndex.dim
        guard n > 0, q.count == d else { return [:] }
        var out = [Float](repeating: 0, count: n)
        let chunk = 4096
        var buf = [Float](repeating: 0, count: chunk * d)
        embs.withUnsafeBufferPointer { e in
            buf.withUnsafeMutableBufferPointer { b in
                out.withUnsafeMutableBufferPointer { o in
                    q.withUnsafeBufferPointer { qp in
                        var start = 0
                        while start < n {
                            let m = min(chunk, n - start)
                            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: e.baseAddress! + start * d), height: 1,
                                                    width: vImagePixelCount(m * d), rowBytes: m * d * 2)
                            var dst = vImage_Buffer(data: b.baseAddress!, height: 1, width: vImagePixelCount(m * d), rowBytes: m * d * 4)
                            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                            vDSP_mmul(b.baseAddress!, 1, qp.baseAddress!, 1, o.baseAddress! + start, 1, vDSP_Length(m), 1, vDSP_Length(d))
                            start += m
                        }
                    }
                }
            }
        }
        var r: [Int: Float] = [:]; r.reserveCapacity(n)
        for i in 0..<n where ids[i] >= 0 { r[ids[i]] = out[i] }
        return r
    }
}

/// A running count, touched only on the main thread.
private final class Tally: @unchecked Sendable { var n = 0 }

/// Builds the search index in the background (Background Tasks ▸ "Getting photos ready for search"), a few photos at a time.
/// It can be paused, and (Settings ▸ Search) can wait while the Mac is on battery.
final class SearchScanner: @unchecked Sendable {
    static let shared = SearchScanner()
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = Machine.workers(0.375, min: 2, max: 3); q.qualityOfService = .utility; return q }()
    private let lock = NSLock()
    private var generation = 0
    private var userPaused = false
    private var batteryWait = false
    private var powerTimer: Timer?
    private let modelLock = NSLock()
    private let textLock = NSLock()

    private static func load(_ name: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { NSLog("\(name) model missing"); return nil }
        let c = MLModelConfiguration(); c.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: c)
    }
    private lazy var imageModel: MLModel? = SearchScanner.load("mobileclip_s2_image")
    private lazy var textModel: MLModel? = SearchScanner.load("mobileclip_s2_text")
    private lazy var tokenizer: CLIPTokenizer? = CLIPTokenizer()
    /// Is the picture-understanding model built into this copy of the app?
    static var available: Bool { Bundle.main.url(forResource: "mobileclip_s2_image", withExtension: "mlmodelc") != nil }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }

    func start(_ lib: Library) {
        guard lib.db != nil, SearchSettings.enabled, SearchScanner.available else { return }
        let idx = SearchIndex.shared
        let todo = lib.photos.filter { $0.deleted == nil && !idx.has($0.id) }
        guard !todo.isEmpty else { return }
        lock.lock(); generation += 1; let gen = generation; userPaused = false; lock.unlock()
        queue.cancelAllOperations()
        let total = todo.count
        let tally = Tally()
        let title = "Getting photos ready for search"
        let pause: (Bool) -> Void = { [weak self] on in
            guard let self else { return }
            self.lock.lock(); self.userPaused = on; self.lock.unlock()
            self.applySuspend()
        }
        Activity.shared.report("search", title, done: 0, total: total, pause: pause)
        watchPower(title: title)
        for chunk in stride(from: 0, to: todo.count, by: 16).map({ Array(todo[$0..<min(todo.count, $0 + 16)]) }) {
            let shots = chunk.map { (id: $0.id, rot: $0.rot, p: $0) }
            queue.addOperation { [weak self] in
                guard let self else { return }
                self.lock.lock(); let live = gen == self.generation; self.lock.unlock()
                guard live else { return }
                let ocr = SearchSettings.readText
                var rows: [CatalogDB.ClipRow] = []
                var items: [(id: Int, emb: [Float16], words: String, labels: String)] = []
                for s in shots {
                    autoreleasepool {
                        guard let r = self.look(at: s.p, rot: s.rot, readText: ocr) else { return }
                        let half = r.emb.map { Float16($0) }
                        rows.append(.init(photo: s.id, emb: half.withUnsafeBufferPointer { Data(buffer: $0) }, words: r.words, labels: r.labels))
                        items.append((s.id, half, r.words, r.labels))
                    }
                }
                DispatchQueue.main.async {
                    guard gen == self.currentGeneration else { return }
                    tally.n += shots.count; let done = tally.n
                    SearchIndex.shared.add(items, bump: done % 400 < 16 || done >= total)
                    lib.dbWrite { $0.saveClip(rows) }
                    Activity.shared.report("search", self.batteryWait ? "Search: waiting for power" : title, done: done, total: total, pause: pause)
                    if done >= total { self.stopWatching(); lib.status = "Your photos are ready to search — try “beach at sunset” or a name and a year." }
                }
            }
        }
    }
    private var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
    func stop() {
        lock.lock(); generation += 1; lock.unlock()
        queue.cancelAllOperations(); queue.isSuspended = false
        stopWatching(); Activity.shared.finish("search")
    }

    // MARK: battery
    private func applySuspend() {
        lock.lock(); let on = userPaused || batteryWait || held; lock.unlock()
        queue.isSuspended = on
    }
    /// Held back by BackgroundWork (thumbnails first, and not while you're scrolling).
    private var held = false
    func hold(_ on: Bool) {
        lock.lock(); let changed = held != on; held = on; lock.unlock()
        if changed { applySuspend() }
    }
    private func watchPower(title: String) {
        DispatchQueue.main.async { [self] in
            powerTimer?.invalidate()
            let check = { [weak self] in
                guard let self else { return }
                let wait = SearchSettings.waitOnBattery && SearchScanner.onBattery
                if wait != self.batteryWait { self.batteryWait = wait; self.applySuspend() }
            }
            check()
            powerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in check() }
        }
    }
    private func stopWatching() {
        DispatchQueue.main.async { [self] in powerTimer?.invalidate(); powerTimer = nil; batteryWait = false }
    }

    // MARK: looking at one photo
    /// Fingerprint, text found and scene labels for one photo (off the main thread).
    private func look(at p: Photo, rot: Int, readText: Bool) -> (emb: [Float], words: String, labels: String)? {
        guard var img = PreviewStore.shared.image(p.id, .thumb) ?? ThumbBuilder.shared.image(p, .thumb) else { return nil }
        if rot % 4 != 0, let r = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)).rotated(rot).cgImage(forProposedRect: nil, context: nil, hints: nil) { img = r }
        guard let emb = embed(img) else { return nil }
        // Apple's scene labels ("beach", "dog", "sunset"…) and any readable text, from the same small image
        let classify = VNClassifyImageRequest()
        var reqs: [VNRequest] = [classify]
        let text = VNRecognizeTextRequest()
        if readText { text.recognitionLevel = .accurate; text.usesLanguageCorrection = true; reqs.append(text) }
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform(reqs)
        let labels = (classify.results ?? []).filter { $0.confidence >= 0.35 }.prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
        var words = ""
        if readText {
            words = (text.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.4 }.map(\.string).joined(separator: " ")
            if words.count > 600 { words = String(words.prefix(600)) }
        }
        return (emb, words, labels)
    }

    /// The photo's centre square at 256×256, through MobileCLIP's image model → a length-1 fingerprint.
    private func embed(_ img: CGImage) -> [Float]? {
        guard let model = imageModel else { return nil }
        let side = min(img.width, img.height)
        guard side > 0, let sq = img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)) else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(sq, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        modelLock.lock(); defer { modelLock.unlock() }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)]),
              let out = try? model.prediction(from: input), let arr = out.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
        return SearchScanner.unit(arr)
    }

    /// A phrase through MobileCLIP's text model → a length-1 fingerprint (fast: a few milliseconds).
    var why = ""
    func embed(text: String) -> [Float]? {
        textLock.lock(); defer { textLock.unlock() }        // its own lock: typing never waits for a photo being indexed
        guard let model = textModel else { why = "no text model"; return nil }
        guard let tok = tokenizer else { why = "no tokenizer"; return nil }
        guard let arr = try? MLMultiArray(shape: [1, 77], dataType: .int32) else { return nil }
        let t = tok.encode_full(text: text)
        for (i, v) in t.enumerated() { arr[i] = NSNumber(value: v) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: arr)]),
              let out = try? model.prediction(from: input) else { why = "prediction failed"; return nil }
        guard let e = out.featureValue(for: "final_emb_1")?.multiArrayValue else { why = "no output: \(out.featureNames)"; return nil }
        guard let u = SearchScanner.unit(e) else { why = "bad output \(e.count) \(e.dataType.rawValue)"; return nil }
        return u
    }
    private static func unit(_ a: MLMultiArray) -> [Float]? {
        guard a.count == SearchIndex.dim else { return nil }
        var v = [Float](repeating: 0, count: a.count)
        if a.dataType == .float32 { let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count); for i in 0..<a.count { v[i] = p[i] } }
        else { for i in 0..<a.count { v[i] = a[i].floatValue } }
        var n: Float = 0; vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = sqrt(n)
        guard n > 0 else { return nil }
        return v.map { $0 / n }
    }
}

// MARK: - understanding the search phrase

/// One understood part of a search, shown as a chip under the toolbar. × takes it out of the search.
struct SearchChip: Identifiable, Hashable {
    enum Kind: String { case person, place, date, rating, flag, words }
    let kind: Kind
    let label: String
    let phrase: String           // the words in the search field it came from
    var id: String { kind.rawValue + "|" + phrase }
    var icon: String {
        switch kind {
        case .person: return "person.crop.circle"
        case .place: return "mappin.and.ellipse"
        case .date: return "calendar"
        case .rating: return "star.fill"
        case .flag: return "flag.fill"
        case .words: return "sparkle.magnifyingglass"
        }
    }
}

/// "Sam at the beach in June 2019, 4 stars" → Sam · June 2019 · ★★★★ and up · "beach".
struct ParsedSearch {
    var people: [Int] = []
    var places: [String] = []
    var from: Date?, to: Date?          // capture date range (to is exclusive)
    var monthOnly: Int?                 // "June" with no year: that month in any year
    var minRating: Int?
    var flagged = false
    var words = ""                      // what's left: matched against what's in the pictures
    var chips: [SearchChip] = []
    var hasFilters: Bool { !people.isEmpty || !places.isEmpty || from != nil || minRating != nil || flagged }
}

@Observable
final class NaturalSearch {
    static let shared = NaturalSearch()
    /// Results bar ▸ Fewer / More: how loosely pictures must match the words (0 = only close matches).
    var looseness = 0

    @ObservationIgnored private var placeKey = -1
    @ObservationIgnored private var placeNames: [String] = []
    @ObservationIgnored private var textCache: [String: [Float]] = [:]
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var lastResult: [Int: Float] = [:]

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let monthShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
    private static let filler: Set<String> = ["photos", "photo", "pictures", "picture", "pics", "pic", "images", "image", "shots", "show", "me", "find",
                                              "all", "my", "of", "from", "in", "at", "on", "with", "and", "taken", "during", "the", "a", "an", "some", "any"]
    private static let joiners = "(?:taken\\s+)?(?:in|at|from|on|of|during|with|and|near)\\s+"

    static func fold(_ t: String) -> String { t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
    /// Is plain-words search switched on and possible here?
    var active: Bool { SearchSettings.enabled }

    func parse(_ query: String, lib: Library) -> ParsedSearch {
        var r = ParsedSearch()
        var s = " " + NaturalSearch.fold(query).replacingOccurrences(of: "’", with: "'") + " "
        /// Takes the first match of a pattern out of the phrase (with a leading "in"/"at"/… if there is one).
        func take(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: "(?:\\s" + NaturalSearch.joiners + ")?(?<=\\s|^)" + pattern + "(?='s\\b|\\s|[,.!?]|$)", options: []) else { return nil }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            var groups: [String] = []
            for i in 0..<m.numberOfRanges { let g = m.range(at: i); groups.append(g.location == NSNotFound ? "" : ns.substring(with: g)) }
            s = ns.replacingCharacters(in: m.range, with: " ")
            s = s.replacingOccurrences(of: " 's ", with: " ")
            return groups
        }
        func esc(_ t: String) -> String { NSRegularExpression.escapedPattern(for: t) }
        let original = query

        // people — full names first (longest first), then a first name if only one person has it
        let fi = FaceIndex.shared
        let everyone = fi.named.sorted { $0.name.count > $1.name.count }
        for p in everyone {
            let n = NaturalSearch.fold(p.name)
            if let g = take(esc(n)) { r.people.append(p.id); r.chips.append(.init(kind: .person, label: p.name, phrase: phrase(g[0], in: original))) }
        }
        var firsts: [String: [Person]] = [:]
        for p in everyone { if let f = NaturalSearch.fold(p.name).split(separator: " ").first, f.count >= 3 { firsts[String(f), default: []].append(p) } }
        for (f, ps) in firsts where ps.count == 1 && !r.people.contains(ps[0].id) {
            if let g = take(esc(f)) { r.people.append(ps[0].id); r.chips.append(.init(kind: .person, label: ps[0].name, phrase: phrase(g[0], in: original))) }
        }

        // stars and flags
        if let g = take("([1-5]|one|two|three|four|five)\\s*\\+?\\s*stars?(?:\\s+(?:and\\s+(?:up|above|over)|or\\s+(?:more|better)))?") {
            let n = Int(g[1]) ?? NaturalSearch.numbers[g[1]] ?? 0
            if n > 0 { r.minRating = n; r.chips.append(.init(kind: .rating, label: String(repeating: "★", count: n) + (n < 5 ? " and up" : ""), phrase: phrase(g[0], in: original))) }
        }
        if let g = take("(?:flagged|picks|favou?rites?)") { r.flagged = true; r.chips.append(.init(kind: .flag, label: "Flagged", phrase: phrase(g[0], in: original))) }

        // dates
        let cal = Calendar.current
        func day(_ y: Int, _ m: Int = 1, _ d: Int = 1) -> Date? { cal.date(from: DateComponents(year: y, month: m, day: d)) }
        let now = Date(), thisYear = cal.component(.year, from: now), thisMonth = cal.component(.month, from: now)
        let monthAlt = (NaturalSearch.months + NaturalSearch.monthShort.filter { $0 != "may" }).joined(separator: "|")
        if let g = take("(\(monthAlt))\\.?(?:\\s+(?:of\\s+)?((?:19|20)\\d{2}))?") {
            let name = g[1]
            let m = (NaturalSearch.months.firstIndex(of: name) ?? NaturalSearch.monthShort.firstIndex(of: name) ?? 0) + 1
            if let y = Int(g[2]) {
                r.from = day(y, m); r.to = day(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1)
                r.chips.append(.init(kind: .date, label: "\(NaturalSearch.months[m - 1].capitalized) \(y)", phrase: phrase(g[0], in: original)))
            } else {
                r.monthOnly = m
                r.chips.append(.init(kind: .date, label: "Any \(NaturalSearch.months[m - 1].capitalized)", phrase: phrase(g[0], in: original)))
            }
        }
        if r.from == nil, let g = take("((?:19|20)\\d{2})\\s*(?:-|–|to|until|through)\\s*((?:19|20)\\d{2})") {
            if let a = Int(g[1]), let b = Int(g[2]) {
                r.from = day(min(a, b)); r.to = day(max(a, b) + 1)
                r.chips.append(.init(kind: .date, label: "\(min(a, b))–\(max(a, b))", phrase: phrase(g[0], in: original)))
            }
        }
        if r.from == nil, let g = take("(?:the\\s+)?((?:19|20)?\\d0)'?s") {
            var d = Int(g[1]) ?? 0; if d < 100 { d += d >= 30 ? 1900 : 2000 }
            r.from = day(d); r.to = day(d + 10)
            r.chips.append(.init(kind: .date, label: "The \(d)s", phrase: phrase(g[0], in: original)))
        }
        if r.from == nil, let g = take("((?:19|20)\\d{2})") {
            if let y = Int(g[1]) { r.from = day(y); r.to = day(y + 1); r.chips.append(.init(kind: .date, label: "\(y)", phrase: phrase(g[0], in: original))) }
        }
        if r.from == nil {
            let rel: [(String, String, () -> (Date?, Date?))] = [
                ("today", "Today", { (cal.startOfDay(for: now), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))) }),
                ("yesterday", "Yesterday", { let t = cal.startOfDay(for: now); return (cal.date(byAdding: .day, value: -1, to: t), t) }),
                ("(?:this|past|last)\\s+week", "Last 7 days", { (cal.date(byAdding: .day, value: -7, to: now), nil) }),
                ("this\\s+month", "This month", { (day(thisYear, thisMonth), nil) }),
                ("last\\s+month", "Last month", { let s0 = cal.date(byAdding: .month, value: -1, to: day(thisYear, thisMonth) ?? now); return (s0, day(thisYear, thisMonth)) }),
                ("this\\s+year", "\(thisYear)", { (day(thisYear), day(thisYear + 1)) }),
                ("last\\s+year", "\(thisYear - 1)", { (day(thisYear - 1), day(thisYear)) }),
            ]
            for (pat, label, range) in rel {
                if let g = take(pat) { (r.from, r.to) = range(); r.chips.append(.init(kind: .date, label: label, phrase: phrase(g[0], in: original))); break }
            }
        }

        // places — names from your own photos' locations, longest first
        if placeKey != lib.placeVersion &+ lib.structKey &* 31 {
            var set = Set<String>()
            for p in lib.photos { if let pl = p.place { for k in ["t", "r", "c"] { if let v = pl[k] as? String, v.count >= 3 { set.insert(NaturalSearch.fold(v)) } } } }
            placeNames = set.sorted { $0.count > $1.count }; placeKey = lib.placeVersion &+ lib.structKey &* 31
        }
        for n in placeNames where s.contains(n) {
            if let g = take(esc(n)) { r.places.append(n); r.chips.append(.init(kind: .place, label: n.capitalized, phrase: phrase(g[0], in: original))) }
        }

        // what's left is about what's in the pictures
        var rest = s.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        while let f = rest.first, NaturalSearch.filler.contains(f) { rest.removeFirst() }
        while let l = rest.last, NaturalSearch.filler.contains(l) { rest.removeLast() }
        r.words = rest.joined(separator: " ")
        if !r.words.isEmpty, r.hasFilters || r.monthOnly != nil { r.chips.append(.init(kind: .words, label: "“\(r.words)”", phrase: r.words)) }
        return r
    }
    /// The same words as typed (so × can take them out of the search field).
    private func phrase(_ matched: String, in original: String) -> String {
        let t = matched.trimmingCharacters(in: .whitespaces)
        if let r = original.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) { return String(original[r]) }
        return t
    }

    /// Takes a chip's words out of the search phrase.
    static func removing(_ chip: SearchChip, from query: String) -> String {
        var q = query
        if let r = q.range(of: chip.phrase, options: [.caseInsensitive]) { q.removeSubrange(r) }
        return q.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// The photos a search finds among `pool`, best first when there are words to match; nil = use the plain old search.
    func run(_ query: String, lib: Library, in pool: [Photo], loose: Int? = nil) -> (photos: [Photo], ranked: Bool)? {
        guard active else { return nil }
        let q = parse(query, lib: lib)
        let fi = FaceIndex.shared, idx = SearchIndex.shared
        var l = pool
        if !q.people.isEmpty { l = l.filter { let here = fi.peopleIn($0.id); return q.people.allSatisfy(here.contains) } }
        if !q.places.isEmpty { l = l.filter { let t = NaturalSearch.fold($0.placeLabel); return q.places.allSatisfy { t.contains($0) } } }
        // (untracked reads: this runs over the whole library on each keystroke)
        if let f = q.from { let a = f.timeIntervalSince1970 * 1000; l = l.filter { !$0.quickNoDate && $0.quickDate >= a } }
        if let t = q.to { let b = t.timeIntervalSince1970 * 1000; l = l.filter { !$0.quickNoDate && $0.quickDate < b } }
        if let m = q.monthOnly { l = l.filter { !$0.quickNoDate && $0.ymd.m == m } }
        if let n = q.minRating { l = l.filter { $0.quickRating >= n } }
        if q.flagged { l = l.filter(\.quickFlag) }
        guard !q.words.isEmpty else { return (l, false) }

        // words: literal matches (names, keywords, captions, places, text in the photo, scene labels)…
        let terms = q.words.split(separator: " ").map(String.init).filter { !NaturalSearch.filler.contains($0) }
        func literal(_ p: Photo) -> Bool {
            guard !terms.isEmpty else { return false }
            let t = p.searchText + " " + fi.nameText(p.id) + " " + (idx.words[p.id] ?? "")
            return terms.allSatisfy { t.contains($0) }
        }
        // …plus pictures that look like the words (MobileCLIP)
        let sc = clipScores(q.words)
        guard !sc.isEmpty else { return (l.filter(literal), false) }
        let cut = cutoff(sc, loose ?? looseness)
        var out: [(Photo, Float)] = []
        for p in l {
            let s = sc[p.id] ?? -1
            if literal(p) { out.append((p, s + 0.15)) } else if s >= cut { out.append((p, s)) }
        }
        out.sort { $0.1 > $1.1 }
        return (out.map(\.0), true)
    }

    /// Scores for every indexed photo against a phrase (remembered while you look at the results).
    @ObservationIgnored var debug = ""
    private func clipScores(_ words: String) -> [Int: Float] {
        let idx = SearchIndex.shared
        guard idx.count > 0, SearchScanner.available else { debug = "no index (\(idx.count)) avail=\(SearchScanner.available)"; return [:] }
        let key = "\(idx.version)|\(words)"
        if key == lastKey { return lastResult }
        let e: [Float]
        if let c = textCache[words] { e = c } else {
            guard let v = SearchScanner.shared.embed(text: "a photo of " + words) else { debug = "text model failed: " + SearchScanner.shared.why; return [:] }
            if textCache.count > 200 { textCache.removeAll() }
            textCache[words] = v; e = v
        }
        lastResult = idx.scores(e); lastKey = key
        let vals = lastResult.values
        debug = "rows \(idx.rows) scored \(vals.count) best \(String(format: "%.3f", vals.max() ?? -9)) mean \(String(format: "%.3f", vals.reduce(0, +) / Float(max(1, vals.count))))"
        return lastResult
    }
    /// How alike a photo must be: well above the library's usual score for this phrase, and near the best match.
    private func cutoff(_ sc: [Int: Float], _ looseness: Int) -> Float {
        let v = Array(sc.values)
        guard v.count > 1 else { return 0.2 }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(v, 1, nil, 1, &mean, &sd, vDSP_Length(v.count))
        let best = v.max() ?? 0
        let i = min(max(looseness, 0), 3)
        let k: [Float] = [2.6, 2.2, 1.8, 1.3], band: [Float] = [0.05, 0.08, 0.11, 0.15]
        let c = max(mean + k[i] * sd, best - band[i], 0.10)
        debug += " cut \(String(format: "%.3f", c))"
        return c
    }

    /// Smart collections: "Search finds …" — the photos a saved search finds right now.
    @ObservationIgnored private var setCache: [String: (key: String, ids: Set<Int>, at: Date, structure: Int, loose: Int)] = [:]
    func matchSet(_ query: String, loose: Int = 0, lib: Library) -> Set<Int> {
        // a saved search re-runs over the whole library, so not on every little change: when photos come or go
        // straight away, otherwise at most every 30 seconds (while faces and search are indexing, the library changes constantly)
        let key = "\(lib.version)|\(SearchIndex.shared.version)|\(loose)"
        if let c = setCache[query] {
            if c.key == key { return c.ids }
            if c.structure == lib.structKey, c.loose == loose, Date().timeIntervalSince(c.at) < 30 { return c.ids }
        }
        let pool = lib.photos.filter { $0.deleted == nil }
        let ids = Set((run(query, lib: lib, in: pool, loose: loose)?.photos ?? lib.list(source: .all, filter: .all, query: query, sort: nil)).map(\.id))
        setCache[query] = (key, ids, Date(), lib.structKey, loose)
        return ids
    }
}

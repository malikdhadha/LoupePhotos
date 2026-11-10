import Foundation
import AppKit
import Observation

/// What the browser is showing.
enum Source: Hashable {
    case all, flagged, recent, rejected, days, noDate, onThisDay
    case folder(String)
    case album(String)
    case decade(Int)
    case date(Int, Int?, Int?)
    case place(String, String?)                         // country, town
    case label(String)                                  // colour label id
    case unflagged                                      // neither flagged nor rejected
    case keyword(String)                                // a keyword and everything nested under it
    case rating(Int)                                    // exactly this many stars          // year, month (1–12), day
    case people                                         // People: everyone, as faces
    case person(Int)                                    // a named person's photos
    case faceGroup(Int)                                 // an unnamed group of faces
    case together(String)                               // a Group: photos with all these people ("3,8")
}
enum RatingFilter: String, CaseIterable, Identifiable {
    case all = "All Photos", unrated = "Unrated", r1 = "★ or Better", r2 = "★★ or Better", r3 = "★★★ or Better", r4 = "★★★★ or Better", r5 = "★★★★★", flagged = "Flagged", rejected = "Rejected"
    var id: String { rawValue }
}
enum SortOrder: String, CaseIterable, Identifiable {
    case dateAsc = "Oldest First", dateDesc = "Newest First", name = "File Name", rating = "Rating", added = "Recently Added"
    var id: String { rawValue }
}

/// The catalog: one .apcat JSON file in a library folder, with Previews beside it — the same format
/// the Electron version uses, so either app can open it (never both at once; the lock file says who has it).
@Observable
final class Library {
    var photos: [Photo] = []
    var folders: [Folder] = []
    var albums: [Album] = []
    var version = 0                 // bumps whenever anything changes
    /// Shown at the bottom. Progress messages end with "…" and stay; anything else fades after a few seconds.
    var status = "" {
        didSet {
            guard !status.isEmpty, !status.hasSuffix("…") else { return }
            let s = status
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.status == s { self?.status = "" } }
        }
    }
    /// Changes that only touch stars, flags, labels, rotation or keywords don't change which photos
    /// most views show, so views can skip re-listing and the grid can redraw just those cells.
    @ObservationIgnored var metaBumps = 0
    var structKey: Int { version - metaBumps }
    @ObservationIgnored private var metaLog: [(v: Int, ids: Set<Int>, fields: Set<String>)] = []
    static let metaFields: Set<String> = ["rating", "flag", "label", "rot", "keywords", "caption", "iptc", "name", "develop", "place", "gps", "gpsManual"]
    /// Goes up when any photo's location or place name changes (the Map, place lists and place search follow it,
    /// since those changes no longer make every view list the whole library again).
    @ObservationIgnored var placeVersion = 0
    /// The photos touched since version `v`, if every change since then was metadata-only (nil = redraw everything).
    func touchedSince(_ v: Int) -> (ids: Set<Int>, fields: Set<String>)? {
        guard v >= 0, v <= version else { return nil }
        let newer = metaLog.filter { $0.v > v }
        guard newer.count == version - v else { return nil }
        return newer.reduce(into: (Set<Int>(), Set<String>())) { $0.0.formUnion($1.ids); $0.1.formUnion($1.fields) }
    }
    /// Who's in which photos changed (People): counted like a metadata change, so the sidebar, folders and other
    /// lists aren't rebuilt — only views that show people (which also watch `peopleVersion`) list again.
    /// A photo's look changed (Develop remade its thumbnail): just those cells redraw.
    func lookChanged(_ photoIds: Set<Int>) {
        version += 1; metaBumps += 1
        metaLog.append((version, photoIds, ["look"]))
        if metaLog.count > 40 { metaLog.removeFirst(metaLog.count - 40) }
    }
    @ObservationIgnored var peopleVersion = 0
    func facesChanged(_ photoIds: Set<Int>) {
        peopleVersion += 1
        version += 1; metaBumps += 1
        metaLog.append((version, photoIds, ["faces"]))
        if metaLog.count > 40 { metaLog.removeFirst(metaLog.count - 40) }
    }
    var name = ""
    var loaded = false
    var openError: String?

    @ObservationIgnored var byId: [Int: Photo] = [:]
    @ObservationIgnored var raw: [String: Any] = [:]        // the catalog minus photos/folders
    @ObservationIgnored var lib: [String: Any] = [:]        // albums, people, keywords, settings…
    @ObservationIgnored var faces: Any = [String: Any]()
    /// The next photo number. Locked, so folders read at the same time never give two photos the same number.
    @ObservationIgnored private let idLock = NSLock()
    @ObservationIgnored private var _nextId = 1
    var nextId: Int { get { idLock.withLock { _nextId } } set { idLock.withLock { _nextId = newValue } } }
    func takeIds(_ n: Int) -> Int { idLock.withLock { let v = _nextId; _nextId += n; return v } }
    @ObservationIgnored var dir: URL!
    @ObservationIgnored var catFile: URL!
    @ObservationIgnored var journalURL: URL { URL(fileURLWithPath: catFile.path + ".journal") }
    @ObservationIgnored var journal1URL: URL { URL(fileURLWithPath: catFile.path + ".journal.1") }
    @ObservationIgnored var previews: URL { dir.appendingPathComponent("Previews") }
    @ObservationIgnored var lockURL: URL { dir.appendingPathComponent(".aperture-pro.lock") }
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var lockTimer: Timer?
    @ObservationIgnored private let io = DispatchQueue(label: "catalog.io")
    @ObservationIgnored var pathIndex: [String: Int] = [:]
    @ObservationIgnored var openedAt = Date()
    /// The SQLite catalog (`<name>.apdb`); nil while still on the old JSON catalog.
    @ObservationIgnored var db: CatalogDB?
    @ObservationIgnored var dbDirty = Set<Int>()      // photos added since the last save
    @ObservationIgnored var dbRemoved = Set<Int>()    // photos taken out since the last save
    @ObservationIgnored var converting = false
    @ObservationIgnored var convertTouched = Set<Int>()  // changed while the conversion was running
    @ObservationIgnored var convertLib = false
    @ObservationIgnored var dbURL: URL { catFile.deletingPathExtension().appendingPathExtension("apdb") }
    /// Every folder on disk inside the library's folders, including empty ones (for the sidebar).
    @ObservationIgnored var dirs = Set<String>()

    static let shared = Library()
    static var defaultDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Loupe Photos Library") }

    // MARK: opening
    func openDefault() {
        let saved = UserDefaults.standard.string(forKey: "catalogDir")
        open(dir: saved.map { URL(fileURLWithPath: $0) } ?? Library.defaultDir)
    }
    func open(dir: URL) {
        let fm = FileManager.default
        let t0 = CFAbsoluteTimeGetCurrent()
        Timing.start("launch: catalog opened → first grid drawn")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        let file = (try? fm.contentsOfDirectory(atPath: dir.path))?.first { $0.hasSuffix(".apcat") }
        catFile = dir.appendingPathComponent(file ?? dir.lastPathComponent + ".apcat")
        if let other = lockHolder() {
            let a = NSAlert()
            a.messageText = "“\(dir.lastPathComponent)” is open on \(other)."
            a.informativeText = "Opening one catalog in two places at the same time can damage it. Quit Loupe Photos there first."
            a.addButton(withTitle: "Quit"); a.addButton(withTitle: "Open Anyway")
            if a.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil); return }
        }
        db?.close(); db = nil; dbDirty = []; dbRemoved = []
        var cat: [String: Any] = [:]
        var photoDicts: [String: Any] = [:]
        var list: [Photo] = []
        let fromDB = fm.fileExists(atPath: dbURL.path)
        var tt = CFAbsoluteTimeGetCurrent()
        func lap(_ w: String) { Timing.note("  open: " + w, since: tt, always: true); tt = CFAbsoluteTimeGetCurrent() }
        lap("start (lock check)")
        if fromDB, let d = CatalogDB(url: dbURL) {
            // the database: one row per photo, decoded in parallel
            db = d
            cat = d.value("meta") as? [String: Any] ?? [:]
            cat["folders"] = d.value("folders") as? [[String: Any]] ?? []
            lib = d.value("lib") as? [String: Any] ?? ["albums": [], "people": [], "keywords": [], "settings": [:]]
            faces = d.value("faces") ?? [String: Any]()
            lap("settings")
            // the fast copy if it matches the database exactly; otherwise every row, as before
            let stamp = d.value("snapGen") as? String
            d.snapStamped = stamp != nil
            if let stamp, CatalogSnapshot.stamp(snapURL) == stamp, let ps = CatalogSnapshot.read(snapURL) {
                list = ps
                lap("fast copy: \(ps.count) photos")
            } else {
                let rows = d.photoRows()
                lap("read \(rows.count) rows")
                list = Library.decodeRows(rows)
                lap("decode rows")
            }
        } else {
            if let data = try? Data(contentsOf: catFile), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cat = obj }
            faces = cat["faces"] ?? [String: Any](); cat.removeValue(forKey: "faces")
            photoDicts = cat["photos"] as? [String: Any] ?? [:]
            lib = cat["lib"] as? [String: Any] ?? ["albums": [], "people": [], "keywords": [], "settings": [:]]
            // replay changes written since the last full save
            for url in [journal1URL, journalURL] { replay(url, &photoDicts) }
        }
        cat.removeValue(forKey: "photos")
        nextId = Photo.int(cat["nextId"]) ?? 1
        folders = (cat["folders"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let p = $0["path"] as? String else { return nil }
            return Folder(id: id, path: p, name: $0["name"] as? String ?? (p as NSString).lastPathComponent, offline: !fm.fileExists(atPath: p))
        }
        cat.removeValue(forKey: "folders")
        raw = cat
        if !fromDB {
            list.reserveCapacity(photoDicts.count)
            for v in photoDicts.values { if let d = v as? [String: Any], let p = Photo(dict: d) { list.append(p) } }
        }
        list.sort { $0.quickDate < $1.quickDate }
        lap("sort")
        photos = list
        lap("assign photos")
        // lookup tables, filled directly (without SwiftUI's per-photo change tracking)
        var bi = [Int: Photo](minimumCapacity: list.count), pi = [String: Int](minimumCapacity: list.count), maxId = 0
        for p in list { bi[p.id] = p; if pi[p.quickPath] == nil { pi[p.quickPath] = p.id }; maxId = max(maxId, p.id) }
        byId = bi; pathIndex = pi
        nextId = max(nextId, maxId + 1)
        lap("indexes")
        DevelopStore.shared.load(list)
        readAlbums()
        lap("albums")
        name = dir.lastPathComponent
        UserDefaults.standard.set(dir.path, forKey: "catalogDir")
        takeLock()
        PreviewStore.shared.open(libraryDir: dir, catalogName: catFile.deletingPathExtension().lastPathComponent, legacyPreviews: previews)
        lap("lock + previews store")
        PreviewSettings.shared.load(self)
        BigPreviews.discardOldFull()
        loaded = true; version += 1; openedAt = Date()
        Timing.note("open catalog: \(photos.count) photos", since: t0, always: true)
        FaceScanner.shared.stop(); FaceIndex.shared.reset()
        SearchScanner.shared.stop(); SearchIndex.shared.reset()
        if db == nil { convertToDatabase() } else { dbWrite { FaceIndex.shared.load($0); SearchIndex.shared.load($0) } }
        // the grid comes first: checking folders, naming places and catching up on thumbnails start a few seconds later
        let opened = dir
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.dir == opened else { return }
            self.buildThumbnails()
            for f in self.folders where !f.offline { self.scan(f) }
            FolderWatcher.shared.start(self)      // new photos copied into these folders are added by themselves
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.dir == opened else { return }
                PlaceNamer.shared.nameMissing(self)
            }
        }
        AwayReport.shared.start()
        BackgroundWork.shared.start()           // thumbnails first; faces, search and places wait their turn
        Importer.shared.startWatching()           // a card going in opens Import (Settings in the Import window)
    }
    private func replay(_ url: URL, _ photoDicts: inout [String: Any]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let ps = o["p"] as? [[String: Any]] {
                for pt in ps {
                    guard let id = Photo.int(pt["id"]), var d = photoDicts[String(id)] as? [String: Any] else { continue }
                    for (k, v) in pt where k != "id" { d[k] = v }
                    photoDicts[String(id)] = d
                }
            }
            if let l = o["l"] as? [String: Any] { lib = l }
            if o["fr"] != nil { faces = [String: Any]() }
            if let f = o["f"] as? [String: Any], var all = faces as? [String: Any] {
                for (k, v) in f { if v is NSNull { all.removeValue(forKey: k) } else { all[k] = v } }
                faces = all
            }
        }
    }
    func readAlbums() {
        albums = (lib["albums"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return Album(id: id, type: $0["type"] as? String ?? "album", name: $0["name"] as? String ?? "Album",
                         parent: $0["parent"] as? String, ids: ($0["ids"] as? [Any] ?? []).compactMap { Photo.int($0) },
                         match: $0["match"] as? String ?? "all", rules: ($0["rules"] as? [[String: Any]] ?? []).compactMap(SmartRule.init))
        }
    }

    // MARK: saving — a tiny journal line per change, and a full save now and then
    func changed(_ ps: [Photo], _ fields: [String]) {
        guard !ps.isEmpty else { return }
        for p in ps { p.detailsChanged() }           // their search text is rebuilt next time it's needed
        version += 1
        if fields.contains(where: { $0 == "place" || $0 == "gps" || $0 == "gpsManual" }) { placeVersion += 1 }
        if fields.contains("date") { FaceIndex.shared.dateCache = nil }     // matching compares when photos were taken
        if Set(fields).isSubset(of: Library.metaFields) {
            metaBumps += 1
            metaLog.append((version, Set(ps.map(\.id)), Set(fields)))
            if metaLog.count > 40 { metaLog.removeFirst(metaLog.count - 40) }
        }
        if converting { convertTouched.formUnion(ps.map(\.id)) }
        // Settings ▸ Metadata ▸ "Write changes into XMP": the files follow the catalog
        if XMPSync.enabled, !XMPSync.fields.isDisjoint(with: fields) { XMPSync.write(ps) }
        if let db {
            // the database: just these photos' rows — snapshotted here, turned into text and written on the catalog's queue
            let snap: [(Int, [String: Any])] = ps.map { ($0.id, $0.dict()) }
            io.async {
                let rows: [(Int, Data)] = snap.compactMap { id, d in (try? JSONSerialization.data(withJSONObject: d)).map { (id, $0) } }
                db.writePhotos(rows)
            }
            return
        }
        let patches: [[String: Any]] = ps.map { p in
            let d = p.dict(); var pt: [String: Any] = ["id": p.id]
            for f in fields { pt[f] = d[f] ?? NSNull() }
            return pt
        }
        appendJournal(["p": patches])
    }
    func libChanged() {
        lib["albums"] = albums.map { a -> [String: Any] in
            var d: [String: Any] = (lib["albums"] as? [[String: Any]] ?? []).first { ($0["id"] as? String) == a.id } ?? [:]
            d["id"] = a.id; d["type"] = a.type; d["name"] = a.name; d["parent"] = a.parent ?? NSNull()
            if a.type == "album" || a.type == "light" { d["ids"] = a.ids }
            if a.type == "smart" { d["match"] = a.match; d["rules"] = a.rules.map(\.dict) }
            return d
        }
        version += 1
        if converting { convertLib = true }
        if let db {
            if let data = try? JSONSerialization.data(withJSONObject: lib) { io.async { db.setValue("lib", data) } }
            return
        }
        appendJournal(["l": lib])
    }
    private func appendJournal(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let url = journalURL
        io.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); h.write(Data("\n".utf8)); try? h.close() }
            else { var d = data; d.append(Data("\n".utf8)); try? d.write(to: url) }
        }
        scheduleSave(60)
    }
    func scheduleSave(_ seconds: Double = 4) {
        DispatchQueue.main.async {
            if let t = self.saveTimer, t.isValid, t.fireDate.timeIntervalSinceNow < seconds { return }
            self.saveTimer?.invalidate()
            self.saveTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in self.saveNow() }
        }
    }
    /// Writes what changed. Only taking a snapshot of the changed photos happens here; turning them into text and
    /// writing them happens on the catalog's own queue, so the app never freezes while a big change is saved.
    /// `wait` (quitting): finish writing before returning.
    func saveNow(wait: Bool = false) {
        saveTimer?.invalidate(); saveTimer = nil
        guard loaded else { return }
        if let db {
            // the database: catalog settings, folders, collections, and any photos added or removed
            var meta = raw; meta["version"] = 4; meta["nextId"] = nextId
            meta.removeValue(forKey: "folders"); meta.removeValue(forKey: "lib"); meta.removeValue(forKey: "faces"); meta.removeValue(forKey: "photos")
            let fs = folders.map { ["id": $0.id, "path": $0.path, "name": $0.name] }
            let snap: [(Int, [String: Any])] = dbDirty.compactMap { id in byId[id].map { (id, $0.dict()) } }
            let removed = Array(dbRemoved)
            dbDirty = []; dbRemoved = []
            let libCopy = lib, facesCopy = faces
            let work = {
                let added: [(Int, Data)] = snap.compactMap { id, d in (try? JSONSerialization.data(withJSONObject: d)).map { (id, $0) } }
                let m = try? JSONSerialization.data(withJSONObject: meta), f = try? JSONSerialization.data(withJSONObject: fs)
                let l = try? JSONSerialization.data(withJSONObject: libCopy), fc = try? JSONSerialization.data(withJSONObject: facesCopy, options: [.fragmentsAllowed])
                if let m { db.setValue("meta", m) }; if let f { db.setValue("folders", f) }
                if let l { db.setValue("lib", l) }; if let fc { db.setValue("faces", fc) }
                db.writePhotos(added); db.deletePhotos(removed)
            }
            if wait { io.sync(execute: work) } else { io.async(execute: work) }
            return
        }
        guard let data = catalogJSON() else { return }
        let file = catFile!, j = journalURL, j1 = journal1URL
        io.sync {
            let tmp = URL(fileURLWithPath: file.path + ".tmp")
            do {
                try data.write(to: tmp)
                _ = try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
                try? FileManager.default.removeItem(at: j); try? FileManager.default.removeItem(at: j1)
            } catch { NSLog("save failed: \(error)") }
        }
    }
    /// The whole catalog as the JSON the Electron version (and older versions of this app) read.
    func catalogJSON() -> Data? {
        var cat = raw
        cat["version"] = 3; cat["nextId"] = nextId
        cat["folders"] = folders.map { ["id": $0.id, "path": $0.path, "name": $0.name] }
        var pd: [String: Any] = [:]
        for p in photos { pd[String(p.id)] = p.dict() }
        cat["photos"] = pd; cat["lib"] = lib; cat["faces"] = faces
        return try? JSONSerialization.data(withJSONObject: cat)
    }

    // MARK: lock — one Mac at a time
    private func lockHolder() -> String? {
        guard let data = try? Data(contentsOf: lockURL), let l = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let host = l["host"] as? String ?? "another Mac", pid = Photo.int(l["pid"]) ?? 0, t = Photo.dbl(l["t"]) ?? 0
        if Date().timeIntervalSince1970 * 1000 - t > 180_000 { return nil }
        if host == ProcessInfo.processInfo.hostName { return kill(pid_t(pid), 0) == 0 && pid != Int(getpid()) ? "this Mac (another app)" : nil }
        return "“\(host)”"
    }
    private func takeLock() {
        let write = { [weak self] in
            guard let self else { return }
            let o: [String: Any] = ["host": ProcessInfo.processInfo.hostName, "pid": Int(getpid()), "t": Date().timeIntervalSince1970 * 1000]
            if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: self.lockURL) }
        }
        write()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in write() }
    }
    /// Fills in missing thumbnails in the background; the status line shows progress.
    func buildThumbnails() {
        ThumbBuilder.shared.buildMissing(photos) { [weak self] s in self?.status = s }
        CameraMatchJob.shared.run(photos)          // new RAWs: the camera's look, worked out in the background
    }
    /// A consistent copy of the catalog in `folder` (Catalog Backup): saved first, then the database copied
    /// with SQLite's own snapshot (safe while it's open) and the settings file alongside.
    func writeBackup(to folder: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        var ok = true
        io.sync {
            if let db {
                let target = folder.appendingPathComponent(dbURL.lastPathComponent).path.replacingOccurrences(of: "'", with: "''")
                ok = db.exec("VACUUM INTO '\(target)'")
            }
            if fm.fileExists(atPath: catFile.path) {
                ok = ok && (try? fm.copyItem(at: catFile, to: folder.appendingPathComponent(catFile.lastPathComponent))) != nil
            }
        }
        if let places = PreviewStore.shared.url?.appendingPathComponent("Places.json"), fm.fileExists(atPath: places.path) {
            try? fm.copyItem(at: places, to: folder.appendingPathComponent("Places.json"))
        }
        return ok
    }
    /// The fast catalog copy beside the database (CatalogSnapshot).
    var snapURL: URL { dbURL.deletingPathExtension().appendingPathExtension("apsnap") }
    func close() {
        ThumbBuilder.shared.stop()
        FaceScanner.shared.stop(); SearchScanner.shared.stop()
        PreviewStore.shared.close()
        saveNow(wait: true)
        // everything is saved: write the fast copy for next launch, then stamp the database to match it
        if let db, loaded, !CatalogBackup.shared.restoring {
            let stamp = UUID().uuidString
            if CatalogSnapshot.write(photos, to: snapURL, stamp: stamp),
               let d = try? JSONSerialization.data(withJSONObject: stamp, options: [.fragmentsAllowed]) {
                io.sync { db.setValue("snapGen", d); db.snapStamped = true }
            }
        }
        if let db { io.sync { db.checkpoint(); db.close() } }
        lockTimer?.invalidate()
        try? FileManager.default.removeItem(at: lockURL)
    }

    // MARK: folders
    /// Adds a folder of photos to the library where it is. `done` (from Import) gets the new photos; previews are then up to the caller.
    func addFolder(_ url: URL, done: (([Photo]) -> Void)? = nil) {
        let p = url.standardizedFileURL.path
        if folders.contains(where: { p == $0.path || p.hasPrefix($0.path + "/") }) { return }
        // a parent folder takes over folders already added inside it
        let kids = folders.filter { $0.path.hasPrefix(p + "/") }
        let f = Folder(id: "f\(nextId)", path: p, name: url.lastPathComponent, offline: false)
        nextId += 1
        for k in kids { for ph in photos where ph.fid == k.id { ph.fid = f.id } }
        folders.removeAll { kids.contains($0) }
        folders.append(f); folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        version += 1
        scheduleSave(1)
        scan(f, handlesPreviews: done != nil, done: done)
        FolderWatcher.shared.start(self)
    }
    /// Reads a library folder: adds new photos, marks missing ones. `handlesPreviews`: the caller (Import) builds previews itself.
    /// Reads a library folder for new and missing photos. `under`: just one sub-folder of it (what the folder watcher saw change),
    /// so a photo copied into one folder doesn't mean checking all 70,000.
    func scan(_ folder: Folder, under: String? = nil, handlesPreviews: Bool = false, done: (([Photo]) -> Void)? = nil) {
        let known = pathIndex
        let root = under ?? folder.path
        let job = under == nil ? "scan-" + folder.id : "scan-" + folder.id + "-" + String(root.hashValue, radix: 36)
        let title = under == nil ? "Reading “\(folder.name)”" : "Reading “\((root as NSString).lastPathComponent)”"
        Activity.shared.report(job, title, done: 0, total: 1)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var files: [(String, Int, Double)] = []
            var found = Set<String>([root])
            if let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en {
                    if let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), v.isDirectory == true {
                        if v.isPackage != true { found.insert(u.path) }
                        continue
                    }
                    guard Photo.imageExt.contains(u.pathExtension.lowercased()) else { continue }
                    let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                    guard v?.isRegularFile == true else { continue }
                    files.append((u.path, v?.fileSize ?? 0, (v?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))
                }
            }
            let seen = Set(files.map(\.0))
            let fresh = files.filter { known[$0.0] == nil }
            var made: [Photo] = []
            var id = self?.takeIds(fresh.count) ?? 0
            let batch = Date().timeIntervalSince1970 * 1000
            for (i, f) in fresh.enumerated() {
                let p = Photo(id: id, path: f.0, fid: folder.id); id += 1
                p.size = f.1; p.mtime = f.2.rounded(); p.added = batch
                Metadata.read(into: p)
                made.append(p)
                if i % 50 == 0 { Activity.shared.report(job, title, done: i, total: fresh.count + 1) }
            }
            DispatchQueue.main.async {
                Activity.shared.finish(job)
                guard let self else { return }
                self.dirs = self.dirs.filter { $0 != root && !$0.hasPrefix(root + "/") }.union(found)
                self.nextId = max(self.nextId, id)
                let added = made.filter { self.pathIndex[$0.path] == nil }        // another scan may have added some already
                for p in added { self.photos.append(p); self.byId[p.id] = p; self.pathIndex[p.path] = p.id; self.dbDirty.insert(p.id) }
                if !added.isEmpty { self.photos.sort { $0.date < $1.date } }
                var gone: [Photo] = [], back: [Photo] = []
                let inside = root + "/"
                for p in self.photos where p.fid == folder.id && (under == nil || p.path.hasPrefix(inside)) {
                    let exists = seen.contains(p.path)
                    if !exists && !p.missing { p.missing = true; gone.append(p) }
                    if exists && p.missing { p.missing = false; back.append(p) }
                }
                if !gone.isEmpty || !back.isEmpty { self.changed(gone + back, ["missing"]) }
                self.status = added.isEmpty ? "" : "Added \(added.count) photos from “\(folder.name)”."
                AwayReport.shared.added += added.count
                if !added.isEmpty {
                    self.buildThumbnails()
                    if self.db != nil { FaceScanner.shared.start(self); SearchScanner.shared.start(self) }
                    if !handlesPreviews {
                        PreviewSettings.shared.buildForNew(added)                // Settings ▸ Previews ▸ "Build on import" (RAW / other)
                    }
                }
                self.version += 1
                if !added.isEmpty { self.scheduleSave(2) }
                done?(added)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.status.hasPrefix("Added") { self.status = "" } }
            }
        }
    }

    // MARK: what's showing
    /// When the last import happened (Last Import shows that batch). Worked out once per change to the library, not per call.
    @ObservationIgnored private var lastAddedCache: (key: Int, value: Double) = (-1, 0)
    var lastAdded: Double {
        if lastAddedCache.key == structKey { return lastAddedCache.value }
        let v = photos.lazy.map(\.quickAdded).max() ?? 0
        lastAddedCache = (structKey, v)
        return v
    }
    func list(source: Source, filter: RatingFilter, query: String, sort: SortOrder?) -> [Photo] {
        let q = query.lowercased().split(separator: " ").map(String.init)
        var base: [Photo]
        switch source {
        case .all, .rejected: base = photos
        case .flagged: base = photos.filter { $0.quickFlag }
        case .recent: let la = lastAdded; base = photos.filter { $0.quickAdded == la }
        case .folder(let path): let pre = path + "/"; base = photos.filter { $0.quickPath.hasPrefix(pre) }
        case .album(let id):
            if let a = albums.first(where: { $0.id == id }), a.type == "smart" { let test = smartTest(a, smartPre(a)); base = photos.filter { test($0) } }
            else { base = (albums.first { $0.id == id }?.ids ?? []).compactMap { byId[$0] } }
        case .label(let id): base = id.isEmpty ? photos.filter { $0.quickLabel == nil } : photos.filter { $0.quickLabel == id }   // "" = No Label
        case .unflagged: base = photos.filter { !$0.quickFlag }
        case .keyword(let k): let pre = k + "/"; base = photos.filter { $0.quickKeywords.contains { $0 == k || $0.hasPrefix(pre) } }
        case .rating(let n): base = photos.filter { $0.quickRating == n }
        case .people: base = []
        case .person(let id): let ids = FaceIndex.shared.photoIds(person: id); base = photos.filter { ids.contains($0.id) }
        case .faceGroup(let g): let ids = FaceIndex.shared.photoIds(group: g); base = photos.filter { ids.contains($0.id) }
        case .together(let k): let ids = FaceIndex.shared.photoIds(together: k.split(separator: ",").compactMap { Int($0) }); base = photos.filter { ids.contains($0.id) }
        case .place(let c, let t):
            base = photos.filter { p in guard let pl = p.place, (pl["c"] as? String ?? "") == c else { return false }; return t == nil || (pl["t"] as? String) == t }
        case .days: base = photos
        case .noDate: base = photos.filter { $0.quickNoDate }
        case .onThisDay:
            let t = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            base = photos.filter { let c = $0.ymd; return !$0.quickNoDate && c.m == t.month && c.d == t.day && c.y < (t.year ?? 0) }
        case .decade(let d): base = photos.filter { !$0.quickNoDate && $0.ymd.y / 10 * 10 == d }
        case .date(let y, let m, let d):
            base = photos.filter { let c = $0.ymd; return c.y == y && (m == nil || c.m == m) && (d == nil || c.d == d) }
        }
        let wantRejected = filter == .rejected || source == .rejected
        var l = wantRejected ? base.filter { !$0.quickDeleted && $0.quickRejected } : base.filter(\.quickLive)
        switch filter {
        case .unrated: l = l.filter { $0.quickRating == 0 }
        case .r1, .r2, .r3, .r4, .r5:
            let n = [RatingFilter.r1, .r2, .r3, .r4, .r5].firstIndex(of: filter)! + 1
            l = l.filter { $0.quickRating >= n }
        case .flagged: l = l.filter { $0.quickFlag }
        default: break
        }
        if !q.isEmpty {
            // plain words: people, places, dates and stars are understood, and the rest matched against what's in the pictures
            if let found = NaturalSearch.shared.run(query, lib: self, in: l) {
                l = found.photos
                if found.ranked { return l }                               // best matches first
            } else {
                let fi = FaceIndex.shared, idx = SearchIndex.shared
                l = l.filter { p in let t = p.searchText + " " + fi.nameText(p.id) + " " + (idx.words[p.id] ?? ""); return q.allSatisfy { t.contains($0) } }
            }
        }
        if case .album(let id) = source, albums.first(where: { $0.id == id })?.type != "smart" { return l }   // collections keep their own order
        guard let sort else { return l }                                   // counting only: no need to sort
        switch sort {
        case .dateAsc: break                                  // the library is always kept in date order already
        case .dateDesc: l.reverse()
        case .name:
            // each name worked out once, not twice per comparison
            let names = l.map(\.quickFileName)
            l = zip(l, names).sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map(\.0)
        case .rating: l.sort { $0.quickRating != $1.quickRating ? $0.quickRating > $1.quickRating : $0.quickDate < $1.quickDate }
        case .added: l.sort { $0.quickAdded != $1.quickAdded ? $0.quickAdded > $1.quickAdded : $0.quickDate < $1.quickDate }
        }
        return l
    }
    func count(_ source: Source) -> Int { list(source: source, filter: .all, query: "", sort: nil).count }

    /// Sub-folders of a folder, from the photos inside it.
    func subfolders(of dir: String) -> [String] {
        var out = Set<String>()
        let prefix = dir + "/"
        for p in photos where p.quickPath.hasPrefix(prefix) {
            let rest = p.quickPath.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { out.insert(prefix + rest[..<slash]) }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func folderCount(_ dir: String) -> Int { let pre = dir + "/"; return photos.reduce(0) { $0 + ($1.quickPath.hasPrefix(pre) && $1.quickLive ? 1 : 0) } }

    var allKeywords: [String] {
        var s = Set<String>(); for p in photos { s.formUnion(p.keywords) }
        if let k = lib["keywords"] as? [String] { s.formUnion(k) }
        return s.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: editing metadata
    func setRating(_ ps: [Photo], _ n: Int) {
        let unreject = n > 0 && ps.contains { $0.rejected }
        for p in ps { p.rating = n; if n > 0 { p.rejected = false } }
        changed(ps, unreject ? ["rating", "rejected"] : ["rating"])
    }
    func toggleFlag(_ ps: [Photo]) {
        let v = !(ps.first?.flag ?? false), unreject = v && ps.contains { $0.rejected }
        for p in ps { p.flag = v; if v { p.rejected = false } }
        changed(ps, unreject ? ["flag", "rejected"] : ["flag"])
    }
    func toggleReject(_ ps: [Photo]) { let v = !(ps.first?.rejected ?? false); for p in ps { p.rejected = v; if v { p.flag = false; p.rating = 0 } }; changed(ps, ["rejected", "flag", "rating"]) }
    func setLabel(_ ps: [Photo], _ l: String?) { for p in ps { p.label = l }; changed(ps, ["label"]) }
    func rotate(_ ps: [Photo], _ dir: Int) { for p in ps { p.rot = ((p.rot + dir) % 4 + 4) % 4 }; changed(ps, ["rot"]) }
    func addKeyword(_ ps: [Photo], _ k: String) {
        let k = k.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " > ", with: "/")
        guard !k.isEmpty else { return }
        for p in ps where !p.keywords.contains(k) { p.keywords.append(k) }
        changed(ps, ["keywords"])
    }
    /// Renames a keyword (and its children) on every photo.
    func renameKeyword(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " > ", with: "/")
        guard !n.isEmpty, n != old else { return }
        var touched: [Photo] = []
        for p in photos where p.keywords.contains(where: { $0 == old || $0.hasPrefix(old + "/") }) {
            p.keywords = Array(NSOrderedSet(array: p.keywords.map { $0 == old ? n : $0.hasPrefix(old + "/") ? n + $0.dropFirst(old.count) : $0 })) as! [String]
            touched.append(p)
        }
        changed(touched, ["keywords"])
    }
    /// Takes a keyword (and its children) off every photo.
    func deleteKeyword(_ k: String) {
        let ps = photos.filter { $0.keywords.contains { $0 == k || $0.hasPrefix(k + "/") } }
        for p in ps { p.keywords.removeAll { $0 == k || $0.hasPrefix(k + "/") } }
        changed(ps, ["keywords"])
    }
    func removeKeyword(_ ps: [Photo], _ k: String) { for p in ps { p.keywords.removeAll { $0 == k } }; changed(ps, ["keywords"]) }
    func setText(_ p: Photo, name: String? = nil, caption: String? = nil) {
        if let name { p.name = name }; if let caption { p.caption = caption }
        changed([p], ["name", "caption"])
    }
    func newAlbum(named n: String, with ids: [Int]) -> Album {
        let a = Album(id: "a" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 1000...9999)), type: "album", name: n, parent: nil, ids: ids)
        albums.append(a); libChanged(); return a
    }
    func addToAlbum(_ id: String, _ ps: [Photo]) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        for p in ps where !albums[i].ids.contains(p.id) { albums[i].ids.append(p.id) }
        libChanged()
    }
}


// MARK: - the SQLite catalog
extension Library {
    /// Photo rows → photos, spread over all the Mac's cores (260K rows decode in a second or two).
    static func decodeRows(_ rows: [Data]) -> [Photo] {
        let n = rows.count
        guard n > 0 else { return [] }
        let chunks = max(1, min(32, n / 2000))
        var parts = [[Photo]](repeating: [], count: chunks)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * n / chunks, hi = (c + 1) * n / chunks
            var out: [Photo] = []; out.reserveCapacity(hi - lo)
            for i in lo..<hi {
                if let d = try? JSONSerialization.jsonObject(with: rows[i]) as? [String: Any], let p = Photo(dict: d) { out.append(p) }
            }
            lock.lock(); parts[c] = out; lock.unlock()
        }
        return parts.flatMap { $0 }
    }

    /// One-time move from the JSON catalog to the database. The .apcat (and its journal) are left exactly as they
    /// were, as a backup; if the copy doesn't check out, the database is thrown away and nothing changes.
    func convertToDatabase() {
        let url = dbURL
        let rowsOnMain: [(Int, [String: Any])] = photos.map { ($0.id, $0.dict()) }
        var meta = raw; meta["version"] = 4; meta["nextId"] = nextId
        let fs = folders.map { ["id": $0.id, "path": $0.path, "name": $0.name] }
        let l = lib, fc = faces, total = rowsOnMain.count, albumCount = albums.count
        let title = "Converting catalog to the new database"
        Activity.shared.report("convert", title, done: 0, total: max(1, total))
        converting = true; convertTouched = []; convertLib = false
        status = "Converting the catalog to the faster database… your original catalog is kept as a backup."
        io.async { [weak self] in
            try? FileManager.default.removeItem(at: url)
            guard let d = CatalogDB(url: url) else { Activity.shared.finish("convert"); return }
            var ok = true
            for (k, v) in [("meta", meta as Any), ("folders", fs as Any), ("lib", l as Any), ("faces", fc as Any)] {
                if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) { d.setValue(k, data) } else { ok = false }
            }
            var batch: [(Int, Data)] = []
            for (i, r) in rowsOnMain.enumerated() {
                if let data = try? JSONSerialization.data(withJSONObject: r.1) { batch.append((r.0, data)) } else { ok = false }
                if batch.count == 2000 || i == total - 1 {
                    d.writePhotos(batch); batch = []
                    Activity.shared.report("convert", title, done: i + 1, total: max(1, total))
                }
            }
            // check it: same number of photos and collections as the JSON catalog
            let lib2 = d.value("lib") as? [String: Any]
            ok = ok && d.photoCount == total && ((lib2?["albums"] as? [Any])?.count ?? 0) == ((l["albums"] as? [Any])?.count ?? 0)
            d.checkpoint()
            DispatchQueue.main.async {
                Activity.shared.finish("convert")
                guard let self else { return }
                self.converting = false
                if ok {
                    // anything changed while converting goes in too, then from now on every change is saved straight to the database
                    let touched: [(Int, Data)] = self.convertTouched.compactMap { id in self.byId[id].flatMap { p in (try? JSONSerialization.data(withJSONObject: p.dict())).map { (id, $0) } } }
                    let libData = self.convertLib ? try? JSONSerialization.data(withJSONObject: self.lib) : nil
                    self.io.async { d.writePhotos(touched); if let libData { d.setValue("lib", libData) } }
                    self.convertTouched = []
                    self.db = d
                    self.scheduleSave(1)
                    self.dbWrite { FaceIndex.shared.load($0); SearchIndex.shared.load($0) }          // People and Search can start now
                    self.status = "The catalog now uses the new database: \(total.formatted()) photos, \(albumCount.formatted()) collections. The old catalog file is kept as a backup."
                } else {
                    d.close(); try? FileManager.default.removeItem(at: url)
                    for x in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + x) }
                    self.status = "Couldn't convert the catalog — still using the old one, nothing changed."
                }
            }
        }
    }

    /// Runs database work on the catalog's own queue (so writes never overlap).
    func dbWrite(_ work: @escaping (CatalogDB) -> Void) {
        guard let db else { return }
        io.async { work(db) }
    }

    /// File ▸ Export Catalog as JSON… — a copy in the old format (for the Electron version, or as an extra backup).
    func exportJSON() {
        let p = NSSavePanel()
        p.nameFieldStringValue = catFile.deletingPathExtension().lastPathComponent + " (export).apcat"
        p.message = "A copy of the catalog in the older JSON format. Your library keeps using the database."
        guard p.runModal() == .OK, let u = p.url, let data = catalogJSON() else { return }
        do { try data.write(to: u, options: .atomic); status = "Exported the catalog to “\(u.lastPathComponent)”." }
        catch { fail("Couldn't export the catalog.", error) }
    }
}

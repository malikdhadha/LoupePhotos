import AppKit
import ImageIO
import CryptoKit
import Observation

/// File ▸ Import… (⇧⌘I): photos from a memory card or any folder, copied safely into one of your library folders —
/// organised into dated folders, already-imported photos skipped, every copy checked, optional backup copy,
/// keywords and caption, and the previews you want. Nothing is ever deleted from the source.
@Observable
final class Importer {
    static let shared = Importer()

    struct Source: Identifiable, Hashable {
        enum Kind { case card, folder, files }
        let url: URL
        let name: String
        let kind: Kind
        var id: String { url.path }
    }
    struct Item: Identifiable, Hashable {
        let url: URL
        let size: Int
        var date: Date
        let sidecar: URL?            // the .xmp beside it, which travels with it
        var imported: Bool           // already in the library
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    var cards: [Source] = []
    var folders: [Source] = []
    var current: Source?
    var items: [Item] = []
    var loading = false
    var selection = Set<String>()
    var hideImported = true

    // running
    var running = false
    var done = 0
    var total = 0
    var message = ""
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private let pauseLock = NSCondition()

    // choices, remembered
    private static let d = UserDefaults.standard
    /// Where imports go: any folder. The last one you chose is the default; if it isn't available (a drive not plugged in),
    /// imports go to My Pictures (your first library folder) instead.
    var destPath: String = d.string(forKey: "imp.destPath") ?? "" { didSet { Importer.d.set(destPath, forKey: "imp.destPath"); remember(destPath) } }
    var recentDests: [String] = d.stringArray(forKey: "imp.recentDests") ?? [] { didSet { Importer.d.set(recentDests, forKey: "imp.recentDests") } }
    private func remember(_ p: String) {
        guard !p.isEmpty, !Library.shared.folders.contains(where: { $0.path == p }) else { return }
        recentDests = Array(([p] + recentDests.filter { $0 != p }).prefix(5))
    }
    static func exists(_ p: String) -> Bool { var dir: ObjCBool = false; return !p.isEmpty && FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue }
    /// The fallback: "My Pictures" if you have a library folder by that name, otherwise the first one that's available.
    var fallbackDest: String? {
        let online = Library.shared.folders.filter { !$0.offline && Importer.exists($0.path) }
        return (online.first { $0.name.localizedCaseInsensitiveCompare("My Pictures") == .orderedSame } ?? online.first)?.path
    }
    /// Where this import will actually go, and whether that's the fallback because your usual folder isn't there.
    var effectiveDest: (path: String, rerouted: Bool)? {
        if Importer.exists(destPath) { return (destPath, false) }
        return fallbackDest.map { ($0, !destPath.isEmpty) }
    }
    func chooseDestination() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Import Here"; p.message = "Choose where imported photos go. Folders outside your library are added to it."
        if Importer.exists(destPath) { p.directoryURL = URL(fileURLWithPath: destPath) }
        Importer.present(p) { u in self.destPath = u.standardizedFileURL.path }
    }
    /// Shows an Open panel attached to the Import window (so it can never end up hidden behind it),
    /// a moment later — never from inside a menu that's still closing, which is what left it hidden before.
    static func present(_ p: NSOpenPanel, _ chosen: @escaping (URL) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.title == "Import" && $0.isVisible }) {
                w.makeKeyAndOrderFront(nil)
                p.beginSheetModal(for: w) { r in if r == .OK, let u = p.url { chosen(u) } }
            } else if p.runModal() == .OK, let u = p.url { chosen(u) }
        }
    }
    var organise: String = d.string(forKey: "imp.org") ?? "ymd" { didSet { Importer.d.set(organise, forKey: "imp.org") } }
    var event: String = ""
    /// A metadata preset put on every photo as it comes in (copyright and contact, say).
    var metaPreset: String = d.string(forKey: "imp.preset") ?? "" { didSet { Importer.d.set(metaPreset, forKey: "imp.preset") } }
    var rename: Bool = d.bool(forKey: "imp.rename") { didSet { Importer.d.set(rename, forKey: "imp.rename") } }
    var renameBase: String = d.string(forKey: "imp.renameBase") ?? "" { didSet { Importer.d.set(renameBase, forKey: "imp.renameBase") } }
    var keywords: String = ""
    var caption: String = ""
    /// Previews for this import: RAW files and the rest separately. Start from Settings ▸ Previews each time the window opens.
    var previews: PreviewSettings.OnImport = PreviewSettings.shared.onImport
    var previewsRaw: PreviewSettings.OnImport = PreviewSettings.shared.onImportRaw
    func previewsFromSettings() { previews = PreviewSettings.shared.onImport; previewsRaw = PreviewSettings.shared.onImportRaw }
    var backup: Bool = d.bool(forKey: "imp.backup") { didSet { Importer.d.set(backup, forKey: "imp.backup") } }
    var backupPath: String = d.string(forKey: "imp.backupPath") ?? "" { didSet { Importer.d.set(backupPath, forKey: "imp.backupPath") } }
    var eject: Bool = d.object(forKey: "imp.eject") as? Bool ?? true { didSet { Importer.d.set(eject, forKey: "imp.eject") } }
    var autoOpen: Bool = d.object(forKey: "imp.autoOpen") as? Bool ?? true { didSet { Importer.d.set(autoOpen, forKey: "imp.autoOpen") } }

    init() {
        if destPath.isEmpty, let old = Importer.d.string(forKey: "imp.dest"), let f = Library.shared.folders.first(where: { $0.id == old }) { destPath = f.path }
    }

    static let organiseChoices: [(String, String)] = [("ymd", "Year / Year-Month-Day"), ("ym", "Year / Year-Month"), ("day", "Year-Month-Day"), ("none", "One folder")]

    // MARK: sources
    @ObservationIgnored private var watching = false
    /// Watches for cards going in and out. A new card opens the Import window (if that's on).
    func startWatching() {
        guard !watching else { return }
        watching = true
        refreshCards()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let before = Set(self.cards.map(\.id))
            self.refreshCards()
            if let new = self.cards.first(where: { !before.contains($0.id) }) {
                if self.autoOpen && !self.running {
                    self.choose(new)
                    NotificationCenter.default.post(name: .openImport, object: nil)
                }
            }
            _ = n
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshCards()
            if let c = self.current, c.kind == .card, !self.cards.contains(c) { self.current = nil; self.items = [] }
        }
    }
    /// Memory cards (and cameras mounted as disks): any mounted volume with a DCIM folder.
    func refreshCards() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        cards = vols.compactMap { v in
            guard v.path != "/", FileManager.default.fileExists(atPath: v.appendingPathComponent("DCIM").path) else { return nil }
            let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
            return Source(url: v, name: name, kind: .card)
        }
    }
    /// Files and folders chosen one by one, or dragged in from Finder.
    @ObservationIgnored private var picked: [String: [URL]] = [:]
    @ObservationIgnored private var pickCount = 0
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pickCount += 1
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let s = Source(url: URL(fileURLWithPath: "/.aperture-pro-chosen/\(pickCount)"), name: name, kind: .files)
        picked[s.id] = urls
        folders.append(s)
        choose(s)
    }
    /// The real folders behind a chosen/dropped source (for "Add Where They Are").
    var chosenFolders: [URL] {
        guard let s = current else { return [] }
        if s.kind == .folder { return [s.url] }
        guard s.kind == .files else { return [] }
        return (picked[s.id] ?? []).filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
    }
    func chooseFiles() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true; p.prompt = "Choose"
        p.message = "Choose photos (or folders) to import."
        Importer.presentMany(p) { urls in self.addFiles(urls) }
    }
    static func presentMany(_ p: NSOpenPanel, _ chosen: @escaping ([URL]) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.title == "Import" && $0.isVisible }) {
                w.makeKeyAndOrderFront(nil)
                p.beginSheetModal(for: w) { r in if r == .OK { chosen(p.urls) } }
            } else if p.runModal() == .OK { chosen(p.urls) }
        }
    }
    func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Choose"
        p.message = "Choose a folder of photos to import from."
        Importer.present(p) { u in
            let s = Source(url: u, name: u.lastPathComponent, kind: .folder)
            if !self.folders.contains(s) { self.folders.append(s) }
            self.choose(s)
        }
    }

    // MARK: what's on the source
    @ObservationIgnored private var loadGen = 0
    func choose(_ s: Source) {
        current = s; items = []; selection = []; loading = true
        loadGen += 1; let gen = loadGen
        let lib = Library.shared
        // what's already in the library: same name and size, or same size and capture time (renamed on import)
        var nameSize = Set<String>(), sizeTime = Set<String>()
        for p in lib.photos where p.deleted == nil {
            nameSize.insert(p.fileName.lowercased() + "|\(p.size)")
            if !p.dateFromFile { sizeTime.insert("\(p.size)|\(Int(p.date / 1000))") }
        }
        let roots = s.kind == .files ? (picked[s.id] ?? []) : [s.kind == .card ? s.url.appendingPathComponent("DCIM") : s.url]
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [(URL, Int, Date)] = []
            var xmp: [String: URL] = [:]
            for root in roots {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
            // a single file chosen or dropped: it, and its .xmp if one sits beside it
            let list: [URL]
            if isDir.boolValue {
                list = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL]) ?? []
            } else {
                let side = root.deletingPathExtension().appendingPathExtension("xmp")
                list = [root] + (FileManager.default.fileExists(atPath: side.path) ? [side] : [])
            }
            do {
                for u in list {
                    let ext = u.pathExtension.lowercased()
                    if ext == "xmp" { xmp[u.deletingPathExtension().path.lowercased()] = u; continue }
                    guard Photo.imageExt.contains(ext) else { continue }
                    let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                    guard v?.isRegularFile == true else { continue }
                    files.append((u, v?.fileSize ?? 0, v?.contentModificationDate ?? Date()))
                }
            }
            }
            // capture dates (from the files themselves), several at once
            var dates = [Date?](repeating: nil, count: files.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let d = Importer.captureDate(files[i].0)
                lock.lock(); dates[i] = d; lock.unlock()
            }
            var out: [Item] = []
            for (i, f) in files.enumerated() {
                let date = dates[i] ?? f.2
                let known = nameSize.contains(f.0.lastPathComponent.lowercased() + "|\(f.1)")
                    || (dates[i] != nil && sizeTime.contains("\(f.1)|\(Int(date.timeIntervalSince1970))"))
                out.append(Item(url: f.0, size: f.1, date: date, sidecar: xmp[f.0.deletingPathExtension().path.lowercased()], imported: known))
            }
            out.sort { $0.date < $1.date }
            DispatchQueue.main.async {
                guard gen == self.loadGen else { return }
                self.items = out
                self.selection = Set(out.filter { !$0.imported }.map(\.id))      // everything new, ready to go
                self.loading = false
            }
        }
    }
    static func captureDate(_ u: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        guard let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String else { return nil }
        return Metadata.exifDate.date(from: s)
    }
    var newCount: Int { items.lazy.filter { !$0.imported }.count }
    /// A folder that is (or is inside, or holds) one of your library folders: its photos are already where they belong.
    var insideLibrary: Folder? {
        guard let s = current, s.kind == .folder else { return nil }
        let p = s.url.standardizedFileURL.path
        return Library.shared.folders.first { p == $0.path || p.hasPrefix($0.path + "/") || $0.path.hasPrefix(p + "/") }
    }

    // MARK: importing
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    private static let monthFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    private static let yearFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// The folder (inside the destination) a photo taken on `date` goes into.
    func subfolder(for date: Date) -> String {
        let ev = event.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let day = Importer.dayFormat.string(from: date) + (ev.isEmpty ? "" : " " + ev)
        switch organise {
        case "ym": return Importer.yearFormat.string(from: date) + "/" + Importer.monthFormat.string(from: date) + (ev.isEmpty ? "" : " " + ev)
        case "day": return day
        case "none": return ev
        default: return Importer.yearFormat.string(from: date) + "/" + day
        }
    }

    func setPaused(_ on: Bool) { pauseLock.lock(); paused = on; pauseLock.broadcast(); pauseLock.unlock() }
    func cancel() { cancelled = true; setPaused(false) }

    func start(_ chosen: [Item]) {
        guard !running, !chosen.isEmpty, let source = current, insideLibrary == nil else { return }
        guard let target = effectiveDest else {
            message = "Choose where the photos go (Into), or add a library folder first."; return
        }
        let destDir = target.path
        if backup && backupPath.isEmpty { message = "Choose where the backup copies go, or turn Backup off."; return }
        running = true; done = 0; total = chosen.count; message = ""; cancelled = false; paused = false
        let plan = chosen.sorted { $0.date < $1.date }
        let folders = plan.map { subfolder(for: $0.date) }
        let renameTo = rename ? renameBase.trimmingCharacters(in: .whitespaces) : ""
        let backupRoot = backup ? backupPath : ""
        let job = "import"
        Activity.shared.report(job, "Importing from “\(source.name)”", done: 0, total: plan.count) { [weak self] on in self?.setPaused(on) }
        FolderWatcher.shared.stop()                       // this import adds the photos itself

        DispatchQueue.global(qos: .userInitiated).async {
            var copied: [String] = [], skipped = 0, failed: [String] = []
            var seq = 0
            for (i, item) in plan.enumerated() {
                self.pauseLock.lock(); while self.paused && !self.cancelled { self.pauseLock.wait() }; self.pauseLock.unlock()
                if self.cancelled { break }
                autoreleasepool {
                    let dir = URL(fileURLWithPath: destDir).appendingPathComponent(folders[i])
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let ext = item.url.pathExtension
                    var base = item.url.deletingPathExtension().lastPathComponent
                    if !renameTo.isEmpty { seq += 1; base = renameTo + " " + String(format: "%03d", seq) }
                    var target = dir.appendingPathComponent(base).appendingPathExtension(ext)
                    // already there (an earlier, interrupted import)? then it counts as done
                    if let a = try? FileManager.default.attributesOfItem(atPath: target.path), (a[.size] as? Int) == item.size {
                        skipped += 1; copied.append(target.path); return
                    }
                    var n = 1
                    while FileManager.default.fileExists(atPath: target.path) { target = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext); n += 1 }
                    if Importer.copyChecked(item.url, to: target) {
                        copied.append(target.path)
                        if let x = item.sidecar { _ = Importer.copyChecked(x, to: target.deletingPathExtension().appendingPathExtension("xmp")) }
                        if !backupRoot.isEmpty {
                            let bdir = URL(fileURLWithPath: backupRoot).appendingPathComponent(folders[i])
                            try? FileManager.default.createDirectory(at: bdir, withIntermediateDirectories: true)
                            if !Importer.copyChecked(target, to: bdir.appendingPathComponent(target.lastPathComponent)) { failed.append(item.name + " (backup)") }
                        }
                    } else { failed.append(item.name) }
                }
                let k = i + 1
                if k % 3 == 0 || k == plan.count {
                    DispatchQueue.main.async { self.done = k }
                    Activity.shared.report(job, "Importing from “\(source.name)”", done: k, total: plan.count + 1)
                }
            }
            DispatchQueue.main.async { self.finish(copied: copied, skipped: skipped, failed: failed, destDir: destDir, rerouted: target.rerouted, source: source) }
        }
    }

    /// Copies a file, then reads both and compares them; only a perfect copy counts. The original is left alone.
    static func copyChecked(_ from: URL, to: URL) -> Bool {
        let tmp = to.deletingLastPathComponent().appendingPathComponent(".apimport-" + to.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        guard let input = InputStream(url: from), let output = OutputStream(url: tmp, append: false) else { return false }
        input.open(); output.open()
        var hash = Insecure.MD5()
        let size = 4 << 20
        var buf = [UInt8](repeating: 0, count: size)
        var ok = true
        while true {
            let n = input.read(&buf, maxLength: size)
            if n < 0 { ok = false; break }
            if n == 0 { break }
            hash.update(data: buf[0..<n])
            var w = 0
            while w < n { let m = buf[w..<n].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: n - w) }; if m <= 0 { ok = false; break }; w += m }
            if !ok { break }
        }
        input.close(); output.close()
        guard ok else { try? FileManager.default.removeItem(at: tmp); return false }
        // read the copy back and compare
        guard let back = InputStream(url: tmp) else { return false }
        back.open()
        var h2 = Insecure.MD5()
        while true { let n = back.read(&buf, maxLength: size); if n <= 0 { break }; h2.update(data: buf[0..<n]) }
        back.close()
        guard hash.finalize() == h2.finalize() else { try? FileManager.default.removeItem(at: tmp); return false }
        if let a = try? FileManager.default.attributesOfItem(atPath: from.path), let m = a[.modificationDate] {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: tmp.path)
        }
        do { try FileManager.default.moveItem(at: tmp, to: to) } catch { try? FileManager.default.removeItem(at: tmp); return false }
        return true
    }

    private func finish(copied: [String], skipped: Int, failed: [String], destDir: String, rerouted: Bool, source: Source) {
        let lib = Library.shared
        Activity.shared.finish("import")
        let wanted = Set(copied)
        let kws = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cap = caption.trimmingCharacters(in: .whitespaces)
        let level = previews, levelRaw = previewsRaw
        let preset = MetadataPresets.shared.preset(metaPreset)
        let after: ([Photo]) -> Void = { [weak self] made in
            guard let self else { return }
            let mine = made.filter { wanted.contains($0.path) }
            for k in kws { lib.addKeyword(mine, k) }
            if !cap.isEmpty { for p in mine { lib.setText(p, caption: cap) } }
            if let preset { lib.setIPTC(mine, preset.values, replace: false) }
            PreviewSettings.shared.buildForNew(mine, raw: levelRaw, other: level)
            FolderWatcher.shared.start(lib)
            var parts = ["Imported \(copied.count - skipped) photo\(copied.count - skipped == 1 ? "" : "s")"]
            if skipped > 0 { parts.append("\(skipped) were already there") }
            if !failed.isEmpty { parts.append("\(failed.count) couldn't be copied: " + failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? "…" : "")) }
            if self.cancelled { parts.insert("Stopped", at: 0) }
            if rerouted { parts.append("your usual folder wasn't available, so they went to “\((destDir as NSString).lastPathComponent)”") }
            self.message = parts.joined(separator: " · ") + "."
            lib.status = self.message
            self.running = false
            // mark what's now in the library
            for i in self.items.indices where self.selection.contains(self.items[i].id) && !failed.contains(self.items[i].name) { self.items[i].imported = true }
            self.selection = []
            if source.kind == .card && self.eject && failed.isEmpty && !self.cancelled {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: source.url); self.message += " The card was ejected — it's safe to remove." }
                catch { self.message += " (The card couldn't be ejected — eject it in Finder.)" }
            }
            if !mine.isEmpty {
                // all went well: the Import window closes and the library shows what came in (it stays open if anything failed)
                NotificationCenter.default.post(name: .importFinished, object: nil, userInfo: ["close": failed.isEmpty && !self.cancelled])
            }
        }
        // inside a library folder: read that folder; anywhere else: it becomes a library folder
        if let root = lib.rootFor(destDir) { lib.scan(root, under: destDir == root.path ? nil : destDir, handlesPreviews: true, done: after) }   // just where they went
        else { lib.addFolder(URL(fileURLWithPath: destDir), done: after) }
    }
}

extension Notification.Name {
    static let openImport = Notification.Name("apOpenImport")
    static let importFinished = Notification.Name("apImportFinished")
}

extension PreviewSettings.OnImport {
    var importKey: String { switch self { case .standard: return "standard"; case .full: return "full"; case .thumbnails: return "thumbs" } }
}

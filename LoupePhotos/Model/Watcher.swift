import AppKit
import CoreServices
import Observation

/// Watches your library folders: photos copied in (from a card, AirDrop, another app) are added by themselves —
/// faces found, named and ready to search — without pressing Synchronize. Settings ▸ Library can turn it off.
final class FolderWatcher {
    static let shared = FolderWatcher()
    static var enabled: Bool { UserDefaults.standard.object(forKey: "watch.folders") as? Bool ?? true }
    private var stream: FSEventStreamRef?
    private var pending: [String: Set<String>] = [:]   // library folder → the sub-folders with something new
    private var work: DispatchWorkItem?

    func start(_ lib: Library) {
        stop()
        guard FolderWatcher.enabled else { return }
        let paths = lib.folders.filter { !$0.offline }.map(\.path)
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(eventPaths, to: NSArray.self)
            me.changed((0..<count).compactMap { arr[$0] as? String })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
    func stop() {
        work?.cancel(); pending = [:]
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil
    }
    /// Something changed on disk: wait until it's been quiet for 20 seconds (a card can take a while to copy), then read those folders.
    private func changed(_ paths: [String]) {
        let lib = Library.shared
        for p in paths {
            let ext = (p as NSString).pathExtension.lowercased()
            guard ext.isEmpty || Photo.imageExt.contains(ext) else { continue }     // sidecars, catalogs and the like don't matter
            if (p as NSString).lastPathComponent.hasPrefix(".") { continue }
            if let r = lib.rootFor(p), !r.offline {
                let dir = ext.isEmpty ? p : (p as NSString).deletingLastPathComponent
                pending[r.id, default: []].insert(dir)
            }
        }
        guard !pending.isEmpty else { return }
        work?.cancel()
        schedule(after: 20)
    }
    /// Reads the changed folders once things are quiet — and not while a folder is already being read
    /// (on a big library one read takes a while; starting another on top only doubles the work).
    private func schedule(after seconds: Double) {
        let lib = Library.shared
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Activity.shared.jobs.contains(where: { $0.id.hasPrefix("scan-") }) { self.schedule(after: 15); return }
            let want = self.pending; self.pending = [:]
            for f in lib.folders where !f.offline {
                guard var dirs = want[f.id] else { continue }
                // only the folders that changed (the whole library folder if it was many, or the top itself)
                dirs = dirs.filter { d in !dirs.contains { $0 != d && d.hasPrefix($0 + "/") } }      // a folder covers those inside it
                if dirs.count > 8 || dirs.contains(where: { $0 == f.path || !$0.hasPrefix(f.path + "/") }) { lib.scan(f) }
                else { for d in dirs.sorted() { lib.scan(f, under: d) } }
            }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

/// "While you were away": what happened by itself while you weren't using Loupe Photos —
/// photos added, faces named — shown once when you come back.
@Observable
final class AwayReport {
    static let shared = AwayReport()
    var added = 0
    var named = 0
    var showing = false
    @ObservationIgnored private var lastActive = Date()
    @ObservationIgnored private var monitor: Any?
    static var enabled: Bool { UserDefaults.standard.object(forKey: "away.summary") as? Bool ?? true }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] e in self?.touch(); return e }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.touch() }
    }
    /// You're here: if you've been gone 20 minutes or more and things happened, say what.
    private func touch() {
        let now = Date()
        if now.timeIntervalSince(lastActive) >= 20 * 60, added > 0 || named > 0, AwayReport.enabled {
            if !showing {
                showing = true
                for p in FaceIndex.shared.named { FaceIndex.shared.refreshCount(p.id) }     // how many faces are left to look at
            }
        } else if !showing {
            added = 0; named = 0                 // you were here when these happened
        }
        lastActive = now
    }
    func dismiss() { showing = false; added = 0; named = 0 }
}

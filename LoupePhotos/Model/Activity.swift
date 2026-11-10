import Foundation
import AppKit
import Observation

/// Background Tasks (like Lightroom Classic's activity menu under its name plate): every long job reports here,
/// so the status line stays quiet and you can see, pause or resume what's running.
@Observable
final class Activity {
    static let shared = Activity()

    struct Job: Identifiable {
        let id: String
        var title: String
        var done: Int
        var total: Int
        var paused = false
        var canPause: Bool
        var waiting: String? = nil
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        var detail: String { paused ? "Paused" : waiting ?? (total > 0 ? "\(done.formatted()) of \(total.formatted())" : "") }
    }
    private(set) var jobs: [Job] = [] { didSet { stayAwake(jobs.contains { !$0.paused }) } }
    @ObservationIgnored private var pausers: [String: (Bool) -> Void] = [:]
    /// While anything is running, macOS is asked not to put Loupe Photos to rest ("App Nap") when its window is hidden
    /// or in the background — so faces, search and previews keep going overnight at full speed. The Mac can still sleep.
    @ObservationIgnored private var awake: NSObjectProtocol?
    private func stayAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Background Tasks running")
        } else if !on, let a = awake {
            ProcessInfo.processInfo.endActivity(a); awake = nil
        }
    }

    /// Call from any thread. A job disappears once `done` reaches `total`.
    func report(_ id: String, _ title: String, done: Int, total: Int, pause: ((Bool) -> Void)? = nil) {
        let work = { [self] in
            if let pause { pausers[id] = pause }
            if done >= total { finish(id); return }
            if let i = jobs.firstIndex(where: { $0.id == id }) {
                jobs[i].title = title; jobs[i].done = done; jobs[i].total = total
            } else {
                jobs.append(Job(id: id, title: title, done: done, total: total, canPause: pausers[id] != nil))
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
    func finish(_ id: String) {
        let work = { [self] in jobs.removeAll { $0.id == id }; pausers.removeValue(forKey: id) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
    /// Shown instead of the count while BackgroundWork holds a job back.
    func setWaiting(_ id: String, _ why: String?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].waiting != why else { return }
        jobs[i].waiting = why
    }
    func togglePause(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), let p = pausers[id] else { return }
        jobs[i].paused.toggle()
        p(jobs[i].paused)
    }
    func pauseAll(_ on: Bool) {
        for j in jobs where j.canPause && j.paused != on { togglePause(j.id) }
    }
    /// One line for the button: the first running job and its percentage.
    var summary: String? {
        guard let j = jobs.first(where: { !$0.paused }) ?? jobs.first else { return nil }
        let more = jobs.count > 1 ? " +\(jobs.count - 1)" : ""
        return j.paused ? "\(j.title) — paused\(more)" : "\(j.title) \(Int(j.fraction * 100))%\(more)"
    }
}

/// How much work at once suits this Mac (an M1 Pro has 8 fast cores, an M1 Air 4), so background jobs
/// use a bigger Mac fully and leave a smaller one responsive.
enum Machine {
    static let fastCores: Int = {
        var n: Int32 = 0, size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()
    static func workers(_ share: Double, min lo: Int, max hi: Int) -> Int { Swift.min(hi, Swift.max(lo, Int((Double(fastCores) * share).rounded()))) }
}

/// Keeps background jobs out of each other's way, and yours: thumbnails come first (you see them), faces and search
/// wait until thumbnails are done and while you're scrolling or flipping through photos, and place names wait for
/// thumbnails too. Each job's own Pause (Background Tasks ▸ Pause All) works as before.
final class BackgroundWork {
    static let shared = BackgroundWork()
    private var timer: Timer?
    private var monitor: Any?
    private var lastInput = Date.distantPast
    private var powerChecked = Date.distantPast
    private var onBattery = false
    func start() {
        guard timer == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDragged, .magnify, .swipe]) { [weak self] e in
            self?.lastInput = Date(); return e
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func tick() {
        let jobs = Activity.shared.jobs
        // thumbnails still being made, or photos still coming in
        let first = jobs.contains { ($0.id == "thumbs" || $0.id == "import" || $0.id.hasPrefix("scan-")) && !$0.paused }
        let busy = Date().timeIntervalSince(lastInput) < 1.5          // you're scrolling, flipping or typing
        // on battery (a MacBook Air away from its charger): faces wait for power, unless switched off in Settings ▸ Library
        if Date().timeIntervalSince(powerChecked) > 10 { powerChecked = Date(); onBattery = SearchScanner.onBattery }
        let battery = onBattery && (UserDefaults.standard.object(forKey: "bg.battery") as? Bool ?? true)
        FaceScanner.shared.hold(first || busy || battery)
        Activity.shared.setWaiting("faces", first ? "Waiting for thumbnails" : battery ? "Waiting for power" : nil)
        SearchScanner.shared.hold(first || busy)
        PlaceNamer.shared.hold(first)
        CameraMatchJob.shared.hold(first || busy)
        Activity.shared.setWaiting("search", first ? "Waiting for thumbnails" : nil)
        Activity.shared.setWaiting("places", first ? "Waiting for thumbnails" : nil)
    }
}

/// Debug builds only: how long things take, written to Documents ▸ Loupe Photos timing.log (so slow spots are found,
/// not guessed). Sidebar clicks are timed from the click to the grid being drawn.
enum Timing {
    private static var started: (String, CFAbsoluteTime)?
    static func start(_ what: String) { started = (what, CFAbsoluteTimeGetCurrent()) }
    /// Called when the grid has drawn: closes the timing started by the last click.
    static func drawn() {
        guard let (what, t0) = started else { return }
        started = nil
        note(what + " (click to grid drawn)", since: t0, always: true)
    }
    static func note(_ what: String, since t0: CFAbsoluteTime, always: Bool = false) {
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard always || ms > 8 else { return }
        let line = String(format: "%@  %7.1f ms  %@\n", Date().formatted(date: .omitted, time: .standard), ms, what)
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Loupe Photos timing.log")
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: u) }
        #endif
    }
}

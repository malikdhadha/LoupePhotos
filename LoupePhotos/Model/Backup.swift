import AppKit

/// Catalog backups, like Lightroom Classic's: when you quit, every so often (your choice), a copy of the catalog —
/// ratings, keywords, collections, faces, people and the search index — goes to a folder you choose.
/// Previews aren't included (they can be made again). Settings ▸ Library ▸ Catalog Backup; File ▸ Back Up Catalog Now.
final class CatalogBackup {
    static let shared = CatalogBackup()
    enum When: String, CaseIterable, Identifiable {
        case never = "Never", everyQuit = "Every time Loupe Photos quits", daily = "Once a day, when quitting",
             weekly = "Once a week, when quitting", monthly = "Once a month, when quitting"
        var id: String { rawValue }
        var days: Double? { switch self { case .never: return nil; case .everyQuit: return 0; case .daily: return 1; case .weekly: return 7; case .monthly: return 30 } }
    }
    private let d = UserDefaults.standard
    var when: When { When(rawValue: d.string(forKey: "backup.when") ?? "") ?? .weekly }
    var ask: Bool { d.object(forKey: "backup.ask") as? Bool ?? true }
    var keep: Int { d.object(forKey: "backup.keep") as? Int ?? 10 }
    var last: Date? { (d.object(forKey: "backup.last") as? Double).map { Date(timeIntervalSince1970: $0) } }
    /// Where backups go: your choice, else a Backups folder inside the library (like Lightroom's).
    var folder: URL {
        if let p = d.string(forKey: "backup.folder"), !p.isEmpty { return URL(fileURLWithPath: p) }
        return Library.shared.dir.appendingPathComponent("Backups")
    }
    var due: Bool {
        guard let days = when.days else { return false }
        guard let last else { return true }
        return Date().timeIntervalSince(last) >= days * 86_400 - 3_600
    }
    /// Set while restoring, so quitting doesn't save over the restored catalog or back it up.
    var restoring = false

    // MARK: backing up
    /// Makes a backup now; `done` (on the main thread) gets where it went, or nil if it failed.
    func backUp(done: @escaping (URL?) -> Void) {
        let lib = Library.shared
        guard lib.loaded else { done(nil); return }
        lib.saveNow(wait: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let target = folder.appendingPathComponent(f.string(from: Date()))
        let keep = keep, root = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = lib.writeBackup(to: target)
            if ok { Self.prune(root, keep: keep) }
            DispatchQueue.main.async {
                if ok { self.d.set(Date().timeIntervalSince1970, forKey: "backup.last") }
                done(ok ? target : nil)
            }
        }
    }
    /// Keeps the newest `keep` backups (0 = all). Only folders this feature made (named by date) are touched.
    private static func prune(_ root: URL, keep: Int) {
        guard keep > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let ours = names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2} \d{4}$"#, options: .regularExpression) != nil }.sorted()
        for n in ours.dropLast(keep) { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
    }

    // MARK: on quit
    /// Called when quitting: asks (or not) and backs up if one is due. Returns .terminateLater while it works.
    func onQuit(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !restoring, Library.shared.loaded, due else { return .terminateNow }
        if ask {
            let a = NSAlert()
            a.messageText = "Back up the catalog before quitting?"
            let when = last.map { "The last backup was " + $0.formatted(date: .abbreviated, time: .shortened) + "." } ?? "It hasn't been backed up yet."
            a.informativeText = "\(when) Backups go to “\(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))”. You can change how often, and whether to ask, in Settings ▸ Library."
            a.addButton(withTitle: "Back Up"); a.addButton(withTitle: "Skip This Time")
            if a.runModal() != .alertFirstButtonReturn { return .terminateNow }
        }
        let panel = Self.progressPanel()
        panel.makeKeyAndOrderFront(nil)
        backUp { url in
            panel.orderOut(nil)
            if url == nil {
                let a = NSAlert(); a.messageText = "The catalog couldn't be backed up."
                a.informativeText = "Check that “\(self.folder.path)” is available and has room. Your catalog itself is fine."
                a.runModal()
            }
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private static func progressPanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Loupe Photos"
        let spin = NSProgressIndicator(frame: NSRect(x: 20, y: 25, width: 20, height: 20)); spin.style = .spinning; spin.startAnimation(nil)
        let t = NSTextField(labelWithString: "Backing up the catalog…"); t.frame = NSRect(x: 52, y: 26, width: 250, height: 18)
        p.contentView?.addSubview(spin); p.contentView?.addSubview(t)
        p.center(); p.level = .modalPanel
        return p
    }

    // MARK: menu and settings
    func backUpNowFromMenu() {
        Library.shared.status = "Backing up the catalog…"
        backUp { url in
            Library.shared.status = url == nil ? "The catalog couldn't be backed up." : "Catalog backed up to “\(url!.deletingLastPathComponent().lastPathComponent)”."
        }
    }
    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"; p.message = "Where should catalog backups go? Another drive is safest."
        if p.runModal() == .OK, let u = p.url { d.set(u.path, forKey: "backup.folder") }
    }

    // MARK: restoring
    /// File ▸ Restore Catalog Backup…: pick a backup; the current catalog is kept aside first, then Loupe Photos
    /// reopens with the backup.
    func restore() {
        let lib = Library.shared
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = folder
        p.prompt = "Restore"; p.message = "Choose a backup (a dated folder) to go back to."
        guard p.runModal() == .OK, let src = p.url else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
        guard let dbFile = items.first(where: { $0.hasSuffix(".apdb") }) ?? items.first(where: { $0.hasSuffix(".apcat") }) else {
            let a = NSAlert(); a.messageText = "That folder isn't a catalog backup."; a.informativeText = "Choose one of the dated folders inside the backups folder."; a.runModal(); return
        }
        _ = dbFile
        let a = NSAlert()
        a.messageText = "Go back to the backup from “\(src.lastPathComponent)”?"
        a.informativeText = "Changes made since then (ratings, keywords, collections, names) will be replaced by the backup. The current catalog is kept in “Before restore” inside the backups folder, so nothing is lost. Loupe Photos will reopen."
        a.addButton(withTitle: "Restore"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        restoring = true
        lib.close()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let aside = folder.appendingPathComponent("Before restore " + f.string(from: Date()))
        try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
        // the current catalog (and its database's side files) aside, then the backup in its place
        let db = lib.dbURL, cat = lib.catFile!
        for u in [db, URL(fileURLWithPath: db.path + "-wal"), URL(fileURLWithPath: db.path + "-shm"), cat, lib.journalURL, lib.journal1URL, lib.snapURL]
        where fm.fileExists(atPath: u.path) {
            try? fm.moveItem(at: u, to: aside.appendingPathComponent(u.lastPathComponent))
        }
        if let b = items.first(where: { $0.hasSuffix(".apdb") }) { try? fm.copyItem(at: src.appendingPathComponent(b), to: db) }
        if let b = items.first(where: { $0.hasSuffix(".apcat") }) { try? fm.copyItem(at: src.appendingPathComponent(b), to: cat) }
        if items.contains("Places.json"), let pl = PreviewStore.shared.url?.appendingPathComponent("Places.json") {
            try? fm.removeItem(at: pl); try? fm.copyItem(at: src.appendingPathComponent("Places.json"), to: pl)
        }
        let task = Process(); task.launchPath = "/usr/bin/open"; task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

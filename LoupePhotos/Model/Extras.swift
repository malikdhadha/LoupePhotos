import AppKit
import UniformTypeIdentifiers

/// Copy / paste settings (⇧⌘C / ⇧⌘V): stars, flag, label and keywords from one photo onto others.
struct CopiedSettings { let rating: Int; let flag: Bool; let rejected: Bool; let label: String?; let keywords: [String] }

extension UIState {
    func copySettings(_ lib: Library) {
        guard let p = primaryPhoto(lib) else { return }
        copied = CopiedSettings(rating: p.rating, flag: p.flag, rejected: p.rejected, label: p.label, keywords: p.keywords)
        lib.status = "Copied stars, flag, label and \(p.keywords.count) keyword\(p.keywords.count == 1 ? "" : "s") — ⇧⌘V pastes them."
    }
    func pasteSettings(_ lib: Library) {
        guard let c = copied else { return }
        let t = targets(lib)
        lib.setRating(t, c.rating)
        lib.setLabel(t, c.label)
        let flagWrong = t.filter { $0.flag != c.flag }
        if !flagWrong.isEmpty { for p in flagWrong { p.flag = c.flag; if c.flag { p.rejected = false } }; lib.changed(flagWrong, ["flag", "rejected"]) }
        for k in c.keywords { lib.addKeyword(t, k) }
        lib.status = "Pasted onto \(t.count) photo\(t.count == 1 ? "" : "s")."
    }
}

/// Open With… / Edit in (⌘E) / Set as Desktop Picture.
enum Outside {
    /// Apps that can open this kind of file, the default first.
    static func apps(for url: URL) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let def = NSWorkspace.shared.urlForApplication(toOpen: url)
        return ([def].compactMap { $0 } + all.filter { $0 != def }).reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
    }
    static func open(_ ps: [Photo], with app: URL) {
        NSWorkspace.shared.open(ps.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    static func name(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }

    /// ⌘E: opens the photos in your chosen editor (asks which one the first time).
    static func edit(_ ps: [Photo]) {
        guard !ps.isEmpty else { return }
        if let path = UserDefaults.standard.string(forKey: "editorApp"), FileManager.default.fileExists(atPath: path) {
            open(ps, with: URL(fileURLWithPath: path)); return
        }
        if let app = chooseEditor() { open(ps, with: app) }
    }
    @discardableResult
    static func chooseEditor() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the app ⌘E should open photos in (Photoshop, Pixelmator, Affinity Photo…)"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let u = panel.url else { return nil }
        UserDefaults.standard.set(u.path, forKey: "editorApp")
        return u
    }

    /// Puts the photo on every screen's desktop (RAW files go via their camera JPEG preview).
    static func setDesktop(_ p: Photo, lib: Library) {
        var url = p.url
        if p.isRaw || !["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains(p.ext) {
            guard let img = BigPreviews.render(p, .standard) else { return }
            let out = lib.dir.appendingPathComponent("Desktop Picture \(p.id % 2).jpg")   // alternate names so macOS notices the change
            guard let data = ThumbMaker.jpeg(img, q: 0.92), (try? data.write(to: out)) != nil else { return }
            url = out
        }
        for s in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [:]) }
        lib.status = "Set as desktop picture."
    }
}

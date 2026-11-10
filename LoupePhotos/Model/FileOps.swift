import AppKit

/// Folder and file management, like Lightroom Classic's Folders panel: every change here happens in Finder too.
extension Library {
    func rootFor(_ path: String) -> Folder? { folders.first { path == $0.path || path.hasPrefix($0.path + "/") } }
    func isRoot(_ path: String) -> Bool { folders.contains { $0.path == path } }

    /// After something moved on disk, point the catalog's photos (and known folders) at the new place.
    private func repath(from old: String, to new: String) {
        var moved: [Photo] = []
        for p in photos where p.path == old || p.path.hasPrefix(old + "/") {
            let np = new + p.path.dropFirst(old.count)
            pathIndex.removeValue(forKey: p.path)
            p.path = np
            pathIndex[np] = p.id
            if let r = rootFor(np) { p.fid = r.id }
            moved.append(p)
        }
        dirs = Set(dirs.map { $0 == old || $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 })
        if moved.isEmpty { version += 1 } else { changed(moved, ["path", "fid"]) }
    }

    // MARK: folders
    @discardableResult
    func createFolder(in parent: String, named name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), !n.hasPrefix(".") else { fail("“\(name)” can't be used as a folder name."); return nil }
        let path = (parent as NSString).appendingPathComponent(n)
        do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
        catch { fail("Couldn't create “\(n)”.", error); return nil }
        dirs.insert(path); version += 1
        return path
    }

    @discardableResult
    func renameFolder(_ path: String, to name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), !n.hasPrefix(".") else { fail("“\(name)” can't be used as a folder name."); return nil }
        let new = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(n)
        guard new != path else { return path }
        do { try FileManager.default.moveItem(atPath: path, toPath: new) } catch { fail("Couldn't rename the folder.", error); return nil }
        if let i = folders.firstIndex(where: { $0.path == path }) { folders[i].path = new; folders[i].name = n; scheduleSave(1) }
        repath(from: path, to: new)
        return new
    }

    /// Moves a folder (with everything in it) into another folder.
    @discardableResult
    func moveFolder(_ path: String, into dest: String) -> String? {
        let new = (dest as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        guard dest != path, !dest.hasPrefix(path + "/"), (path as NSString).deletingLastPathComponent != dest else { return nil }
        guard !FileManager.default.fileExists(atPath: new) else { fail("“\(dest.lastPart)” already has a folder called “\(path.lastPart)”."); return nil }
        do { try FileManager.default.moveItem(atPath: path, toPath: new) } catch { fail("Couldn't move the folder.", error); return nil }
        if isRoot(path) { folders.removeAll { $0.path == path }; scheduleSave(1) }      // it now lives inside another library folder
        repath(from: path, to: new)
        return new
    }

    /// Moves photos (and their .xmp sidecars) into a folder. Name clashes are skipped and reported.
    func movePhotos(_ ps: [Photo], to dest: String) {
        let fm = FileManager.default
        var moved: [Photo] = [], clashes: [String] = [], errors = 0
        for p in ps where p.dir != dest {
            let target = (dest as NSString).appendingPathComponent(p.fileName)
            if fm.fileExists(atPath: target) { clashes.append(p.fileName); continue }
            do { try fm.moveItem(atPath: p.path, toPath: target) } catch { errors += 1; continue }
            for side in sidecars(p.path) {
                try? fm.moveItem(atPath: side, toPath: (dest as NSString).appendingPathComponent(side.lastPart))
            }
            pathIndex.removeValue(forKey: p.path)
            p.path = target; pathIndex[target] = p.id
            if let r = rootFor(target) { p.fid = r.id }
            moved.append(p)
        }
        if !moved.isEmpty { changed(moved, ["path", "fid"]) }
        status = "Moved \(moved.count) photo\(moved.count == 1 ? "" : "s") to “\(dest.lastPart)”."
        if !clashes.isEmpty || errors > 0 {
            fail("\(clashes.count + errors) photo\(clashes.count + errors == 1 ? " wasn't" : "s weren't") moved." +
                 (clashes.isEmpty ? "" : " A file with the same name is already in “\(dest.lastPart)”: \(clashes.prefix(5).joined(separator: ", "))\(clashes.count > 5 ? "…" : "")."))
        }
    }
    private func sidecars(_ path: String) -> [String] {
        let base = (path as NSString).deletingPathExtension
        return [base + ".xmp", base + ".XMP", path + ".xmp"].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Lightroom's "Add Parent Folder": the folder above becomes the library folder.
    func addParentFolder(_ root: String) {
        addFolder(URL(fileURLWithPath: (root as NSString).deletingLastPathComponent))
    }

    /// Only empty folders can be thrown away from here (into the Trash, so it can be undone in Finder).
    func folderIsEmpty(_ path: String) -> Bool {
        // stops at the first real item instead of listing the whole folder
        guard let d = opendir(path) else { return false }
        defer { closedir(d) }
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." && name != ".DS_Store" { return false }
        }
        return true
    }
    func trashFolder(_ path: String) {
        guard folderIsEmpty(path), !isRoot(path) else { return }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch { fail("Couldn't move the folder to the Trash.", error); return }
        dirs.remove(path); version += 1
    }

    /// Takes a library folder (and its photos) out of Loupe Photos. Nothing on disk is touched.
    func removeLibraryFolder(_ root: Folder) {
        let ps = photos.filter { $0.fid == root.id || $0.path.hasPrefix(root.path + "/") }
        folders.removeAll { $0.id == root.id }
        dirs = dirs.filter { !($0 == root.path || $0.hasPrefix(root.path + "/")) }
        removeFromCatalog(ps)          // also saves the catalog
        FolderWatcher.shared.start(self)
        status = "Removed “\(root.name)” from the library. Its files are still on disk."
    }
    /// Moves a folder with its photos to the Trash (they can be put back from the Trash) and out of the catalog.
    func trashFolderWithPhotos(_ path: String) {
        guard !isRoot(path) else { return }
        let ps = photos.filter { $0.path.hasPrefix(path + "/") }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch { fail("Couldn't move the folder to the Trash.", error); return }
        dirs = dirs.filter { !($0 == path || $0.hasPrefix(path + "/")) }
        removeFromCatalog(ps)
        status = "Moved “\(path.lastPart)” and \(ps.count.formatted()) photo\(ps.count == 1 ? "" : "s") to the Trash."
    }

    // MARK: asking and telling
    func fail(_ message: String, _ error: Error? = nil) {
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = message
        if let e = error { a.informativeText = e.localizedDescription }
        a.runModal()
    }
    static func ask(_ title: String, _ info: String, value: String = "", ok: String) -> String? {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        let f = NSTextField(string: value); f.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = f; a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }
    static func confirm(_ title: String, _ info: String, ok: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

extension String { var lastPart: String { (self as NSString).lastPathComponent } }

// MARK: deleting photos
extension Library {
    /// Delete (⌫) and Photo ▸ Delete…: asks first — Move to Trash (files go to Finder's Trash and can be put back
    /// until it's emptied), or Remove from Catalog (files stay on disk). Returns whether anything was removed.
    @discardableResult
    func deletePhotos(_ ps: [Photo]) -> Bool {
        guard !ps.isEmpty else { return false }
        let n = ps.count
        let a = NSAlert()
        a.messageText = n == 1 ? "Delete “\(ps[0].displayName)”?" : "Delete \(n.formatted()) photos?"
        a.informativeText = "Move to Trash puts the file\(n == 1 ? "" : "s") (and any .xmp sidecars) in the Trash in Finder — you can put them back until the Trash is emptied.\n\nRemove from Catalog only takes \(n == 1 ? "it" : "them") out of Loupe Photos; the files stay where they are."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Remove from Catalog")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: trashPhotos(ps); return true
        case .alertSecondButtonReturn:
            removeFromCatalog(ps)
            status = "Removed \(n.formatted()) photo\(n == 1 ? "" : "s") from the catalog. The files are still on disk."
            return true
        default: return false
        }
    }
    /// Files (with their .xmp sidecars) to Finder's Trash, then out of the catalog. Photos on a drive that isn't
    /// plugged in can't be trashed; they're left alone and you're told.
    func trashPhotos(_ ps: [Photo]) {
        var gone: [Photo] = [], failed = 0
        for p in ps {
            do {
                try FileManager.default.trashItem(at: p.url, resultingItemURL: nil)
                let xmp = p.url.deletingPathExtension().appendingPathExtension("xmp")
                if FileManager.default.fileExists(atPath: xmp.path), !photos.contains(where: { $0.id != p.id && $0.url.deletingPathExtension() == p.url.deletingPathExtension() }) {
                    try? FileManager.default.trashItem(at: xmp, resultingItemURL: nil)     // unless a RAW+JPEG partner still uses it
                }
                gone.append(p)
            } catch { failed += 1 }
        }
        if !gone.isEmpty { removeFromCatalog(gone) }
        status = "Moved \(gone.count.formatted()) photo\(gone.count == 1 ? "" : "s") to the Trash." +
            (failed > 0 ? " \(failed) couldn't be moved (is the drive plugged in?) — use Remove from Catalog for those." : "")
    }
    /// Photo ▸ Delete Rejected Photos…: every rejected photo in the library, after asking.
    func deleteRejected() {
        let rej = photos.filter { $0.rejected && $0.deleted == nil }
        guard !rej.isEmpty else { status = "There are no rejected photos."; return }
        deletePhotos(rej)
    }
}


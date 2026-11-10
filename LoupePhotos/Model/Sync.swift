import AppKit

/// Folder ▸ Synchronize Folder… (like Lightroom Classic's): after changing folders in Finder,
/// bring the catalog back in step — new photos added, moved or renamed photos re-linked
/// (keeping stars, flags, labels, keywords and collections), and missing ones kept or removed.
struct SyncPlan {
    let root: Folder
    var newCount = 0                       // files on disk the catalog doesn't know
    var moved: [(Photo, String)] = []      // catalog photo → where its file is now
    var missing: [Photo] = []              // catalog photos whose file can't be found
    var foldersAdded = 0
    var foldersGone = 0
    var isEmpty: Bool { newCount == 0 && moved.isEmpty && missing.isEmpty && foldersAdded == 0 && foldersGone == 0 }
}

extension Library {
    /// Checks the library folder that holds `path` against the disk, then asks before changing anything.
    func synchronize(_ path: String) {
        guard let root = rootFor(path) else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            fail("“\(root.name)” can't be found. If it's on an external drive, plug the drive in and try again.")
            return
        }
        status = "Checking “\(root.name)” against the disk…"
        // a snapshot of what the catalog knows, taken here so the background work doesn't touch live photos
        let known = photos.filter { $0.fid == root.id && $0.deleted == nil }.map { (p: $0, path: $0.path, size: $0.size, mtime: $0.mtime) }
        let knownPaths = Set(known.map(\.path))
        let oldDirs = dirs.filter { $0 == root.path || $0.hasPrefix(root.path + "/") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var files: [(path: String, size: Int, mtime: Double)] = []
            var found = Set<String>([root.path])
            if let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root.path),
                                                       includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en {
                    if let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), v.isDirectory == true {
                        if v.isPackage != true { found.insert(u.path) }
                        continue
                    }
                    guard Photo.imageExt.contains(u.pathExtension.lowercased()) else { continue }
                    let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                    guard v?.isRegularFile == true else { continue }
                    files.append((u.path, v?.fileSize ?? 0, ((v?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000).rounded()))
                }
            }
            let onDisk = Set(files.map(\.path))
            var fresh = files.filter { !knownPaths.contains($0.path) }
            let lost = known.filter { !onDisk.contains($0.path) }

            // re-link: the same file in a new place — same name and size first, then (for renamed files) same size and date
            var plan = SyncPlan(root: root)
            var unmatched: [Photo] = []
            var byNameSize: [String: [Int]] = [:], bySizeTime: [String: [Int]] = [:]
            for (i, f) in fresh.enumerated() {
                byNameSize[(f.path as NSString).lastPathComponent.lowercased() + "|\(f.size)", default: []].append(i)
                bySizeTime["\(f.size)|\(Int(f.mtime / 1000))", default: []].append(i)
            }
            var taken = Set<Int>()
            for k in lost {
                let k1 = (k.path as NSString).lastPathComponent.lowercased() + "|\(k.size)"
                let k2 = "\(k.size)|\(Int(k.mtime / 1000))"
                let hit = (byNameSize[k1] ?? []).first { !taken.contains($0) } ?? (k.size > 0 ? (bySizeTime[k2] ?? []).first { !taken.contains($0) } : nil)
                if let i = hit { taken.insert(i); plan.moved.append((k.p, fresh[i].path)) } else { unmatched.append(k.p) }
            }
            fresh = fresh.enumerated().filter { !taken.contains($0.offset) }.map(\.element)
            plan.newCount = fresh.count
            plan.missing = unmatched
            plan.foldersAdded = found.subtracting(oldDirs).count
            plan.foldersGone = oldDirs.subtracting(found).count

            DispatchQueue.main.async {
                guard let self else { return }
                self.status = ""
                self.confirmSync(plan)
            }
        }
    }

    private func confirmSync(_ plan: SyncPlan) {
        let a = NSAlert()
        a.messageText = "Synchronize “\(plan.root.name)”"
        if plan.isEmpty {
            a.informativeText = "Everything is already in step with Finder."
            a.addButton(withTitle: "OK"); a.runModal(); return
        }
        func n(_ c: Int, _ one: String, _ many: String) -> String { "\(c.formatted()) \(c == 1 ? one : many)" }
        var lines: [String] = []
        if plan.newCount > 0 { lines.append("• " + n(plan.newCount, "new photo", "new photos") + " to add") }
        if !plan.moved.isEmpty { lines.append("• " + n(plan.moved.count, "photo", "photos") + " moved or renamed in Finder — re-linked, keeping stars, flags, labels, keywords and collections") }
        if !plan.missing.isEmpty { lines.append("• " + n(plan.missing.count, "photo", "photos") + " missing from the disk") }
        if plan.foldersAdded > 0 || plan.foldersGone > 0 {
            var f: [String] = []
            if plan.foldersAdded > 0 { f.append(n(plan.foldersAdded, "folder", "folders") + " new or renamed") }
            if plan.foldersGone > 0 { f.append(n(plan.foldersGone, "folder", "folders") + " gone") }
            lines.append("• " + f.joined(separator: ", "))
        }
        a.informativeText = lines.joined(separator: "\n")
        var remove: NSButton?
        if !plan.missing.isEmpty {
            let b = NSButton(checkboxWithTitle: "Remove missing photos from the catalog", target: nil, action: nil)
            b.state = .off
            b.toolTip = "Leave this off if they're on a drive that isn't plugged in — they stay, marked missing."
            a.accessoryView = b; remove = b
        }
        a.addButton(withTitle: "Synchronize")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        applySync(plan, removeMissing: remove?.state == .on)
    }

    private func applySync(_ plan: SyncPlan, removeMissing: Bool) {
        // 1. re-link moved photos (only if the file is still where we found it and nothing else claims that path)
        var relinked: [Photo] = []
        for (p, to) in plan.moved where pathIndex[to] == nil && FileManager.default.fileExists(atPath: to) {
            pathIndex.removeValue(forKey: p.path)
            p.path = to; pathIndex[to] = p.id
            if let r = rootFor(to) { p.fid = r.id }
            p.missing = false
            relinked.append(p)
        }
        if !relinked.isEmpty { changed(relinked, ["path", "fid", "missing"]) }
        // 2. missing photos: removed if asked (their previews stay until discarded), otherwise kept and marked missing by the scan
        if removeMissing, !plan.missing.isEmpty { removeFromCatalog(plan.missing) }
        // 3. the usual folder scan adds the new photos, updates the folder list and marks anything still missing
        scan(plan.root)
        var done: [String] = []
        if !relinked.isEmpty { done.append("re-linked \(relinked.count)") }
        if removeMissing, !plan.missing.isEmpty { done.append("removed \(plan.missing.count) missing") }
        if !done.isEmpty { status = "Synchronized “\(plan.root.name)”: " + done.joined(separator: ", ") + "." }
    }

    /// Takes photos out of the catalog (and out of collections). Files on disk are not touched.
    func removeFromCatalog(_ ps: [Photo]) {
        let gone = Set(ps.map(\.id))
        dbRemoved.formUnion(gone); dbDirty.subtract(gone)
        let goneIds = Array(gone); dbWrite { $0.deleteFaces(ofPhotos: goneIds); $0.deleteClip(ofPhotos: goneIds) }
        SearchIndex.shared.remove(gone)
        photos.removeAll { gone.contains($0.id) }
        for p in ps { byId.removeValue(forKey: p.id); pathIndex.removeValue(forKey: p.path) }
        for i in albums.indices where albums[i].ids.contains(where: gone.contains) { albums[i].ids.removeAll { gone.contains($0) } }
        libChanged()
        version += 1
        saveNow()      // removals aren't journaled, so write the catalog straight away
    }
}

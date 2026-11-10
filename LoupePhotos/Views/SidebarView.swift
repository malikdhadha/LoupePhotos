import SwiftUI

struct FolderNode: Identifiable, Hashable {
    let id: String          // the folder's path
    let name: String
    var children: [FolderNode]?
}

struct DateNode: Identifiable, Hashable {
    let id: String; let name: String; let count: Int; let level: Int; let source: Source
    var children: [DateNode]?
}
struct RecentDay: Equatable { let key: String; let title: String; let y: Int; let m: Int; let d: Int; let count: Int }

/// A label with or without its icon (date rows show the icon only at the top two levels).
/// Built from the label's own parts rather than by borrowing another style — Xcode warned about that.
struct IconWhenStyle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        if showIcon { Label { configuration.title } icon: { configuration.icon } } else { configuration.title }
    }
}

struct SidebarView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var treeKey = -1
    @State private var structSeen = -1
    @State private var tree: [FolderNode] = []
    @State private var counts: [String: Int] = [:]
    @State private var dates: [DateNode] = []
    @State private var recent: [RecentDay] = []
    @State private var noDate = 0
    @State private var libCounts: [Source: Int] = [:]
    @State private var folderQuery = ""
    // which sidebar sections are open (remembered between launches)
    @AppStorage("side.library") private var openLibrary = true
    @AppStorage("side.photosOpen") private var photosOpen = false
    @AppStorage("show.people") private var showPeople = true
    // Settings ▸ Sidebar: which parts are shown
    @AppStorage("show.recentDays") private var showRecentDays = true
    @AppStorage("show.lastImport") private var showLastImport = true
    @AppStorage("show.flags") private var showFlags = true
    @AppStorage("show.labels") private var showLabels = true
    @AppStorage("show.ratings") private var showRatings = true
    @AppStorage("show.quick") private var showQuick = true
    @AppStorage("show.dates") private var showDates = true
    @AppStorage("show.onThisDay") private var showOnThisDay = true
    @AppStorage("show.folders") private var showFolders = true
    @AppStorage("show.collections") private var showCollections = true
    @AppStorage("show.keywords") private var showKeywords = true
    @AppStorage("show.places") private var showPlaces = true
    @AppStorage("side.dates") private var openDates = true
    @AppStorage("side.folders") private var openFolders = true
    @AppStorage("side.collections") private var openCollections = true
    @AppStorage("side.places") private var openPlaces = true
    @AppStorage("side.keywords") private var openKeywords = true
    @State private var keyTree: [KeyNode] = []
    @State private var keyCounts: [String: Int] = [:]
    @State private var keyQuery = ""
    var keyCount: Int { keyCounts.count }
    @State private var collQuery = ""
    @State private var smartCounts: [String: Int] = [:]
    @State private var lastBuilt = Date.distantPast
    @State private var editing: Album?
    @State private var places: [PlaceNode] = []
    @State private var markNodes: [MarkNode] = []

    var body: some View {
        @Bindable var ui = ui
        List(selection: $ui.source) {
            Section("Library", isExpanded: $openLibrary) {
                HStack(spacing: 0) {
                    row("Photos", "photo.on.rectangle", .all)
                    Button { withAnimation { photosOpen.toggle() } } label: {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(photosOpen ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(photosOpen ? "Hide the views" : "All Photos, Days, Weeks, Months, Years")
                }
                .tag(Source.all)
                .simultaneousGesture(TapGesture().onEnded { goPhotos(.all) })   // Photos always goes home: the All Photos grid
                if photosOpen {
                    ForEach([BrowseScale.all, .days, .weeks, .months, .years], id: \.self) { s in
                        let on = ui.source == .all && ui.mode == .browser && ui.scale == s
                        HStack {
                            Label(s.rawValue, systemImage: s == .all ? "square.grid.3x3" : s == .days ? "calendar.day.timeline.left" : s == .weeks ? "calendar" : s == .months ? "calendar.badge.clock" : "square.stack")
                                .foregroundStyle(on ? Color.accentColor : Color.primary)
                            Spacer()
                        }
                        .padding(.leading, 18)
                        .contentShape(Rectangle())
                        .onTapGesture { goPhotos(s) }
                    }
                }
                if showPeople {
                    HStack {
                        Label("People", systemImage: "person.2.crop.square.stack")
                        Spacer()
                        let n = FaceIndex.shared.people.count
                        if n > 0 { Text(n.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }.tag(Source.people)
                }
                if showRecentDays { plain("Recent Days", "calendar", .days) }
                if showLastImport { row("Last Import", "clock", .recent) }
                if showQuick, let q = lib.quick, !q.ids.isEmpty {
                    HStack {
                        Label("Quick Collection", systemImage: "bolt.circle")
                        Spacer()
                        Text(q.ids.count.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(Source.album(Library.quickID))
                    .help("B adds or removes the selected photos")
                    .contextMenu {
                        Button("Save as Collection…") {
                            if let n = Library.ask("Save Quick Collection", "Its photos become a collection, and the Quick Collection is emptied.", value: "Untitled Collection", ok: "Save"),
                               let c = lib.saveQuick(as: n.isEmpty ? "Untitled Collection" : n) { ui.source = .album(c.id) }
                        }
                        Button("Clear Quick Collection") { lib.clearQuick(); if ui.source == .album(Library.quickID) { ui.source = .all } }
                    }
                }
                OutlineGroup(markNodes.filter { ($0.id == "flags" && showFlags) || ($0.id == "labels" && showLabels) || ($0.id == "ratings" && showRatings) }, children: \.children) { n in
                    HStack {
                        Label {
                            Text(n.name)
                        } icon: {
                            if let hex = n.hex { Circle().fill(Color(hex: hex)).frame(width: 11, height: 11) }
                            else { Image(systemName: n.icon) }
                        }
                        Spacer()
                        if let c = n.count { Text(c.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .modifier(OptionalTag(source: n.source))
                }
            }
            if showDates { Section("Dates", isExpanded: $openDates) {
                if noDate > 0 { HStack { Label("No Date", systemImage: "calendar.badge.exclamationmark"); Spacer(); Text(noDate.formatted()).font(.caption).foregroundStyle(.secondary) }.tag(Source.noDate) }
                if showOnThisDay { plain("On This Day", "calendar.badge.clock", .onThisDay) }
                OutlineGroup(dates, children: \.children) { n in
                    HStack {
                        Label(n.name, systemImage: n.level < 2 ? "calendar" : "")
                            .labelStyle(IconWhenStyle(showIcon: n.level < 2))
                        Spacer()
                        Text(n.count.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.tag(n.source)
                }
            }
            }
            if showFolders { Section("Folders", isExpanded: $openFolders) {
                if lib.folders.isEmpty {
                    Button("Add Folder…") { ui.addFolder(lib) }.buttonStyle(.link)
                } else {
                    FilterField(text: $folderQuery, prompt: "Filter Folders")
                }
                if folderQuery.isEmpty {
                    OutlineGroup(tree, children: \.children) { n in folderRow(n.id, name: n.name, subtitle: nil) }
                } else {
                    ForEach(matchingFolders(), id: \.self) { d in folderRow(d, name: d.lastPart, subtitle: (d as NSString).deletingLastPathComponent.lastPart) }
                }
            }
            }
            if showCollections { Section(isExpanded: $openCollections) {
                if lib.albums.contains(where: { $0.id != Library.quickID }) { FilterField(text: $collQuery, prompt: "Filter Collections") }
                if collQuery.isEmpty {
                    OutlineGroup(collTree(nil), children: \.children) { n in collRow(n.album, subtitle: nil) }
                } else {
                    let q = collQuery.lowercased()
                    ForEach(lib.albums.filter { $0.id != Library.quickID && $0.name.lowercased().contains(q) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { a in
                        collRow(a, subtitle: lib.collectionPath(a))
                    }
                }
                if !lib.albums.contains(where: { $0.id != Library.quickID }) {
                    Text("Use + to make a collection, smart collection or collection set.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Menu { newCollectionMenu(parent: nil) } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New collection, smart collection or collection set")
                }
            }
            }
            if showKeywords && !keyTree.isEmpty {
                Section("Keywords", isExpanded: $openKeywords) {
                    if keyCount > 12 { FilterField(text: $keyQuery, prompt: "Filter Keywords") }
                    if keyQuery.isEmpty {
                        OutlineGroup(keyTree, children: \.children) { n in keyRow(n.id, n.name) }
                    } else {
                        ForEach(keyCounts.keys.filter { $0.lowercased().contains(keyQuery.lowercased()) }.sorted(), id: \.self) { k in keyRow(k, k.replacingOccurrences(of: "/", with: " › ")) }
                    }
                }
            }
            if showPlaces { Section("Places", isExpanded: $openPlaces) {
                if places.isEmpty {
                    Text("Photos with GPS appear here by country and town.").font(.caption).foregroundStyle(.secondary)
                } else {
                    OutlineGroup(places, children: \.children) { n in
                        HStack {
                            Label(n.name, systemImage: n.children == nil ? "mappin.and.ellipse" : "globe")
                            Spacer()
                            Text(n.count.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(n.source)
                    }
                }
            } }
        }
        .sheet(item: $editing) { a in SmartCollectionEditor(album: a, isNew: lib.collection(a.id) == nil) }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarActions() }
        .onAppear(perform: rebuild)
        // quick bursts of changes (holding a key, rating many photos) are counted once
        // while Background Tasks run, the library changes all the time: recount at most every 3 seconds then
        .task(id: lib.version) {
            let busy = !Activity.shared.jobs.isEmpty
            // face names arriving as People keywords: catch up every 15 seconds, not after each one
            let gap: Double = lib.onlyBackgroundSince(treeKey) ? 15 : busy ? 3 : 0
            let wait = max(0.25, gap - Date().timeIntervalSince(lastBuilt))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if !Task.isCancelled { rebuild(); lastBuilt = Date() }
        }
    }

    /// Photos ▸ All Photos / Days / Weeks / Months / Years, from anywhere.
    func goPhotos(_ s: BrowseScale) {
        ui.source = .all; ui.back = nil; ui.fullScreen = false
        ui.mode = .browser; ui.browse = s
        if s == .all, let p = ui.primary { ui.scrollTarget = p }
    }

    // MARK: folders and collections rows
    func folderRow(_ path: String, name: String, subtitle: String?) -> some View {
        let root = lib.folders.first { $0.path == path }
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            } icon: { Image(systemName: root != nil ? "externaldrive" : "folder") }
            Spacer()
            if root?.offline == true { Text("Offline").font(.caption2).foregroundStyle(.orange) }
            Text((counts[path] ?? 0).formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(Source.folder(path))
        .contextMenu { folderMenu(path, isRoot: root != nil) }
        .draggable(URL(fileURLWithPath: path))
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: path) }
    }
    func matchingFolders() -> [String] {
        let q = folderQuery.lowercased()
        return Set(counts.keys).union(lib.dirs).filter { d in lib.folders.contains { d == $0.path || d.hasPrefix($0.path + "/") } && d.lastPart.lowercased().contains(q) }
            .sorted { $0.lastPart.localizedStandardCompare($1.lastPart) == .orderedAscending }
    }

    struct CollNode: Identifiable { let album: Album; let children: [CollNode]?; var id: String { album.id } }
    func collTree(_ parent: String?) -> [CollNode] {
        lib.children(of: parent).map { CollNode(album: $0, children: $0.type == "folder" ? collTree($0.id) : nil) }
    }
    func collRow(_ a: Album, subtitle: String?) -> some View {
        let isSet = a.type == "folder"
        let icon = isSet ? "archivebox" : a.type == "smart" ? "gearshape.2" : a.type == "light" ? "square.on.square" : "rectangle.stack"
        let n = a.type == "smart" ? smartCounts[a.id] : isSet ? nil : a.ids.count
        return HStack {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.name).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            } icon: { Image(systemName: icon) }
            Spacer()
            if let n { Text(n.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .modifier(OptionalTag(source: isSet ? nil : .album(a.id)))        // sets only hold collections, so they can't be picked
        .contextMenu { collMenu(a) }
        .draggable(URL(string: "apcollection:\(a.id)")!)
        .dropDestination(for: URL.self) { urls, _ in dropOnCollection(urls, a) }
    }

    @ViewBuilder
    func newCollectionMenu(parent: String?) -> some View {
        Button("New Collection…") { newCollection(parent: parent) }
        Button("New Smart Collection…") {
            editing = Album(id: "a" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 1000...9999)),
                            type: "smart", name: "Untitled Smart Collection", parent: parent, ids: [], match: "all", rules: [SmartRule.make("rating")])
        }
        Button("New Collection Set…") {
            if let name = Library.ask("New Collection Set", "A set holds collections and other sets.", value: "Untitled Set", ok: "Create") {
                lib.newCollection(type: "folder", name: name.isEmpty ? "Untitled Set" : name, parent: parent)
            }
        }
    }
    func newCollection(parent: String?) {
        let sel = ui.targets(lib)
        let a = NSAlert(); a.messageText = "New Collection"
        a.informativeText = parent.flatMap { lib.collection($0) }.map { "Inside “\($0.name)”." } ?? ""
        let name = NSTextField(string: "Untitled Collection"); name.frame = NSRect(x: 0, y: 30, width: 300, height: 24)
        let include = NSButton(checkboxWithTitle: "Include the \(sel.count) selected photo\(sel.count == 1 ? "" : "s")", target: nil, action: nil)
        include.frame = NSRect(x: 0, y: 0, width: 300, height: 22); include.state = sel.count > 1 ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56)); box.addSubview(name); box.addSubview(include)
        a.accessoryView = box; a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let c = lib.newCollection(type: "album", name: n.isEmpty ? "Untitled Collection" : n, parent: parent, ids: include.state == .on ? sel.map(\.id) : [])
        ui.source = .album(c.id)
    }

    @ViewBuilder
    func collMenu(_ a: Album) -> some View {
        if a.type == "folder" { newCollectionMenu(parent: a.id); Divider() }
        if a.type == "smart" { Button("Edit Smart Collection…") { editing = a } }
        if a.type == "album" {
            Button("Add Selected Photos") { lib.addToAlbum(a.id, ui.targets(lib)) }
        }
        Button("Rename…") {
            if let n = Library.ask("Rename", "", value: a.name, ok: "Rename") { lib.renameCollection(a.id, n) }
        }
        Menu("Move To") {
            Button("Top Level") { lib.moveCollection(a.id, into: nil) }.disabled(a.parent == nil)
            let sets = lib.albums.filter { $0.type == "folder" && $0.id != a.id }.sorted { lib.collectionPath($0) + $0.name < lib.collectionPath($1) + $1.name }
            if !sets.isEmpty { Divider() }
            ForEach(sets) { s in
                let path = lib.collectionPath(s)
                Button(path.isEmpty ? s.name : path + " › " + s.name) { lib.moveCollection(a.id, into: s.id) }.disabled(a.parent == s.id)
            }
        }
        Divider()
        Button(a.type == "folder" ? "Delete Set…" : "Delete…") {
            let inside = a.type == "folder" ? " and every collection inside it" : ""
            if Library.confirm("Delete “\(a.name)”\(inside)?", "Your photos stay in the catalog and on disk; only the collection goes.", ok: "Delete") {
                if case .album(let id) = ui.source, id == a.id || lib.collectionPath(lib.collection(id) ?? a).contains(a.name) { ui.source = .all }
                lib.deleteCollection(a.id)
            }
        }
    }
    /// Photos dropped on a collection are added to it; collections dropped on a set move into it.
    func dropOnCollection(_ urls: [URL], _ a: Album) -> Bool {
        let moved = urls.filter { $0.scheme == "apcollection" }.map { String($0.absoluteString.dropFirst("apcollection:".count)) }
        if !moved.isEmpty {
            guard a.type == "folder" else { return false }
            for id in moved where id != a.id { lib.moveCollection(id, into: a.id) }
            return true
        }
        guard a.type == "album" else { return false }
        let ps = urls.compactMap { lib.pathIndex[$0.path] }.compactMap { lib.byId[$0] }
        guard !ps.isEmpty else { return false }
        lib.addToAlbum(a.id, ps)
        lib.status = "Added \(ps.count) photo\(ps.count == 1 ? "" : "s") to “\(a.name)”."
        return true
    }

    func keyRow(_ k: String, _ name: String) -> some View {
        HStack {
            Label(name, systemImage: "tag")
            Spacer()
            Text((keyCounts[k] ?? 0).formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(Source.keyword(k))
        .contextMenu {
            Button("Add to Selected Photos") { lib.addKeyword(ui.targets(lib), k) }
            Button("Remove from Selected Photos") { lib.removeKeyword(ui.targets(lib), k) }
            Divider()
            Button("Rename…") {
                if let n = Library.ask("Rename Keyword", "Every photo with “\(k.lastPart)” gets the new name. Use Parent/Child to nest it.", value: k, ok: "Rename") {
                    lib.renameKeyword(k, to: n); if ui.source == .keyword(k) { ui.source = .keyword(n) }
                }
            }
            Button("Delete…") {
                if Library.confirm("Delete the keyword “\(k.lastPart)”?", "It is taken off \((keyCounts[k] ?? 0).formatted()) photos. The photos stay.", ok: "Delete") {
                    lib.deleteKeyword(k); if ui.source == .keyword(k) { ui.source = .all }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let ps = urls.compactMap { lib.pathIndex[$0.path] }.compactMap { lib.byId[$0] }
            guard !ps.isEmpty else { return false }
            lib.addKeyword(ps, k); return true
        }
    }

    // MARK: folder management (changes happen in Finder too)
    @ViewBuilder
    func folderMenu(_ path: String, isRoot: Bool) -> some View {
        Button("New Folder Inside “\(path.lastPart)”…") {
            if let name = Library.ask("New Folder", "A new folder is made inside “\(path.lastPart)” on disk.", value: "untitled folder", ok: "Create"),
               let made = lib.createFolder(in: path, named: name) { ui.source = .folder(made) }
        }
        Button("Rename…") {
            if let name = Library.ask("Rename Folder", "The folder is renamed in Finder too.", value: path.lastPart, ok: "Rename"),
               let new = lib.renameFolder(path, to: name) { follow(path, new) }
        }
        if isRoot {
            Button("Add Parent Folder") {
                let parent = (path as NSString).deletingLastPathComponent
                if Library.confirm("Add “\(parent.lastPart)” as the library folder?", "“\(path.lastPart)” will appear inside it. Any other photos in “\(parent.lastPart)” are added to the catalog too.", ok: "Add Parent Folder") {
                    lib.addParentFolder(path)
                }
            }
        }
        Button("Synchronize Folder…") { lib.synchronize(path) }
            .help("After changing folders in Finder: add new photos, re-link moved ones, deal with missing ones")
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Divider()
        if isRoot {
            Button("Remove “\(path.lastPart)” from Library…") {
                let n = lib.folderCount(path)
                if Library.confirm("Remove “\(path.lastPart)” from Loupe Photos?",
                                   "Its \(n.formatted()) photo\(n == 1 ? "" : "s") leave the catalog, with their stars, flags, labels and keywords kept only in any XMP files. The folder and files stay on disk — add it again any time.",
                                   ok: "Remove"), let r = lib.rootFor(path) {
                    if case .folder(let f) = ui.source, f == path || f.hasPrefix(path + "/") { ui.source = .all }
                    lib.removeLibraryFolder(r)
                }
            }
        // (a folder with photos in the catalog isn't empty — the disk is only asked about folders with none,
        //  because this menu is made whenever the row is drawn, and reading a big folder froze the window)
        } else if (counts[path] ?? 0) == 0 && lib.folderIsEmpty(path) {
            Button("Move Empty Folder to Trash") { lib.trashFolder(path); if ui.source == .folder(path) { ui.source = .all } }
        } else {
            Button("Move Folder to Trash…") {
                let n = lib.folderCount(path)
                if Library.confirm("Move “\(path.lastPart)” to the Trash?",
                                   "The folder and its \(n.formatted()) photo\(n == 1 ? "" : "s") go to the Trash in Finder and leave the catalog. You can put them back from the Trash until it's emptied.",
                                   ok: "Move to Trash") {
                    if case .folder(let f) = ui.source, f == path || f.hasPrefix(path + "/") { ui.source = .all }
                    lib.trashFolderWithPhotos(path)
                }
            }
        }
    }
    /// The sidebar keeps pointing at a folder after it is renamed or moved.
    func follow(_ old: String, _ new: String) {
        if case .folder(let f) = ui.source, f == old || f.hasPrefix(old + "/") { ui.source = .folder(new + f.dropFirst(old.count)) }
    }
    /// Photos dragged from the grid (or folders from this list) dropped on a folder: moved on disk, with a confirmation.
    func drop(_ urls: [URL], into dest: String) -> Bool {
        let paths = urls.map(\.path)
        let folders = paths.filter { lib.dirs.contains($0) || lib.isRoot($0) }
        let photos = paths.compactMap { lib.pathIndex[$0] }.compactMap { lib.byId[$0] }
        if let f = folders.first, photos.isEmpty {
            guard Library.confirm("Move “\(f.lastPart)” into “\(dest.lastPart)”?", "The folder and everything in it is moved on disk.", ok: "Move") else { return false }
            if let new = lib.moveFolder(f, into: dest) { follow(f, new) }
            return true
        }
        guard !photos.isEmpty else { return false }
        let n = photos.count
        guard Library.confirm("Move \(n) photo\(n == 1 ? "" : "s") to “\(dest.lastPart)”?", "The files (and any .xmp sidecars) are moved on disk.", ok: "Move") else { return false }
        lib.movePhotos(photos, to: dest)
        return true
    }

    func row(_ title: String, _ icon: String, _ s: Source) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text((libCounts[s] ?? 0).formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }.tag(s)
    }
    func plain(_ title: String, _ icon: String, _ s: Source) -> some View { Label(title, systemImage: icon).tag(s) }
    /// One pass over the photos builds the whole folder tree and its counts.
    /// The sidebar's counts, folders, dates, places and keywords — worked out in the background (at 120,000 photos this
    /// took several seconds, and on the main thread it froze the window at launch and after every import), then shown.
    @State private var building = false
    @State private var buildAgain = false
    @State private var smartAt = Date.distantPast
    func rebuild() {
        guard treeKey != lib.version else { return }
        if building { buildAgain = true; return }
        let touched = lib.touchedSince(treeKey)
        treeKey = lib.version
        let full = structSeen != lib.structKey && touched == nil
        if touched == nil { structSeen = lib.structKey }
        // (too many changes to know which: keywords and places are counted again too)
        let doKeywords = full || touched == nil || touched?.fields.contains("keywords") == true
        // place names arriving (one every second or so while they're looked up): just the Places list, not everything
        let doPlaces = full || touched == nil || touched?.fields.contains("place") == true
        // smart collection counts check every photo against every rule: when something big changed, or every 30 seconds
        let doSmart = full || Date().timeIntervalSince(smartAt) > 30
        if doSmart { smartAt = Date() }
        building = true
        let lib = self.lib
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = SidebarData.make(lib, keywords: doKeywords, tree: full, smart: doSmart, places: doPlaces)
            Timing.note("sidebar rebuilt (background)", since: t0)
            DispatchQueue.main.async {
                // only what actually changed is handed over: each new list makes the sidebar compare every row again
                if libCounts != r.libCounts { libCounts = r.libCounts }
                if markNodes != r.markNodes { markNodes = r.markNodes }
                if doSmart {
                    for (k, v) in r.smartCounts where smartCounts[k] != v { smartCounts[k] = v }
                    // search and people collections: one at a time, so the window stays responsive
                    let rest = lib.albums.filter { $0.type == "smart" && Library.smartNeedsMain($0) }
                    // (not in the first seconds after opening, while the grid and People are getting ready)
                    let wait = max(0, 12 - Date().timeIntervalSince(lib.openedAt))
                    for (n, a) in rest.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.3 * Double(n + 1)) { let c = lib.smartPhotos(a).count; if smartCounts[a.id] != c { smartCounts[a.id] = c } }
                    }
                }
                if doKeywords { if keyCounts != r.keyCounts { keyCounts = r.keyCounts }; if keyTree != r.keyTree { keyTree = r.keyTree } }
                if doPlaces, places != r.places { places = r.places }
                if full {
                    if tree != r.tree { tree = r.tree }
                    if counts != r.counts { counts = r.counts }
                    if noDate != r.noDate { noDate = r.noDate }
                    if dates != r.dates { dates = r.dates }
                    if recent != r.recent { recent = r.recent }
                }
                building = false
                if buildAgain { buildAgain = false; rebuild() }
            }
        }
    }
}

/// Everything the sidebar shows, made in one go off the main thread.
struct SidebarData {
    var libCounts: [Source: Int] = [:]
    var markNodes: [MarkNode] = []
    var smartCounts: [String: Int] = [:]
    var keyCounts: [String: Int] = [:]
    var keyTree: [KeyNode] = []
    var places: [PlaceNode] = []
    var tree: [FolderNode] = []
    var counts: [String: Int] = [:]
    var noDate = 0
    var dates: [DateNode] = []
    var recent: [RecentDay] = []

    static func make(_ lib: Library, keywords: Bool, tree doTree: Bool, smart: Bool, places doPlaces: Bool) -> SidebarData {
        var r = SidebarData()
        var tt = CFAbsoluteTimeGetCurrent()
        func lap(_ w: String) { Timing.note("  sidebar: " + w, since: tt); tt = CFAbsoluteTimeGetCurrent() }
        // every count in one pass over the library
        var all = 0, flagged = 0, rejected = 0, recent = 0
        var labelCount: [String: Int] = [:], starCount: [Int: Int] = [:]
        let last = lib.lastAdded
        for p in lib.photos where !p.quickDeleted {
            if p.quickRejected { rejected += 1; continue }
            all += 1
            if p.quickFlag { flagged += 1 }
            if p.quickAdded == last { recent += 1 }
            if let l = p.quickLabel { labelCount[l, default: 0] += 1 }
            let r = p.quickRating
            if r > 0 { starCount[r, default: 0] += 1 }
        }
        r.libCounts = [.all: all, .flagged: flagged, .rejected: rejected, .recent: recent]
        r.markNodes = [
            MarkNode(id: "flags", name: "Flags", icon: "flag", hex: nil, count: nil, source: nil, children: [
                MarkNode(id: "fF", name: "Flagged", icon: "flag.fill", hex: nil, count: flagged, source: .flagged, children: nil),
                MarkNode(id: "fR", name: "Rejected", icon: "xmark.circle", hex: nil, count: rejected, source: .rejected, children: nil),
                MarkNode(id: "fU", name: "Unflagged", icon: "flag.slash", hex: nil, count: all - flagged, source: .unflagged, children: nil),
            ]),
            MarkNode(id: "labels", name: "Color Labels", icon: "circle.lefthalf.filled", hex: nil, count: nil, source: nil,
                     children: PhotoLabel.all.map { MarkNode(id: "l" + $0.id, name: $0.name, icon: "", hex: $0.hex, count: labelCount[$0.id] ?? 0, source: .label($0.id), children: nil) }
                        + [MarkNode(id: "lnone", name: "No Label", icon: "circle.dashed", hex: nil, count: all - labelCount.values.reduce(0, +), source: .label(""), children: nil)]),
            MarkNode(id: "ratings", name: "Ratings", icon: "star", hex: nil, count: nil, source: nil,
                     children: (1...5).reversed().map { n in MarkNode(id: "r\(n)", name: String(repeating: "★", count: n), icon: "star.fill", hex: nil, count: starCount[n] ?? 0, source: .rating(n), children: nil) }
                        + [MarkNode(id: "r0", name: "Unrated", icon: "star.slash", hex: nil, count: all - starCount.values.reduce(0, +), source: .rating(0), children: nil)]),
        ]
        lap("counts")
        // collections with search or people rules are counted on the main thread afterwards (those answers live there)
        if smart {
            r.smartCounts = Dictionary(uniqueKeysWithValues: lib.albums.filter { $0.type == "smart" && !Library.smartNeedsMain($0) }.map { a -> (String, Int) in
                let test = lib.smartTest(a)
                return (a.id, lib.photos.lazy.filter { $0.quickLive && test($0) }.count)
            })
        }
        lap("smart collections")
        if keywords {
        r.keyCounts = lib.keywordCounts()
        func kids(_ parent: String?) -> [KeyNode] {
            r.keyCounts.keys.filter { k in
                let parts = k.split(separator: "/")
                return parent == nil ? parts.count == 1 : k.hasPrefix(parent! + "/") && parts.count == parent!.split(separator: "/").count + 1
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { k in let c = kids(k); return KeyNode(id: k, name: k.lastPart, children: c.isEmpty ? nil : c) }
        }
        r.keyTree = kids(nil)
        lap("keywords")
        }
        if doPlaces {
        var pc: [String: [String: Int]] = [:]
        for p in lib.photos where p.quickLive {
            guard let pl = p.place, let c = pl["c"] as? String, !c.isEmpty else { continue }
            pc[c, default: [:]][pl["t"] as? String ?? "", default: 0] += 1
        }
        r.places = pc.keys.sorted().map { c in
            let towns = pc[c]!.filter { !$0.key.isEmpty }.sorted { $0.key < $1.key }
            return PlaceNode(id: "c|" + c, name: c, count: pc[c]!.values.reduce(0, +), source: .place(c, nil),
                             children: towns.isEmpty ? nil : towns.map { PlaceNode(id: "t|\(c)|\($0.key)", name: $0.key, count: $0.value, source: .place(c, $0.key), children: nil) })
        }
        lap("places")
        }
        if doTree {
        var c: [String: Int] = [:]
        var dirs = Set(lib.dirs.filter { d in lib.folders.contains { d.hasPrefix($0.path + "/") } })   // empty folders too
        // count photos per folder first (one lookup each), then add each folder's count to the folders above it —
        // walking up once per folder, not once per photo (this took 3 seconds at 120,000 photos)
        var inDir: [String: Int] = [:]
        for p in lib.photos where p.quickLive { inDir[p.quickDir, default: 0] += 1 }
        let roots = lib.folders.map(\.path).sorted { $0.count > $1.count }      // the deepest library folder wins
        for (dir, n) in inDir {
            guard let root = roots.first(where: { dir == $0 || dir.hasPrefix($0 + "/") }) else { continue }
            var d = dir
            while d.count >= root.count { c[d, default: 0] += n; dirs.insert(d); if d == root { break }; d = (d as NSString).deletingLastPathComponent }
        }
        var under: [String: [String]] = [:]                       // each folder's sub-folders, worked out once
        for d in dirs { under[(d as NSString).deletingLastPathComponent, default: []].append(d) }
        func node(_ dir: String, root: Bool) -> FolderNode {
            let kids = (under[dir] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let name = root ? (lib.folders.first { $0.path == dir }?.name ?? (dir as NSString).lastPathComponent) : (dir as NSString).lastPathComponent
            return FolderNode(id: dir, name: name, children: kids.isEmpty ? nil : kids.map { node($0, root: false) })
        }
        r.tree = lib.folders.map { node($0.path, root: true) }
        r.counts = c
        lap("folders")
        // Dates: decades › years › months › days (like the decade tree in the other app), plus Recent Days
        var dc: [String: Int] = [:]; var nd = 0
        var yearsIn: [Int: Set<Int>] = [:], monthsIn: [Int: Set<Int>] = [:], daysIn: [String: Set<Int>] = [:]   // the tree, built in the same pass
        for p in lib.photos where p.quickLive {
            if p.quickNoDate { nd += 1; continue }
            let d = p.ymd
            dc["D\(d.y / 10 * 10)", default: 0] += 1; dc["y\(d.y)", default: 0] += 1; dc["m\(d.y)-\(d.m)", default: 0] += 1; dc["d\(d.y)-\(d.m)-\(d.d)", default: 0] += 1
            yearsIn[d.y / 10 * 10, default: []].insert(d.y); monthsIn[d.y, default: []].insert(d.m); daysIn["\(d.y)-\(d.m)", default: []].insert(d.d)
        }
        r.noDate = nd
        lap("dates pass")
        let months = Calendar.current.monthSymbols
        r.dates = yearsIn.keys.sorted().map { dec in          // oldest first
            DateNode(id: "D\(dec)", name: "\(dec)s", count: dc["D\(dec)"] ?? 0, level: 0, source: .decade(dec), children:
                (yearsIn[dec] ?? []).sorted().map { y in
                    DateNode(id: "y\(y)", name: String(y), count: dc["y\(y)"] ?? 0, level: 1, source: .date(y, nil, nil), children:
                        (monthsIn[y] ?? []).sorted().map { m in
                            DateNode(id: "m\(y)-\(m)", name: months[max(0, min(11, m - 1))], count: dc["m\(y)-\(m)"] ?? 0, level: 2, source: .date(y, m, nil), children:
                                (daysIn["\(y)-\(m)"] ?? []).sorted().map { d in
                                    let dt = Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
                                    return DateNode(id: "d\(y)-\(m)-\(d)", name: "\(d) – \(dt.formatted(.dateTime.weekday(.wide)))", count: dc["d\(y)-\(m)-\(d)"] ?? 0, level: 3, source: .date(y, m, d), children: nil)
                                })
                        })
                })
        }
        // the ten most recent days with photos
        lap("date tree")
        let dayKeys = dc.keys.filter { $0.hasPrefix("d") }.compactMap { k -> (Int, Int, Int)? in
            let a = k.dropFirst().split(separator: "-").compactMap { Int($0) }; return a.count == 3 ? (a[0], a[1], a[2]) : nil
        }.sorted { ($0.0, $0.1, $0.2) > ($1.0, $1.1, $1.2) }.prefix(10)
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        r.recent = dayKeys.map { y, m, d in
            let dt = cal.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
            let ago = cal.dateComponents([.day], from: dt, to: today).day ?? 99
            let t = ago == 0 ? "Today" : ago == 1 ? "Yesterday" : ago < 7 ? dt.formatted(.dateTime.weekday(.wide)) : dt.formatted(.dateTime.day().month(.abbreviated).year())
            return RecentDay(key: "\(y)-\(m)-\(d)", title: t, y: y, m: m, d: d, count: dc["d\(y)-\(m)-\(d)"] ?? 0)
        }
        }
        return r
    }
}


/// The small search box at the top of the Folders and Collections lists.
struct FilterField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.callout)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .selectionDisabled()
    }
}

/// Tags a sidebar row so it can be selected — or leaves it unselectable when there is nothing to show.
struct OptionalTag: ViewModifier {
    let source: Source?
    @ViewBuilder func body(content: Content) -> some View {
        if let source { content.tag(source) } else { content }
    }
}

struct PlaceNode: Identifiable, Equatable { let id: String; let name: String; let count: Int; let source: Source; let children: [PlaceNode]? }

struct MarkNode: Identifiable, Equatable { let id: String; let name: String; let icon: String; let hex: UInt32?; let count: Int?; let source: Source?; let children: [MarkNode]? }

struct KeyNode: Identifiable, Equatable { let id: String; let name: String; let children: [KeyNode]? }

/// Import… and Export… at the foot of the sidebar, as in Lightroom Classic. They stay put while the sidebar scrolls.
struct SidebarActions: View {
    @Environment(UIState.self) private var ui
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        // counted from the selection alone, so selecting everything doesn't build a list on every redraw
        let n = ui.selection.isEmpty ? (ui.primary == nil ? 0 : 1) : ui.selection.count
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button { openWindow(id: "import") } label: { Text("Import…").frame(maxWidth: .infinity) }
                    .help("Import photos from a card or folder (⇧⌘I)")
                Button { ui.showExport = true } label: { Text(n > 1 ? "Export \(n.formatted())…" : "Export…").lineLimit(1).frame(maxWidth: .infinity) }
                    .disabled(n == 0)
                    .help(n == 0 ? "Select photos to export" : "Export the selected photo\(n == 1 ? "" : "s") (⇧⌘E)")
            }
            .controlSize(.large)
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
        .background(.bar)
    }
}

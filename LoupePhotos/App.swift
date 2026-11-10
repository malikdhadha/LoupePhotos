import SwiftUI
import AppKit
import CoreLocation

@main
struct LoupePhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var lib = Library.shared
    @State private var ui = UIState()

    var body: some Scene {
        WindowGroup("Loupe Photos") {
            ContentView()
                .environment(lib)
                .environment(ui)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear {
                    guard !lib.loaded else { return }
                    // the splash first, so it's on screen while the catalog opens
                    Splash.shared.show()
                    DispatchQueue.main.async { lib.openDefault(); Splash.shared.ready(lib.photos.count) }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) { Button("About \(Splash.appName)") { Splash.shared.showAbout() } }
            CommandGroup(replacing: .newItem) {
                ImportMenuItem()
                Button("Add Folder…") { ui.addFolder(lib) }.keyboardShortcut("i", modifiers: [.command, .shift, .option])
                Button("New Collection from Selection…") { ui.newAlbum(lib) }.keyboardShortcut("n", modifiers: [.command])
                Divider()
                Button("Open Catalog…") { ui.openCatalog(lib) }.keyboardShortcut("o", modifiers: [.command, .option])
                Button("Show Catalog in Finder") { NSWorkspace.shared.activateFileViewerSelecting([lib.db?.url ?? lib.catFile]) }
                Button("Export Photos…") { ui.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(ui.targets(lib).isEmpty)
                Button("Share…") { Exporter.shared.share(ui.targets(lib), from: nil) }.disabled(ui.targets(lib).isEmpty)
                Divider()
                Button("Export Catalog as JSON…") { lib.exportJSON() }
                Divider()
                Button("Back Up Catalog Now") { CatalogBackup.shared.backUpNowFromMenu() }
                Button("Restore Catalog Backup…") { CatalogBackup.shared.restore() }
            }
            CommandMenu("Library") {
                Menu("Previews") {
                    Button("Build Standard Previews") { PreviewJobs.shared.build(ui.previewTargets(lib), .standard) }
                    Button("Build 1:1 Previews") { PreviewJobs.shared.build(ui.previewTargets(lib), .full) }
                    Divider()
                    Button("Discard 1:1 Previews") { BigPreviews.discard(ui.previewTargets(lib).map(\.id), .full) }
                    Button("Discard Standard Previews") { BigPreviews.discard(ui.previewTargets(lib).map(\.id), .standard) }
                    Divider()
                    Button("Rebuild All Thumbnails") {
                        ThumbBuilder.shared.stop(); PreviewStore.shared.discardAll()
                        GridDocView.clearCache(); Images.shared.forgetAll(); lib.buildThumbnails(); lib.version += 1
                    }
                    Divider()
                    Button("Stop Building Previews") { PreviewJobs.shared.stop() }.disabled(!PreviewJobs.shared.running)
                }
            }
            CommandMenu("Metadata") {
                Menu("Append with Preset") {
                    ForEach(MetadataPresets.shared.all) { pr in Button(pr.name) { lib.setIPTC(ui.targets(lib), pr.values, replace: false) } }
                    if MetadataPresets.shared.all.isEmpty { Text("No presets yet — Manage Presets…") }
                }
                Menu("Replace with Preset") {
                    ForEach(MetadataPresets.shared.all) { pr in Button(pr.name) { lib.setIPTC(ui.targets(lib), pr.values, replace: true) } }
                }
                Button("New Preset from Photo…") { ui.newPresetFromPhoto(lib) }.disabled(ui.primaryPhoto(lib) == nil)
                Button("Manage Presets…") { ui.showPresets = true }
                Divider()
                Button("Batch Change…") { ui.showBatch = true }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(ui.targets(lib).isEmpty)
                Button("Lift Metadata") { if let p = ui.primaryPhoto(lib) { ui.lifted = LiftedMetadata(p); lib.status = "Lifted rating, label, keywords, caption, IPTC and location — Stamp to apply them." } }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift]).disabled(ui.primaryPhoto(lib) == nil)
                Button("Stamp Metadata") { ui.lifted?.stamp(ui.targets(lib), lib: lib) }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift]).disabled(ui.lifted == nil || ui.targets(lib).isEmpty)
                Button("Clear IPTC Metadata") { lib.clearIPTC(ui.targets(lib)) }.disabled(ui.targets(lib).isEmpty)
                Divider()
                Button("Save Metadata to Files") {
                    let t = ui.targets(lib)
                    lib.status = "Writing metadata to \(t.count.formatted()) file\(t.count == 1 ? "" : "s")…"
                    XMPSync.write(t) { failed in lib.status = failed == 0 ? "Metadata saved to \(t.count.formatted()) file\(t.count == 1 ? "" : "s")." : "\(failed) file\(failed == 1 ? "" : "s") couldn't be written (read-only or offline)." }
                }.keyboardShortcut("s", modifiers: [.command]).disabled(ui.targets(lib).isEmpty)
                Button("Read Metadata from Files…") { ui.readMetadata(lib) }.disabled(ui.targets(lib).isEmpty)
            }
            CommandMenu("Photo") {
                Button("Rotate Left") { lib.rotate(ui.targets(lib), -1) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Rotate Right") { lib.rotate(ui.targets(lib), 1) }.keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Copy Location") { ui.copyLocation(lib) }.disabled(ui.primaryPhoto(lib).flatMap(Library.gps) == nil)
                Button("Paste Location") { ui.pasteLocation(lib) }.disabled(ui.copiedLocation == nil)
                Divider()
                Button("Copy Settings") { ui.copySettings(lib) }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste Settings") { ui.pasteSettings(lib) }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(ui.copied == nil)
                Divider()
                Button("Revert to Original") { ui.revertAdjustments(lib) }.disabled(!ui.targets(lib).contains { DevelopStore.shared.isEdited($0.id) })
                Button("Copy Adjustments") { ui.copyAdjustments(lib) }.keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(ui.primaryPhoto(lib).map { !DevelopStore.shared.isEdited($0.id) } ?? true)
                Button("Paste Adjustments") { ui.pasteAdjustments(lib) }.keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(ui.copiedRecipe == nil || ui.targets(lib).isEmpty)
                Divider()
                Button("Edit in External Editor") { Outside.edit(ui.targets(lib)) }.keyboardShortcut("e", modifiers: [.command])
                Button("Choose External Editor…") { Outside.chooseEditor() }
                Divider()
                Button("Show in Finder") { if let p = ui.primaryPhoto(lib) { NSWorkspace.shared.activateFileViewerSelecting([p.url]) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Delete…") { ui.deleteTargets(lib) }.keyboardShortcut(.delete, modifiers: [.command]).disabled(ui.targets(lib).isEmpty)
                Button("Delete Rejected Photos…") { lib.deleteRejected() }
                // on a person's page: takes the selected photos off them (always listed, so the menu doesn't change shape)
                Button(ui.personName(lib).map { ui.targets(lib).count > 1 ? "These Aren't \($0)  ⌫" : "This Isn't \($0)  ⌫" } ?? "This Isn't This Person  ⌫") { ui.notThisPerson(lib) }
                    .disabled(ui.personName(lib) == nil || ![.browser, .viewer, .split].contains(ui.mode) || ui.targets(lib).isEmpty)
                Button("Select All Photos  ⌘A") { ui.selectAll(lib) }
                Button("Select None  ⇧⌘A") { ui.selectNone(lib) }
            }
            CommandGroup(after: .sidebar) {
                Button("Browser") { ui.mode = .browser }.keyboardShortcut("1", modifiers: [.command])
                Button("Viewer") { ui.mode = .viewer }.keyboardShortcut("2", modifiers: [.command])
                Button("Split View") { ui.mode = .split }.keyboardShortcut("3", modifiers: [.command])
                Button("Develop  D") { if ui.primaryPhoto(lib) != nil { ui.mode = .develop } }
                Button("People") { ui.source = .people; ui.mode = .people }.keyboardShortcut("p", modifiers: [.command, .option])
                Button(ui.showFaces ? "Hide Face Names" : "Show Face Names") { ui.showFaces.toggle() }.keyboardShortcut("n", modifiers: [.command, .option])
                Button(ui.viewerDetails ? "Hide Photo Details" : "Show Photo Details") {
                    if ui.mode == .browser { ui.mode = .viewer }
                    withAnimation(.easeOut(duration: 0.25)) { ui.viewerDetails.toggle() }
                }.keyboardShortcut("d", modifiers: [.command, .option])
                Button("Compare  C") { ui.startCompare(lib) }
                Button("Survey  N") { ui.startSurvey(lib) }
                Button("Calendar") { ui.mode = .calendar }.keyboardShortcut("4", modifiers: [.command])
                Button("Map") { ui.mode = .map }.keyboardShortcut("5", modifiers: [.command])
                Divider()
                Button(ui.showInspector ? "Hide Inspector" : "Show Inspector") { ui.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command])
                ViewOptionsMenuItem()
                Button(ui.showFilterBar ? "Hide Library Filter" : "Show Library Filter") { ui.showFilterBar.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button(ui.lf.isOn ? "Turn Library Filter Off" : "Turn Library Filter On") { if ui.lf.isOn { ui.lf.tabs = [] } else { ui.lf.tabs = [.metadata]; ui.showFilterBar = true } }.keyboardShortcut("l", modifiers: [.command])
            }
        }
        Settings { SettingsView() }
        Window("View Options", id: "view-options") { ViewOptionsView() }
            .windowResizability(.contentSize)
        Window("Import", id: "import") { ImportView() }
            .defaultSize(width: 1180, height: 760)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { if !Library.shared.loaded { Splash.shared.show() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { CatalogBackup.shared.onQuit(sender) }
    func applicationWillTerminate(_ notification: Notification) { if !CatalogBackup.shared.restoring { Library.shared.close() } }
}

enum ViewMode: String, CaseIterable, Identifiable { case browser = "Browser", viewer = "Viewer", split = "Split", develop = "Develop", people = "People", compare = "Compare", survey = "Survey", calendar = "Calendar", map = "Map"; var id: String { rawValue } }
enum BrowseScale: String, CaseIterable, Identifiable { case years = "Years", months = "Months", weeks = "Weeks", days = "Days", all = "All Photos"; var id: String { rawValue } }
/// Where "‹ Back" returns to after opening a day card.
struct BackPoint { var source: Source?; var browse: BrowseScale; var label: String }

/// What the window is showing and what is selected.
@Observable
final class UIState {
    var source: Source? = .all
    var filter: RatingFilter = .all
    var sort: SortOrder = .dateAsc
    var query = ""
    @ObservationIgnored var sourceBeforePeople: Source?          // where Browser goes back to after People
    @ObservationIgnored var beforeSearch: (source: Source?, browse: BrowseScale)?   // restored when the search is cleared
    var mode: ViewMode = .browser
    var selection: Set<Int> = []
    var primary: Int?
    var tile: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "tile") as? Double ?? 170) { didSet { UserDefaults.standard.set(Double(tile), forKey: "tile") } }
    var dayCard: CGFloat = 220               // Days / Weeks card size (− / +)
    var monthCard: CGFloat = 300             // Months card size (Years are 1.4× this)
    /// The size the slider and − / + change, for whichever scale is showing.
    var sizeRange: ClosedRange<CGFloat> { scale == .all ? 16...400 : (scale == .days || scale == .weeks) ? 70...420 : 120...560 }
    var size: CGFloat {
        get { scale == .all ? tile : (scale == .days || scale == .weeks) ? dayCard : monthCard }
        set {
            let v = min(sizeRange.upperBound, max(sizeRange.lowerBound, newValue))
            if scale == .all { tile = v } else if scale == .days || scale == .weeks { dayCard = v } else { monthCard = v }
        }
    }
    var back: BackPoint?                     // a day card was opened; "‹ Back" returns here
    var listView = UserDefaults.standard.bool(forKey: "listView") { didSet { UserDefaults.standard.set(listView, forKey: "listView") } }   // All Photos as Aperture's List view
    var squareGrid = UserDefaults.standard.object(forKey: "squareGrid") as? Bool ?? true { didSet { UserDefaults.standard.set(squareGrid, forKey: "squareGrid") } }                    // All Photos: square crops, or whole photos (normal)
    /// The scale actually shown: the Recent Days album always shows day cards.
    var scale: BrowseScale { source == .days ? .days : browse }
    var showInspector = UserDefaults.standard.bool(forKey: "showInspector") { didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") } }   // off until you open it
    var zoom = false
    var zoomFocus = CGPoint(x: 0.5, y: 0.5)   // which point of the photo to zoom into (0–1)
    var zoomAnchor = CGPoint(x: 0.5, y: 0.5)  // where on screen it should stay (0–1)
    var zoomStart: CGFloat = 1
    var hoverFrac: CGPoint?                   // pointer position over the photo, for Z
    var hoverAnchor = CGPoint(x: 0.5, y: 0.5)
    var loupe = false
    /// Loupe diameter in points (scroll in the Viewer, ⇧-scroll in the grid), and 200% while ⌥ is held.
    var loupeSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "loupeSize") as? Double ?? 240) { didSet { UserDefaults.standard.set(Double(loupeSize), forKey: "loupeSize") } }
    var loupeDouble = false
    var loupeMag: CGFloat { loupeDouble ? 2 : 1 }
    func resizeLoupe(_ dy: CGFloat) { loupeSize = min(640, max(120, loupeSize + dy * 2)) }
    var showNavigator = true
    var browse: BrowseScale = BrowseScale(rawValue: UserDefaults.standard.string(forKey: "browse") ?? "") ?? .all { didSet { UserDefaults.standard.set(browse.rawValue, forKey: "browse") } }
    var lf = LibraryFilter()
    var lfExpanded: Set<String> = []
    var showFilterBar = UserDefaults.standard.object(forKey: "showFilterBar") as? Bool ?? true { didSet { UserDefaults.standard.set(showFilterBar, forKey: "showFilterBar"); if !showFilterBar { lf.tabs = [] } } }
    var scrollTarget: Int?                    // photo or card to bring into view
    var columns = 5                       // the grid reports how many fit, for ↑/↓

    @ObservationIgnored private var cacheKey = ""
    /// Identifies what visible() last returned (cards and summaries are remembered by it).
    var visibleKey: String { cacheKey }
    @ObservationIgnored private var cache: [Photo] = []

    /// Does this view's list depend on stars, flags, labels or keywords? If not, rating a photo needn't re-list.
    func dependsOnMetadata(_ lib: Library) -> Bool {
        if filter != .all || !query.isEmpty || lf.isOn || sort == .rating { return true }
        switch source ?? .all {
        case .flagged, .unflagged, .rejected, .label, .rating, .keyword, .place: return true
        case .album(let id): return lib.collection(id)?.type == "smart"
        default: return false
        }
    }
    /// Search results also change as photos are indexed, and with Fewer / More.
    var searchKey: String { query.isEmpty ? "" : "\(SearchIndex.shared.version)|\(NaturalSearch.shared.looseness)" }
    func listVersion(_ lib: Library) -> Int {
        if dependsOnMetadata(lib) { return lib.version }
        switch source ?? .all {
        case .person, .faceGroup, .together, .people: return lib.structKey &* 1_000_003 &+ lib.peopleVersion   // who's in them changed
        default: return lib.structKey
        }
    }
    func visible(_ lib: Library) -> [Photo] {
        let key = "\(listVersion(lib))|\(String(describing: source))|\(filter)|\(sort)|\(query)|\(lib.photos.count)|\(lf.hashValue)|\(personAll)|\(searchKey)"
        if key != cacheKey {
            // going back to something you just looked at (a folder, a year…): the list is still here
            if let hit = recent.first(where: { $0.key == key }) { cache = hit.list }
            else {
                let t0 = CFAbsoluteTimeGetCurrent()
                cache = lf.apply(sourceList(lib))
                Timing.note("list \(String(describing: source ?? .all)) → \(cache.count) photos", since: t0)
                recent.insert((key, cache), at: 0)
                if recent.count > 8 { recent.removeLast() }
            }
            cacheKey = key
        }
        return cache
    }
    @ObservationIgnored private var recent: [(key: String, list: [Photo])] = []
    @ObservationIgnored private var srcKey = ""
    @ObservationIgnored private var srcCache: [Photo] = []
    @ObservationIgnored private var srcParts = ""
    @ObservationIgnored private var srcPerson = Set<Int>()
    /// The source's photos before the Library Filter (the metadata columns count from these).
    func sourceList(_ lib: Library) -> [Photo] {
        let key = "\(listVersion(lib))|\(String(describing: source))|\(filter)|\(sort)|\(query)|\(lib.photos.count)|\(personAll)|\(searchKey)"
        if key != srcKey {
            // "This isn't them" on a person's page: just take those photos out, without listing the library again
            let parts = String(key.drop { $0 != "|" })
            if case .person(let id) = source, parts == srcParts {
                let ids = FaceIndex.shared.photoIds(person: id)
                if ids.count < srcPerson.count, ids.isSubset(of: srcPerson) {
                    srcCache.removeAll { !ids.contains($0.id) }
                    srcPerson = ids; srcKey = key
                    return srcCache
                }
            }
            srcParts = parts
            if case .person(let id) = source { srcPerson = FaceIndex.shared.photoIds(person: id) } else { srcPerson = [] }
            srcCache = lib.list(source: source ?? .all, filter: filter, query: query, sort: sort)
            // a person's page opens on a Summary of their best photos across the years
            if case .person(let id) = source, !personAll {
                let keep = FaceIndex.shared.summaryPhotoIds(person: id, lib: lib)
                srcCache = srcCache.filter { keep.contains($0.id) }
            }
            srcKey = key
        }
        return srcCache
    }
    func zoomAtPointer() {
        if let f = hoverFrac, (0...1).contains(f.x), (0...1).contains(f.y) { zoomFocus = f; zoomAnchor = hoverAnchor }
        else { zoomFocus = CGPoint(x: 0.5, y: 0.5); zoomAnchor = CGPoint(x: 0.5, y: 0.5) }
        zoomStart = 1; zoom = true
    }
    func primaryPhoto(_ lib: Library) -> Photo? { primary.flatMap { lib.byId[$0] } }
    /// Delete…: asks (Move to Trash / Remove from Catalog), then moves on to the next photo, as in Aperture.
    func deleteTargets(_ lib: Library) {
        let t = targets(lib)
        guard !t.isEmpty else { return }
        let list = visible(lib), gone = Set(t.map(\.id))
        let first = list.firstIndex { gone.contains($0.id) } ?? 0
        let next = list[first...].first { !gone.contains($0.id) } ?? list[..<first].last { !gone.contains($0.id) }
        if lib.deletePhotos(t) { selection = []; primary = next?.id }
    }
    /// "This isn't them" on a person's page (Delete): off the person at once. In the Viewer and Split View it
    /// carries on with the next photo, so you can step through someone's photos and press Delete on each wrong one.
    func notThisPerson(_ lib: Library) {
        guard case .person(let pid) = source else { return }
        let t = targets(lib)
        guard !t.isEmpty else { return }
        let list = visible(lib), gone = Set(t.map(\.id))
        let first = list.firstIndex { gone.contains($0.id) } ?? 0
        let next = list[first...].first { !gone.contains($0.id) } ?? list[..<first].last { !gone.contains($0.id) }
        FaceIndex.shared.remove(photos: gone, from: pid, lib: lib)
        if mode == .browser { selection = []; return }
        guard let next else { selection = []; primary = nil; mode = .browser; return }
        selection = [next.id]; primary = next.id
    }
    /// The name for Photo ▸ This Isn't … (on a person's page).
    func personName(_ lib: Library) -> String? {
        guard case .person(let pid) = source else { return nil }
        return FaceIndex.shared.people[pid]?.name
    }
    func targets(_ lib: Library) -> [Photo] {
        let s = selection.compactMap { lib.byId[$0] }
        if !s.isEmpty { return s }
        return primaryPhoto(lib).map { [$0] } ?? []
    }
    func select(_ p: Photo, in list: [Photo], extend: Bool, toggle: Bool) {
        if toggle { if selection.contains(p.id) { selection.remove(p.id) } else { selection.insert(p.id) }; primary = p.id; return }
        if extend, let a = primary, let i = list.firstIndex(where: { $0.id == a }), let j = list.firstIndex(of: p) {
            for k in min(i, j)...max(i, j) { selection.insert(list[k].id) }
            primary = p.id; return
        }
        selection = [p.id]; primary = p.id
    }
    func step(_ d: Int, _ lib: Library) {
        let l = visible(lib); guard !l.isEmpty else { return }
        let i = primary.flatMap { id in l.firstIndex { $0.id == id } } ?? -1
        let n = max(0, min(l.count - 1, i < 0 ? 0 : i + d))
        selection = [l[n].id]; primary = l[n].id
    }
    /// What Library ▸ Previews works on: the selection when several are picked, else everything shown.
    func previewTargets(_ lib: Library) -> [Photo] { selection.count > 1 ? targets(lib) : visible(lib) }
    static var keysInstalled = false
    var fullScreen = false                       // F: the photo alone, filling the screen
    var slideshow = false                        // S: photos advance on their own
    var copied: CopiedSettings?                  // ⇧⌘C / ⇧⌘V
    var fastStepping = false
    var lifted: LiftedMetadata?                                   // Metadata ▸ Lift / Stamp
    var showBatch = false                                         // Metadata ▸ Batch Change…
    var showExport = false                                        // File ▸ Export ▸ Photos…
    var showPresets = false                                       // Metadata ▸ Manage Presets…
    var viewerDetails = false                                     // the details panel under the photo in the Viewer (swipe up)
    var personAll = false                        // a person's page: Summary (false) or Show All
    var showFaces = UserDefaults.standard.bool(forKey: "showFaces") { didSet { UserDefaults.standard.set(showFaces, forKey: "showFaces") } }   // Viewer: boxes and names on faces
    var lightsOut = false                        // L: the photo alone on black
    var panelsHidden = false                     // ⇧Tab: hide the toolbar and panels
    var viewerInfo = UserDefaults.standard.object(forKey: "viewerInfo") as? Int ?? 1 { didSet { UserDefaults.standard.set(viewerInfo, forKey: "viewerInfo") } }   // I: 0 off, 1 Info 1, 2 Info 2
    // Compare (C) and Survey (N)
    var compareSelect: Int?
    var compareCandidate: Int?
    var compareActive = 0                        // 0 = Select, 1 = Candidate
    var compareZoom = false
    var compareFocus = CGPoint(x: 0.5, y: 0.5)
    var surveyIds: [Int] = []
    var copiedLocation: (lat: Double, lng: Double)?                     // an arrow key is being held: show quick previews only
    var detailedCells = UserDefaults.standard.bool(forKey: "detailedCells") { didSet { UserDefaults.standard.set(detailedCells, forKey: "detailedCells") } }   // J
    var showInfo = UserDefaults.standard.object(forKey: "showInfo") as? Bool ?? true { didSet { UserDefaults.standard.set(showInfo, forKey: "showInfo") } }   // H
    var mapFocus: MapFocus?                      // Show on Map: where the map should fly to
    var showKeywords = false                     // K: the keyword panel
    /// Split view filmstrip thumbnail height (the slider at the bottom right).
    var stripHeight: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "stripHeight") as? Double ?? 120) { didSet { UserDefaults.standard.set(Double(stripHeight), forKey: "stripHeight") } }
    // Pinch (trackpad): All Photos resizes; the cards step Years ▸ Months ▸ Weeks ▸ Days ▸ All Photos
    @ObservationIgnored var pinchSum: CGFloat = 0
    @ObservationIgnored var pinchStepped = false
    func setScale(_ v: BrowseScale) { if source == .days { source = .all }; browse = v }
    /// +1 = closer (towards All Photos), -1 = further out (towards Years).
    /// Settings ▸ Toolbar can hide views and browse steps (Browser and All Photos always stay).
    static func shown(_ m: ViewMode) -> Bool { m == .browser || (UserDefaults.standard.object(forKey: "show.mode." + m.rawValue) as? Bool ?? (m != .compare && m != .survey)) }
    static func shown(_ s: BrowseScale) -> Bool { s == .all || (UserDefaults.standard.object(forKey: "show.scale." + s.rawValue) as? Bool ?? true) }
    func stepScale(_ dir: Int) {
        let all = BrowseScale.allCases.filter { UIState.shown($0) || $0 == scale }, i = all.firstIndex(of: scale) ?? all.count - 1
        let n = max(0, min(all.count - 1, i + dir))
        if n != i { setScale(all[n]) }
    }
    func pinchGrid(_ m: CGFloat, began: Bool) {
        if began { pinchSum = 0; pinchStepped = false }
        pinchSum += m
        let atSmallest = tile <= 16.5
        tile = min(400, max(16, tile * (1 + m)))
        if atSmallest && m < 0 && pinchSum < -0.35 && !pinchStepped { pinchStepped = true; stepScale(-1) }   // keep pinching in: back to Days
    }
    // Calendar
    var calMode: CalMode = CalMode(rawValue: UserDefaults.standard.string(forKey: "calMode") ?? "") ?? .month { didSet { UserDefaults.standard.set(calMode.rawValue, forKey: "calMode") } }
    var calDate: Date?
    var calHeat = UserDefaults.standard.bool(forKey: "calHeat") { didSet { UserDefaults.standard.set(calHeat, forKey: "calHeat") } }
    var returnMode: ViewMode = .browser          // where Esc goes back to from the Viewer
    // Develop
    var developFrom: ViewMode = .browser         // where Esc / D / Back go from Develop
    @ObservationIgnored var inspectorBeforeDevelop: Bool?
    var copiedRecipe: Recipe?                    // Photo ▸ Copy / Paste Adjustments
    // Map
    var mapPicks: [Int] = []                     // photos in the pin or cluster last clicked
    var mapStyle = UserDefaults.standard.string(forKey: "mapStyle") ?? "Hybrid" { didSet { UserDefaults.standard.set(mapStyle, forKey: "mapStyle") } }
    var mapUnplaced = false                      // the strip shows photos without a location, to drag onto the map
    var refocus = 0
    /// Esc: out of zoom, then the Loupe, then back to the grid. Returns false when there was nothing to leave.
    func escape() -> Bool {
        if mode == .develop {
            if DevelopModel.shared.escape() { return true }
            mode = developFrom; refocus += 1; return true
        }
        if zoom { zoom = false; return true }
        if compareZoom { compareZoom = false; return true }
        if lightsOut { lightsOut = false; fullScreen = false; return true }
        if loupe { loupe = false; return true }
        if slideshow { slideshow = false; return true }
        if fullScreen { fullScreen = false; return true }
        if mode != .browser && mode != .calendar && mode != .map { mode = returnMode; returnMode = .browser; refocus += 1; return true }
        return false
    }
    func selectNone(_ lib: Library) { selection = primary.map { [$0] } ?? [] }
    func selectAll(_ lib: Library) { let l = visible(lib); selection = Set(l.map(\.id)); if primary == nil { primary = l.first?.id } }
    func ensurePrimary(_ lib: Library) {
        let l = visible(lib)
        if let p = primary, l.contains(where: { $0.id == p }) { return }
        primary = l.first?.id; selection = primary.map { [$0] } ?? []
    }

    func addFolder(_ lib: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"; panel.message = "Your photos stay where they are. Loupe Photos reads them in place."
        if panel.runModal() == .OK { for u in panel.urls { lib.addFolder(u) } }
    }
    func openCatalog(_ lib: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowedContentTypes = []
        panel.prompt = "Open"; panel.message = "Choose an Loupe Photos library folder (or the .apcat file inside it)."
        guard panel.runModal() == .OK, var u = panel.url else { return }
        if u.pathExtension == "apcat" { u.deleteLastPathComponent() }
        lib.close()
        UserDefaults.standard.set(u.path, forKey: "catalogDir")
        let task = Process(); task.launchPath = "/usr/bin/open"; task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run(); NSApp.terminate(nil)
    }
    /// Metadata ▸ New Preset from Photo…
    func newPresetFromPhoto(_ lib: Library) {
        guard let p = primaryPhoto(lib) else { return }
        let a = NSAlert(); a.messageText = "New Metadata Preset"; a.informativeText = "Made from this photo's IPTC fields and caption."
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.placeholderString = "Preset name"; a.accessoryView = f
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        _ = MetadataPresets.shared.fromPhoto(p, name: name.isEmpty ? "Untitled Preset" : name)
    }
    /// Metadata ▸ Read Metadata from Files…: what the files say replaces the catalog's (asked first).
    func readMetadata(_ lib: Library) {
        let t = targets(lib)
        let a = NSAlert()
        a.messageText = "Read metadata from \(t.count.formatted()) file\(t.count == 1 ? "" : "s")?"
        a.informativeText = "Ratings, labels, keywords, captions and IPTC fields found in the files (or their .xmp sidecars) will replace what the catalog has for them."
        a.addButton(withTitle: "Read"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        XMPSync.read(t, lib: lib)
    }
    func newAlbum(_ lib: Library) {
        let a = NSAlert(); a.messageText = "New Collection"; a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.placeholderString = "Collection name"; a.accessoryView = f
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        let al = lib.newAlbum(named: name.isEmpty ? "Untitled Collection" : name, with: targets(lib).map(\.id))
        source = .album(al.id)
    }
}

/// View ▸ View Options… (⌘J)
struct ViewOptionsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("View Options…") { openWindow(id: "view-options") }.keyboardShortcut("j", modifiers: [.command]) }
}

extension UIState {
    /// C: the current photo (Select) beside another (Candidate) — the second selected photo, or the next one.
    func startCompare(_ lib: Library) {
        let l = visible(lib)
        guard let sel = primary ?? l.first?.id else { return }
        let others = l.filter { selection.contains($0.id) && $0.id != sel }
        let next = l.firstIndex { $0.id == sel }.flatMap { i in l.indices.contains(i + 1) ? l[i + 1].id : (i > 0 ? l[i - 1].id : nil) }
        compareSelect = sel; compareCandidate = others.first?.id ?? next; compareActive = 0; compareZoom = false
        if mode != .compare && mode != .survey { returnMode = mode == .calendar || mode == .map ? mode : .browser }
        primary = sel; selection = [sel]; zoom = false; loupe = false
        mode = .compare
    }
    /// ← → in Compare: the next or previous photo becomes the Candidate.
    func compareStep(_ d: Int, _ lib: Library) {
        let l = visible(lib)
        guard let c = compareCandidate ?? compareSelect, var i = l.firstIndex(where: { $0.id == c }) else { return }
        repeat { i += d } while l.indices.contains(i) && l[i].id == compareSelect
        guard l.indices.contains(i) else { return }
        compareCandidate = l[i].id
        if compareActive == 1 { primary = l[i].id; selection = [l[i].id] }
    }
    /// ↑: the Candidate becomes the Select (and the next photo the new Candidate). ↓: swap them.
    func compareMakeSelect(_ lib: Library) { guard let c = compareCandidate else { return }; compareSelect = c; compareActive = 0; primary = c; selection = [c]; compareStep(1, lib) }
    func compareSwap() { swap(&compareSelect, &compareCandidate); compareActive = 0; if let s = compareSelect { primary = s; selection = [s] } }
    func compareSetActive(_ side: Int) { compareActive = side; if let id = side == 0 ? compareSelect : compareCandidate { primary = id; selection = [id] } }

    /// N: the selected photos side by side (or the current photo and the next three when only one is picked).
    func startSurvey(_ lib: Library) {
        let l = visible(lib)
        var ids = l.filter { selection.contains($0.id) }.map(\.id)
        if ids.count < 2, let p = primary ?? l.first?.id, let i = l.firstIndex(where: { $0.id == p }) { ids = l[i..<min(l.count, i + 4)].map(\.id) }
        guard !ids.isEmpty else { return }
        surveyIds = ids
        if !ids.contains(primary ?? -1) { primary = ids[0] }
        selection = [primary!]
        if mode != .compare && mode != .survey { returnMode = mode == .calendar || mode == .map ? mode : .browser }
        zoom = false; loupe = false
        mode = .survey
    }
    func surveyStep(_ d: Int) {
        guard let p = primary, let i = surveyIds.firstIndex(of: p) else { if let f = surveyIds.first { primary = f; selection = [f] }; return }
        let n = max(0, min(surveyIds.count - 1, i + d)); primary = surveyIds[n]; selection = [surveyIds[n]]
    }
    /// ✕ / Delete in Survey: drop a photo from the survey (it stays in the library).
    func surveyDrop(_ id: Int) {
        guard let i = surveyIds.firstIndex(of: id) else { return }
        surveyIds.remove(at: i)
        if surveyIds.isEmpty { mode = returnMode; return }
        if primary == id { let n = surveyIds[min(i, surveyIds.count - 1)]; primary = n; selection = [n] }
    }

    // Copy / paste a location from one photo to others
    func copyLocation(_ lib: Library) {
        guard let p = primaryPhoto(lib), let g = Library.gps(p) else { return }
        copiedLocation = (g.latitude, g.longitude)
        lib.status = "Copied the location of “\(p.displayName)”."
    }
    func pasteLocation(_ lib: Library) {
        guard let c = copiedLocation else { return }
        let t = targets(lib)
        lib.setLocation(t, CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng))
        PlaceNamer.shared.nameMissing(lib)
        lib.status = "Pasted the location onto \(t.count) photo\(t.count == 1 ? "" : "s")."
    }
}


/// File ▸ Import… (⇧⌘I)
struct ImportMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Import…") { openWindow(id: "import") }.keyboardShortcut("i", modifiers: [.command, .shift]) }
}


// MARK: Develop from the menus
extension UIState {
    func copyAdjustments(_ lib: Library) {
        guard let p = primaryPhoto(lib), let r = DevelopStore.shared.recipe(p.id) else { return }
        copiedRecipe = r
        lib.status = "Copied the adjustments of “\(p.displayName)” — ⌥⌘V pastes them (all but the crop)."
    }
    /// Pastes every adjustment except the crop and RAW Fine Tuning onto the selected photos.
    func pasteAdjustments(_ lib: Library) {
        guard let c = copiedRecipe else { return }
        let t = targets(lib)
        for p in t {
            var r = DevelopStore.shared.recipe(p.id) ?? Recipe()
            for b in Brick.allCases where b != .crop && b != .raw {
                for k in b.keys { r.set(k, c.has(k) ? c.v(k) : nil) }
                if b == .exposure { r.curve = c.curve }
                r.setOn(b, c.on(b))
            }
            DevelopStore.shared.save(p, r, lib: lib, after: 0.3)
            DevelopModel.shared.reloadIfShowing(p.id)
        }
        lib.status = "Pasted adjustments onto \(t.count.formatted()) photo\(t.count == 1 ? "" : "s")."
    }
    func revertAdjustments(_ lib: Library) {
        let t = targets(lib).filter { DevelopStore.shared.isEdited($0.id) }
        guard !t.isEmpty else { return }
        if t.count > 1 {
            let a = NSAlert(); a.messageText = "Revert \(t.count.formatted()) photos to their originals?"
            a.informativeText = "Their Develop adjustments (including crops) are removed. The original files were never changed."
            a.addButton(withTitle: "Revert"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        for p in t { DevelopStore.shared.save(p, nil, lib: lib, after: 0.3); DevelopModel.shared.reloadIfShowing(p.id) }
    }
}

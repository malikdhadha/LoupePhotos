import SwiftUI

/// Loupe Photos ▸ Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            SidebarSettingsView().tabItem { Label("Sidebar", systemImage: "sidebar.left") }
            ToolbarSettingsView().tabItem { Label("Toolbar", systemImage: "menubar.rectangle") }
            PreviewSettingsView().tabItem { Label("Previews", systemImage: "photo.stack") }
            PeopleSettingsView().tabItem { Label("People", systemImage: "person.2") }
            SearchSettingsView().tabItem { Label("Search", systemImage: "sparkle.magnifyingglass") }
            LibrarySettingsView().tabItem { Label("Library", systemImage: "folder.badge.gearshape") }
            MetadataSettingsView().tabItem { Label("Metadata", systemImage: "tag") }
            DevelopSettingsView().tabItem { Label("Develop", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560)
    }
}

struct PreviewSettingsView: View {
    @State private var s = PreviewSettings.shared
    @State private var space: (thumbs: Int64, standard: Int64, full: Int64)?
    @State private var confirm: String?

    var body: some View {
        Form {
            Section {
                Picker("Standard preview size", selection: $s.standardSize) {
                    ForEach(PreviewSettings.sizes, id: \.self) { n in Text(n == 0 ? "Auto (\(PreviewSettings.shared.standardPixels) pixels, fits this screen)" : "\(n) pixels").tag(n) }
                }
                Picker("Preview quality", selection: $s.quality) { ForEach(PreviewSettings.Quality.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Automatically discard 1:1 previews", selection: $s.discardFullAfter) {
                    ForEach(PreviewSettings.discardDays, id: \.self) { d in Text(d == 0 ? "Never" : d == 1 ? "After one day" : "After \(d) days").tag(d) }
                }
                Picker("Build on import: RAW files", selection: $s.onImportRaw) { ForEach(PreviewSettings.OnImport.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Build on import: JPEG, HEIC and others", selection: $s.onImport) { ForEach(PreviewSettings.OnImport.allCases) { Text($0.rawValue).tag($0) } }
            } footer: {
                Text("Previews are saved as HEIC, about half the size of JPEG at the same quality. Thumbnails are always kept. Standard previews are made when you first view a photo, or ahead of time with Library ▸ Previews.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Space used") {
                row("Thumbnails", space?.thumbs, nil)
                row("Standard previews", space?.standard) { BigPreviews.discardAll(.standard) }
                row("1:1 previews", space?.full) { BigPreviews.discardAll(.full) }
                HStack {
                    Text(PreviewStore.shared.url?.lastPathComponent ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { if let u = PreviewStore.shared.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                }
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    func row(_ name: String, _ bytes: Int64?, _ discard: (() -> Void)?) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").foregroundStyle(.secondary).monospacedDigit()
            if let discard {
                Button("Discard All") { discard(); Task { await measure() } }.controlSize(.small)
            }
        }
    }
    func measure() async {
        space = await Task.detached(priority: .utility) { (PreviewStore.shared.bytesOnDisk, BigPreviews.bytes(.standard), BigPreviews.bytes(.full)) }.value
    }
}

/// Settings ▸ Sidebar: switch parts of the sidebar on or off.
struct SidebarSettingsView: View {
    @AppStorage("show.people") private var people = true
    @AppStorage("show.recentDays") private var recentDays = true
    @AppStorage("show.lastImport") private var lastImport = true
    @AppStorage("show.quick") private var quick = true
    @AppStorage("show.flags") private var flags = true
    @AppStorage("show.labels") private var labels = true
    @AppStorage("show.ratings") private var ratings = true
    @AppStorage("show.dates") private var dates = true
    @AppStorage("show.onThisDay") private var onThisDay = true
    @AppStorage("show.folders") private var folders = true
    @AppStorage("show.collections") private var collections = true
    @AppStorage("show.keywords") private var keywords = true
    @AppStorage("show.places") private var places = true

    var body: some View {
        Form {
            Section("Library") {
                Toggle("People", isOn: $people)
                Toggle("Recent Days", isOn: $recentDays)
                Toggle("Last Import", isOn: $lastImport)
                Toggle("Quick Collection (when it has photos)", isOn: $quick)
                Toggle("Flags", isOn: $flags)
                Toggle("Color Labels", isOn: $labels)
                Toggle("Ratings", isOn: $ratings)
            }
            Section("Sections") {
                Toggle("Dates", isOn: $dates)
                Toggle("On This Day", isOn: $onThisDay).disabled(!dates).padding(.leading, 16)
                Toggle("Folders", isOn: $folders)
                Toggle("Collections", isOn: $collections)
                Toggle("Keywords (when you have some)", isOn: $keywords)
                Toggle("Places", isOn: $places)
            }
            Section {
                Text("Photos is always shown. Hidden parts keep everything in them — switch them back on any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings ▸ Toolbar: which views and browse steps appear.
struct ToolbarSettingsView: View {
    @AppStorage("show.mode.Split") private var split = true
    @AppStorage("show.mode.Viewer") private var viewer = true
    @AppStorage("show.mode.Calendar") private var calendar = true
    @AppStorage("show.mode.Map") private var map = true
    @AppStorage("show.mode.Compare") private var compare = false
    @AppStorage("show.mode.Survey") private var survey = false
    @AppStorage("show.mode.People") private var peopleMode = true
    @AppStorage("show.mode.Develop") private var develop = true
    @AppStorage("show.scale.Years") private var years = true
    @AppStorage("show.scale.Months") private var months = true
    @AppStorage("show.scale.Weeks") private var weeks = true
    @AppStorage("show.scale.Days") private var days = true

    var body: some View {
        Form {
            Section("Views (top of the window)") {
                Toggle("Viewer", isOn: $viewer)
                Toggle("Split", isOn: $split)
                Toggle("Develop (D)", isOn: $develop)
                Toggle("People", isOn: $peopleMode)
                Toggle("Compare (C)", isOn: $compare)
                Toggle("Survey (N)", isOn: $survey)
                Toggle("Calendar", isOn: $calendar)
                Toggle("Map", isOn: $map)
            }
            Section("Browse steps (above the photos)") {
                Toggle("Years", isOn: $years)
                Toggle("Months", isOn: $months)
                Toggle("Weeks", isOn: $weeks)
                Toggle("Days", isOn: $days)
            }
            Section {
                Text("Browser and All Photos always stay. Hidden views still work from the View menu and their shortcuts (⌘2 Viewer, ⌘3 Split, ⌘4 Calendar, ⌘5 Map); pinching skips hidden steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// Settings ▸ People
struct PeopleSettingsView: View {
    @AppStorage("faces.enabled") private var enabled = true
    @AppStorage("faces.keywords") private var keywords = true
    @AppStorage("show.people") private var showPeople = true
    @State private var compare = ModelCompare.shared
    @State private var startWith: String?
    var body: some View {
        Form {
            Section {
                Toggle("Find faces in photos", isOn: $enabled)
                    .onChange(of: enabled) { _, on in if on { FaceScanner.shared.start(Library.shared) } else { FaceScanner.shared.stop() } }
                Text("Faces are found and recognised on this Mac only (Apple Vision plus the recognition model below, on the Neural Engine). Nothing is uploaded. New photos are checked as they're added.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Add names as keywords (People › Name)", isOn: $keywords)
                    .onChange(of: keywords) { _, on in if on { FaceIndex.shared.syncKeywords(Library.shared) } }
                Text("So Lightroom and other apps can see who's in each photo. Only names you've given in Loupe Photos are added or removed.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show People in the sidebar", isOn: $showPeople)
            }
            Section("Recognition model") {
                LabeledContent("In use", value: "AuraFace (Apache-2.0)")
                Text("AuraFace runs on this Mac's Neural Engine. Faces never leave your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Start People over?", isPresented: Binding(get: { startWith != nil }, set: { if !$0 { startWith = nil } }), titleVisibility: .visible) {
            Button("Erase All Faces and Names", role: .destructive) {
                if let m = startWith { FaceIndex.shared.startOver(model: m, lib: Library.shared) }
                startWith = nil
            }
        } message: {
            Text("Every face, name, confirmation, hidden face and “not this person” answer is erased, and every photo is looked at again with \(startWith == "Glint100" ? "InsightFace glintr100" : "AuraFace"). Your photos, ratings, keywords and collections are not touched (only the People › Name keywords Loupe Photos added are removed). This can't be undone.")
        }
    }
}


/// Settings ▸ Search
struct SearchSettingsView: View {
    @AppStorage("search.enabled") private var enabled = true
    @AppStorage("search.ocr") private var ocr = true
    @AppStorage("search.battery") private var battery = false
    @State private var confirm = false
    var body: some View {
        let idx = SearchIndex.shared, lib = Library.shared
        let total = lib.photos.filter { $0.deleted == nil }.count
        Form {
            Section {
                Toggle("Search in plain words", isOn: $enabled)
                    .onChange(of: enabled) { _, on in if on { SearchScanner.shared.start(lib) } else { SearchScanner.shared.stop() } }
                Text("Type what you remember — “dog on the beach”, “Sam 2019”, “sunset in Lisbon”, “5 stars”. Names, places, dates and stars are understood; what's in the pictures is found from Apple's scene labels and any text in them (on this Mac only — nothing is uploaded).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Read text in photos (signs, documents, screenshots)", isOn: $ocr)
                Toggle("Wait while on battery", isOn: $battery)
                Text("Getting photos ready takes a moment each, in the background. You can pause it from Background Tasks in the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ready to search") {
                if !SearchScanner.available {
                    Text("The picture-understanding model isn't built into this copy of Loupe Photos, so only names, places, keywords and captions are searched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Photos", value: "\(min(idx.count, total).formatted()) of \(total.formatted())")
                HStack {
                    Spacer()
                    Button("Start Over…") { confirm = true }
                        .help("Forget what's been learned and look at every photo again (after changing the settings above, for example)")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Look at every photo again?", isPresented: $confirm) {
            Button("Start Over") {
                SearchScanner.shared.stop(); SearchIndex.shared.reset()
                lib.dbWrite { $0.deleteClip(ofPhotos: nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SearchScanner.shared.start(lib) }
            }
        } message: { Text("Search keeps working while it catches up.") }
    }
}


/// Settings ▸ Library
struct LibrarySettingsView: View {
    @AppStorage("watch.folders") private var watch = true
    @AppStorage("away.summary") private var away = true
    @AppStorage("places.enabled") private var places = true
    @AppStorage("bg.battery") private var battery = true
    @AppStorage("backup.when") private var backupWhen = CatalogBackup.When.weekly.rawValue
    @AppStorage("backup.ask") private var backupAsk = true
    @AppStorage("backup.keep") private var backupKeep = 10
    @AppStorage("backup.folder") private var backupFolder = ""
    @AppStorage("backup.last") private var backupLast = 0.0
    var body: some View {
        Form {
            Section("Catalog backup") {
                Picker("Back up the catalog", selection: $backupWhen) {
                    ForEach(CatalogBackup.When.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("Ask before backing up", isOn: $backupAsk).disabled(backupWhen == CatalogBackup.When.never.rawValue)
                HStack {
                    Text("Backups go to")
                    Spacer()
                    Text(CatalogBackup.shared.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(CatalogBackup.shared.folder.path)
                    Button("Choose…") { CatalogBackup.shared.chooseFolder(); backupFolder = UserDefaults.standard.string(forKey: "backup.folder") ?? "" }
                }
                Picker("Keep", selection: $backupKeep) {
                    Text("The last 5").tag(5); Text("The last 10").tag(10); Text("The last 20").tag(20); Text("All of them").tag(0)
                }
                HStack {
                    Text(backupLast > 0 ? "Last backup: " + Date(timeIntervalSince1970: backupLast).formatted(date: .abbreviated, time: .shortened) : "Not backed up yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Back Up Now") { CatalogBackup.shared.backUpNowFromMenu() }
                    Button("Restore…") { CatalogBackup.shared.restore() }
                }
                Text("Ratings, keywords, collections, faces, people and the search index. Previews aren't included; they can be made again. With “Ask” off, backups happen by themselves when you quit. Another drive is the safest place.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Background work") {
                Toggle("Look up place names for photos with a location", isOn: $places)
                Toggle("Wait for power before finding faces (on battery)", isOn: $battery)
                    .onChange(of: places) { _, on in if on { PlaceNamer.shared.nameMissing(Library.shared) } }
                Text("Asks Apple Maps for the town and country of each spot (over the internet; each spot only once). Finding faces and getting photos ready for search are switched on and off under People and Search.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("After an import, thumbnails are made first. Faces, search and place names wait for them, and pause while you scroll or flip through photos. Pause everything from Background Tasks in the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Add new photos by themselves", isOn: $watch)
                    .onChange(of: watch) { _, on in if on { FolderWatcher.shared.start(Library.shared) } else { FolderWatcher.shared.stop() } }
                Text("Photos copied into your library folders (from a card, AirDrop or another app) are added a few seconds later — faces found and named, and ready to search — while Loupe Photos is open.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Say what happened while you were away", isOn: $away)
                Text("After 20 minutes or more away: “While you were away: 1,000 photos added · 812 faces named · 9 to review.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings ▸ Metadata: who you are (for presets and imports) and whether metadata is also written into the files.
struct MetadataSettingsView: View {
    @AppStorage("xmp.auto") private var auto = false
    @AppStorage("xmp.embed") private var embed = true
    @State private var values: [IPTCField: String] = [:]
    var body: some View {
        Form {
            Section("Identity") {
                ForEach(IPTCField.identity) { f in
                    TextField(f.label, text: Binding(get: { values[f] ?? "" }, set: { values[f] = $0; Identity.set(f, $0) }),
                              prompt: Text(f == .copyright ? "© 2026 Your Name" : ""))
                }
                Text("Used by the “My Identity” metadata preset — in the Metadata menu, Batch Change and the Import window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing to files (XMP)") {
                Toggle("Automatically write changes into XMP", isOn: $auto)
                Toggle("JPEG, HEIC and TIFF: write inside the file (otherwise a sidecar)", isOn: $embed).disabled(!auto)
                Text("Off: ratings, keywords, captions and IPTC stay in the catalog only (the default, like Lightroom). On: they're also written to the photo files so other apps see them — RAW files get a .xmp sidecar beside them; an existing sidecar from Lightroom is updated, not replaced. Metadata ▸ Save Metadata to Files (⌘S) writes the selected photos any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { for f in IPTCField.identity { values[f] = Identity.value(f) } }
    }
}

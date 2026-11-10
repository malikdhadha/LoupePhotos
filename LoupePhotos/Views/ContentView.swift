import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @FocusState private var mainFocus: Bool
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var restored = false
    @State private var before: (mode: ViewMode, inspector: Bool, wasFull: Bool)?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("show.mode.Split") private var m1 = true
    @AppStorage("show.mode.Viewer") private var m2 = true
    @AppStorage("show.mode.Calendar") private var m3 = true
    @AppStorage("show.mode.Map") private var m4 = true
    @AppStorage("show.mode.Compare") private var m5 = false
    @AppStorage("show.mode.Survey") private var m6 = false
    @AppStorage("show.mode.People") private var m7 = true
    @AppStorage("show.mode.Develop") private var m8 = true
    var toolbarKey: String { "\(m1)\(m2)\(m3)\(m4)\(m5)\(m6)\(m7)\(m8)" }

    var body: some View {
        @Bindable var ui = ui
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if ui.fullScreen { ViewerView() } else {
                    if AwayReport.shared.showing { AwayBanner(); Divider() }
                    main; StatusBar()
                }
            }
            .sheet(isPresented: $ui.showKeywords) { KeywordPanel() }
            // photos or folders dragged in from Finder: the Import window, with them chosen (copied into the library by default)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                let group = DispatchGroup(); var urls: [URL] = []; let lock = NSLock()
                for pr in providers {
                    group.enter()
                    _ = pr.loadObject(ofClass: URL.self) { u, _ in if let u { lock.lock(); urls.append(u); lock.unlock() }; group.leave() }
                }
                group.notify(queue: .main) {
                    // photos already in the library (dragged out of the grid and back) aren't imported again
                    let known = lib.pathIndex
                    let new = urls.filter { known[$0.standardizedFileURL.path] == nil }
                    guard !new.isEmpty else { return }
                    openWindow(id: "import")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Importer.shared.addFiles(new) }
                }
                return true
            }
            .sheet(isPresented: $ui.showBatch) { BatchChangeView(targets: ui.targets(lib)) }
            .sheet(isPresented: $ui.showPresets) { PresetsView() }
            .sheet(isPresented: $ui.showExport) { ExportView(targets: ui.targets(lib)) }
            .inspector(isPresented: $ui.showInspector) {
                InspectorView().inspectorColumnWidth(min: 260, ideal: 290, max: 380)
            }
        }
        .toolbar(ui.fullScreen || ui.panelsHidden ? .hidden : .automatic, for: .windowToolbar)
        .searchable(text: $ui.query, placement: .toolbar, prompt: SearchSettings.enabled ? "Search — “beach 2019”, a name, a place" : "Search names, places, keywords")
        .onChange(of: ui.query) { old, new in
            NaturalSearch.shared.looseness = 0
            // results show as a grid of photos; going back to where you were when the search is cleared
            if old.isEmpty && !new.isEmpty {
                ui.beforeSearch = (ui.source == .people || ui.mode == .people ? .people : nil, ui.browse)
                if ui.source == .people || ui.mode == .people { ui.source = .all; ui.mode = .browser }   // results are photos
                if ui.scale != .all && ui.source != .days { ui.browse = .all }
            } else if new.isEmpty, let b = ui.beforeSearch {
                if let s = b.source, ui.source == .all { ui.source = s }
                ui.browse = b.browse; ui.beforeSearch = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { ActivityButton() }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $ui.mode) { ForEach(ViewMode.allCases.filter { UIState.shown($0) || $0 == ui.mode }) { Text($0.rawValue).tag($0) } }
                    .id(toolbarKey)
                    .pickerStyle(.segmented).fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { lib.rotate(ui.targets(lib), -1) } label: { Image(systemName: "rotate.left") }.help("Rotate left ([)")
                Button { lib.rotate(ui.targets(lib), 1) } label: { Image(systemName: "rotate.right") }.help("Rotate right (])")
                Button { openWindow(id: "import") } label: { Image(systemName: "square.and.arrow.down") }.help("Import photos from a card or folder (⇧⌘I)")
                Button { ui.addFolder(lib) } label: { Image(systemName: "folder.badge.plus") }.help("Add a folder of photos where it is")
                Button { ui.showExport = true } label: { Image(systemName: "square.and.arrow.up") }.help("Export the selected photos (⇧⌘E)").disabled(ui.targets(lib).isEmpty)
                Button { ui.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Show or hide the Inspector")
            }
        }
        .onChange(of: ui.source) { _, _ in ui.ensurePrimary(lib) }
        .onReceive(NotificationCenter.default.publisher(for: .openImport)) { _ in openWindow(id: "import") }
        .onReceive(NotificationCenter.default.publisher(for: .importFinished)) { _ in
            ui.query = ""; ui.source = .recent; if ui.mode == .people { ui.mode = .browser }   // show what just came in (Last Import)
        }
        // People is its own view: the sidebar's People row and the toolbar's People button lead to the same place
        .onChange(of: ui.source) { _, s in
            Timing.start("sidebar → \(String(describing: s ?? .all))")
            if s == .people && ui.mode != .people { ui.mode = .people }
            // anything else picked in the sidebar while in People (a year, a folder, a collection, a person): show it in the grid
            else if s != .people && ui.mode == .people { ui.mode = .browser }
        }
        .onChange(of: ui.mode) { old, new in
            // Develop: the adjustments live in the Inspector, so it's shown while you're there
            if new == .develop && old != .develop {
                ui.developFrom = [.people, .compare, .survey].contains(old) ? .browser : old
                ui.inspectorBeforeDevelop = ui.showInspector
                ui.showInspector = true; ui.zoom = false; ui.loupe = false
                ui.ensurePrimary(lib)
            } else if old == .develop && new != .develop {
                DevelopModel.shared.leave()
                if let b = ui.inspectorBeforeDevelop, !b { ui.showInspector = false }
                ui.inspectorBeforeDevelop = nil
            }
            if new == .people && ui.source != .people { ui.sourceBeforePeople = ui.source; ui.source = .people }
            else if old == .people && new != .people && ui.source == .people { ui.source = ui.sourceBeforePeople ?? .all }
        }
        .onChange(of: lib.version) { _, _ in if ui.primary == nil { ui.ensurePrimary(lib) } }
        // remember where you were, and go back there next time
        .task { if lib.loaded && !restored { restored = true; ui.restorePlace(lib) } }
        .onChange(of: lib.loaded) { _, now in if now && !restored { restored = true; ui.restorePlace(lib) } }
        .onChange(of: ui.source) { _, _ in if restored { ui.rememberPlace() } }
        .onChange(of: ui.mode) { _, _ in if restored { ui.rememberPlace() } }
        .onChange(of: ui.primary) { _, _ in if restored { ui.rememberPlace() } }
        // slideshow: next photo every 3 seconds with a soft fade
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard ui.slideshow else { return }
            let l = ui.visible(lib)
            guard let i = l.firstIndex(where: { $0.id == ui.primary }) else { return }
            let n = l[(i + 1) % l.count]
            withAnimation(.easeInOut(duration: 0.8)) { ui.primary = n.id; ui.selection = [n.id] }
        }
        .onChange(of: ui.fullScreen) { _, on in if !on { ui.slideshow = false; ui.lightsOut = false } }
        // View Options (⌘J) changed the thumbnail style
        .onReceive(NotificationCenter.default.publisher(for: .gridCellsChanged)) { n in
            if let (info, det) = n.object as? (Bool, Bool) { ui.showInfo = info; ui.detailedCells = det }
        }
        // ⇧Tab hides the panels; Tab just the sidebar
        .onChange(of: ui.panelsHidden) { _, on in columns = on ? .detailOnly : .all; if on { ui.showInspector = false } }
        // F: full screen — the photo alone; Esc comes back
        .onChange(of: ui.fullScreen) { _, on in
            let win = NSApp.mainWindow ?? NSApp.windows.first { $0.title == "Loupe Photos" }
            let isFull = win?.styleMask.contains(.fullScreen) ?? false
            if on {
                before = (ui.mode, ui.showInspector, isFull)
                ui.showInspector = false; columns = .detailOnly; ui.zoom = false
                if !isFull { win?.toggleFullScreen(nil) }
            } else {
                columns = .all
                if let b = before { ui.showInspector = b.inspector; if !b.wasFull && isFull { win?.toggleFullScreen(nil) } }
                before = nil
            }
        }
    }

    @ViewBuilder var main: some View {
        Group {
            switch ui.mode {
            case .browser: BrowserView()
            case .people: PeopleView()
            case .calendar: CalendarView()
            case .map: PhotoMapView()
            case .viewer: ViewerView()
            case .compare: CompareView()
            case .survey: SurveyView()
            case .develop: DevelopView()
            case .split:
                VStack(spacing: 0) {
                    ViewerView().frame(minHeight: 200)
                    Divider()
                    PhotoActionBar()
                    Divider()
                    FilmstripView().frame(height: ui.stripHeight + 20)
                    Divider()
                    QuickFilterBar()
                }
            }
        }
        .onAppear { installSelectionKeys() }
    }

    /// Keys work only while the photos have focus, so typing in a text field never rates or flags anything.
    /// ⌘A selects every photo shown, ⇧⌘A / ⌘D select none (keeping the current photo), wherever the focus is,
    /// except while typing in a text field, where ⌘A selects the text as usual.
    func installSelectionKeys() {
        guard !UIState.keysInstalled else { return }
        UIState.keysInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            // Esc leaves zoom / the Loupe / the Viewer even when the sidebar or another control has the keyboard
            if e.keyCode == 53, mods.isEmpty, !(NSApp.keyWindow?.firstResponder is NSText), NSApp.keyWindow?.title == "Loupe Photos" {
                if ui.escape() { return nil }
                return e
            }
            guard let ch = e.charactersIgnoringModifiers?.lowercased(), mods.contains(.command), !mods.contains(.option), !mods.contains(.control) else { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e }          // typing: leave ⌘A to the text field
            guard NSApp.keyWindow?.title == "Loupe Photos" || NSApp.keyWindow == NSApp.mainWindow else { return e }
            // ⌘Z / ⇧⌘Z in Develop: undo and redo adjustments
            if ch == "z", ui.mode == .develop { if mods.contains(.shift) { DevelopModel.shared.redo() } else { DevelopModel.shared.undo() }; return nil }
            if ch == "a" && !mods.contains(.shift) { ui.selectAll(lib); return nil }
            if (ch == "a" && mods.contains(.shift)) || (ch == "d" && !mods.contains(.shift)) { ui.selectNone(lib); return nil }
            return e
        }
        // Magic Mouse and mouse wheel: Smart Zoom (one-finger double-tap) and ⌥-scroll work like a trackpad pinch
        var wheelSum: CGFloat = 0, lastWheel: TimeInterval = 0, stepped = false
        // holding ⌥ shows the Loupe at 200%
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            let d = e.modifierFlags.contains(.option)
            if ui.loupeDouble != d { ui.loupeDouble = d }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: [.smartMagnify, .scrollWheel]) { e in
            guard ui.mode == .browser, e.window?.title == "Loupe Photos" else { return e }
            if e.type == .smartMagnify {
                if ui.scale == .all { ui.tile = ui.tile < 140 ? 220 : 70 } else { ui.stepScale(1) }
                return nil
            }
            guard e.modifierFlags.contains(.option) else { return e }
            let dy = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 12)
            let fresh = e.phase == .began || e.timestamp - lastWheel > 0.45
            lastWheel = e.timestamp
            if fresh { wheelSum = 0; stepped = false }
            wheelSum += dy
            if ui.scale == .all {
                ui.pinchGrid(dy * 0.006, began: fresh)          // scroll up = bigger, down = smaller (then back to Days)
            } else if !stepped && abs(wheelSum) > 50 {
                stepped = true; ui.stepScale(wheelSum > 0 ? 1 : -1)
            }
            return nil
        }
        // letting go of a held arrow: load the sharp preview of where you stopped
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { e in
            if [123, 124, 125, 126].contains(e.keyCode), ui.fastStepping { ui.fastStepping = false }
            return e
        }
        // single-key shortcuts (arrows, ratings, Z, L, I…) — never while typing in a text or search box
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard NSApp.keyWindow?.title == "Loupe Photos", !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            let mods = e.modifierFlags.intersection([.command, .control])
            guard mods.isEmpty else { return e }
            return handleKey(e) ? nil : e
        }
    }

    /// Returns true when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        let t = ui.targets(lib)
        let code = e.keyCode, isArrow = [123, 124, 125, 126].contains(code)
        let left = code == 123, right = code == 124, down = code == 125, up = code == 126
        // Calendar: ← → move through time, ↑ ↓ zoom out and in
        if ui.mode == .calendar, isArrow {
            if left || right { ui.calShift(right ? 1 : -1, CalData.make(ui.visible(lib), key: ui.visibleKey)) } else { ui.calZoom(up ? 1 : -1) }
            return true
        }
        // Compare: ← → change the Candidate, ↑ makes it the Select, ↓ swaps
        if ui.mode == .compare, isArrow, !e.isARepeat || left || right {
            if left || right { ui.compareStep(right ? 1 : -1, lib) } else if up { ui.compareMakeSelect(lib) } else { ui.compareSwap() }
            return true
        }
        // Survey: arrows move between the photos; Delete takes one out of the survey
        if ui.mode == .survey {
            if isArrow { ui.surveyStep(left || up ? -1 : 1); return true }
            if code == 51 || code == 117 { if let p = ui.primary { ui.surveyDrop(p) }; return true }
        }
        // Tab: sidebar; ⇧Tab: sidebar, toolbar and inspector (like Lightroom)
        if code == 48 {
            if e.modifierFlags.contains(.shift) { ui.panelsHidden.toggle() }
            else { ui.panelsHidden = false; columns = columns == .detailOnly ? .all : .detailOnly }
            return true
        }
        // holding an arrow key keeps moving through the photos; other keys act once per press
        if e.isARepeat && !isArrow { return true }
        if isArrow && e.isARepeat && ui.mode != .browser && !ui.fastStepping { ui.fastStepping = true }
        if left { ui.step(-1, lib); return true }
        if right { ui.step(1, lib); return true }
        if up { ui.step(ui.mode == .browser ? -ui.columns : -1, lib); return true }
        if down { ui.step(ui.mode == .browser ? ui.columns : 1, lib); return true }
        switch code {
        case 36, 76, 49:   // Return, Enter, Space
            if ui.mode == .map { return false }
            if ui.mode == .develop { if DevelopModel.shared.cropping { DevelopModel.shared.cropping = false }; return true }
            if ui.mode == .calendar { ui.returnMode = .calendar; ui.mode = .viewer }
            else if ui.mode == .browser { ui.mode = .viewer }
            else { ui.mode = ui.returnMode; ui.returnMode = .browser }
            ui.zoom = false; return true
        case 53: return ui.escape()
        case 51, 117:      // Delete in a collection takes the selected photos out of it (the photos themselves stay)
            if case .album(let id) = ui.source, lib.collection(id)?.type == "album" { lib.removeFromCollection(id, t); return true }
            // …and on a person's page, "these aren't them"
            if case .person = ui.source, [.browser, .viewer, .split].contains(ui.mode), !t.isEmpty { ui.notThisPerson(lib); return true }
            // anywhere else: delete (asks first: Move to Trash or Remove from Catalog)
            if [.browser, .viewer, .split].contains(ui.mode), !t.isEmpty { ui.deleteTargets(lib); return true }
            return false
        default: break
        }
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if e.modifierFlags.contains(.option), let n = Int(ch), (1...7).contains(n) { lib.setLabel(t, PhotoLabel.all[n - 1].id); return true }
        // Crop: O changes the guide, ⇧O turns it, H shows or hides it, X turns the crop landscape/portrait
        if ui.mode == .develop, DevelopModel.shared.cropping {
            let dm = DevelopModel.shared
            switch ch {
            case "o": if e.modifierFlags.contains(.shift) { dm.guideTurn = (dm.guideTurn + 1) % 4 } else { dm.nextGuide() }; return true
            case "h": dm.guideShow = (dm.guideShow + 1) % 3; return true
            case "x":
                let r = dm.image.map { Double($0.size.width / max(1, $0.size.height)) } ?? 1.5
                dm.flipAspect(photoRatio: r); return true
            default: break
            }
        }
        switch ch {
        case "0", "1", "2", "3", "4", "5": lib.setRating(t, Int(ch)!); return true
        case "/", "p", "t": lib.toggleFlag(t); return true                       // T = pick (flag)
        case "u":                                                                    // U = no flag, not rejected
            let f = t.filter { $0.flag }, r = t.filter { $0.rejected }
            if !f.isEmpty { lib.toggleFlag(f) }
            if !r.isEmpty { lib.toggleReject(r) }
            return true
        case "6", "7", "8", "9":                                                     // 6–9 = Red, Orange, Yellow, Green
            let l = PhotoLabel.all[Int(ch)! - 6].id
            lib.setLabel(t, t.allSatisfy { $0.label == l } ? nil : l)
            return true
        case "x": lib.toggleReject(t); return true
        case "[": lib.rotate(t, -1); return true
        case "]": lib.rotate(t, 1); return true
        case "z" where ui.mode == .compare: ui.compareZoom.toggle(); return true
        case "z" where ui.mode == .develop: DevelopModel.shared.zoomed.toggle(); return true
        case "\\" where ui.mode == .develop, "m" where ui.mode == .develop: DevelopModel.shared.showBefore.toggle(); return true
        case "r" where ui.mode == .develop: DevelopModel.shared.cropping.toggle(); return true
        case "d": if ui.mode == .develop { ui.mode = ui.developFrom } else if ui.primaryPhoto(lib) != nil { ui.mode = .develop }; return true
        case "z":
            if ui.zoom { ui.zoom = false } else { if ui.mode == .browser || ui.mode == .calendar { if ui.mode == .calendar { ui.returnMode = .calendar }; ui.mode = .viewer; ui.hoverFrac = nil }; ui.zoomAtPointer() }
            return true
        // ` : the Loupe (Aperture's key); L : lights out (Lightroom's)
        case "`" where ui.mode == .browser && ui.scale == .all: ui.loupe.toggle(); return true
        case "`": if ui.mode == .browser || ui.mode == .calendar { if ui.mode == .calendar { ui.returnMode = .calendar }; ui.mode = .viewer }; ui.loupe.toggle(); return true
        case "l":
            if ui.lightsOut { ui.lightsOut = false; ui.fullScreen = false }
            else if ui.primaryPhoto(lib) != nil {
                if ui.mode != .viewer && ui.mode != .split { ui.returnMode = ui.mode == .calendar || ui.mode == .map ? ui.mode : .browser; ui.mode = .viewer }
                ui.lightsOut = true; ui.fullScreen = true
            }
            return true
        case "n" where ui.zoom: ui.showNavigator.toggle(); return true
        case "n": if ui.mode == .survey { ui.mode = ui.returnMode } else { ui.startSurvey(lib) }; return true
        case "c": if ui.mode == .compare { ui.mode = ui.returnMode } else { ui.startCompare(lib) }; return true
        case "g": ui.zoom = false; ui.mode = .browser; ui.browse = .all; return true
        case "e": if ui.primaryPhoto(lib) != nil { if ui.mode == .calendar || ui.mode == .map { ui.returnMode = ui.mode }; ui.mode = .viewer }; return true
        case "-": ui.size -= ui.scale == .all ? 30 : 40; return true
        case "=", "+": ui.size += ui.scale == .all ? 30 : 40; return true
        case "v": ui.mode = ui.mode == .browser ? .viewer : ui.mode == .viewer ? .split : .browser; return true   // V: Browser ▸ Viewer ▸ Split
        case "i": ui.viewerInfo = (ui.viewerInfo + 1) % 3; return true             // I: Info 1 ▸ Info 2 ▸ off (⌘I: Inspector)
        case "f": if ui.primaryPhoto(lib) != nil || ui.fullScreen { ui.fullScreen.toggle(); if !ui.fullScreen { ui.slideshow = false } }; return true
        case "s":                                                                    // S: slideshow (goes full screen)
            if ui.slideshow { ui.slideshow = false } else if ui.primaryPhoto(lib) != nil { ui.fullScreen = true; ui.slideshow = true }
            return true
        case "h": ui.showInfo.toggle(); return true
        case "j" where ui.mode == .browser:                                          // J: plain → badges → detailed cells (like Lightroom)
            if ui.detailedCells { ui.detailedCells = false; ui.showInfo = false }
            else if ui.showInfo { ui.detailedCells = true }
            else { ui.showInfo = true }
            return true                                 // H: hide / show info on photos
        case "k": if !t.isEmpty { ui.showKeywords = true }; return true            // K: keywords for the selection
        case "b": lib.toggleQuick(t); return true                                  // B: in / out of the Quick Collection
        default: return false
        }
    }
}

struct StatusBar: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    private static var memo: [String: Int] = [:]
    /// "14 years · " in Years, "96 months · " in Months, and so on.
    var periodText: String {
        let s = ui.scale
        guard s != .all else { return "" }
        let key = "\(s)|\(ui.visibleKey)"
        let n: Int
        if let m = Self.memo[key] { n = m } else {
            var set = Set<Int>()
            for p in ui.visible(lib) where !p.quickNoDate {
                let d = p.ymd
                switch s {
                case .years: set.insert(d.y)
                case .months: set.insert(d.y * 100 + d.m)
                case .days: set.insert(d.y * 10000 + d.m * 100 + d.d)
                default: set.insert(CivilDate.weekStart(CivilDate.localDay(ms: p.quickDate)))
                }
            }
            n = set.count
            if Self.memo.count > 30 { Self.memo.removeAll() }
            Self.memo[key] = n
        }
        let word = s == .years ? "year" : s == .months ? "month" : s == .weeks ? "week" : "day"
        return "\(n.formatted()) \(word)\(n == 1 ? "" : "s") · "
    }
    var body: some View {
        HStack(spacing: 10) {
            if ui.mode == .people {
                let idx = FaceIndex.shared, n = idx.named.count, g = idx.groups.count
                Text("\(n.formatted()) \(n == 1 ? "person" : "people") · \(g.formatted()) group\(g == 1 ? "" : "s")")
            } else {
            let n = ui.visible(lib).count
            Text((ui.mode == .browser ? periodText : "") + "\(n.formatted()) \(n == 1 ? "photo" : "photos")\(ui.selection.count > 1 ? " · \(ui.selection.count) selected" : "")")
            }
            if !lib.status.isEmpty { Text(lib.status).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if ui.mode == .split {
                Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
                Slider(value: Binding(get: { ui.stripHeight }, set: { ui.stripHeight = $0 }), in: 50...260).frame(width: 130).controlSize(.small)
                    .help("Filmstrip size")
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
            if ui.mode == .browser {
                Image(systemName: "photo").imageScale(.small).foregroundStyle(.secondary)
                Slider(value: Binding(get: { ui.size }, set: { ui.size = $0 }), in: ui.sizeRange).frame(width: 130).controlSize(.small)
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}


/// "While you were away: 1,000 photos added · 812 faces named · 9 to review" — once, when you come back.
struct AwayBanner: View {
    @Environment(UIState.self) private var ui
    var body: some View {
        let r = AwayReport.shared, idx = FaceIndex.shared
        let toReview = idx.named.reduce(0) { $0 + (idx.suggestionCounts[$1.id] ?? 0) }
        var parts: [String] = []
        if r.added > 0 { parts.append("\(r.added.formatted()) photo\(r.added == 1 ? "" : "s") added") }
        if r.named > 0 { parts.append("\(r.named.formatted()) face\(r.named == 1 ? "" : "s") named") }
        if toReview > 0 { parts.append("\(toReview.formatted()) to review") }
        return HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill").foregroundStyle(.indigo)
            Text("While you were away: ").fontWeight(.semibold) + Text(parts.joined(separator: " · "))
            Spacer()
            if r.added > 0 {
                Button("Show New Photos") { ui.query = ""; ui.source = .recent; ui.browse = .all; r.dismiss() }
            }
            if r.named > 0 || toReview > 0 {
                Button("Open People") { ui.query = ""; ui.source = .people; r.dismiss() }
            }
            Button("OK") { r.dismiss() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.indigo.opacity(0.12))
    }
}

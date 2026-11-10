import SwiftUI

/// The browser: Lightroom's Library Filter on top, Apple Photos' Years | Months | All Photos underneath.
struct BrowserView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        if ui.source == .people { PeopleView() } else { browser }
    }
    var isPerson: Bool {
        switch ui.source { case .person, .faceGroup, .together: return true; default: return false }
    }
    var browser: some View {
        VStack(spacing: 0) {
            if isPerson { PersonHeader(); Divider() }
            if !ui.query.isEmpty && NaturalSearch.shared.active { SearchResultsBar(); Divider() }
            BrowseBar()
            Divider()
            if ui.showFilterBar { LibraryFilterBar(); Divider() }
            Group {
                switch ui.scale {
                case .years: CardsView(kind: .year)
                case .months: CardsView(kind: .month)
                case .weeks: CardsView(kind: .week)
                case .days: CardsView(kind: .day)
                case .all: PhotoGrid()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: ui.source) { _, s in if case .date = s {} else { ui.back = nil } }
        .onChange(of: ui.lf.picks) { old, new in
            guard new != old, new.contains(where: { !$0.isEmpty }) else { return }
            if ui.source == .days { ui.source = .all }
            ui.browse = .all
        }
    }
}

/// The strip under the toolbar: Years | Months | Weeks | Days | All Photos, grid style, size, and the filter switch.
struct BrowseBar: View {
    @Environment(UIState.self) private var ui
    @AppStorage("show.scale.Years") private var s1 = true
    @AppStorage("show.scale.Months") private var s2 = true
    @AppStorage("show.scale.Weeks") private var s3 = true
    @AppStorage("show.scale.Days") private var s4 = true
    var scaleKey: String { "\(s1)\(s2)\(s3)\(s4)" }
    var body: some View {
        let scale = Binding<BrowseScale>(get: { ui.scale }, set: { v in if ui.source == .days { ui.source = .all }; ui.browse = v })
        HStack(spacing: 10) {
            HStack {
                if let b = ui.back {
                    Button { ui.back = nil; ui.source = b.source; ui.browse = b.browse } label: { Label(b.label, systemImage: "chevron.left") }
                        .buttonStyle(.borderless).help("Back to \(b.label)")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Picker("", selection: scale) { ForEach(BrowseScale.allCases.filter { UIState.shown($0) || $0 == ui.scale }) { Text($0.rawValue).tag($0) } }
                .id(scaleKey)
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Years, Months, Weeks, Days or every photo")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if ui.scale == .all {
                    Picker("", selection: Binding(get: { ui.listView ? 2 : ui.detailedCells ? 3 : ui.squareGrid ? 0 : 1 },
                                                  set: { v in
                                                      ui.listView = v == 2
                                                      if v == 3 { ui.detailedCells = true; ui.showInfo = true }
                                                      else if v < 2 { ui.detailedCells = false; ui.squareGrid = v == 0 }
                                                  })) {
                        Image(systemName: "square.grid.3x3.fill").help("Square grid").tag(0)
                        Image(systemName: "rectangle.grid.2x2").help("Normal: whole photos").tag(1)
                        Image(systemName: "text.below.photo").help("Detailed: name, flag, stars and label on each photo (J)").tag(3)
                        Image(systemName: "list.bullet").help("List: details in columns").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 148)
                }
                Picker("", selection: Binding(get: { ui.sort }, set: { ui.sort = $0 })) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize().help("Sort order")
                if ui.scale == .all {
                    Toggle(isOn: Binding(get: { ui.loupe }, set: { ui.loupe = $0 })) {
                        Label("Loupe", systemImage: "magnifyingglass.circle")
                    }
                    .toggleStyle(.button).help("Loupe (L): the photo under the pointer at 100% · ⇧-scroll to resize · hold ⌥ for 200%")
                }
                Toggle(isOn: Binding(get: { ui.showFilterBar }, set: { ui.showFilterBar = $0 })) {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button).help("Show or hide the Library Filter (⇧⌘F)")
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
    func resize(_ dir: CGFloat) {
        ui.size = dir > 0 ? ui.size * 1.3 : ui.size / 1.3   // even steps from tiny to big
    }
}

struct DaySection: Identifiable { let id: String; let title: String; let subtitle: String; let photos: [Photo] }

/// All Photos: the fast grid (square crops or whole photos), with no date headings.
struct PhotoGrid: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui

    var body: some View {
        let list = ui.visible(lib)
        if list.isEmpty {
            empty.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ui.listView {
            PhotoListView()
        } else {
            FastGrid(photos: list, tile: ui.tile, square: ui.squareGrid, selection: ui.selection, primary: ui.primary,
                     stamp: lib.version, badges: ui.showInfo, scrollTarget: ui.scrollTarget,
                     onColumns: { c in if ui.columns != c { ui.columns = c } },
                     onScrolled: { ui.scrollTarget = nil },
                     onSelect: { p, m in ui.select(p, in: list, extend: m.contains(.shift), toggle: m.contains(.command)); ui.refocus += 1 },
                     onOpen: { p in ui.select(p, in: list, extend: false, toggle: false); ui.mode = .viewer; ui.refocus += 1 },
                     menu: { p in GridMenu.make(p, lib: lib, ui: ui) },
                     onPinch: { m, began in ui.pinchGrid(m, began: began) },
                     detailed: ui.detailedCells,
                     onRate: { p, n in lib.setRating(ui.selection.contains(p.id) ? ui.targets(lib) : [p], n) },
                     onFlag: { p in lib.toggleFlag(ui.selection.contains(p.id) ? ui.targets(lib) : [p]) },
                     onRotate: { p, d in lib.rotate(ui.selection.contains(p.id) ? ui.targets(lib) : [p], d) },
                     loupe: ui.loupe, loupeSize: ui.loupeSize, loupeMag: ui.loupeMag,
                     onLoupeResize: { dy in ui.resizeLoupe(dy) },
                     touched: { v in lib.touchedSince(v)?.ids },
                     options: ViewOptions.shared.gridStamp,
                     onMap: { p in ui.showOnMap(p) },
                     yearLabels: ui.source == .all && ui.tile <= 64 && !ui.detailedCells)
        }
    }

    var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: lib.folders.isEmpty ? "folder.badge.plus" : "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(lib.folders.isEmpty ? "Add the folders where your photos live" : "No photos here").font(.title3)
            Text(lib.folders.isEmpty ? "Loupe Photos reads them in place and never moves or copies them unless you ask." : "Try another album, or turn the Library Filter off (⌘L).").foregroundStyle(.secondary)
            if lib.folders.isEmpty { Button("Add Folder…") { ui.addFolder(lib) }.controlSize(.large).padding(.top, 6) }
        }
    }

}

struct SquareCell: View {
    let photo: Photo
    let size: CGFloat
    var fit = false
    let selected: Bool
    let primary: Bool
    @Environment(Library.self) private var lib
    @State private var img: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(white: fit ? 0.2 : 0.16))
            if let img {
                if fit {
                    Image(nsImage: img).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .padding(size * 0.07).frame(width: size, height: size)
                } else {
                    Image(nsImage: img).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size).clipped()
                }
            }
            if size >= 60 { HStack(spacing: 3) {
                if let l = PhotoLabel.find(photo.label) { Circle().fill(Color(hex: l.hex)).frame(width: 9, height: 9).overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1)) }
                if photo.flag { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                if photo.rating > 0 { Text(String(repeating: "★", count: photo.rating)).foregroundStyle(.white) }
            }
            .font(.system(size: max(9, min(12, size / 14))))
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(5) }
            if photo.missing {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: size, height: size)
        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: selected ? (size < 60 ? 2 : primary ? 4 : 3) : 0))
        .overlay(Rectangle().fill(.white.opacity(selected && !primary ? 0.12 : 0)))
        .contentShape(Rectangle())
        .task(id: "\(photo.id)-\(photo.rot)") {
            if let c = Images.shared.cachedThumb(photo.id) { img = c.rotated(photo.rot); return }
            img = await Images.shared.thumb(photo, lib: lib)?.rotated(photo.rot)
        }
    }
}

/// Years, Months and Days as big photo cards, like Apple Photos.
struct CardsView: View {
    enum Kind { case year, month, week, day }
    let kind: Kind
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui

    @State private var pinched = false
    struct Card: Identifiable { let id: String; let title: String; let subtitle: String; let cover: Photo; let first: Photo; let y: Int; let m: Int; let d: Int; let count: Int }

    var body: some View {
        let cards = summary(ui.visible(lib))
        GeometryReader { geo in
            let minW: CGFloat = kind == .day || kind == .week ? ui.dayCard : kind == .month ? ui.monthCard : ui.monthCard * 1.4
            let gap: CGFloat = minW < 120 ? 6 : minW < 200 ? 10 : 18
            let cols = max(1, Int((geo.size.width - 40) / (minW + gap)))
            let w = floor((geo.size.width - 40 - CGFloat(cols - 1) * gap) / CGFloat(cols))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: gap), count: cols), spacing: gap) {
                        ForEach(cards) { c in
                            CardCell(card: c, width: w, height: kind == .year ? w * 0.62 : w, big: kind == .year || kind == .month)
                                .id(c.id)
                                .onTapGesture { open(c) }
                        }
                    }
                    .padding(20).padding(.bottom, 60)
                }
                .onAppear { if let t = ui.scrollTarget { proxy.scrollTo("c\(t)", anchor: .top); ui.scrollTarget = nil } }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        // pinch out: one step closer (Years ▸ Months ▸ Weeks ▸ Days ▸ All Photos); pinch in: one step back
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                guard !pinched else { return }
                if v.magnification > 1.3 { pinched = true; ui.stepScale(1) }
                else if v.magnification < 0.77 { pinched = true; ui.stepScale(-1) }
            }
            .onEnded { _ in pinched = false })
    }

    func open(_ c: Card) {
        // the card you open becomes "where you are", so Photos ▸ All Photos comes back to this spot
        ui.primary = c.first.id; ui.selection = [c.first.id]
        switch kind {
        case .day:
            ui.back = BackPoint(source: ui.source, browse: ui.scale, label: ui.source == .days ? "Recent Days" : "Days")
            ui.source = .date(c.y, c.m, c.d); ui.browse = .all
        case .week: ui.browse = .days; ui.scrollTarget = c.first.id
        case .month: ui.browse = .days; ui.scrollTarget = c.first.id          // a month opens its days, like Photos
        case .year: ui.browse = .months; ui.scrollTarget = c.first.id
        }
    }
    /// Years / Months / Weeks / Days are worked out once per change and remembered, so switching is instant.
    private static var memo: [String: [Card]] = [:]
    func summary(_ list: [Photo]) -> [Card] {
        let key = "\(kind)|\(ui.visibleKey)"
        if let c = Self.memo[key] { return c }
        let c = makeCards(list)
        if Self.memo.count > 40 { Self.memo.removeAll() }
        Self.memo[key] = c
        return c
    }
    func makeCards(_ list: [Photo]) -> [Card] {
        // number keys and plain date arithmetic (Calendar and text keys for 120,000 photos took most of a second)
        var groups: [(Int, [Photo])] = [], idx: [Int: Int] = [:]
        let cal = Calendar.current
        for p in list where !p.quickNoDate {
            let k: Int
            switch kind {
            case .year: k = p.ymd.y
            case .month: let d = p.ymd; k = d.y * 100 + d.m
            case .week: k = CivilDate.weekStart(CivilDate.localDay(ms: p.quickDate))
            case .day: let d = p.ymd; k = d.y * 10000 + d.m * 100 + d.d
            }
            if let i = idx[k] { groups[i].1.append(p) } else { idx[k] = groups.count; groups.append((k, [p])) }
        }
        if kind == .day || kind == .week { groups.sort { ($0.1.first?.quickDate ?? 0) > ($1.1.first?.quickDate ?? 0) } }
        return groups.map { _, ps in
            var first = ps[0]
            let d = first.ymd
            var cover = ps.max { a, b in score(a) < score(b) } ?? ps[ps.count / 2]
            if kind == .year {
                // like Photos: each year shows this time of year, and opens at that month
                let now = cal.component(.month, from: Date())
                let months = Set(ps.map { $0.ymd.m })
                if let m = months.min(by: { (abs($0 - now), $0) < (abs($1 - now), $1) }) {
                    let inMonth = ps.filter { $0.ymd.m == m }
                    first = inMonth[0]
                    cover = inMonth.max { a, b in score(a) < score(b) } ?? inMonth[inMonth.count / 2]
                }
            }
            let title: String
            switch kind {
            case .year: title = String(d.y)
            case .month: title = first.captureDate.formatted(.dateTime.month(.wide).year())
            case .week:
                let start = cal.dateInterval(of: .weekOfYear, for: first.captureDate)?.start ?? first.captureDate
                let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
                let now = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
                let ago = cal.dateComponents([.weekOfYear], from: start, to: now).weekOfYear ?? 99
                let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
                let endText = sameMonth ? "\(cal.component(.day, from: end))" : end.formatted(.dateTime.month(.abbreviated).day())
                title = ago == 0 ? "This Week" : ago == 1 ? "Last Week" : "\(start.formatted(.dateTime.month(.abbreviated).day()))–\(endText), \(cal.component(.year, from: end))"
            case .day:
                let day = cal.startOfDay(for: first.captureDate), today = cal.startOfDay(for: Date())
                let ago = cal.dateComponents([.day], from: day, to: today).day ?? 99
                title = ago == 0 ? "Today" : ago == 1 ? "Yesterday" : ago < 7 ? first.captureDate.formatted(.dateTime.weekday(.wide)) : first.captureDate.formatted(.dateTime.month(.abbreviated).day().year())
            }
            let place = ps.lazy.map(\.placeLabel).first { !$0.isEmpty }.flatMap { $0.split(separator: ",").first.map(String.init) } ?? ""
            let sub = kind == .day || kind == .week ? "" : "\(ps.count.formatted()) photos" + (place.isEmpty ? "" : " · \(place)")
            return Card(id: "c\(ps[0].id)", title: title, subtitle: sub, cover: cover, first: first, y: d.y, m: d.m, d: d.d, count: ps.count)
        }
    }
    func score(_ p: Photo) -> Int { p.quickRating * 2 + (p.quickFlag ? 3 : 0) - (p.quickRejected ? 10 : 0) }
}

struct CardCell: View {
    let card: CardsView.Card
    let width: CGFloat, height: CGFloat
    let big: Bool
    @Environment(Library.self) private var lib
    @State private var img: NSImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(white: 0.18))
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: width, height: height).clipped() }
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom)
            let t = min(big ? 17 : 12, max(9, width / (big ? 18 : 13)))   // type follows the card size
            let pad = min(big ? 12 : 9, max(5, width / 22))
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: t, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    if !card.subtitle.isEmpty { Text(card.subtitle).font(.system(size: t * 0.72, weight: .medium)).opacity(0.85).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if !big { Text(card.count.formatted()).font(.system(size: t * 0.85, weight: .medium)).monospacedDigit().opacity(0.9) }
            }
            .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2).padding(pad)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: min(12, width / 14), style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .task(id: "\(card.cover.id)-\(card.cover.rot)") {
            if let c = Images.shared.cachedThumb(card.cover.id) { img = c.rotated(card.cover.rot); return }
            img = await Images.shared.thumb(card.cover, lib: lib)?.rotated(card.cover.rot)
        }
    }
}



/// Under the toolbar while searching: how many photos, what was understood (× to drop it), Fewer / More, and Save as Smart Collection.
struct SearchResultsBar: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let ns = NaturalSearch.shared
        let q = ns.parse(ui.query, lib: lib)
        let n = ui.visible(lib).count
        let job = Activity.shared.jobs.first { $0.id == "search" }
        HStack(spacing: 8) {
            Text("\(n.formatted()) \(n == 1 ? "photo" : "photos")").font(.callout.weight(.semibold)).monospacedDigit()
                .help(ns.debug)
            if ui.source != .all {
                Button("Search All Photos") { ui.source = .all }
                    .controlSize(.small).help("You're searching only what's selected in the sidebar")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(q.chips) { c in
                        HStack(spacing: 4) {
                            Image(systemName: c.icon).font(.caption)
                            Text(c.label).font(.callout)
                            Button { ui.query = NaturalSearch.removing(c, from: ui.query) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Take this out of the search")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                }
            }
            Spacer(minLength: 8)
            if let job { Text("\(job.title): \(job.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if !q.words.isEmpty && SearchScanner.available && SearchIndex.shared.count > 0 {
                ControlGroup {
                    Button("Fewer") { ns.looseness = max(0, ns.looseness - 1) }.disabled(ns.looseness == 0)
                        .help("Only the closest matches")
                    Button("More") { ns.looseness = min(3, ns.looseness + 1) }.disabled(ns.looseness == 3)
                        .help("Show looser matches too")
                }
                .controlSize(.small).fixedSize()
            }
            Button {
                let name = ui.query.trimmingCharacters(in: .whitespaces)
                let a = lib.newCollection(type: "smart", name: name.prefix(1).uppercased() + name.dropFirst(), parent: nil,
                                          rules: [SmartRule(f: "search", op: ns.looseness == 0 ? "finds" : "finds\(ns.looseness)", v: name)])
                ui.query = ""
                ui.source = .album(a.id)
            } label: { Label("Save as Smart Collection", systemImage: "gearshape.2") }
                .controlSize(.small).help("Keep this search in the sidebar — it updates as photos are added")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

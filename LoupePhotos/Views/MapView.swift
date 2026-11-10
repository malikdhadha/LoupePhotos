import SwiftUI
import MapKit

/// Photos that were taken at (almost) the same spot share one pin.
struct MapSpot { let key: String; let coord: CLLocationCoordinate2D; let ids: [Int]; let cover: Photo }

enum MapSpots {
    private static var memo: (String, [MapSpot], Int)?
    /// Groups the shown photos by place (about 10 m) — returns the spots and how many photos have no location.
    static func make(_ list: [Photo], key: String) -> (spots: [MapSpot], unplaced: Int) {
        if let m = memo, m.0 == key { return (m.1, m.2) }
        var groups: [String: (CLLocationCoordinate2D, [Photo])] = [:]
        var none = 0
        for p in list {
            guard let c = Library.gps(p) else { none += 1; continue }
            let k = String(format: "%.4f,%.4f", c.latitude, c.longitude)
            if groups[k] == nil { groups[k] = (c, []) }
            groups[k]!.1.append(p)
        }
        let spots = groups.map { k, v in MapSpot(key: k, coord: v.0, ids: v.1.map(\.id), cover: CalData.cover(v.1) ?? v.1[0]) }
        memo = (key, spots, none)
        return (spots, none)
    }
}

/// Map (⌘5): every shown photo with a location, on Apple Maps — street map, satellite or hybrid, with 3D terrain.
/// Click a pin or cluster to see its photos below; drag photos from "No Location" onto the map to place them.
struct PhotoMapView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var fit = 0
    @State private var search = PlaceSearch()
    @State private var goTo: (MKCoordinateRegion, CLLocationCoordinate2D, String, Int)?
    @State private var showSuggestions = false
    @State private var track = Tracklogs.shared

    var body: some View {
        @Bindable var ui = ui
        let list = ui.visible(lib)
        let spotsKey = "\(ui.visibleKey)|\(lib.placeVersion)"      // locations changing don't re-list the library any more
        let m = MapSpots.make(list, key: spotsKey)
        let placed = list.count - m.unplaced
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(placed.formatted()) photo\(placed == 1 ? "" : "s") on the map").fontWeight(.medium)
                if m.unplaced > 0 { Text("· \(m.unplaced.formatted()) without a location").foregroundStyle(.secondary) }
                Spacer()
                SearchBox(text: $search.query, prompt: "Search places",
                          onChange: { showSuggestions = true }, onSubmit: { pick(search.results.first) }, onCancel: { search.query = ""; showSuggestions = false })
                    .frame(width: 240)
                trackMenu
                Picker("", selection: $ui.mapStyle) { ForEach(["Map", "Satellite", "Hybrid"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Show All") { fit += 1 }.help("Zoom to fit every photo")
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.bar)
            if showSuggestions && !search.query.isEmpty && !search.results.isEmpty { suggestions }
            Divider()
            MapRepresentable(spots: m.spots, spotsKey: spotsKey, style: ui.mapStyle, fit: fit, goTo: goTo, lib: lib,
                             track: track.coordinates, trackKey: track.version,
                             onOpen: { id in ui.primary = id; ui.selection = [id]; ui.returnMode = .map; ui.mode = .viewer },
                             onPick: { ids in ui.mapPicks = ids; ui.mapUnplaced = false; if let f = ids.first { ui.primary = f; ui.selection = Set(ids) } },
                             onDrop: { urls, c in
                                 let ps = urls.compactMap { lib.pathIndex[$0.path] }.compactMap { lib.byId[$0] }
                                 guard !ps.isEmpty else { return false }
                                 lib.setLocation(ps, c)
                                 lib.status = "Placed \(ps.count) photo\(ps.count == 1 ? "" : "s") on the map."
                                 return true
                             })
            Divider()
            strip(list)
        }
        .onAppear {
            if ui.mapFocus == nil, let p = ui.primaryPhoto(lib), let g = Library.gps(p) {
                ui.mapFocus = MapFocus(lat: g.latitude, lng: g.longitude, token: (ui.mapFocus?.token ?? 0) + 1)
            }
            focusIfAsked()
        }
        .onChange(of: ui.mapFocus) { _, _ in focusIfAsked() }
    }
    /// Right-click ▸ Show on Map: fly to that photo's spot.
    func focusIfAsked() {
        guard let f = ui.mapFocus else { return }
        let c = CLLocationCoordinate2D(latitude: f.lat, longitude: f.lng)
        goTo = (MKCoordinateRegion(center: c, latitudinalMeters: 350, longitudinalMeters: 350), c, "", (goTo?.3 ?? 0) + 1)
        ui.mapFocus = nil
    }

    /// Apple Maps suggestions under the search box (part of the layout, so clicks reach them).
    var suggestions: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(search.results.enumerated()), id: \.offset) { _, r in
                    Button { pick(r) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).lineLimit(1)
                                if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .frame(width: 340)
        }
        .padding(.horizontal, 14)
        .background(.bar)
    }
    /// Tracklog ▸ load a GPX file, see it on the map, and tag photos from it.
    var trackMenu: some View {
        Menu {
            Button("Load Tracklog…") { track.choose(); if !track.points.isEmpty { fitTrack() } }
            Menu("Recent Tracklogs") {
                ForEach(track.recent, id: \.self) { p in Button((p as NSString).lastPathComponent) { if track.load(URL(fileURLWithPath: p)) { fitTrack() } } }
            }.disabled(track.recent.isEmpty)
            Divider()
            Button("Set Time Offset… (\(track.offsetHours == 0 ? "none" : String(format: "%+g h", track.offsetHours)))") { track.askOffset() }
            Button("Auto-Tag \(ui.selection.count > 1 ? "Selected" : "Shown") Photos") {
                track.tag(ui.selection.count > 1 ? ui.targets(lib) : ui.visible(lib), lib: lib)
            }.disabled(track.points.isEmpty)
            Button("Select Photos on Tracklog") {
                guard let r = track.timeRange else { return }
                let off = track.offsetHours * 3600
                let ids = ui.visible(lib).filter { !$0.dateFromFile && r.contains($0.captureDate.timeIntervalSince1970 + off) }.map(\.id)
                ui.selection = Set(ids); ui.mapPicks = ids; ui.mapUnplaced = false
                lib.status = "\(ids.count.formatted()) photo\(ids.count == 1 ? "" : "s") taken during “\(track.name)”."
            }.disabled(track.points.isEmpty)
            Divider()
            Button("Close Tracklog") { track.close() }.disabled(track.points.isEmpty)
        } label: {
            Label(track.points.isEmpty ? "Tracklog" : track.name, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }
        .fixedSize()
        .help("GPX tracklogs: tag photos with locations from a GPS track")
    }
    func fitTrack() {
        let cs = track.coordinates
        guard !cs.isEmpty else { return }
        let lats = cs.map(\.latitude), lngs = cs.map(\.longitude)
        let c = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.3), longitudeDelta: max(0.005, (lngs.max()! - lngs.min()!) * 1.3))
        goTo = (MKCoordinateRegion(center: c, span: span), c, "", (goTo?.3 ?? 0) + 1)
    }

    func pick(_ r: MKLocalSearchCompletion?) {
        showSuggestions = false
        search.find(r) { region, coord, name in
            goTo = (region, coord, name, (goTo?.3 ?? 0) + 1)
        }
    }

    func strip(_ list: [Photo]) -> some View {
        @Bindable var ui = ui
        let photos: [Photo] = ui.mapUnplaced ? list.filter { Library.gps($0) == nil } : ui.mapPicks.compactMap { lib.byId[$0] }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $ui.mapUnplaced) { Text("Here").tag(false); Text("No Location").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Text(ui.mapUnplaced ? "Drag photos onto the map to place them." : photos.isEmpty ? "Click a pin or cluster to see its photos." : "\(photos.count) photo\(photos.count == 1 ? "" : "s") · double-click to open")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(photos.prefix(2000)) { p in
                        CalThumb(photo: p, mini: true)
                            .frame(width: 108, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: ui.selection.contains(p.id) ? 2 : 0))
                            .onTapGesture(count: 2) { ui.select(p, in: photos, extend: false, toggle: false); ui.returnMode = .map; ui.mode = .viewer }
                            .simultaneousGesture(TapGesture().onEnded {
                                let mods = NSEvent.modifierFlags
                                ui.select(p, in: photos, extend: mods.contains(.shift), toggle: mods.contains(.command))
                                // reveal where this photo was taken
                                if let g = Library.gps(p), mods.intersection([.shift, .command]).isEmpty {
                                    ui.mapFocus = MapFocus(lat: g.latitude, lng: g.longitude, token: (ui.mapFocus?.token ?? 0) + 1)
                                }
                            })
                            .draggable(p.url) { CalThumb(photo: p, mini: true).frame(width: 60, height: 44) }
                            .contextMenu {
                                if Library.gps(p) != nil { Button("Remove Location") { lib.clearLocation(ui.selection.contains(p.id) ? ui.targets(lib) : [p]) } }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                            }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 82)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - the map itself (MapKit)

final class SpotAnnotation: NSObject, MKAnnotation {
    let spot: MapSpot
    init(_ s: MapSpot) { spot = s }
    var coordinate: CLLocationCoordinate2D { spot.coord }
}

struct MapRepresentable: NSViewRepresentable {
    let spots: [MapSpot]
    let spotsKey: String
    let style: String
    let fit: Int
    let goTo: (MKCoordinateRegion, CLLocationCoordinate2D, String, Int)?
    let lib: Library
    var track: [CLLocationCoordinate2D] = []
    var trackKey = 0
    var onOpen: (Int) -> Void = { _ in }
    let onPick: ([Int]) -> Void
    let onDrop: ([URL], CLLocationCoordinate2D) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> DropMapView {
        let m = DropMapView()
        m.delegate = context.coordinator
        m.showsZoomControls = true
        m.showsCompass = true
        m.showsScale = true
        m.isPitchEnabled = true
        m.isRotateEnabled = true
        m.register(ThumbAnnotationView.self, forAnnotationViewWithReuseIdentifier: "spot")
        m.register(ThumbAnnotationView.self, forAnnotationViewWithReuseIdentifier: "cluster")
        return m
    }
    func updateNSView(_ m: DropMapView, context: Context) {
        let c = context.coordinator
        c.onPick = onPick; c.onOpen = onOpen; c.lib = lib
        if c.trackKey != trackKey {
            c.trackKey = trackKey
            m.removeOverlays(m.overlays)
            if track.count > 1 { m.addOverlay(MKPolyline(coordinates: track, count: track.count)) }
        }
        m.onDrop = onDrop
        if c.style != style {
            c.style = style
            switch style {
            case "Map": m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            case "Satellite": m.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            default: m.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            }
        }
        if c.key != spotsKey {
            let first = c.key == nil
            c.key = spotsKey
            m.removeAnnotations(m.annotations.filter { $0 is SpotAnnotation || $0 is MKClusterAnnotation })
            let anns = spots.map(SpotAnnotation.init)
            m.addAnnotations(anns)
            if first, !anns.isEmpty, goTo == nil { DispatchQueue.main.async { m.showAnnotations(anns, animated: false) } }   // after the map has its size
        }
        if let g = goTo, g.3 != c.goToken {
            c.goToken = g.3
            if let old = c.searchPin { m.removeAnnotation(old) }
            // a searched place gets a red pin; a photo's spot gets Lightroom's orange marker on the exact place
            let pin: MKPointAnnotation = g.2.isEmpty ? SpotMarker() : MKPointAnnotation()
            pin.coordinate = g.1; pin.title = g.2.isEmpty ? nil : g.2
            c.searchPin = pin
            m.addAnnotation(pin)
            // on a brand-new map, wait until it has its size, or the zoom is lost
            // queued, so it lands after the first "show everything" fit (and after the map has its size)
            let fresh = m.bounds.width < 10 || c.goToken == 1
            DispatchQueue.main.async {
                m.setRegion(g.0, animated: true)
                // a brand-new map sometimes doesn't draw its pins after jumping straight in: put them back once it settles
                if fresh {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let pins = m.annotations.filter { !($0 is MKClusterAnnotation) }
                        m.removeAnnotations(pins); m.addAnnotations(pins)
                    }
                }
            }
        }
        if c.fit != fit {
            c.fit = fit
            let anns = m.annotations.compactMap { $0 as? SpotAnnotation }
            if !anns.isEmpty { m.showAnnotations(anns, animated: true) }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var key: String?
        var style = ""
        var fit = 0
        var goToken = 0
        var searchPin: MKPointAnnotation?
        var onPick: (([Int]) -> Void)?
        var onOpen: ((Int) -> Void)?
        weak var lib: Library?
        var trackKey = -1
        private var popover: NSPopover?

        func mapView(_ m: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let l = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: l)
            r.strokeColor = .systemOrange; r.lineWidth = 3.5; r.lineJoin = .round
            return r
        }
        /// Several photos at one spot (or one photo): a popover to step through them, like Lightroom's.
        private func showPopover(_ ids: [Int], on view: NSView) {
            guard let lib else { return }
            let ps = ids.compactMap { lib.byId[$0] }.sorted { $0.date < $1.date }
            guard !ps.isEmpty else { return }
            popover?.close()
            let p = NSPopover()
            p.behavior = .transient
            p.contentViewController = NSHostingController(rootView: SpotPopover(photos: ps, onOpen: { [weak self] id in p.close(); self?.onOpen?(id) }).environment(lib))
            p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            popover = p
        }

        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            if a is SpotMarker {
                let v = MKAnnotationView(annotation: a, reuseIdentifier: "marker")
                v.wantsLayer = true
                v.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
                v.layer?.backgroundColor = NSColor.systemOrange.cgColor
                v.layer?.borderColor = NSColor.white.cgColor; v.layer?.borderWidth = 2; v.layer?.cornerRadius = 3
                v.layer?.shadowOpacity = 0.6; v.layer?.shadowRadius = 3; v.layer?.shadowOffset = .zero
                v.displayPriority = .required; v.zPriority = .max
                v.centerOffset = .zero
                return v
            }
            if let cl = a as? MKClusterAnnotation {
                let v = m.dequeueReusableAnnotationView(withIdentifier: "cluster", for: a) as! ThumbAnnotationView
                let spots = cl.memberAnnotations.compactMap { ($0 as? SpotAnnotation)?.spot }
                let best = spots.max { a, b in (a.cover.rating, a.ids.count) < (b.cover.rating, b.ids.count) }
                v.show(best?.cover, count: spots.reduce(0) { $0 + $1.ids.count })
                return v
            }
            guard let s = a as? SpotAnnotation else { return nil }
            let v = m.dequeueReusableAnnotationView(withIdentifier: "spot", for: a) as! ThumbAnnotationView
            v.clusteringIdentifier = "photos"
            v.show(s.spot.cover, count: s.spot.ids.count)
            return v
        }
        func mapView(_ m: MKMapView, didSelect view: MKAnnotationView) {
            guard let a = view.annotation else { return }
            if let cl = a as? MKClusterAnnotation {
                let spots = cl.memberAnnotations.compactMap { ($0 as? SpotAnnotation)?.spot }
                let ids = spots.flatMap(\.ids)
                onPick?(ids)
                // all in one place (can't be pulled apart by zooming): step through them instead
                let lats = spots.map(\.coord.latitude), lngs = spots.map(\.coord.longitude)
                if (lats.max()! - lats.min()!) < 0.0004 && (lngs.max()! - lngs.min()!) < 0.0004 { showPopover(ids, on: view) }
                else { m.showAnnotations(cl.memberAnnotations, animated: true) }
            } else if let s = a as? SpotAnnotation {
                onPick?(s.spot.ids)
                showPopover(s.spot.ids, on: view)
            }
            m.deselectAnnotation(a, animated: false)
        }
    }
}

/// A map that accepts photos dragged onto it.
final class DropMapView: MKMapView {
    var onDrop: (([URL], CLLocationCoordinate2D) -> Bool)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let c = convert(convert(sender.draggingLocation, from: nil), toCoordinateFrom: self)
        return onDrop?(urls, c) ?? false
    }
}

/// A pin drawn as a small rounded photo with a count, like the Photos app.
final class ThumbAnnotationView: MKAnnotationView {
    private let picture = CALayer()
    private let badge = CATextLayer()
    private var loading: Task<Void, Never>?
    private let side: CGFloat = 50

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        centerOffset = CGPoint(x: 0, y: -side / 2)
        wantsLayer = true
        collisionMode = .rectangle
        picture.frame = bounds.insetBy(dx: 2, dy: 2)
        picture.cornerRadius = 8
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        picture.borderColor = NSColor.white.cgColor
        picture.borderWidth = 2.5
        layer?.addSublayer(picture)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        badge.fontSize = 10
        badge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.systemBlue.cgColor
        badge.cornerRadius = 8
        badge.contentsScale = 2
        layer?.addSublayer(badge)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ p: Photo?, count: Int) {
        displayPriority = count > 1 ? .defaultHigh : .defaultLow
        let text = count > 999 ? "\(count / 1000)k" : "\(count)"
        badge.string = text
        badge.isHidden = count < 2
        let w = max(16, CGFloat(text.count) * 6.5 + 8)
        badge.frame = CGRect(x: side - w + 4, y: side - 12, width: w, height: 16)
        picture.contents = nil
        loading?.cancel()
        guard let p else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        picture.contentsScale = scale
        loading = Task { @MainActor [weak self] in
            let img = await Images.shared.cg(p, .mini)
            guard !Task.isCancelled else { return }
            self?.picture.contents = img
        }
    }
    override func prepareForReuse() { super.prepareForReuse(); loading?.cancel(); picture.contents = nil }
}

/// Apple Maps place search: suggestions while typing, then the chosen place's area.
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" { didSet { if query.isEmpty { results = [] } else { completer.queryFragment = query } } }
    var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }
    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) { results = Array(c.results.prefix(8)) }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }

    /// Looks the place up and hands back a region to show, its point, and its name.
    func find(_ r: MKLocalSearchCompletion?, done: @escaping (MKCoordinateRegion, CLLocationCoordinate2D, String) -> Void) {
        let req: MKLocalSearch.Request
        if let r { req = MKLocalSearch.Request(completion: r) } else {
            guard !query.isEmpty else { return }
            req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        }
        MKLocalSearch(request: req).start { resp, _ in
            guard let resp, let item = resp.mapItems.first else { return }
            let c = item.placemark.coordinate
            // frame the place at its own size: a resort or reef close up, a city, atoll or country whole
            var meters = item.pointOfInterestCategory != nil ? 1200.0 : 4000.0
            if let circle = item.placemark.region as? CLCircularRegion { meters = max(800, min(3_000_000, circle.radius * 2.6)) }
            let region = MKCoordinateRegion(center: c, latitudinalMeters: meters, longitudinalMeters: meters)
            DispatchQueue.main.async { done(region, c, item.name ?? r?.title ?? "") }
        }
    }
}

/// A real macOS search field (typing goes straight to it, whatever else has the keyboard).
struct SearchBox: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var onChange: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        f.controlSize = .small
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return f
    }
    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchBox
        init(_ p: SearchBox) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSSearchField else { return }
            parent.text = f.stringValue
            parent.onChange()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); (control as? NSSearchField)?.stringValue = ""; return true }
            return false
        }
    }
}


/// The popover on a map pin: "1 of 24", the date and exposure, and the photo; ‹ › step, double-click opens it.
struct SpotPopover: View {
    let photos: [Photo]
    let onOpen: (Int) -> Void
    @State private var i = 0
    var body: some View {
        let p = photos[min(i, photos.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.dateFromFile ? p.displayName : p.captureDate.formatted(date: .numeric, time: .standard)).font(.callout.weight(.medium))
                    Text(InfoField.exposure.text(p)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(i + 1) of \(photos.count)").font(.callout.weight(.medium)).monospacedDigit()
                    Text(InfoField.focal.text(p)).font(.caption).foregroundStyle(.secondary)
                }
            }
            ZStack {
                CalThumb(photo: p, mini: false).aspectRatio(p.aspect, contentMode: .fit).id(p.id)
                HStack {
                    if photos.count > 1 {
                        arrow("chevron.left") { i = (i - 1 + photos.count) % photos.count }
                        Spacer()
                        arrow("chevron.right") { i = (i + 1) % photos.count }
                    }
                }.padding(4)
            }
            .frame(width: 300, height: 210)
            .onTapGesture(count: 2) { onOpen(p.id) }
        }
        .padding(10)
        .frame(width: 320)
    }
    func arrow(_ s: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: s).font(.body.weight(.semibold)).padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white) }
            .buttonStyle(.plain)
    }
}

/// The orange marker on a photo's exact spot (Show on Map, the grid's map pin, a photo clicked in the strip).
final class SpotMarker: MKPointAnnotation {}

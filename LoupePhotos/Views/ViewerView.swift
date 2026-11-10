import SwiftUI
import MapKit

struct ViewerView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var img: NSImage?
    @State private var full: NSImage?
    @State private var shownId: Int?
    @State private var zoomCtl = ZoomController()
    @State private var hover: CGPoint?
    @AppStorage("vo.bg") private var bgName = "Black"
    static var lastIndex = 0

    /// The photo, and (swipe up, like Apple Photos) a details panel under it: map, people, date, camera.
    var body: some View {
        VStack(spacing: 0) {
            photoBody
            if ui.viewerDetails, !ui.zoom, let p = ui.primaryPhoto(lib) {
                PhotoDetailsPanel(photo: p, close: { withAnimation(.easeOut(duration: 0.25)) { ui.viewerDetails = false } })
                    .frame(height: 250)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: ui.zoom) { _, z in if z { ui.viewerDetails = false } }
    }

    /// Two-finger swipe (one finger on a Magic Mouse) up and down: up shows the details, down hides them,
    /// and down again goes back to the grid.
    private func vertical(_ d: Int) {
        if d < 0 {
            if !ui.viewerDetails { withAnimation(.easeOut(duration: 0.25)) { ui.viewerDetails = true } }
        } else if ui.viewerDetails {
            withAnimation(.easeOut(duration: 0.25)) { ui.viewerDetails = false }
        } else if ui.mode == .viewer && !ui.fullScreen {
            ui.mode = .browser
        } else if ui.mode == .split {
            ui.mode = .viewer                      // a step at a time: Split View → Viewer → grid
        }
    }

    var photoBody: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: ui.lightsOut ? 0 : ViewOptions.white(bgName))
                if let p = ui.primaryPhoto(lib), let img {
                    let rect = fitRect(img.size, in: geo.size)
                    if ui.zoom {
                        ZoomScrollView(image: full ?? img, pixelSize: pixelSize(p, img), focus: ui.zoomFocus, anchor: ui.zoomAnchor,
                                       startMagnification: ui.zoomStart, controller: zoomCtl, onClick: { ui.zoom = false })
                            .id("\(p.id)-\(p.rot)")
                        VStack { HStack { Spacer(); if ui.showNavigator { NavigatorPanel(thumb: img, zoom: zoomCtl, exit: { ui.zoom = false }) } }; Spacer() }.padding(14)
                        if full == nil { ProgressView().controlSize(.small).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    } else {
                        Image(nsImage: img).resizable().interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .id(p.id).transition(.opacity)
                            .shadow(color: .black.opacity(0.6), radius: 16, y: 4)
                            .position(x: rect.midX, y: rect.midY)
                        // the Loupe: full-size detail under the pointer, like Aperture's
                        if ui.loupe, let h = hover, rect.contains(h) {
                            LoupeView(image: full ?? img, pixelSize: pixelSize(p, img), frac: CGPoint(x: (h.x - rect.minX) / rect.width, y: (h.y - rect.minY) / rect.height),
                                      diameter: ui.loupeSize, mag: ui.loupeMag)
                                .position(h)
                                .allowsHitTesting(false)
                        }
                    }
                    if !ui.zoom && !ui.lightsOut && ui.viewerInfo > 0 {
                        InfoOverlay(photo: p, fields: ui.viewerInfo == 1 ? ViewOptions.shared.info1 : ViewOptions.shared.info2,
                                    light: !ui.lightsOut && ViewOptions.white(bgName) > 0.6)
                            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
                    }
                } else if ui.primaryPhoto(lib) == nil {
                    Text("No photo selected").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            // clicks, hover, Magic Mouse / trackpad swipes and pinch, handled by AppKit so every pointing device works
            .overlay {
                if !ui.zoom, ui.primaryPhoto(lib) != nil {
                    ViewerInput(
                        onHover: { pt in
                            hover = pt
                            guard let pt else { ui.hoverFrac = nil; return }
                            ui.hoverFrac = img.map { i in let r = fitRect(i.size, in: geo.size); return CGPoint(x: (pt.x - r.minX) / r.width, y: (pt.y - r.minY) / r.height) }
                            ui.hoverAnchor = CGPoint(x: pt.x / geo.size.width, y: pt.y / geo.size.height)
                        },
                        onZoom: { pt in zoom(at: pt, in: geo.size) },
                        onSwipe: { d in ui.step(d, lib) },
                        onResize: { dy in guard ui.loupe else { return false }; ui.resizeLoupe(dy); return true },
                        onVertical: { d in vertical(d) },
                        onFlipping: { on in if ui.fastStepping != on { ui.fastStepping = on } })
                }
            }
            // face boxes sit above the click / swipe layer so their name labels can be clicked
            .overlay {
                if ui.showFaces, !ui.zoom, let p = ui.primaryPhoto(lib), let img { FaceBoxes(photo: p, rect: fitRect(img.size, in: geo.size)) }
            }
            // ‹ › at the sides when the pointer is near them
            .overlay {
                if !ui.zoom, !ui.lightsOut, ui.primaryPhoto(lib) != nil { EdgeArrows(hover: hover, size: geo.size) { ui.step($0, lib) } }
            }
            .task(id: "\(ui.primary ?? -1)-\(ui.primaryPhoto(lib)?.rot ?? 0)-\(Int(geo.size.width))-\(ui.fastStepping)-\(DevelopStore.shared.stamps[ui.primary ?? -1] ?? 0)") {
                guard let p = ui.primaryPhoto(lib) else { img = nil; return }
                if shownId != p.id {
                    full = nil
                    // show the stored thumbnail at once, so holding an arrow key flicks through photos quickly
                    if let t = Images.shared.cachedThumb(p.id) { img = t.rotated(p.rot) }
                    else if let cg = PreviewStore.shared.image(p.id, .thumb) { img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).rotated(p.rot) }
                }
                let movedBy = Self.lastIndex
                shownId = p.id
                if ui.fastStepping { return }                    // holding an arrow: the quick preview is enough until you let go
                let px = min(3200, Int(max(geo.size.width, geo.size.height) * (NSScreen.main?.backingScaleFactor ?? 2)))
                // start loading the photos you're likely to go to next (in the direction you're moving), without waiting
                let l = ui.visible(lib)
                if let i = l.firstIndex(where: { $0.id == p.id }) {
                    let dir = i >= movedBy ? 1 : -1
                    Self.lastIndex = i
                    let next = [i + dir, i + 2 * dir, i + 3 * dir, i - dir].filter { l.indices.contains($0) }.map { l[$0] }
                    if let i = Images.shared.cachedFull(p.id, minPixel: px) { img = i.rotated(p.rot) }
                    else if let i = await Images.shared.full(p, lib: lib, maxPixel: px), ui.primary == p.id { img = i.rotated(p.rot) }
                    Images.shared.prefetch(next, lib: lib, maxPixel: px)
                } else if let i = await Images.shared.full(p, lib: lib, maxPixel: px), ui.primary == p.id { img = i.rotated(p.rot) }
            }
            .task(id: "\(ui.zoom || ui.loupe)-\(ui.primary ?? -1)-\(ui.primaryPhoto(lib)?.rot ?? 0)") {
                guard ui.zoom || ui.loupe, let p = ui.primaryPhoto(lib) else { return }
                if full != nil && shownId == p.id { return }
                let f = await Images.shared.full1to1(p)
                if ui.primary == p.id { full = f?.rotated(p.rot) }
            }
        }
    }

    /// Click (or pinch) on the photo: zoom to 100% with that spot staying under the pointer.
    func zoom(at pt: CGPoint, in size: CGSize) {
        guard !ui.zoom, let img else { return }
        let r = fitRect(img.size, in: size)
        guard r.contains(pt) else { return }
        ui.zoomFocus = CGPoint(x: (pt.x - r.minX) / r.width, y: (pt.y - r.minY) / r.height)
        ui.zoomAnchor = CGPoint(x: pt.x / size.width, y: pt.y / size.height)
        ui.zoomStart = 1; ui.zoom = true; ui.refocus += 1
    }

    func fitRect(_ s: CGSize, in box: CGSize) -> CGRect {
        let pad: CGFloat = 18, w = max(1, box.width - pad * 2), h = max(1, box.height - pad * 2)
        let k = min(w / max(1, s.width), h / max(1, s.height))
        let fw = s.width * k, fh = s.height * k
        return CGRect(x: (box.width - fw) / 2, y: (box.height - fh) / 2, width: fw, height: fh)
    }
    func pixelSize(_ p: Photo, _ img: NSImage) -> CGSize {
        if p.w > 0, p.h > 0 { return p.rot % 2 == 1 ? CGSize(width: p.h, height: p.w) : CGSize(width: p.w, height: p.h) }
        return img.size
    }
}

/// A round magnifier showing the photo at full size under the pointer.
struct LoupeView: View {
    let image: NSImage
    let pixelSize: CGSize
    let frac: CGPoint
    var diameter: CGFloat = 240
    var mag: CGFloat = 1
    var body: some View {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let w = pixelSize.width / scale * mag, h = pixelSize.height / scale * mag
        Image(nsImage: image).resizable().interpolation(.high)
            .frame(width: w, height: h)
            .offset(x: -frac.x * w + diameter / 2, y: -frac.y * h + diameter / 2)
            .frame(width: diameter, height: diameter, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))
            .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1).padding(-2))
            .shadow(color: .black.opacity(0.6), radius: 12)
    }
}

struct HUD: View {
    let photo: Photo
    var body: some View {
        HStack(spacing: 10) {
            if let l = PhotoLabel.find(photo.label) { Circle().fill(Color(hex: l.hex)).frame(width: 9, height: 9) }
            Text(photo.displayName).fontWeight(.medium)
            if photo.flag { Image(systemName: "flag.fill").foregroundStyle(.orange) }
            if photo.rating > 0 { Text(String(repeating: "★", count: photo.rating)).foregroundStyle(.yellow) }
            Text(photo.captureDate.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            if !photo.placeLabel.isEmpty { Text(photo.placeLabel.split(separator: ",").first.map(String.init) ?? "").foregroundStyle(.secondary) }
            if photo.rejected { Text("Rejected").foregroundStyle(.red) }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// I: Lightroom-style info over the photo — Info 1, then Info 2, then off (fields chosen in View Options, ⌘J).
struct InfoOverlay: View {
    let photo: Photo
    let fields: [InfoField]
    var light = false
    var body: some View {
        let lines = fields.map { $0.text(photo) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, t in
                Text(t).font(i == 0 ? .title3.weight(.medium) : .callout).lineLimit(1)
            }
        }
        .foregroundStyle(light ? Color.black.opacity(0.8) : Color.white.opacity(0.92))
        .shadow(color: light ? .white.opacity(0.6) : .black.opacity(0.85), radius: 2, y: 1)
    }
}

struct FilmstripView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let list = ui.visible(lib)
        GeometryReader { geo in
            let h = max(60, geo.size.height - 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(list) { p in
                            StripThumb(photo: p, height: h, selected: ui.selection.contains(p.id))
                                .id(p.id)
                                .onTapGesture {
                                    let m = NSEvent.modifierFlags
                                    ui.select(p, in: list, extend: m.contains(.shift), toggle: m.contains(.command))
                                }
                                .contextMenu { PhotoMenu(photo: p) }
                        }
                    }
                    .padding(10)
                }
                .onAppear { if let p = ui.primary { proxy.scrollTo(p, anchor: .center) } }
                .onChange(of: ui.primary) { _, p in if let p { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(p, anchor: .center) } } }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StripThumb: View {
    let photo: Photo
    let height: CGFloat
    let selected: Bool
    @Environment(Library.self) private var lib
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
            else { Rectangle().fill(.quaternary).aspectRatio(photo.aspect, contentMode: .fit) }
        }
        .frame(height: height)
        .overlay(Rectangle().stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
        .overlay(alignment: .bottomTrailing) {
            if DevelopStore.shared.stamps[photo.id] != nil || DevelopStore.shared.isEdited(photo.id) {
                if DevelopStore.shared.isEdited(photo.id) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3)).padding(4)
                }
            }
        }
        .task(id: "\(photo.id)-\(photo.rot)-\(DevelopStore.shared.stamps[photo.id] ?? 0)") {
            if let c = Images.shared.cachedThumb(photo.id) { img = c.rotated(photo.rot); return }
            img = await Images.shared.thumb(photo, lib: lib)?.rotated(photo.rot)
        }
    }
}


/// Pointer input for the Viewer: a click zooms, swiping left/right (Magic Mouse, trackpad two- or three-finger)
/// moves to the next or previous photo, pinching out zooms in, and hover feeds the Loupe.
struct ViewerInput: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void
    var onZoom: (CGPoint) -> Void
    var onSwipe: (Int) -> Void
    var onResize: (CGFloat) -> Bool = { _ in false }
    var onVertical: (Int) -> Void = { _ in }
    var onFlipping: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> ViewerInputView { ViewerInputView() }
    func updateNSView(_ v: ViewerInputView, context: Context) {
        v.onHover = onHover; v.onZoom = onZoom; v.onSwipe = onSwipe; v.onResize = onResize; v.onVertical = onVertical; v.onFlipping = onFlipping
    }
}

final class ViewerInputView: NSView {
    var onHover: ((CGPoint?) -> Void)?
    var onZoom: ((CGPoint) -> Void)?
    var onSwipe: ((Int) -> Void)?
    var onResize: ((CGFloat) -> Bool)?
    var onVertical: ((Int) -> Void)?
    var onFlipping: ((Bool) -> Void)?
    private var downAt: CGPoint?
    private var scrollSum: CGFloat = 0
    private var scrollFired = false
    private var steps = 0                       // photos moved during this swipe
    private var axis = 0                        // 1 sideways, 2 up/down, 0 not decided yet
    private var vSum: CGFloat = 0
    private var pinchSum: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    /// Right-click on the canvas: Background Color, like Lightroom Classic.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let head = NSMenuItem(title: "Background Color", action: nil, keyEquivalent: ""); head.isEnabled = false
        m.addItem(head)
        for (name, _) in ViewOptions.backgrounds {
            let it = ActionItem(name) { ViewOptions.shared.background = name }
            it.state = ViewOptions.shared.background == name ? .on : .off
            m.addItem(it)
        }
        return m
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) { onHover?(point(e)) }
    override func mouseDragged(with e: NSEvent) { onHover?(point(e)) }
    override func mouseExited(with e: NSEvent) { onHover?(nil) }
    override func mouseDown(with e: NSEvent) { downAt = point(e) }
    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if let a = downAt, hypot(p.x - a.x, p.y - a.y) < 5, e.clickCount == 1 { onZoom?(p) }
        downAt = nil
    }

    /// Magic Mouse and trackpad swipes arrive as scrolling.
    /// Sideways: a short swipe moves one photo; keep the fingers moving and it keeps going, a photo for every
    /// bit of travel, like Lightroom's Loupe view. Up and down (Apple Photos): details and back to the grid.
    override func scrollWheel(with e: NSEvent) {
        if e.momentumPhase != [] { return }                      // ignore the coasting after the fingers lift
        // up/down scrolling resizes the Loupe while it's on
        if abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX), let f = onResize,
           f(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12) { return }
        guard e.hasPreciseScrollingDeltas else {
            if e.scrollingDeltaX != 0 { onSwipe?(e.scrollingDeltaX > 0 ? -1 : 1) }   // a mouse with a sideways wheel
            return
        }
        if e.phase == .began || e.phase == .mayBegin { scrollSum = 0; vSum = 0; scrollFired = false; steps = 0; axis = 0 }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if axis == 0, abs(dx) + abs(dy) > 2 { axis = abs(dx) >= abs(dy) ? 1 : 2 }
        if axis == 1 {
            scrollSum += dx
            // the first photo after a short swipe, then one more for every 90 points of travel
            let need: CGFloat = steps == 0 ? 40 : 90
            while abs(scrollSum) > need && steps < 200 {
                let d = scrollSum > 0 ? -1 : 1
                onSwipe?(d)
                steps += 1
                scrollSum -= scrollSum > 0 ? need : -need
                if steps == 2 { onFlipping?(true) }                 // flicking through: quick previews until you stop
                if steps > 1 { break }
            }
        } else if axis == 2 {
            vSum += dy
            if !scrollFired, abs(vSum) > 50 { scrollFired = true; onVertical?(vSum > 0 ? 1 : -1) }
        }
        if e.phase == .ended || e.phase == .cancelled {
            if steps > 1 { onFlipping?(false) }
            scrollSum = 0; vSum = 0; scrollFired = false; steps = 0; axis = 0
        }
    }
    /// Three-finger swipes (when "Swipe between pages" is set to three fingers).
    override func swipe(with e: NSEvent) {
        if e.deltaX != 0 { onSwipe?(e.deltaX > 0 ? -1 : 1) }
    }
    override func magnify(with e: NSEvent) {
        if e.phase == .began { pinchSum = 0 }
        pinchSum += e.magnification
        if pinchSum > 0.12 { pinchSum = -10; onZoom?(point(e)) }  // once per pinch
    }
}


/// View ▸ Show Face Names (⌥⌘N): a box on every face found, with its name — click a name to change it.
struct FaceBoxes: View {
    let photo: Photo
    let rect: CGRect
    @Environment(Library.self) private var lib
    @State private var idx = FaceIndex.shared
    @State private var editing: Int?
    @State private var text = ""
    var body: some View {
        ForEach(idx.faces(inPhoto: photo.id).filter { $0.rect != .zero && $0.rot == photo.rot }, id: \.id) { f in
            let r = CGRect(x: rect.minX + f.rect.minX * rect.width, y: rect.minY + f.rect.minY * rect.height,
                           width: f.rect.width * rect.width, height: f.rect.height * rect.height)
            let name = f.person.flatMap { idx.people[$0]?.name }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.9), lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(width: r.width, height: r.height)
                    .allowsHitTesting(false)
                Button { text = name ?? ""; editing = f.id } label: {
                    Text(name ?? "Click to name").font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .offset(y: r.height + 4)
                .popover(isPresented: Binding(get: { editing == f.id }, set: { if !$0 { editing = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Who is this?").font(.headline)
                        NameField(text: $text, prompt: "Name") { n in
                            guard !n.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            idx.setFace(f.id, toName: n, lib: lib); editing = nil
                        }
                        .frame(width: 220)
                        if let pid = f.person, let n = name {
                            Button("This Isn't \(n)") { idx.remove(photos: [photo.id], from: pid, lib: lib); editing = nil }.controlSize(.small)
                        }
                    }
                    .padding(12)
                }
            }
            .frame(width: r.width, height: r.height, alignment: .top)
            .position(x: r.midX, y: r.midY)
        }
    }
}


/// Swipe up in the Viewer: where and when, who's in it, and what took it — like the panel under a photo in Apple Photos.
struct PhotoDetailsPanel: View {
    let photo: Photo
    var close: () -> Void
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var idx = FaceIndex.shared
    var body: some View {
        let people = idx.peopleIn(photo.id).compactMap { idx.people[$0] }.sorted { $0.name < $1.name }
        HStack(alignment: .top, spacing: 18) {
            if let c = Library.gps(photo) {
                Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 4000, longitudinalMeters: 4000))) {
                    Marker("", coordinate: c)
                }
                .id(photo.id)
                .frame(width: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Button("Show on Map") { ui.showOnMap(photo) }.controlSize(.small).padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(photo.dateFromFile ? "No date" : photo.captureDate.formatted(date: .complete, time: .shortened))
                    .font(.title3.weight(.semibold))
                if !photo.placeLabel.isEmpty { Label(photo.placeLabel, systemImage: "mappin.and.ellipse") }
                if !photo.camera.isEmpty { Label([photo.camera, photo.lens].filter { !$0.isEmpty }.joined(separator: " · "), systemImage: "camera") }
                if !photo.exposure.isEmpty { Label(photo.exposure, systemImage: "camera.aperture") }
                Label("\(photo.w) × \(photo.h)  ·  \(photo.ext.uppercased())  ·  \(ByteCountFormatter.string(fromByteCount: Int64(photo.size), countStyle: .file))",
                      systemImage: "photo")
                    .foregroundStyle(.secondary)
                if !photo.caption.isEmpty { Text(photo.caption).lineLimit(2) }
                if !people.isEmpty {
                    Text("People").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    FlowLayout(spacing: 8) {
                        ForEach(people, id: \.id) { pr in
                            Button { ui.source = .person(pr.id); ui.mode = .browser } label: {
                                HStack(spacing: 6) { FaceCircle(faceId: idx.keyFace(pr), size: 26); Text(pr.name) }
                                    .padding(.trailing, 8).padding(2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help("Show \(pr.name)'s photos")
                        }
                    }
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "chevron.down").font(.title3) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide the details (or swipe down)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

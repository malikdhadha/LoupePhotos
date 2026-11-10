import SwiftUI
import AppKit

/// Develop (D): the photo large, a filmstrip along the bottom, and the adjustments in the Inspector on the right.
struct DevelopView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var m = DevelopModel.shared
    @State private var hover: CGPoint?
    @State private var zoomCtl = ZoomController()
    @State private var zoomFocus = CGPoint(x: 0.5, y: 0.5)
    @State private var zoomAnchor = CGPoint(x: 0.5, y: 0.5)

    var body: some View {
        VStack(spacing: 0) {
            DevelopBar()
            Divider()
            canvas
            Divider()
            FilmstripView().frame(height: 96)
        }
        .task(id: "\(ui.primary ?? -1)-\(ui.primaryPhoto(lib)?.rot ?? 0)") { if let p = ui.primaryPhoto(lib) { m.load(p) } }
        .onDisappear { m.leave() }
    }

    var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.13)
                if let p = ui.primaryPhoto(lib), let img = (m.showBefore ? (m.before ?? m.image) : m.image) {
                    let rect = fitRect(img.size, in: geo.size)
                    if m.zoomed {
                        ZoomScrollView(image: m.zoomImage ?? img, pixelSize: m.zoomImage?.size ?? fullSize(p), focus: zoomFocus, anchor: zoomAnchor,
                                       startMagnification: 1, controller: zoomCtl, onClick: { m.zoomed = false })
                            .id("\(p.id)-\(m.zoomImage == nil ? 0 : 1)")
                        if m.zoomImage == nil { ProgressView().controlSize(.small).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    } else {
                        Image(nsImage: img).resizable().interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
                            .position(x: rect.midX, y: rect.midY)
                        if m.cropping && !m.showBefore {
                            CropOverlay(ir: rect, crop: m.displayCrop, ratio: DevelopModel.ratio(m.recipe.aspect, photo: rect.width / max(1, rect.height)),
                                        pixels: fullSize(p), angle: m.value(.angle), guide: m.guide, turn: m.guideTurn, show: m.guideShow, ruler: m.ruling,
                                        commit: { m.setCrop(display: $0) },
                                        rotate: { a, done in if done { m.end() } else { m.set(.angle, a) } },
                                        level: { a, b in m.level(from: a, to: b) })
                        }
                    }
                    if m.showBefore { tag("Before") }
                    if m.picking { tag("Click something that should be neutral grey or white") }
                    if m.cropping && !m.showBefore { tag("Drag the corners or edges · Return when done") }
                }
            }
            .contentShape(Rectangle())
            .overlay {
                if !m.cropping && !m.zoomed && ui.primaryPhoto(lib) != nil {
                    ViewerInput(onHover: { hover = $0 }, onZoom: { pt in click(pt, geo.size) }, onSwipe: { ui.step($0, lib) })
                }
            }
            .overlay {
                if !m.cropping && !m.zoomed { EdgeArrows(hover: hover, size: geo.size) { ui.step($0, lib) } }
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.callout.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 12)
            .allowsHitTesting(false)
    }

    /// A click: the eyedropper's colour, or zoom to 100% at that spot.
    private func click(_ pt: CGPoint, _ size: CGSize) {
        guard let img = m.image else { return }
        let r = fitRect(img.size, in: size)
        guard r.contains(pt) else { return }
        let f = CGPoint(x: (pt.x - r.minX) / r.width, y: (pt.y - r.minY) / r.height)
        if m.picking { m.pick(f); return }
        zoomFocus = f; zoomAnchor = CGPoint(x: pt.x / size.width, y: pt.y / size.height)
        m.zoomed = true
    }
    private func fullSize(_ p: Photo) -> CGSize {
        let s = p.w > 0 && p.h > 0 ? CGSize(width: p.w, height: p.h) : (m.image?.size ?? CGSize(width: 1000, height: 1000))
        return p.rot % 2 != 0 ? CGSize(width: s.height, height: s.width) : s
    }
    func fitRect(_ s: CGSize, in box: CGSize) -> CGRect {
        let pad: CGFloat = 24, w = max(1, box.width - pad * 2), h = max(1, box.height - pad * 2)
        let k = min(w / max(1, s.width), h / max(1, s.height))
        let fw = s.width * k, fh = s.height * k
        return CGRect(x: (box.width - fw) / 2, y: (box.height - fh) / 2, width: fw, height: fh)
    }
}

/// The strip above the photo in Develop.
struct DevelopBar: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var m = DevelopModel.shared
    var body: some View {
        HStack(spacing: 10) {
            Button { ui.mode = ui.developFrom } label: { Label("Back", systemImage: "chevron.left") }.help("Back to where you were (Esc or D)")
            Divider().frame(height: 16)
            Button("Revert to Original") { m.revert() }.disabled(!m.recipe.isEdited)
            Toggle(isOn: Binding(get: { m.showBefore }, set: { m.showBefore = $0 })) { Label("Before", systemImage: "square.split.2x1") }
                .toggleStyle(.button).help("Show the original (\\)")
            Toggle(isOn: Binding(get: { m.cropping }, set: { m.cropping = $0 })) { Label("Crop", systemImage: "crop") }
                .toggleStyle(.button).help("Crop and straighten (R)")
            Button { m.auto(nil) } label: { Label("Auto Enhance", systemImage: "wand.and.stars") }.help("Apple's Auto Enhance, as slider values you can change")
            Toggle(isOn: Binding(get: { m.zoomed }, set: { m.zoomed = $0 })) { Label("100%", systemImage: "plus.magnifyingglass") }
                .toggleStyle(.button).help("Full size, for sharpening and noise (Z)")
            Spacer(minLength: 8)
            if let p = ui.primaryPhoto(lib) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(p.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Text([p.w > 0 ? "\(p.w) × \(p.h)" : "", p.ext.uppercased(), p.rating > 0 ? String(repeating: "★", count: p.rating) : ""]
                        .filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView().controlSize(.small).opacity(m.busy ? 1 : 0)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

/// Soft ‹ › arrows at the sides of the photo when the pointer is near them (Viewer and Develop).
struct EdgeArrows: View {
    let hover: CGPoint?
    let size: CGSize
    let step: (Int) -> Void
    @State private var over = 0          // the pointer is on an arrow (so it stays while you click)
    var body: some View {
        let near: CGFloat = 130
        let left = over == -1 || (hover.map { $0.x < near } ?? false)
        let right = over == 1 || (hover.map { $0.x > size.width - near } ?? false)
        HStack {
            if left { arrow("chevron.left", -1) }
            Spacer()
            if right { arrow("chevron.right", 1) }
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.15), value: left)
        .animation(.easeOut(duration: 0.15), value: right)
    }
    private func arrow(_ name: String, _ d: Int) -> some View {
        Button { step(d) } label: {
            Image(systemName: name).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { over = $0 ? d : (over == d ? 0 : over) }
        .transition(.opacity)
        .help(d < 0 ? "Previous photo (←)" : "Next photo (→)")
    }
}

/// The guides drawn over the crop (O cycles through them, ⇧O turns them, H shows or hides them — as in Lightroom).
enum CropGuide: Int, CaseIterable, Identifiable {
    case thirds, grid, fifths, diagonal, crosshair, triangle, phi, spiral, ratios
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .thirds: return "Rule of Thirds"
        case .grid: return "Grid"
        case .fifths: return "Fifths"
        case .diagonal: return "Diagonal"
        case .crosshair: return "Centre"
        case .triangle: return "Golden Triangle"
        case .phi: return "Golden Ratio"
        case .spiral: return "Golden Spiral"
        case .ratios: return "Aspect Ratios"
        }
    }
    /// The guide's lines inside `r`. `turn` 0–3 mirrors it left–right and/or top–bottom (for the spiral and triangles).
    func path(in r: CGRect, turn: Int) -> Path {
        var p = Path()
        func line(_ a: CGPoint, _ b: CGPoint) { p.move(to: a); p.addLine(to: b) }
        func splits(_ fs: [CGFloat]) {
            for f in fs {
                line(CGPoint(x: r.minX + r.width * f, y: r.minY), CGPoint(x: r.minX + r.width * f, y: r.maxY))
                line(CGPoint(x: r.minX, y: r.minY + r.height * f), CGPoint(x: r.maxX, y: r.minY + r.height * f))
            }
        }
        switch self {
        case .thirds: splits([1.0 / 3, 2.0 / 3])
        case .fifths: splits([0.2, 0.4, 0.6, 0.8])
        case .phi: splits([0.382, 0.618])
        case .grid:
            let step = max(r.width, r.height) / 12
            var x = r.minX + step; while x < r.maxX - 1 { line(CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY)); x += step }
            var y = r.minY + step; while y < r.maxY - 1 { line(CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)); y += step }
        case .diagonal:
            // 45° from each corner, as far as the frame allows
            let s = min(r.width, r.height)
            line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + s, y: r.minY + s))
            line(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - s, y: r.minY + s))
            line(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + s, y: r.maxY - s))
            line(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - s, y: r.maxY - s))
        case .crosshair:
            let c = CGPoint(x: r.midX, y: r.midY), l = min(r.width, r.height) * 0.08
            line(CGPoint(x: c.x - l, y: c.y), CGPoint(x: c.x + l, y: c.y)); line(CGPoint(x: c.x, y: c.y - l), CGPoint(x: c.x, y: c.y + l))
            p.addEllipse(in: CGRect(x: c.x - l * 0.45, y: c.y - l * 0.45, width: l * 0.9, height: l * 0.9))
            splits([0.5])
        case .triangle:
            // one diagonal, and from the other two corners a line meeting it at a right angle
            let a = CGPoint(x: r.minX, y: r.maxY), b = CGPoint(x: r.maxX, y: r.minY)
            line(a, b)
            func foot(_ q: CGPoint) -> CGPoint {
                let d = CGPoint(x: b.x - a.x, y: b.y - a.y), t = ((q.x - a.x) * d.x + (q.y - a.y) * d.y) / (d.x * d.x + d.y * d.y)
                return CGPoint(x: a.x + d.x * t, y: a.y + d.y * t)
            }
            let tl = CGPoint(x: r.minX, y: r.minY), br = CGPoint(x: r.maxX, y: r.maxY)
            line(tl, foot(tl)); line(br, foot(br))
        case .spiral:
            // squares cut off in turn (left, top, right, bottom), a quarter circle in each
            var x = r.minX, y = r.minY, w = r.width, h = r.height
            for i in 0..<10 {
                let s = min(w, h)
                guard s > 2 else { break }
                switch i % 4 {
                case 0: p.addRect(CGRect(x: x, y: y, width: s, height: s))
                    p.move(to: CGPoint(x: x, y: y + s)); p.addArc(center: CGPoint(x: x + s, y: y + s), radius: s, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                    x += s; w -= s
                case 1: p.addRect(CGRect(x: x, y: y, width: s, height: s))
                    p.move(to: CGPoint(x: x, y: y)); p.addArc(center: CGPoint(x: x, y: y + s), radius: s, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
                    y += s; h -= s
                case 2: p.addRect(CGRect(x: x + w - s, y: y, width: s, height: s))
                    p.move(to: CGPoint(x: x + w, y: y)); p.addArc(center: CGPoint(x: x + w - s, y: y), radius: s, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                    w -= s
                default: p.addRect(CGRect(x: x, y: y + h - s, width: s, height: s))
                    p.move(to: CGPoint(x: x + s, y: y + h)); p.addArc(center: CGPoint(x: x + s, y: y + h - s), radius: s, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                    h -= s
                }
            }
        case .ratios:
            // where common print shapes would cut, centred
            for k in [1.0, 4.0 / 5, 5.0 / 7, 2.0 / 3] {
                let k2 = r.width >= r.height ? 1 / k : k
                var fw = r.width, fh = fw / k2
                if fh > r.height { fh = r.height; fw = fh * k2 }
                p.addRect(CGRect(x: r.midX - fw / 2, y: r.midY - fh / 2, width: fw, height: fh))
            }
        }
        // turned: mirrored left–right (1), top–bottom (2), or both (3)
        guard turn % 4 != 0 else { return p }
        let sx: CGFloat = turn % 2 == 1 ? -1 : 1, sy: CGFloat = turn >= 2 ? -1 : 1
        let t = CGAffineTransform(translationX: r.midX, y: r.midY).scaledBy(x: sx, y: sy).translatedBy(x: -r.midX, y: -r.midY)
        return p.applying(t)
    }
}

/// The crop frame: drag a corner or an edge to resize it, inside to move it, outside to turn the photo (a fine grid
/// appears to line things up). With the ruler, draw along something that should be level or upright.
/// `crop` and the result are fractions of the photo as shown.
struct CropOverlay: View {
    let ir: CGRect
    let crop: CGRect
    let ratio: Double?
    let pixels: CGSize                       // the shown photo's full size, for the size readout
    let angle: Double
    let guide: CropGuide
    let turn: Int
    let show: Int                            // 0 always, 1 while dragging, 2 never
    let ruler: Bool
    let commit: (CGRect) -> Void
    let rotate: (Double, Bool) -> Void       // new angle, finished
    let level: (CGPoint, CGPoint) -> Void    // the ruler's line
    @State private var live: CGRect?
    @State private var start = CGRect.zero
    @State private var grab = 0          // 1 move, 2 top-left, 3 top-right, 4 bottom-left, 5 bottom-right, 6 left, 7 right, 8 top, 9 bottom, 10 turn, 11 ruler
    @State private var turnFrom: (a0: Double, angle: Double) = (0, 0)
    @State private var line: (CGPoint, CGPoint)?
    @AppStorage("crop.guideStrength") private var strength = 1   // 0 Subtle, 1 Normal, 2 Strong

    /// White lines on a soft dark edge, so they show on bright skies and dark shadows alike.
    @ViewBuilder func lines(_ path: Path, width: CGFloat, white: Double, dark: Double) -> some View {
        path.stroke(Color.black.opacity(dark), lineWidth: width + 1.5)
        path.stroke(Color.white.opacity(white), lineWidth: width)
    }
    var body: some View {
        let c = live ?? crop
        let r = CGRect(x: ir.minX + c.minX * ir.width, y: ir.minY + c.minY * ir.height, width: c.width * ir.width, height: c.height * ir.height)
        let dragging = grab != 0
        ZStack {
            Path { p in p.addRect(ir); p.addRect(r) }.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            let st = max(0, min(2, strength))
            let w: CGFloat = [0.75, 1, 1.4][st], white = [0.5, 0.8, 0.95][st], dark = [0.25, 0.4, 0.55][st]
            let lift = dragging ? 0.15 : 0
            if grab == 10 || grab == 11 {
                lines(CropGuide.grid.path(in: r, turn: 0), width: w * 0.75, white: min(1, white * 0.8 + lift), dark: dark)
            } else if show == 0 || (show == 1 && dragging) {
                lines(guide.path(in: r, turn: turn), width: w, white: min(1, white + lift), dark: dark)
            }
            Path { p in p.addRect(r) }.stroke(Color.black.opacity(0.4), lineWidth: 3)
            Path { p in p.addRect(r) }.stroke(Color.white, lineWidth: 1)
            Path { p in
                let L: CGFloat = 16
                for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                    p.move(to: CGPoint(x: x + L * sx, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + L * sy))
                }
                for (x, y, horiz) in [(r.midX, r.minY, true), (r.midX, r.maxY, true), (r.minX, r.midY, false), (r.maxX, r.midY, false)] {
                    if horiz { p.move(to: CGPoint(x: x - 9, y: y)); p.addLine(to: CGPoint(x: x + 9, y: y)) }
                    else { p.move(to: CGPoint(x: x, y: y - 9)); p.addLine(to: CGPoint(x: x, y: y + 9)) }
                }
            }.stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .square))
            if let (a, b) = line {
                Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            }
            // what's happening, while it happens
            if dragging, let label = readout(c) {
                Text(label).font(.caption.monospacedDigit().weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                    .position(x: r.midX, y: max(ir.minY + 12, r.minY - 14))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if grab == 0 && live == nil && line == nil {
                        start = c
                        grab = ruler ? 11 : hit(g.startLocation, r)
                        if grab == 0 { grab = 10 }                       // outside the frame: turn the photo
                        if grab == 10 { turnFrom = (bearing(g.startLocation, r), angle) }
                        if grab != 10 && grab != 11 { live = c }
                    }
                    switch grab {
                    case 10:
                        let d = bearing(g.location, r) - turnFrom.a0
                        let wrapped = d > 180 ? d - 360 : d < -180 ? d + 360 : d
                        rotate(max(-45, min(45, turnFrom.angle + wrapped)), false)
                    case 11: line = (g.startLocation, g.location)
                    default: live = adjust(start, grab, dx: g.translation.width / ir.width, dy: g.translation.height / ir.height)
                    }
                }
                .onEnded { g in
                    switch grab {
                    case 10: rotate(angle, true)
                    case 11: if let (a, b) = line, hypot(b.x - a.x, b.y - a.y) > 10 { level(a, b) }
                    default: if let l = live, l != start { commit(l) }
                    }
                    live = nil; grab = 0; line = nil
                }
        )
    }

    private func bearing(_ p: CGPoint, _ r: CGRect) -> Double { atan2(Double(p.y - r.midY), Double(p.x - r.midX)) * 180 / .pi }
    private func readout(_ c: CGRect) -> String? {
        switch grab {
        case 10: return String(format: "%+.1f°", angle)
        case 11: return "Draw along something level or upright"
        default:
            guard pixels.width > 0 else { return nil }
            return "\(Int((c.width * pixels.width).rounded())) × \(Int((c.height * pixels.height).rounded()))"
        }
    }

    private func hit(_ p: CGPoint, _ r: CGRect) -> Int {
        let t: CGFloat = 16
        func near(_ a: CGPoint) -> Bool { hypot(p.x - a.x, p.y - a.y) < t * 1.3 }
        if near(CGPoint(x: r.minX, y: r.minY)) { return 2 }
        if near(CGPoint(x: r.maxX, y: r.minY)) { return 3 }
        if near(CGPoint(x: r.minX, y: r.maxY)) { return 4 }
        if near(CGPoint(x: r.maxX, y: r.maxY)) { return 5 }
        let inY = p.y > r.minY - t && p.y < r.maxY + t, inX = p.x > r.minX - t && p.x < r.maxX + t
        if inY && abs(p.x - r.minX) < t { return 6 }
        if inY && abs(p.x - r.maxX) < t { return 7 }
        if inX && abs(p.y - r.minY) < t { return 8 }
        if inX && abs(p.y - r.maxY) < t { return 9 }
        return r.contains(p) ? 1 : 0
    }
    private func adjust(_ s: CGRect, _ g: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSize: CGFloat = 0.04
        func cl(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }
        if g == 1 {
            return CGRect(x: cl(s.minX + dx, 0, 1 - s.width), y: cl(s.minY + dy, 0, 1 - s.height), width: s.width, height: s.height)
        }
        var x0 = s.minX, y0 = s.minY, x1 = s.maxX, y1 = s.maxY
        if [2, 4, 6].contains(g) { x0 = cl(s.minX + dx, 0, x1 - minSize) }
        if [3, 5, 7].contains(g) { x1 = cl(s.maxX + dx, x0 + minSize, 1) }
        if [2, 3, 8].contains(g) { y0 = cl(s.minY + dy, 0, y1 - minSize) }
        if [4, 5, 9].contains(g) { y1 = cl(s.maxY + dy, y0 + minSize, 1) }
        let free = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard let ratio else { return free }
        // keep the shape: work out the other side, then fit inside the photo from the corner or edge that stays put
        let k = ir.width / max(1, ir.height)              // fraction-of-width → pixels, relative to height
        var w = free.width, h = free.height
        if g == 8 || g == 9 { w = h * ratio / k } else { h = w * k / ratio }
        let (ax, ay, sx, sy): (CGFloat, CGFloat, CGFloat, CGFloat) = {
            switch g {
            case 2: return (s.maxX, s.maxY, -1, -1)
            case 3: return (s.minX, s.maxY, 1, -1)
            case 4: return (s.maxX, s.minY, -1, 1)
            case 5: return (s.minX, s.minY, 1, 1)
            case 6: return (s.maxX, s.midY, -1, 0)
            case 7: return (s.minX, s.midY, 1, 0)
            case 8: return (s.midX, s.maxY, 0, -1)
            default: return (s.midX, s.minY, 0, 1)
            }
        }()
        let availW = sx < 0 ? ax : sx > 0 ? 1 - ax : 2 * min(ax, 1 - ax)
        let availH = sy < 0 ? ay : sy > 0 ? 1 - ay : 2 * min(ay, 1 - ay)
        let f = min(1, availW / max(w, 0.0001), availH / max(h, 0.0001))
        w *= f; h *= f
        let x = sx < 0 ? ax - w : sx > 0 ? ax : ax - w / 2
        let y = sy < 0 ? ay - h : sy > 0 ? ay : ay - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - The panel in the Inspector

/// The Inspector's Develop tab: histogram, then Aperture's adjustment sections.
struct DevelopPanel: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @State private var m = DevelopModel.shared
    @State private var presets = DevelopPresets.shared

    var shown: [Brick] {
        Brick.allCases.filter { b in
            if b == .raw && !m.isRaw { return false }
            return b.standard || m.recipe.on(b) || m.added.contains(b) || (b == .crop && m.cropping)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HistogramView(bins: m.histogram).frame(height: 92)
                let bits = [photo.exposure, photo.camera].filter { !$0.isEmpty }
                if !bits.isEmpty { Text(bits.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity) }
                HStack(spacing: 6) {
                    Menu("Add Adjustment") {
                        ForEach(Brick.allCases.filter { !shown.contains($0) && !($0 == .raw && !m.isRaw) }) { b in
                            Button(b.title) { m.added.insert(b); m.expanded.insert(b.rawValue); if b != .crop { m.toggle(b) } else { m.cropping = true } }
                        }
                    }
                    .fixedSize()
                    Menu("Presets") {
                        ForEach(presets.all, id: \.name) { pr in Button(pr.name) { apply(pr) } }
                        if !presets.all.isEmpty { Divider() }
                        Button("Save Adjustments as Preset…") { savePreset() }.disabled(!m.recipe.isEdited)
                        if !presets.all.isEmpty {
                            Menu("Delete Preset") { ForEach(presets.all, id: \.name) { pr in Button(pr.name) { presets.delete(pr.name) } } }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button { m.auto(nil) } label: { Image(systemName: "wand.and.stars") }.help("Auto Enhance")
                }
                .controlSize(.small)
                if m.isRaw { ProfileRow(photo: photo) }
                ForEach(shown) { b in BrickView(brick: b) }
                HStack {
                    Button("Revert to Original") { m.revert() }.disabled(!m.recipe.isEdited)
                    Spacer()
                    if m.recipe.isEdited { Text("Your original is never changed").font(.caption2).foregroundStyle(.tertiary) }
                }
                .controlSize(.small).padding(.top, 4)
            }
            .padding(12)
        }
    }
    private func apply(_ pr: DevelopPresets.Preset) {
        m.change { r in
            for b in Brick.allCases where b != .crop && b != .raw {
                if pr.recipe.on(b) {
                    for k in b.keys { r.set(k, pr.recipe.has(k) ? pr.recipe.v(k) : nil) }
                    if b == .exposure { r.curve = pr.recipe.curve }
                    r.setOn(b, true)
                }
            }
        }
    }
    private func savePreset() {
        let a = NSAlert(); a.messageText = "Save Adjustments as Preset"; a.informativeText = "Everything except the crop and RAW Fine Tuning, to use on other photos."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.placeholderString = "Preset name"; a.accessoryView = f
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        var r = m.recipe; r.clear(.crop); r.clear(.raw); r.decoder = nil
        presets.save(name.isEmpty ? "Untitled Preset" : name, r)
    }
}

/// RAW only: the look the photo starts from — what the camera's LCD showed, the camera's learned profile, or Apple's own.
struct ProfileRow: View {
    let photo: Photo
    @State private var m = DevelopModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Profile").font(.callout.weight(.semibold))
                Spacer()
                Picker("", selection: Binding(get: { m.profile }, set: { m.setProfile($0) })) {
                    ForEach(RawProfile.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
    }
    private var note: String? {
        let hasCamera = CameraMatchStore.shared.cameraLUT(photo.camera) != nil
        switch m.profile {
        case .match:
            switch CameraMatchStore.shared.status(photo.id) {
            case .matched: return nil
            case .noReference: return hasCamera ? "This file's own preview can't be used (edited in Lightroom, or missing) — starting from Camera Standard instead."
                                                : "This file's own preview can't be used, and there's no Camera Standard for this camera yet — Apple's look for now."
            case .unknown: return "Matching the camera's look…"
            }
        case .camera: return hasCamera ? nil : "No Camera Standard for this camera yet (it's learned once a few of its RAWs are matched) — Apple's look for now."
        case .neutral: return "Apple's own rendering: flat, with the most room for editing."
        }
    }
}

/// One section ("brick"): ▸ ☑ Title  Auto ↺, then its sliders.
struct BrickView: View {
    let brick: Brick
    @State private var m = DevelopModel.shared
    @AppStorage("crop.guideStrength") private var guideStrength = 1
    var open: Bool { m.expanded.contains(brick.rawValue) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { if open { m.expanded.remove(brick.rawValue) } else { m.expanded.insert(brick.rawValue) } } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                }.buttonStyle(.plain)
                Toggle("", isOn: Binding(get: { m.recipe.on(brick) }, set: { _ in m.toggle(brick) })).labelsHidden().toggleStyle(.checkbox)
                    .help("Turn this adjustment on or off")
                Text(brick.title).font(.callout.weight(.semibold))
                    .onTapGesture { if open { m.expanded.remove(brick.rawValue) } else { m.expanded.insert(brick.rawValue) } }
                Spacer()
                if brick.hasAuto { Button("Auto") { m.auto(brick) }.controlSize(.mini) }
                Button { m.reset(brick) } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Put this section back as it was").disabled(!m.recipe.on(brick) && !brick.keys.contains { m.recipe.has($0) })
            }
            if open { content.padding(.leading, 4) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
        .opacity(m.recipe.on(brick) || !m.recipe.isEdited ? 1 : 0.85)
    }

    @ViewBuilder var content: some View {
        switch brick {
        case .raw:
            if let inf = m.info {
                HStack {
                    Text("Version").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    Picker("", selection: Binding(get: { m.recipe.decoder ?? inf.decoder }, set: { m.setDecoder($0) })) {
                        ForEach(inf.versions, id: \.self) { Text(DevelopEngine.label($0)).tag($0) }
                    }.labelsHidden().controlSize(.small)
                }
                if let newest = inf.versions.first, DevelopEngine.number(newest) > DevelopEngine.number(m.recipe.decoder ?? inf.decoder) {
                    Button("Upgrade to \(DevelopEngine.label(newest))") { m.setDecoder(newest) }.controlSize(.mini).padding(.leading, 86)
                }
                AdjSlider(k: .boost)
                AdjSlider(k: .boostShadow)
                if inf.sharp != nil { AdjSlider(k: .rawSharp) }
                if inf.moire != nil { AdjSlider(k: .moire) }
                if inf.lens != nil {
                    Toggle("Lens Correction", isOn: Binding(get: { m.value(.lens) > 0.5 }, set: { v in m.change { $0.set(.lens, v ? 1 : 0); $0.setOn(.raw, true) } }))
                        .toggleStyle(.checkbox).font(.caption).padding(.leading, 86)
                }
            } else {
                Text("Reading the RAW file…").font(.caption).foregroundStyle(.secondary)
            }
        case .wb:
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { m.picking }, set: { m.picking = $0 })) { Image(systemName: "eyedropper") }
                    .toggleStyle(.button).controlSize(.small).help("Click something in the photo that should be neutral grey or white")
                Button(m.isRaw ? "As Shot" : "Original") { m.change { $0.set(.temp, nil); $0.set(.tint, nil); $0.setOn(.wb, false) } }.controlSize(.small)
                Spacer()
            }
            .padding(.leading, 86)
            AdjSlider(k: .temp, gradient: [.blue, .yellow])
            AdjSlider(k: .tint, gradient: [.green, .pink])
        case .crop:
            HStack {
                Text("Aspect").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Picker("", selection: Binding(get: { m.recipe.aspect }, set: { a in m.setAspect(a, photoRatio: photoRatio) })) {
                    ForEach(DevelopModel.aspects, id: \.self) { Text($0).tag($0) }
                    if !DevelopModel.aspects.contains(m.recipe.aspect) { Text("Custom").tag(m.recipe.aspect) }
                }.labelsHidden().controlSize(.small)
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 80)
                Button { m.lockAspect(photoRatio: photoRatio) } label: { Image(systemName: m.recipe.aspect == "Free" ? "lock.open" : "lock") }
                    .help(m.recipe.aspect == "Free" ? "Keep this shape while resizing" : "Free shape")
                Button { m.flipAspect(photoRatio: photoRatio) } label: { Image(systemName: "rectangle.portrait.rotate") }
                    .help("Turn the crop between landscape and portrait (X)")
                Spacer()
            }
            .buttonStyle(.borderless).controlSize(.small)
            HStack {
                Text("Guide").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Picker("", selection: Binding(get: { m.guide }, set: { m.guide = $0 })) {
                    ForEach(CropGuide.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().controlSize(.small)
            }
            HStack {
                Text("Show").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Picker("", selection: Binding(get: { m.guideShow }, set: { m.guideShow = $0 })) {
                    Text("Always").tag(0); Text("While Dragging").tag(1); Text("Never").tag(2)
                }.labelsHidden().controlSize(.small)
            }
            HStack {
                Text("Lines").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Picker("", selection: $guideStrength) {
                    Text("Subtle").tag(0); Text("Normal").tag(1); Text("Strong").tag(2)
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).help("How strongly the guide lines show over the photo")
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 80)
                Toggle(isOn: Binding(get: { m.cropping }, set: { m.cropping = $0 })) { Image(systemName: "crop") }
                    .toggleStyle(.button).help(m.cropping ? "Done cropping (Return)" : "Crop (R)")
                Toggle(isOn: Binding(get: { m.ruling }, set: { m.ruling = $0; if $0 { m.cropping = true } })) { Image(systemName: "ruler") }
                    .toggleStyle(.button).help("Ruler: draw along something that should be level or upright")
                Button { m.autoStraighten() } label: { Image(systemName: "level") }.help("Auto: level the horizon")
                Button { m.reset(.crop) } label: { Image(systemName: "arrow.counterclockwise") }.help("Reset the crop and straightening")
            }
            .controlSize(.small)
            AdjSlider(k: .angle)
            Text("O changes the guide · ⇧O turns it · H shows or hides it · drag outside the frame to straighten")
                .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 86)
        case .nr:
            AdjSlider(k: .nrLum)
            if m.isRaw { AdjSlider(k: .nrColor) }
        default:
            ForEach(brick.keys) { k in AdjSlider(k: k) }
        }
    }
    /// The shown photo's width ÷ height (after your rotation).
    private var photoRatio: Double {
        if let i = m.image, m.cropping, i.size.height > 0 { return i.size.width / i.size.height }
        guard let p = Library.shared.byId[m.photoId ?? -1], p.w > 0, p.h > 0 else { return 1.5 }
        return m.rot % 2 != 0 ? Double(p.h) / Double(p.w) : Double(p.w) / Double(p.h)
    }
}

/// Label · slider · value. Double-click the label to put it back.
struct AdjSlider: View {
    let k: K
    var gradient: [Color]? = nil
    @State private var m = DevelopModel.shared
    @State private var text = ""
    @FocusState private var typing: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(k.label).font(.caption).foregroundStyle(m.recipe.has(k) ? .primary : .secondary)
                .frame(width: 80, alignment: .trailing).lineLimit(1)
                .onTapGesture(count: 2) { m.resetKey(k) }
                .help("Double-click to put \(k.label) back")
            Slider(value: Binding(get: { m.value(k) }, set: { m.set(k, $0) }), in: k.range, onEditingChanged: { if !$0 { m.end() } })
                .controlSize(.mini)
                .background(alignment: .bottom) {
                    if let gradient { LinearGradient(colors: gradient.map { $0.opacity(0.55) }, startPoint: .leading, endPoint: .trailing).frame(height: 2).offset(y: 5) }
                }
            TextField("", text: $text)
                .font(.caption.monospacedDigit()).multilineTextAlignment(.trailing)
                .textFieldStyle(.plain).frame(width: 46)
                .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                .focused($typing)
                .onSubmit { if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { m.set(k, min(k.range.upperBound, max(k.range.lowerBound, v))); m.end() }; typing = false }
        }
        .onAppear { text = format(m.value(k)) }
        .onChange(of: m.value(k)) { _, v in if !typing { text = format(v) } }
    }
    private func format(_ v: Double) -> String { String(format: "%.\(k.digits)f", v) }
}

/// Red, green and blue levels of the photo as it looks now.
struct HistogramView: View {
    let bins: [[Float]]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Color(white: 0.1)))
            guard bins.count == 3 else { return }
            let colors: [Color] = [.red, .green, .blue]
            ctx.blendMode = .plusLighter
            for (c, b) in bins.enumerated() {
                var p = Path()
                let n = b.count, w = size.width - 8, h = size.height - 8
                p.move(to: CGPoint(x: 4, y: 4 + h))
                for (i, v) in b.enumerated() { p.addLine(to: CGPoint(x: 4 + w * CGFloat(i) / CGFloat(max(1, n - 1)), y: 4 + h - h * CGFloat(v))) }
                p.addLine(to: CGPoint(x: 4 + w, y: 4 + h))
                p.closeSubpath()
                ctx.fill(p, with: .color(colors[c].opacity(0.6)))
            }
        }
    }
}

/// Develop ▸ Presets: saved adjustments (everything but the crop and RAW Fine Tuning).
@Observable
final class DevelopPresets {
    static let shared = DevelopPresets()
    struct Preset { let name: String; let recipe: Recipe }
    private(set) var all: [Preset] = []
    init() {
        let list = UserDefaults.standard.array(forKey: "develop.presets") as? [[String: Any]] ?? []
        all = list.compactMap { d in (d["name"] as? String).flatMap { n in Recipe(d["recipe"]).map { Preset(name: n, recipe: $0) } } }
    }
    func save(_ name: String, _ r: Recipe) {
        all.removeAll { $0.name == name }
        all.append(Preset(name: name, recipe: r)); all.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        store()
    }
    func delete(_ name: String) { all.removeAll { $0.name == name }; store() }
    private func store() { UserDefaults.standard.set(all.map { ["name": $0.name, "recipe": $0.recipe.dict] }, forKey: "develop.presets") }
}

/// Settings ▸ Develop
struct DevelopSettingsView: View {
    @AppStorage("develop.decoder") private var decoder = "latest"
    @AppStorage("develop.badge") private var badge = true
    @AppStorage("develop.profile") private var profile = RawProfile.match.rawValue
    @AppStorage("develop.matchOnImport") private var matchOnImport = true
    var body: some View {
        Form {
            Section("RAW") {
                Picker("RAW version for new edits", selection: $decoder) {
                    Text("Newest available").tag("latest")
                    ForEach(["9", "8", "7", "6"], id: \.self) { Text("RAW \($0)").tag($0) }
                }
                Text("Apple's RAW engine improves with macOS. Each photo keeps the version it was edited with, so an update never changes how a finished photo looks — RAW Fine Tuning in Develop can upgrade a photo when you want.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Starting look for RAW files") {
                Picker("Profile", selection: $profile) {
                    ForEach(RawProfile.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Camera Match new RAW files in the background", isOn: $matchOnImport)
                Text("Camera Match makes a RAW start out looking like the JPEG the camera made — what you saw on its screen, with your Picture Control. Each file is compared with the preview inside it once (about a second, in the background). Camera Standard is learned for each camera from its matched files, and is used for files whose preview was edited elsewhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Grid") {
                Toggle("Mark edited photos", isOn: $badge)
            }
            Section {
                Text("Edits are kept in the catalog; your original files are never changed. Edited photos' thumbnails, previews and exports show the edits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

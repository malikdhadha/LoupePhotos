import SwiftUI

/// Compare (C), like Lightroom Classic: the Select on the left, the Candidate on the right.
/// ← → bring in another Candidate, ↑ makes the Candidate the Select, ↓ swaps them.
/// Click a side to make it the one your stars, flags and labels go to. Z zooms both to 100% together; drag to look around both.
struct CompareView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @AppStorage("vo.bg") private var bgName = "Black"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                pane(ui.compareSelect, side: 0)
                pane(ui.compareCandidate, side: 1)
            }
            Divider()
            HStack(spacing: 12) {
                Text("Select").fontWeight(.semibold)
                Text(lib.byId[ui.compareSelect ?? -1]?.displayName ?? "—").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { ui.compareSwap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }.help("Swap (↓)")
                Button { ui.compareMakeSelect(lib) } label: { Label("Make Select", systemImage: "arrow.left") }.help("The Candidate becomes the Select (↑)")
                Button { ui.compareZoom.toggle() } label: { Label(ui.compareZoom ? "Fit" : "100%", systemImage: "plus.magnifyingglass") }.help("Zoom both (Z)")
                Spacer()
                Text(lib.byId[ui.compareCandidate ?? -1]?.displayName ?? "—").foregroundStyle(.secondary).lineLimit(1)
                Text("Candidate").fontWeight(.semibold)
                Button("Done") { ui.mode = ui.returnMode; ui.returnMode = .browser }.keyboardShortcut(.cancelAction).hidden().frame(width: 0)
            }
            .controlSize(.small).font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.bar)
        }
    }

    func pane(_ id: Int?, side: Int) -> some View {
        let active = ui.compareActive == side
        return ZStack(alignment: .topLeading) {
            Color(white: ViewOptions.white(bgName))
            if let id, let p = lib.byId[id] {
                CompareImage(photo: p, zoomed: ui.compareZoom, focus: ui.compareFocus) { ui.compareFocus = $0 }
                if ui.viewerInfo > 0 {
                    InfoOverlay(photo: p, fields: ui.viewerInfo == 1 ? ViewOptions.shared.info1 : ViewOptions.shared.info2,
                                light: ViewOptions.white(bgName) > 0.6)
                        .padding(14).allowsHitTesting(false)
                }
                badge(p, side: side).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(10).allowsHitTesting(false)
            } else {
                Text(side == 0 ? "No photo" : "No Candidate — use → to bring one in").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: active ? 2 : 0))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { ui.compareSetActive(side) })
    }
    func badge(_ p: Photo, side: Int) -> some View {
        HStack(spacing: 8) {
            Text(side == 0 ? "SELECT" : "CANDIDATE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            if p.flag { Image(systemName: "flag.fill").foregroundStyle(.orange) }
            if p.rejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            if p.rating > 0 { Text(String(repeating: "★", count: p.rating)).foregroundStyle(.yellow) }
            if let l = PhotoLabel.find(p.label) { Circle().fill(Color(hex: l.hex)).frame(width: 9, height: 9) }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// One side of Compare: fitted, or at 100% around a shared focus point (so both sides show the same spot).
struct CompareImage: View {
    let photo: Photo
    let zoomed: Bool
    let focus: CGPoint
    let onPan: (CGPoint) -> Void
    @Environment(Library.self) private var lib
    @State private var img: NSImage?
    @State private var full: NSImage?
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let i = zoomed ? (full ?? img) : img {
                    if zoomed {
                        let scale = NSScreen.main?.backingScaleFactor ?? 2
                        let ps = pixelSize(i)
                        let w = ps.width / scale, h = ps.height / scale
                        Image(nsImage: i).resizable().interpolation(.high)
                            .frame(width: w, height: h)
                            .position(x: geo.size.width / 2 + (0.5 - focus.x) * w, y: geo.size.height / 2 + (0.5 - focus.y) * h)
                            .gesture(DragGesture()
                                .onChanged { v in
                                    if dragStart == nil { dragStart = focus }
                                    guard let s = dragStart else { return }
                                    onPan(CGPoint(x: min(1, max(0, s.x - v.translation.width / w)), y: min(1, max(0, s.y - v.translation.height / h))))
                                }
                                .onEnded { _ in dragStart = nil })
                    } else {
                        Image(nsImage: i).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .padding(14)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: "\(photo.id)-\(photo.rot)-\(Int(geo.size.width))") {
                if let t = Images.shared.cachedThumb(photo.id) { img = t.rotated(photo.rot) }
                let px = min(3200, Int(max(geo.size.width, geo.size.height) * (NSScreen.main?.backingScaleFactor ?? 2)))
                if let i = await Images.shared.full(photo, lib: lib, maxPixel: px) { img = i.rotated(photo.rot) }
            }
            .task(id: "\(photo.id)-\(photo.rot)-\(zoomed)") {
                guard zoomed, full == nil else { return }
                full = await Images.shared.full1to1(photo)?.rotated(photo.rot)
            }
        }
    }
    func pixelSize(_ i: NSImage) -> CGSize {
        if photo.w > 0, photo.h > 0 { return photo.rot % 2 == 1 ? CGSize(width: photo.h, height: photo.w) : CGSize(width: photo.w, height: photo.h) }
        return i.size
    }
}

/// Survey (N), like Lightroom Classic: several photos fitted on screen at once to pick between.
/// Click one to make it active (keys rate, flag and label it), ✕ or Delete drops it from the survey, double-click opens it.
struct SurveyView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @AppStorage("vo.bg") private var bgName = "Black"
    @State private var hover: Int?

    var body: some View {
        let ps = ui.surveyIds.compactMap { lib.byId[$0] }
        GeometryReader { geo in
            let (cols, rows) = layout(ps, in: geo.size)
            let gap: CGFloat = 10
            let cw = (geo.size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let ch = (geo.size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            ZStack {
                Color(white: ViewOptions.white(bgName))
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(0..<cols, id: \.self) { c in
                                let i = r * cols + c
                                if i < ps.count { tile(ps[i], w: cw, h: ch) } else { Color.clear.frame(width: cw, height: ch) }
                            }
                        }
                    }
                }
                .padding(gap)
            }
        }
    }
    /// The columns × rows that make the photos as big as possible.
    func layout(_ ps: [Photo], in size: CGSize) -> (Int, Int) {
        let n = max(1, ps.count)
        let aspect = ps.isEmpty ? 1.5 : ps.map { $0.aspect }.reduce(0, +) / CGFloat(ps.count)
        var best = (1, n), bestArea: CGFloat = 0
        for cols in 1...n {
            let rows = (n + cols - 1) / cols
            let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
            let w = min(cw, ch * aspect), area = w * (w / aspect)
            if area > bestArea { bestArea = area; best = (cols, rows) }
        }
        return best
    }
    func tile(_ p: Photo, w: CGFloat, h: CGFloat) -> some View {
        let active = ui.primary == p.id
        return ZStack(alignment: .topTrailing) {
            SurveyImage(photo: p, size: CGSize(width: w, height: h - 22))
                .frame(width: w, height: h - 22)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: active ? 3 : 0))
            if hover == p.id {
                Button { ui.surveyDrop(p.id) } label: { Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)) }
                    .buttonStyle(.plain).padding(6).help("Take out of the survey (Delete)")
            }
            HStack(spacing: 6) {
                if p.flag { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                if p.rejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                Text(p.rating > 0 ? String(repeating: "★", count: p.rating) : "☆☆☆☆☆").foregroundStyle(p.rating > 0 ? .yellow : .secondary)
                if let l = PhotoLabel.find(p.label) { Circle().fill(Color(hex: l.hex)).frame(width: 8, height: 8) }
            }
            .font(.caption)
            .frame(width: w, height: 18).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onHover { hover = $0 ? p.id : (hover == p.id ? nil : hover) }
        .onTapGesture(count: 2) { ui.primary = p.id; ui.selection = [p.id]; ui.returnMode = .survey; ui.mode = .viewer }
        .simultaneousGesture(TapGesture().onEnded { ui.primary = p.id; ui.selection = [p.id] })
    }
}

struct SurveyImage: View {
    let photo: Photo
    let size: CGSize
    @Environment(Library.self) private var lib
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            if let img { Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: "\(photo.id)-\(photo.rot)-\(Int(size.width))") {
            if let t = Images.shared.cachedThumb(photo.id) { img = t.rotated(photo.rot) }
            let px = min(3200, Int(max(size.width, size.height) * (NSScreen.main?.backingScaleFactor ?? 2)))
            if px <= 520 { if img == nil, let t = await Images.shared.thumb(photo, lib: lib) { img = t.rotated(photo.rot) }; return }
            if let i = await Images.shared.full(photo, lib: lib, maxPixel: px) { img = i.rotated(photo.rot) }
        }
    }
}

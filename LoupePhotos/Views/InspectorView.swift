import SwiftUI

struct InspectorView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var newKeyword = ""
    @State private var nameDraft = ""
    @State private var captionDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            // Info | Develop — the same as the Develop button at the top of the window
            Picker("", selection: Binding(get: { ui.mode == .develop ? 1 : 0 }, set: { t in
                if t == 1 { if ui.mode != .develop, ui.primaryPhoto(lib) != nil { ui.mode = .develop } }
                else if ui.mode == .develop { ui.mode = ui.developFrom }
            })) {
                Text("Info").tag(0)
                Text("Develop").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if ui.mode == .develop, let p = ui.primaryPhoto(lib) { DevelopPanel(photo: p) } else { infoBody }
        }
    }

    var infoBody: some View {
        let targets = ui.targets(lib)
        return ScrollView {
            if let p = ui.primaryPhoto(lib) {
                VStack(alignment: .leading, spacing: 16) {
                    if targets.count > 1 {
                        Text("\(targets.count) photos selected — changes apply to all of them").font(.callout).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    }
                    field("Name") {
                        TextField(p.fileName, text: $nameDraft).textFieldStyle(.roundedBorder)
                            .onSubmit { lib.setText(p, name: nameDraft) }
                    }
                    field("Rating") {
                        HStack(spacing: 4) {
                            ForEach(1...5, id: \.self) { n in
                                Button { lib.setRating(targets, p.rating == n ? 0 : n) } label: {
                                    Image(systemName: p.rating >= n ? "star.fill" : "star").foregroundStyle(p.rating >= n ? .yellow : .secondary)
                                }.buttonStyle(.plain).help("\(n) star\(n > 1 ? "s" : "") (\(n))")
                            }
                            Spacer()
                            Toggle(isOn: Binding(get: { p.flag }, set: { _ in lib.toggleFlag(targets) })) { Label("Flag", systemImage: "flag") }.toggleStyle(.button)
                            Toggle(isOn: Binding(get: { p.rejected }, set: { _ in lib.toggleReject(targets) })) { Label("Reject", systemImage: "xmark") }.toggleStyle(.button)
                        }
                    }
                    field("Color Label") {
                        HStack(spacing: 8) {
                            ForEach(PhotoLabel.all) { l in
                                Button { lib.setLabel(targets, p.label == l.id ? nil : l.id) } label: {
                                    Circle().fill(Color(hex: l.hex)).frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(.white, lineWidth: p.label == l.id ? 2 : 0))
                                }.buttonStyle(.plain).help(l.name)
                            }
                        }
                    }
                    if FaceScanner.enabled || !FaceIndex.shared.faces(inPhoto: p.id).isEmpty {
                        field("People") { InspectorPeople(photo: p) }
                    }
                    field("Keywords") {
                        FlowLayout(spacing: 6) {
                            ForEach(p.keywords, id: \.self) { k in
                                HStack(spacing: 4) {
                                    Text(k.replacingOccurrences(of: "/", with: " › "))
                                    Button { lib.removeKeyword(targets, k) } label: { Image(systemName: "xmark").imageScale(.small) }.buttonStyle(.plain)
                                }
                                .font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                            }
                        }
                        TextField("Add a keyword (Parent/Child for nesting)", text: $newKeyword).textFieldStyle(.roundedBorder)
                            .onSubmit { lib.addKeyword(targets, newKeyword); newKeyword = "" }
                    }
                    // Smart Keywords: what Apple's scene recognition saw — click one to make it a real keyword
                    let _ = SearchIndex.shared.version
                    if let smart = SearchIndex.shared.labels[p.id]?.filter({ l in !p.keywords.contains { $0.lowercased() == l.lowercased() } }), !smart.isEmpty {
                        field("Smart Keywords") {
                            FlowLayout(spacing: 6) {
                                ForEach(smart, id: \.self) { k in
                                    Button { lib.addKeyword(targets, k.capitalized) } label: {
                                        HStack(spacing: 3) { Image(systemName: "plus").imageScale(.small); Text(k) }
                                            .font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
                                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add “\(k.capitalized)” as a keyword")
                                }
                            }
                        }
                    }
                    field("Caption") {
                        TextField("Add a caption", text: $captionDraft, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                            .onSubmit { lib.setText(p, caption: captionDraft) }
                    }
                    MetadataSection(photo: p, targets: targets)
                    Divider()
                    CameraStrip(photo: p)
                    VStack(alignment: .leading, spacing: 6) {
                        info("Date", p.captureDate.formatted(date: .long, time: .shortened) + (p.dateFromFile ? " (file date)" : ""))
                        if !p.placeLabel.isEmpty { info("Place", p.placeLabel) }
                        info("File", "\(p.fileName) · \(p.ext.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file))\(p.w > 0 ? " · \(p.w) × \(p.h)" : "")")
                        info("Folder", p.dir.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        let inAlbums = lib.albums.filter { $0.ids.contains(p.id) }.map(\.name)
                        info("Albums", inAlbums.isEmpty ? "None" : inAlbums.joined(separator: ", "))
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                    Divider()
                    InspectorMap(photo: p, targets: targets)
                }
                .padding(14)
                .onAppear { nameDraft = p.name; captionDraft = p.caption }
                .onChange(of: p.id) { _, _ in nameDraft = p.name; captionDraft = p.caption; newKeyword = "" }
            } else {
                Text("Select a photo to see its details.").foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
            }
        }
    }

    func field<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).tracking(0.6)
            c()
        }
    }
    func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Each tag is measured once per layout pass (in makeCache, while SwiftUI is laying out),
    /// not again while placing — measuring outside the pass is what Xcode warned about.
    struct Cache { var sizes: [CGSize] }
    func makeCache(subviews: Subviews) -> Cache { Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for z in cache.sizes { if x + z.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }; x += z.width + spacing; row = max(row, z.height) }
        return CGSize(width: w, height: cache.sizes.isEmpty ? 0 : y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for (s, z) in zip(subviews, cache.sizes) {
            if x + z.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z)); x += z.width + spacing; row = max(row, z.height)
        }
    }
}


/// The Inspector's People row (like Apple Photos' Info): a circle for each face; click to name or open; + to add someone.
struct InspectorPeople: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var idx = FaceIndex.shared
    @State private var editing: Int?          // face being named; −1 = adding someone with +
    @State private var text = ""
    var body: some View {
        let fs = idx.faces(inPhoto: photo.id).sorted { $0.rect.minX < $1.rect.minX }
        FlowLayout(spacing: 8) {
            ForEach(fs, id: \.id) { f in
                let name = f.person.flatMap { idx.people[$0]?.name }
                Button {
                    if let pid = f.person { ui.personAll = true; ui.source = .person(pid); ui.mode = .browser }
                    else { text = ""; editing = f.id }
                } label: {
                    ZStack {
                        if f.rect == .zero, let p = f.person.flatMap({ idx.people[$0] }) { FaceCircle(faceId: idx.keyFace(p), size: 34) }
                        else { FaceCircle(faceId: f.id, size: 34) }
                        if name == nil { Circle().fill(.black.opacity(0.35)).frame(width: 34, height: 34); Text("?").font(.headline).foregroundStyle(.white) }
                    }
                    .opacity(name == nil && idx.isQuiet(f) ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .help(name ?? "Who is this? Click to name")
                .contextMenu {
                    if let pid = f.person, let n = name {
                        Button("Show \(n)'s Photos") { ui.personAll = true; ui.source = .person(pid); ui.mode = .browser }
                        Button("Rename This Face…") { text = n; editing = f.id }
                        Button("This Isn't \(n)") { idx.remove(photos: [photo.id], from: pid, lib: lib) }
                        if f.rect != .zero { Button("Make Key Photo for \(n)") { idx.setKeyFace(f.id, lib: lib) } }
                    } else {
                        Button("Name This Face…") { text = ""; editing = f.id }
                        if idx.hiddenFaces.contains(f.id) { Button("Show This Face in People") { idx.hide(faces: [f.id], false, lib: lib) } }
                        else if f.rect != .zero { Button("Hide This Face") { idx.hide(faces: [f.id], true, lib: lib) } }
                    }
                }
                .popover(isPresented: Binding(get: { editing == f.id }, set: { if !$0 { editing = nil } })) {
                    namer { n in idx.setFace(f.id, toName: n, lib: lib) }
                }
            }
            Button { text = ""; editing = -1 } label: {
                Image(systemName: "plus").frame(width: 34, height: 34).background(Circle().stroke(.secondary.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain).help("Add someone who's in this photo")
            .popover(isPresented: Binding(get: { editing == -1 }, set: { if !$0 { editing = nil } })) {
                namer { n in idx.addManual(n, photo: photo, lib: lib) }
            }
        }
    }
    func namer(_ done: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who is this?").font(.headline)
            NameField(text: $text, prompt: "Name") { n in
                guard !n.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                done(n); editing = nil
            }
            .frame(width: 220)
        }
        .padding(12)
    }
}

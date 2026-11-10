import SwiftUI

/// Aperture's List view: one row per photo with its details in columns.
/// Right-click a column header to show or hide columns; drag headers to reorder them.
struct PhotoListView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var columns = PhotoListView.loadColumns()

    var body: some View {
        let list = ui.visible(lib)
        ScrollViewReader { proxy in
            Table(list, selection: selection(list), columnCustomization: $columns) {
                firstColumns
                moreColumns
            }
            .contextMenu(forSelectionType: Photo.ID.self) { ids in
                if let id = ids.first, let p = lib.byId[id] { PhotoMenu(photo: p).environment(lib).environment(ui) }   // menus don't inherit the environment
            } primaryAction: { ids in
                // double-click opens the photo in the Viewer, like the grid
                guard let id = ids.first else { return }
                ui.primary = id; ui.mode = .viewer; ui.refocus += 1
            }
            .onAppear {
                ui.columns = 1                                   // ↑ ↓ move one row at a time
                if let p = ui.primary { proxy.scrollTo(p, anchor: .center) }
            }
            .onChange(of: ui.primary) { _, p in if let p { proxy.scrollTo(p) } }
            .onChange(of: columns) { _, c in PhotoListView.saveColumns(c) }
        }
    }

    private func selection(_ list: [Photo]) -> Binding<Set<Int>> {
        Binding(get: { ui.selection }, set: { pick($0, list) })
    }

    @TableColumnBuilder<Photo, Never>
    private var firstColumns: some TableColumnContent<Photo, Never> {
        TableColumn("") { (p: Photo) in ListThumb(photo: p, lib: lib) }
            .width(34).customizationID("thumb").disabledCustomizationBehavior(.visibility)
        TableColumn("Name") { (p: Photo) in Text(p.displayName).lineLimit(1) }
            .width(min: 120, ideal: 220).customizationID("name").disabledCustomizationBehavior(.visibility)
        TableColumn("Date") { (p: Photo) in Text(Self.dateText(p)).monospacedDigit() }
            .width(min: 110, ideal: 150).customizationID("date")
        TableColumn("Rating") { (p: Photo) in Text(Self.stars(p)).foregroundStyle(.yellow) }
            .width(min: 50, ideal: 66).customizationID("rating")
        TableColumn("Flag") { (p: Photo) in FlagMark(photo: p) }
            .width(34).customizationID("flag")
        TableColumn("Label") { (p: Photo) in LabelDot(photo: p) }
            .width(40).customizationID("label")
    }

    @TableColumnBuilder<Photo, Never>
    private var moreColumns: some TableColumnContent<Photo, Never> {
        TableColumn("Camera") { (p: Photo) in Text(p.camera).lineLimit(1) }
            .width(min: 80, ideal: 120).customizationID("camera")
        TableColumn("Lens") { (p: Photo) in Text(p.lens).lineLimit(1) }
            .width(min: 80, ideal: 150).customizationID("lens").defaultVisibility(.hidden)
        TableColumn("Pixels") { (p: Photo) in Text(Self.pixels(p)).monospacedDigit() }
            .width(min: 80, ideal: 96).customizationID("pixels")
        TableColumn("File Size") { (p: Photo) in Text(Self.fileSize(p)).monospacedDigit() }
            .width(min: 60, ideal: 72).customizationID("size")
        TableColumn("Type") { (p: Photo) in Text(SmartRule.kind(p)) }
            .width(min: 40, ideal: 50).customizationID("type")
        TableColumn("Place") { (p: Photo) in Text(p.placeLabel).lineLimit(1) }
            .width(min: 80, ideal: 160).customizationID("place")
        TableColumn("Keywords") { (p: Photo) in Text(Self.keywordText(p)).lineLimit(1) }
            .width(min: 80, ideal: 180).customizationID("keywords").defaultVisibility(.hidden)
    }

    static func dateText(_ p: Photo) -> String { p.captureDate.formatted(date: .abbreviated, time: .shortened) }
    static func stars(_ p: Photo) -> String { p.rating > 0 ? String(repeating: "★", count: p.rating) : "" }
    static func pixels(_ p: Photo) -> String { p.w > 0 ? "\(p.w) × \(p.h)" : "" }
    static func fileSize(_ p: Photo) -> String { ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file) }
    static func keywordText(_ p: Photo) -> String { p.keywords.joined(separator: ", ") }

    /// Keeps the "current photo" in step with what you click in the table.
    private func pick(_ ids: Set<Int>, _ list: [Photo]) {
        ui.selection = ids
        if let p = ui.primary, ids.contains(p) { return }
        ui.primary = ids.count == 1 ? ids.first : list.first { ids.contains($0.id) }?.id
    }

    static func loadColumns() -> TableColumnCustomization<Photo> {
        guard let d = UserDefaults.standard.data(forKey: "listColumns"),
              let c = try? JSONDecoder().decode(TableColumnCustomization<Photo>.self, from: d) else { return TableColumnCustomization<Photo>() }
        return c
    }
    static func saveColumns(_ c: TableColumnCustomization<Photo>) {
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "listColumns") }
    }
}

/// The small thumbnail at the start of each row.
struct ListThumb: View {
    let photo: Photo
    let lib: Library                 // passed in: table cells can't always see the environment
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
            else { Rectangle().fill(.quaternary) }
        }
        .frame(width: 26, height: 20)
        .task(id: "\(photo.id)-\(photo.rot)") {
            if let c = Images.shared.cachedThumb(photo.id) { img = c.rotated(photo.rot); return }
            img = await Images.shared.thumb(photo, lib: lib)?.rotated(photo.rot)
        }
    }
}

struct FlagMark: View {
    let photo: Photo
    var body: some View {
        if photo.rejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
        else if photo.flag { Image(systemName: "flag.fill").foregroundStyle(.orange) }
    }
}

struct LabelDot: View {
    let photo: Photo
    var body: some View {
        if let l = PhotoLabel.find(photo.label) { Circle().fill(Color(hex: l.hex)).frame(width: 9, height: 9) }
    }
}

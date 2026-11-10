import SwiftUI

/// Split view, above the filmstrip: rotate, flag, reject, stars and colour labels for the selected photos.
struct PhotoActionBar: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui

    var body: some View {
        let t = ui.targets(lib), p = ui.primaryPhoto(lib)
        HStack(spacing: 12) {
            ControlGroup {
                Button { lib.rotate(t, -1) } label: { Image(systemName: "rotate.left") }.help("Rotate left ([)")
                Button { lib.rotate(t, 1) } label: { Image(systemName: "rotate.right") }.help("Rotate right (])")
            }
            .frame(width: 64)
            Divider().frame(height: 16)
            Button { lib.toggleFlag(t) } label: { Image(systemName: p?.flag == true ? "flag.fill" : "flag") }
                .foregroundStyle(p?.flag == true ? Color.orange : Color.secondary).buttonStyle(.borderless).help("Pick / flag (T)")
            Button { lib.toggleReject(t) } label: { Image(systemName: p?.rejected == true ? "xmark.circle.fill" : "xmark.circle") }
                .foregroundStyle(p?.rejected == true ? Color.red : Color.secondary).buttonStyle(.borderless).help("Reject (X) · U clears")
            Divider().frame(height: 16)
            StarPicker(value: p?.rating ?? 0) { n in lib.setRating(t, n == p?.rating ? 0 : n) }
            Divider().frame(height: 16)
            HStack(spacing: 5) {
                ForEach(PhotoLabel.all) { l in
                    Button { lib.setLabel(t, p?.label == l.id ? nil : l.id) } label: {
                        Circle().fill(Color(hex: l.hex)).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.primary, lineWidth: p?.label == l.id ? 2 : 0).padding(-2))
                    }
                    .buttonStyle(.plain).help({ let i = PhotoLabel.all.firstIndex { $0.id == l.id }!; return i < 4 ? "\(l.name) label (\(i + 6))" : "\(l.name) label (⌥\(i + 1))" }())
                }
            }
            Divider().frame(height: 16)
            Button { ui.loupe.toggle() } label: { Image(systemName: ui.loupe ? "magnifyingglass.circle.fill" : "magnifyingglass.circle") }
                .foregroundStyle(ui.loupe ? Color.accentColor : Color.secondary).buttonStyle(.borderless)
                .help("Loupe (L): 100% under the pointer · scroll to resize · hold ⌥ for 200%")
            Spacer()
            let n = ui.visible(lib).count
            Text("\(ui.selection.count) selected · \(n.formatted()) displayed").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
        .disabled(p == nil)
    }
}

/// Five clickable stars.
struct StarPicker: View {
    let value: Int
    let set: (Int) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                Button { set(n) } label: { Image(systemName: n <= value ? "star.fill" : "star") }
                    .buttonStyle(.plain).foregroundStyle(n <= value ? Color.yellow : Color.secondary).help("\(n) star\(n == 1 ? "" : "s") (\(n))")
            }
        }
    }
}

/// Split view, below the filmstrip: sort order and quick filters (flagged, minimum stars, colour labels).
/// It drives the Library Filter's Attribute part, so both always agree.
struct QuickFilterBar: View {
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let on = ui.lf.tabs.contains(.attribute)
        HStack(spacing: 12) {
            Text("Sort:").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $ui.sort) { ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().fixedSize()
            Divider().frame(height: 16)
            Text("Show:").font(.caption).foregroundStyle(.secondary)
            Button { change { $0.flagged.toggle() } } label: { Image(systemName: on && ui.lf.flagged ? "flag.fill" : "flag") }
                .buttonStyle(.borderless).foregroundStyle(on && ui.lf.flagged ? Color.orange : Color.secondary).help("Only flagged photos")
            StarPicker(value: on ? ui.lf.minRating : 0) { n in change { $0.minRating = $0.minRating == n ? 0 : n } }
                .help("Only photos with at least this many stars")
            HStack(spacing: 4) {
                ForEach(PhotoLabel.all) { l in
                    Button { change { if $0.labels.contains(l.id) { $0.labels.remove(l.id) } else { $0.labels.insert(l.id) } } } label: {
                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: l.hex)).frame(width: 12, height: 12)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary, lineWidth: on && ui.lf.labels.contains(l.id) ? 2 : 0).padding(-2))
                    }
                    .buttonStyle(.plain).help("Only \(l.name.lowercased())-labelled photos")
                }
            }
            Spacer()
            if active {
                Button("Show All") { change { $0.flagged = false; $0.minRating = 0; $0.labels = [] } }.help("Clear these filters")
            } else {
                Text("Showing All").font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    var active: Bool { ui.lf.tabs.contains(.attribute) && (ui.lf.flagged || ui.lf.minRating > 0 || !ui.lf.labels.isEmpty) }

    /// Changes the attribute filter and switches it on (or off again when nothing is set).
    func change(_ f: (inout LibraryFilter) -> Void) {
        var lf = ui.lf
        f(&lf)
        if lf.flagged || lf.minRating > 0 || !lf.labels.isEmpty { lf.tabs.insert(.attribute) } else { lf.tabs.remove(.attribute) }
        ui.lf = lf
    }
}

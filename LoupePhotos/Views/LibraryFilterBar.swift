import SwiftUI

/// Lightroom Classic's Library Filter bar, in Aperture's graphite.
struct LibraryFilterBar: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Library Filter:").foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(FilterTab.allCases) { t in
                        tabButton(t.rawValue, on: ui.lf.tabs.contains(t)) {
                            if NSEvent.modifierFlags.contains(.shift) { if ui.lf.tabs.contains(t) { ui.lf.tabs.remove(t) } else { ui.lf.tabs.insert(t) } }
                            else { ui.lf.tabs = ui.lf.tabs == [t] ? [] : [t] }
                        }
                        Text("⋮").foregroundStyle(.tertiary).font(.system(size: 11))
                    }
                    tabButton("None", on: ui.lf.tabs.isEmpty) { ui.lf.tabs = []; ui.showFilterBar = false }   // None = filter off and the bar away
                }
                Spacer()
                Text(ui.lf.isActive ? "Custom Filter" : "No Filter").foregroundStyle(.secondary).font(.system(size: 12))
                if ui.lf.isActive {
                    Button { ui.lf = LibraryFilter(tabs: ui.lf.tabs, columns: ui.lf.columns) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6).help("Clear the filter")
                }
            }
            .padding(.horizontal, 12).frame(height: 30)
            if ui.lf.tabs.contains(.text) {
                Divider()
                HStack {
                    Text("Text").foregroundStyle(.secondary)
                    TextField("Any searchable field · !word excludes", text: $ui.lf.text).textFieldStyle(.roundedBorder).frame(maxWidth: 460)
                }
                .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 6)
            }
            if ui.lf.tabs.contains(.attribute) {
                Divider()
                HStack(spacing: 14) {
                    Text("Attribute").foregroundStyle(.secondary)
                    Toggle(isOn: $ui.lf.flagged) { Label("Flagged", systemImage: "flag.fill") }.toggleStyle(.button).controlSize(.small)
                    HStack(spacing: 2) {
                        Text("Rating ≥").foregroundStyle(.secondary)
                        ForEach(1...5, id: \.self) { n in
                            Button { ui.lf.minRating = ui.lf.minRating == n ? 0 : n } label: {
                                Image(systemName: ui.lf.minRating >= n ? "star.fill" : "star").foregroundStyle(ui.lf.minRating >= n ? .yellow : .secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 5) {
                        Text("Color").foregroundStyle(.secondary)
                        ForEach(PhotoLabel.all) { l in
                            Button { if ui.lf.labels.contains(l.id) { ui.lf.labels.remove(l.id) } else { ui.lf.labels.insert(l.id) } } label: {
                                RoundedRectangle(cornerRadius: 3).fill(Color(hex: l.hex)).frame(width: 16, height: 13)
                                    .opacity(ui.lf.labels.isEmpty || ui.lf.labels.contains(l.id) ? 1 : 0.4)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white, lineWidth: ui.lf.labels.contains(l.id) ? 2 : 0))
                            }.buttonStyle(.plain).help(l.name)
                        }
                    }
                    Spacer()
                }
                .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 6)
            }
            if ui.lf.tabs.contains(.metadata) {
                Divider()
                let base = ui.lf.base(ui.sourceList(lib))
                HStack(spacing: 0) {
                    ForEach(ui.lf.columns.indices, id: \.self) { i in
                        MetaColumnView(index: i, base: base)
                        if i < ui.lf.columns.count - 1 { Divider() }
                    }
                }
                .frame(height: 190)
            }
        }
        .background(.bar)
    }

    func tabButton(_ t: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 12, weight: on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(on ? Color.primary.opacity(0.14) : .clear, in: Capsule())
                .foregroundStyle(on ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(t == "None" ? "Turn the filter off and hide this bar" : "Show \(t) (⇧-click to combine)")
    }
}

struct MetaColumnView: View {
    let index: Int
    let base: [Photo]
    @Environment(UIState.self) private var ui

    var body: some View {
        let col = ui.lf.columns[index]
        let r = ui.lf.rows(index, from: base, expanded: ui.lfExpanded)
        let picks = ui.lf.picks[index]
        VStack(spacing: 0) {
            HStack {
                Text(col.rawValue).font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(MetaColumn.allCases) { c in
                        Button { ui.lf.columns[index] = c; ui.lf.picks[index] = [] } label: { if c == col { Label(c.rawValue, systemImage: "checkmark") } else { Text(c.rawValue) } }
                    }
                } label: { Image(systemName: "line.3.horizontal") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Change this column")
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color.primary.opacity(0.06))
            ScrollView {
                LazyVStack(spacing: 0) {
                    row(id: "", title: "All (\(r.distinct) \(plural(col, r.distinct)))", count: r.total, level: 0, expandable: false, on: picks.isEmpty)
                    ForEach(r.rows) { x in row(id: x.id, title: x.title, count: x.count, level: x.level, expandable: x.expandable, on: picks.contains(x.id)) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    func row(id: String, title: String, count: Int, level: Int, expandable: Bool, on: Bool) -> some View {
        HStack(spacing: 4) {
            if expandable {
                Button { if ui.lfExpanded.contains(id) { ui.lfExpanded.remove(id) } else { ui.lfExpanded.insert(id) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(ui.lfExpanded.contains(id) ? 90 : 0))
                        .frame(width: 12)
                }.buttonStyle(.plain).foregroundStyle(on ? .white : .secondary)
            } else if level > 0 { Spacer().frame(width: 12) }
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(count.formatted()).monospacedDigit().foregroundStyle(on ? .white.opacity(0.8) : .secondary)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 8 + CGFloat(level) * 14).padding(.trailing, 10)
        .frame(height: 21)
        .background(on ? Color.accentColor : .clear)
        .foregroundStyle(on ? .white : .primary)
        .contentShape(Rectangle())
        .onTapGesture {
            var p = ui.lf.picks[index]
            if id.isEmpty { p = [] }
            else if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { if p.contains(id) { p.remove(id) } else { p.insert(id) } }
            else { p = p == [id] ? [] : [id] }
            ui.lf.picks[index] = p
        }
        .onTapGesture(count: 2) { if expandable { if ui.lfExpanded.contains(id) { ui.lfExpanded.remove(id) } else { ui.lfExpanded.insert(id) } } }
    }

    func plural(_ c: MetaColumn, _ n: Int) -> String {
        let w: String
        switch c { case .date: w = "Year"; case .camera: w = "Camera"; case .lens: w = n == 1 ? "Lens" : "Lenses"; case .label: w = "Label"; case .rating: w = "Rating"; case .flag: w = "Flag"; case .keyword: w = "Keyword"; case .fileType: w = "Type"; case .folder: w = "Folder"; case .country: w = n == 1 ? "Country" : "Countries"; case .city: w = n == 1 ? "City" : "Cities"; case .people: w = n == 1 ? "Person" : "People" }
        return n == 1 || w.hasSuffix("s") ? w : w + "s"
    }
}

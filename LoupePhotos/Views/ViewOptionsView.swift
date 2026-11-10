import SwiftUI

/// View ▸ View Options… (⌘J): Grid and Viewer tabs, like Lightroom Classic's Library View Options.
struct ViewOptionsView: View {
    @State private var o = ViewOptions.shared
    @AppStorage("showInfo") private var showInfo = true
    @AppStorage("detailedCells") private var detailed = false
    @AppStorage("vo.tab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { Text("Grid View").tag(0); Text("Viewer").tag(1) }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 12)
            Form { if tab == 0 { grid } else { viewer } }.formStyle(.grouped)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    var cells: Binding<Int> {
        Binding(get: { detailed ? 2 : showInfo ? 1 : 0 },
                set: { v in showInfo = v > 0; detailed = v == 2; Self.sync(showInfo, detailed) })
    }
    /// UIState keeps its own copies of these two; keep them in step.
    static func sync(_ info: Bool, _ det: Bool) { NotificationCenter.default.post(name: .gridCellsChanged, object: (info, det)) }

    @ViewBuilder var grid: some View {
        Section {
            Picker("Show on thumbnails", selection: cells) {
                Text("Nothing").tag(0); Text("Badges (stars, flag, label)").tag(1); Text("Detailed cells").tag(2)
            }
            Text("J cycles through these.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Options") {
            Toggle("Show clickable items on mouse-over only", isOn: $o.hoverOnly)
            HStack {
                Toggle("Tint grid cells with label colors", isOn: $o.tintLabels)
                Spacer()
                Picker("", selection: $o.tintPercent) { ForEach([10, 20, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) } }
                    .labelsHidden().fixedSize().disabled(!o.tintLabels)
            }
            Toggle("Show image info tooltips", isOn: $o.tooltips)
            Toggle("Show a map pin on photos with a location", isOn: $o.geotagBadge)
        }
        Section("Detailed cells") {
            Toggle("Index number", isOn: $o.showIndex)
            Toggle("Pixel size", isOn: $o.showDims)
            Toggle("File type", isOn: $o.showType)
            Toggle("Rotation buttons", isOn: $o.showRotate)
            Toggle("Color label", isOn: $o.showLabelDot)
        }
    }

    @ViewBuilder var viewer: some View {
        Section {
            Picker("Background", selection: $o.background) { ForEach(ViewOptions.backgrounds, id: \.0) { Text($0.0).tag($0.0) } }
            Text("For the Viewer and Split. The rest of the app follows your Mac's Light or Dark setting.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Info 1") { fieldPickers($o.info1) }
        Section("Info 2") { fieldPickers($o.info2) }
        Section { Text("I shows Info 1, then Info 2, then nothing.").font(.caption).foregroundStyle(.secondary) }
    }
    func fieldPickers(_ b: Binding<[InfoField]>) -> some View {
        ForEach(0..<3, id: \.self) { i in
            Picker(["Top line", "Second line", "Third line"][i], selection: Binding(get: { b.wrappedValue[i] }, set: { b.wrappedValue[i] = $0 })) {
                ForEach(InfoField.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }
}

extension Notification.Name { static let gridCellsChanged = Notification.Name("gridCellsChanged") }

/// The Background Tasks button beside the window title: shows what's running; click for the list with pause / resume.
struct ActivityButton: View {
    @State private var a = Activity.shared
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                if let s = a.summary {
                    ProgressView(value: a.jobs.first(where: { !$0.paused })?.fraction ?? 0).progressViewStyle(.circular).controlSize(.mini)
                    Text(s).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .help("Background tasks")
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }
    var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background Tasks").font(.headline)
            if a.jobs.isEmpty {
                Text("Nothing running. Thumbnails, previews, place names, imports and syncs show here while they work.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(a.jobs) { j in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(j.title); Spacer(); Text(j.detail).foregroundStyle(.secondary).monospacedDigit() }.font(.callout)
                        ProgressView(value: j.fraction).controlSize(.small)
                    }
                    if j.canPause {
                        Button { a.togglePause(j.id) } label: { Image(systemName: j.paused ? "play.fill" : "pause.fill") }
                            .buttonStyle(.borderless).help(j.paused ? "Resume" : "Pause")
                    }
                }
            }
            if a.jobs.contains(where: \.canPause) {
                Divider()
                HStack {
                    Button("Pause All") { a.pauseAll(true) }
                    Button("Resume All") { a.pauseAll(false) }
                }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

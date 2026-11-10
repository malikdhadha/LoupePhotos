import SwiftUI

/// File ▸ Export ▸ Photos… (⇧⌘E)
struct ExportView: View {
    let targets: [Photo]
    @Environment(\.dismiss) private var dismiss
    @State private var ex = Exporter.shared
    @State private var presetName = ""
    @State private var naming = false
    var body: some View {
        @Bindable var ex = ex
        HStack(spacing: 0) {
            // presets
            VStack(alignment: .leading, spacing: 0) {
                Text("Presets").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding([.top, .horizontal], 12)
                List {
                    ForEach(ex.all) { p in
                        HStack {
                            Text(p.name).lineLimit(1)
                            Spacer()
                            if ex.presets.contains(where: { $0.id == p.id }) {
                                Button { ex.deletePreset(p.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Delete this preset")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { ex.use(p) }
                    }
                }
                .listStyle(.sidebar)
                HStack {
                    if naming {
                        TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                            .onSubmit { if !presetName.isEmpty { ex.savePreset(presetName) }; presetName = ""; naming = false }
                    } else {
                        Button("Save Settings as Preset…") { naming = true }.buttonStyle(.borderless)
                    }
                }.padding(10)
            }
            .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                Form {
                    Section("File") {
                        Picker("Format", selection: $ex.current.format) { ForEach(ExportSettings.Format.allCases) { Text($0 == .original ? "Original file" : $0.rawValue).tag($0) } }
                        if ex.current.format == .jpeg || ex.current.format == .heic {
                            HStack { Text("Quality"); Slider(value: $ex.current.quality, in: 0.4...1); Text("\(Int(ex.current.quality * 100))%").monospacedDigit().frame(width: 40) }
                        }
                        if ex.current.format == .original {
                            Toggle("Include .xmp sidecars (made from the catalog when there isn't one)", isOn: $ex.current.sidecars)
                        }
                    }
                    if ex.current.format != .original {
                        Section("Size") {
                            Picker("Size", selection: $ex.current.size) { ForEach(ExportSettings.Size.allCases) { Text($0.rawValue).tag($0) } }
                            if ex.current.size != .full {
                                TextField(ex.current.size == .longEdge ? "Pixels" : ex.current.size == .megapixels ? "Megapixels" : "Percent", value: $ex.current.sizeValue, format: .number)
                            }
                            Picker("Colour space", selection: $ex.current.space) { ForEach(ExportSettings.Space.allCases) { Text($0.rawValue).tag($0) } }
                            Toggle("Sharpen for screen (when made smaller)", isOn: $ex.current.sharpen)
                        }
                    }
                    Section("Names") {
                        Toggle("Rename", isOn: $ex.current.rename)
                        if ex.current.rename {
                            TextField("Template", text: $ex.current.template)
                            Text("{name} {title} {date} {time} {seq} {camera} — e.g. “{date} Beach {seq}” → 2026-11-09 Beach 001").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Metadata") {
                        Picker("Include", selection: $ex.current.meta) { ForEach(ExportSettings.Meta.allCases) { Text($0.rawValue).tag($0) } }
                        Toggle("Remove location", isOn: $ex.current.removeLocation).disabled(ex.current.meta == .none)
                        Toggle("Remove people's names", isOn: $ex.current.removePeople).disabled(ex.current.meta == .none)
                    }
                    if ex.current.format != .original {
                        Section("Watermark") {
                            Toggle("Add a copyright watermark", isOn: $ex.current.watermark)
                            if ex.current.watermark {
                                TextField("Text", text: $ex.current.watermarkText, prompt: Text(Identity.value(.copyright).isEmpty ? "© 2026 Your Name" : Identity.value(.copyright)))
                            }
                        }
                    }
                    Section("Where") {
                        HStack {
                            Text(ex.current.destination.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary).help(ex.current.destination)
                            Spacer()
                            Button("Choose…") { choose() }
                        }
                        Picker("Put them", selection: $ex.current.subfolder) { ForEach(ExportSettings.Folder.allCases) { Text($0.rawValue).tag($0) } }
                        Toggle("Show in Finder when done", isOn: $ex.current.reveal)
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Text("\(targets.count.formatted()) photo\(targets.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export") { Exporter.shared.export(targets, ex.current); dismiss() }.keyboardShortcut(.defaultAction).disabled(targets.isEmpty)
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 640)
    }
    func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Choose"
        p.message = "Where should the exported photos go?"
        if p.runModal() == .OK, let u = p.url { ex.current.destination = u.path }
    }
}

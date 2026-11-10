import SwiftUI

/// Metadata ▸ Batch Change… (⇧⌘B): a preset, a caption, keywords and the capture time, for every selected photo at once.
struct BatchChangeView: View {
    let targets: [Photo]
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var presetId = ""
    @State private var replace = false
    @State private var caption = ""
    @State private var captionMode = 0          // 0 leave, 1 set, 2 add to the end
    @State private var keywords = ""
    @State private var timeMode = 0             // 0 leave, 1 shift, 2 set the first photo's time
    @State private var hours = 0
    @State private var minutes = 0
    @State private var newDate = Date()
    var body: some View {
        let presets = MetadataPresets.shared.all
        VStack(alignment: .leading, spacing: 0) {
            Text("Batch Change \(targets.count.formatted()) Photo\(targets.count == 1 ? "" : "s")").font(.title3.weight(.semibold)).padding([.horizontal, .top], 18)
            Form {
                Section("Metadata preset") {
                    Picker("Preset", selection: $presetId) {
                        Text("None").tag("")
                        ForEach(presets) { Text($0.name).tag($0.id) }
                    }
                    Picker("", selection: $replace) {
                        Text("Append (fill empty fields only)").tag(false)
                        Text("Replace (overwrite fields)").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden().disabled(presetId.isEmpty)
                }
                Section("Caption") {
                    Picker("", selection: $captionMode) { Text("Leave as is").tag(0); Text("Set to").tag(1); Text("Add to the end").tag(2) }
                        .pickerStyle(.segmented).labelsHidden()
                    if captionMode > 0 { TextField("Caption", text: $caption, axis: .vertical).lineLimit(2...4) }
                }
                Section("Keywords") {
                    TextField("Add keywords (comma separated)", text: $keywords)
                }
                Section("Date & time") {
                    Picker("", selection: $timeMode) { Text("Leave as is").tag(0); Text("Shift by").tag(1); Text("Set the first photo to").tag(2) }
                        .pickerStyle(.segmented).labelsHidden()
                    if timeMode == 1 {
                        Stepper("Hours: \(hours >= 0 ? "+" : "")\(hours)", value: $hours, in: -48...48)
                        Stepper("Minutes: \(minutes >= 0 ? "+" : "")\(minutes)", value: $minutes, in: -59...59)
                        Text("For a camera clock that was wrong, or set to another time zone.").font(.caption).foregroundStyle(.secondary)
                    } else if timeMode == 2 {
                        DatePicker("First photo", selection: $newDate, displayedComponents: [.date, .hourAndMinute])
                        Text("The others move by the same amount, keeping their spacing.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 580)
        .onAppear { if let first = targets.min(by: { $0.date < $1.date }) { newDate = first.captureDate } }
    }
    func apply() {
        if let pr = MetadataPresets.shared.preset(presetId) { lib.setIPTC(targets, pr.values, replace: replace) }
        if captionMode == 1 { lib.setIPTC(targets, ["caption": caption], replace: true) }
        if captionMode == 2, !caption.isEmpty {
            for p in targets { p.caption = p.caption.isEmpty ? caption : p.caption + " " + caption }
            lib.changed(targets, ["caption"])
        }
        if !keywords.trimmingCharacters(in: .whitespaces).isEmpty { lib.setIPTC(targets, ["keywords": keywords], replace: false) }
        switch timeMode {
        case 1: lib.shiftDates(targets, by: Double(hours * 3600 + minutes * 60))
        case 2:
            if let first = targets.min(by: { $0.date < $1.date }) { lib.shiftDates(targets, by: newDate.timeIntervalSince(first.captureDate).rounded()) }
        default: break
        }
    }
}

/// Metadata ▸ Manage Presets…: make, edit and delete presets (any IPTC field, plus caption and keywords).
struct PresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = MetadataPresets.shared
    @State private var selected: String?
    @State private var draft: MetadataPresets.Preset?
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.presets) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button { let p = MetadataPresets.Preset(name: "New Preset", values: Identity.values); store.save(p); selected = p.id } label: { Image(systemName: "plus") }
                    Button { if let s = selected { store.delete(s); selected = nil; draft = nil } } label: { Image(systemName: "minus") }.disabled(selected == nil)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading) {
                if draft != nil {
                    Form {
                        TextField("Name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
                        Section("Caption and keywords") {
                            TextField("Caption", text: binding("caption"), axis: .vertical).lineLimit(1...3)
                            TextField("Keywords (comma separated)", text: binding("keywords"))
                        }
                        ForEach(IPTCField.Group.allCases, id: \.self) { g in
                            Section(g.rawValue) {
                                ForEach(IPTCField.allCases.filter { $0.group == g }) { f in TextField(f.label, text: binding(f.rawValue)) }
                            }
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    Text("Choose a preset, or + to make one.\n“My Identity” comes from Settings ▸ Metadata.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack { Spacer(); Button("Done") { save(); dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
            }
        }
        .frame(width: 640, height: 560)
        .onChange(of: selected) { old, new in
            save()
            draft = new.flatMap { id in store.presets.first { $0.id == id } }
        }
    }
    func binding(_ k: String) -> Binding<String> {
        Binding(get: { draft?.values[k] ?? "" }, set: { v in if v.isEmpty { draft?.values.removeValue(forKey: k) } else { draft?.values[k] = v } })
    }
    func save() { if let d = draft { store.save(d) } }
}

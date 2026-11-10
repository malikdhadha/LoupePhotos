import SwiftUI
import AppKit

/// File ▸ Import… — cards and folders on the left, their photos in the middle (already-imported ones dimmed),
/// where and how on the right. Everything on the right is optional and remembered.
struct ImportView: View {
    @State private var imp = Importer.shared
    @State private var lib = Library.shared
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        HStack(spacing: 0) {
            sources.frame(width: 210)
            Divider()
            middle.frame(minWidth: 460, maxWidth: .infinity)
            Divider()
            options.frame(width: 300)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .onAppear { imp.previewsFromSettings(); imp.startWatching(); imp.refreshCards(); if imp.current == nil, let c = imp.cards.first { imp.choose(c) } }
        .onReceive(NotificationCenter.default.publisher(for: .importFinished)) { n in
            guard (n.userInfo?["close"] as? Bool) == true else { return }
            dismissWindow(id: "import")
            if let main = NSApp.windows.first(where: { $0.title == "Loupe Photos" }) {
                if main.isMiniaturized { main.deminiaturize(nil) }
                main.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: left — where from
    var sources: some View {
        List(selection: Binding(get: { imp.current?.id }, set: { id in
            if let s = (imp.cards + imp.folders).first(where: { $0.id == id }) { imp.choose(s) }
        })) {
            Section("Memory Cards") {
                if imp.cards.isEmpty {
                    Text("Insert a card — it appears here.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(imp.cards) { c in Label(c.name, systemImage: "sdcard").tag(c.id) }
            }
            Section("Folders") {
                ForEach(imp.folders) { f in Label(f.name, systemImage: f.kind == .files ? "doc.on.doc" : "folder").tag(f.id).help(f.kind == .files ? "Chosen or dragged in" : f.url.path) }
                Button { imp.addFolder() } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                Button { imp.chooseFiles() } label: { Label("Choose Files…", systemImage: "doc.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("One photo or a handful — or drag photos and folders from Finder onto Loupe Photos")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: middle — the photos
    var shown: [Importer.Item] { imp.hideImported ? imp.items.filter { !$0.imported } : imp.items }
    var days: [(day: String, items: [Importer.Item])] {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
        var out: [(String, [Importer.Item])] = []
        for it in shown {
            let d = f.string(from: it.date)
            if out.last?.0 == d { out[out.count - 1].1.append(it) } else { out.append((d, [it])) }
        }
        return out.map { (day: $0.0, items: $0.1) }
    }
    var middle: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let s = imp.current {
                    Text(s.name).font(.headline)
                    if imp.loading { ProgressView().controlSize(.small); Text("Reading…").foregroundStyle(.secondary) }
                    else {
                        Text("\(imp.items.count.formatted()) photos · \(imp.newCount.formatted()) new").foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text("Choose a card or folder").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Hide Already Imported", isOn: $imp.hideImported).toggleStyle(.checkbox)
                Button("Select All") { imp.selection = Set(shown.map(\.id)) }.disabled(shown.isEmpty)
                Button("None") { imp.selection = [] }.disabled(imp.selection.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.day) { d in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                                ForEach(d.items) { it in ImportCell(item: it, selected: imp.selection.contains(it.id)) { toggle(it) } }
                            }
                            .padding(.horizontal, 14)
                        } header: {
                            HStack {
                                Text(d.day).font(.callout.weight(.semibold))
                                Text("\(d.items.count)").foregroundStyle(.secondary).font(.callout)
                                Spacer()
                                let ids = Set(d.items.map(\.id))
                                Button(ids.isSubset(of: imp.selection) ? "Deselect Day" : "Select Day") {
                                    if ids.isSubset(of: imp.selection) { imp.selection.subtract(ids) } else { imp.selection.formUnion(ids) }
                                }
                                .buttonStyle(.borderless).controlSize(.small)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
                .padding(.bottom, 14)
            }
            .overlay {
                if !imp.loading && imp.current != nil && shown.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.green)
                        Text(imp.items.isEmpty ? "No photos here." : "Everything here is already in your library.").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    func toggle(_ it: Importer.Item) { if imp.selection.contains(it.id) { imp.selection.remove(it.id) } else { imp.selection.insert(it.id) } }

    // MARK: right — where to and how
    var options: some View {
        VStack(spacing: 0) {
            Form {
                Section("Where") {
                    Picker("Into", selection: Binding(get: { imp.destPath }, set: { v in
                        if v == "__other__" { imp.chooseDestination() } else { imp.destPath = v }
                    })) {
                        ForEach(lib.folders) { f in Text(f.name + (f.offline ? " (not available)" : "")).tag(f.path) }
                        let extra = imp.recentDests.filter { p in !lib.folders.contains { $0.path == p } }
                        if !extra.isEmpty {
                            Divider()
                            ForEach(extra, id: \.self) { p in Text((p as NSString).lastPathComponent + (Importer.exists(p) ? "" : " (not available)")).tag(p) }
                        }
                        if !imp.destPath.isEmpty && !lib.folders.contains(where: { $0.path == imp.destPath }) && !extra.contains(imp.destPath) {
                            Text((imp.destPath as NSString).lastPathComponent).tag(imp.destPath)
                        }
                        Divider()
                        Text("Other Folder…").tag("__other__")
                    }
                    if let e = imp.effectiveDest {
                        Text(e.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(e.path)
                        if e.rerouted {
                            Text("“\((imp.destPath as NSString).lastPathComponent)” isn't available right now, so this import goes to “\((e.path as NSString).lastPathComponent)”.")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else if lib.rootFor(e.path) == nil {
                            Text("Not in your library yet — it's added as a library folder after the import.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Folders", selection: $imp.organise) {
                        ForEach(Importer.organiseChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    TextField("Event (optional)", text: $imp.event, prompt: Text("e.g. Beach Trip"))
                    if let first = imp.items.first(where: { imp.selection.contains($0.id) }) {
                        Text("→ \(((imp.effectiveDest?.path ?? "…") as NSString).lastPathComponent)/\(imp.subfolder(for: first.date))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Section("Names") {
                    Toggle("Rename", isOn: $imp.rename)
                    if imp.rename {
                        TextField("Name", text: $imp.renameBase, prompt: Text("e.g. Beach Trip"))
                        Text("→ \(imp.renameBase.isEmpty ? "Name" : imp.renameBase) 001.NEF, 002…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Add to every photo") {
                    Picker("Metadata preset", selection: $imp.metaPreset) {
                        Text("None").tag("")
                        ForEach(MetadataPresets.shared.all) { Text($0.name).tag($0.id) }
                    }
                    TextField("Keywords", text: $imp.keywords, prompt: Text("comma, separated"))
                    TextField("Caption", text: $imp.caption)
                }
                Section("Previews") {
                    Picker("RAW files", selection: $imp.previewsRaw) {
                        ForEach(PreviewSettings.OnImport.allCases) { Text($0 == .thumbnails ? "Thumbnails only" : $0.rawValue).tag($0) }
                    }
                    Picker("JPEG, HEIC and others", selection: $imp.previews) {
                        ForEach(PreviewSettings.OnImport.allCases) { Text($0 == .thumbnails ? "Thumbnails only" : $0.rawValue).tag($0) }
                    }
                    Text("Built in the background after the photos are in. Thumbnails are always made. JPEGs on a fast disk need nothing more.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Safety") {
                    Toggle("Backup copy", isOn: $imp.backup)
                    if imp.backup {
                        HStack {
                            Text(imp.backupPath.isEmpty ? "No folder chosen" : (imp.backupPath as NSString).lastPathComponent)
                                .foregroundStyle(imp.backupPath.isEmpty ? .orange : .secondary).lineLimit(1).help(imp.backupPath)
                            Spacer()
                            Button("Choose…") { chooseBackup() }
                        }
                    }
                    if imp.current?.kind == .card { Toggle("Eject the card when done", isOn: $imp.eject) }
                    Toggle("Open Import when a card is inserted", isOn: $imp.autoOpen)
                    Text("Every copy is checked against the original. Nothing is ever deleted from the card.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer.padding(12)
        }
        .onAppear { if imp.destPath.isEmpty, let f = imp.fallbackDest { imp.destPath = f } }
    }
    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if imp.running {
                ProgressView(value: Double(imp.done), total: Double(max(imp.total, 1)))
                HStack {
                    Text("Importing \(imp.done.formatted()) of \(imp.total.formatted())…").font(.callout).monospacedDigit()
                    Spacer()
                    Button("Stop") { imp.cancel() }
                }
            } else {
                if !imp.message.isEmpty { Text(imp.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                let chosen = imp.items.filter { imp.selection.contains($0.id) }
                HStack {
                    // folders can also stay where they are (Lightroom's "Add"): the photos are read in place, nothing copied
                    if imp.insideLibrary == nil, !imp.chosenFolders.isEmpty {
                        Button("Add Where They Are") {
                            for u in imp.chosenFolders { Library.shared.addFolder(u) }
                            NotificationCenter.default.post(name: .importFinished, object: nil, userInfo: ["close": true])
                        }
                        .help("Don't copy: add these folders to the library in place")
                    }
                    Spacer()
                    Button("Import \(chosen.count.formatted()) Photo\(chosen.count == 1 ? "" : "s")") { imp.start(chosen) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty || imp.loading || imp.effectiveDest == nil || imp.insideLibrary != nil)
                        .controlSize(.large)
                }
                if imp.effectiveDest == nil { Text("Choose where the photos go (Into ▸ Other Folder…).").font(.caption).foregroundStyle(.orange) }
                if let f = imp.insideLibrary {
                    Text("This folder is already part of your library (“\(f.name)”), so importing would only make duplicates. To pick up photos added to it in Finder, use Folder ▸ Synchronize Folder.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    func chooseBackup() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Use for Backups"; p.message = "Choose a folder on another drive for the backup copies."
        Importer.present(p) { u in imp.backupPath = u.path }
    }
}

/// One photo on the card: its small built-in preview, a tick when chosen, dimmed with "Imported" if it's already in.
struct ImportCell: View {
    let item: Importer.Item
    let selected: Bool
    let tap: () -> Void
    @State private var img: CGImage?
    private static let cache = NSCache<NSString, CGImageBox>()
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let img { Image(decorative: img, scale: 1).resizable().scaledToFit() }
            }
            .frame(width: 118, height: 90)
            .opacity(item.imported ? 0.35 : 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: selected ? 3 : 0))
            if selected {
                Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor).padding(4)
            }
            if item.imported {
                Text("Imported").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(4)
            }
        }
        .frame(width: 118, height: 90)
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
        .help(item.name)
        .task(id: item.id) {
            if let c = Self.cache.object(forKey: item.id as NSString) { img = c.image; return }
            let u = item.url
            let out: CGImage? = await Task.detached(priority: .userInitiated) {
                // the small preview at the start of the file (a quick read, even from a slow card); the big embedded one only if there's none
                ThumbMaker.decode(u, max: 256, always: false) ?? Embedded.image(u, max: 256, minLong: 120)
            }.value
            if let out { Self.cache.setObject(CGImageBox(out), forKey: item.id as NSString) }
            img = out
        }
    }
}

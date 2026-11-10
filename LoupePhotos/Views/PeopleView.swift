import SwiftUI

/// People (like Apple Photos): favourites as big circles, everyone you've named, then unnamed groups to name.
/// ⌘-click to pick several, then drag them onto a person (or use Name…) to put them together.
struct PeopleView: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var idx = FaceIndex.shared
    @State private var picked = Set<String>()          // "p12" = person 12, "g5" = unnamed group 5
    @State private var naming: [String]?               // the Name… sheet
    @State private var showHidden = false
    @State private var showHiddenFaces = false
    @State private var reviewAll: [Int]?                // Review All: everyone with faces to look at, one after another
    @State private var find = ""
    @AppStorage("people.tab") private var tab = "people"
    @AppStorage("people.scale") private var scale = 1.0
    @State private var activity = Activity.shared

    var body: some View {
        let f = find.trimmingCharacters(in: .whitespaces).lowercased()
        let named = idx.named.filter { f.isEmpty || $0.name.lowercased().contains(f) }, favs = named.filter(\.favorite), others = named.filter { !$0.favorite }
        let unnamed = idx.unnamed
        let k = CGFloat(scale)
        VStack(spacing: 0) {
            topBar; Divider()
            if !picked.isEmpty { selectionBar; Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if idx.faces.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.2.crop.square.stack").font(.system(size: 42)).foregroundStyle(.secondary)
                            Text(lib.db == nil ? "People needs the new catalog database — it's being set up." : "Looking for faces… they'll appear here as they're found.")
                                .foregroundStyle(.secondary)
                            Text("Progress is under Background Tasks, next to the title.").font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    if tab == "people" {
                    if !favs.isEmpty { section("Favourites") { personGrid(favs, size: 150 * k) } }
                    let groups = f.isEmpty ? idx.groups : idx.groups.filter { $0.people.contains { idx.people[$0]?.name.lowercased().contains(f) ?? false } }
                    if !groups.isEmpty {
                        section("Groups", note: "People who are often in photos together.") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(groups.prefix(40), id: \.people) { g in
                                        GroupCard(people: g.people, cover: g.cover, count: g.count)
                                            .onTapGesture { ui.source = .together(g.people.map(String.init).joined(separator: ",")); ui.mode = .browser }
                                    }
                                }
                            }
                        }
                    }
                    if !others.isEmpty { section("People") { personGrid(others, size: 104 * k) } }
                    if showHidden && !idx.hiddenPeople.isEmpty {
                        section("Hidden", note: "Right-click someone to show them again.") { personGrid(idx.hiddenPeople, size: 90 * k).opacity(0.6) }
                    }
                    if named.isEmpty && !f.isEmpty { Text("No one called “\(find)”.").foregroundStyle(.secondary) }
                    } else {
                        if unnamed.isEmpty {
                            Text("Nothing to name — every face that appears more than twice belongs to someone, or is hidden.").foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                        } else {
                            section("Unnamed", note: "Faces that look like the same person. Add a name, or ⌘-click several and drag them onto someone (in the People tab). Right-click to hide strangers.") {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104 * k), spacing: 18)], alignment: .leading, spacing: 18) {
                                    ForEach(unnamed.prefix(600), id: \.group) { g in groupTile(g) }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onTapGesture { picked = [] }
        .sheet(isPresented: $showHiddenFaces) { HiddenFacesSheet() }
        .sheet(item: Binding(get: { reviewAll.map { ReviewQueue(ids: $0) } }, set: { reviewAll = $0?.ids })) { q in ReviewSheet(person: q.ids[0], queue: q.ids) }
        .task(id: idx.version) { idx.refreshAllCounts() }
        .sheet(item: Binding(get: { naming.map { NamingKeys(keys: $0) } }, set: { naming = $0?.keys })) { k in
            NameSheet(keys: k.keys) { name in
                if let pid = idx.name(keys: k.keys, as: name, lib: lib) { picked = []; _ = pid }
            }
        }
    }

    var topBar: some View {
        let waiting = idx.named.filter { (idx.suggestionCounts[$0.id] ?? 0) > 0 }
        let total = waiting.reduce(0) { $0 + (idx.suggestionCounts[$1.id] ?? 0) }
        return HStack(spacing: 12) {
            Picker("", selection: $tab) {
                Text("People").tag("people")
                Text("Unnamed (\(idx.unnamed.count.formatted()))").tag("unnamed")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if tab == "people" {
                TextField("Find a name", text: $find).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            if let j = activity.jobs.first(where: { $0.id == "faces" }) {
                ProgressView(value: j.fraction).frame(width: 90).controlSize(.small)
                Text(j.paused ? "Paused" : "Finding faces in \((j.total - j.done).formatted()) photo\(j.total - j.done == 1 ? "" : "s")…").font(.callout).foregroundStyle(.secondary)
            } else if !FaceScanner.enabled {
                Text("Face detection is off (Settings ▸ People).").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if total > 0 {
                Button { reviewAll = waiting.map(\.id) } label: { Label("Review All (\(total.formatted()))", systemImage: "person.crop.circle.badge.questionmark") }
                    .help("Go through everyone's possible matches in one go")
            }
            if !idx.hiddenPeople.isEmpty {
                Toggle("Show Hidden (\(idx.hiddenPeople.count))", isOn: $showHidden).toggleStyle(.button)
            }
            Menu {
                Toggle("Show Background Faces", isOn: Binding(get: { idx.showBackground }, set: { idx.showBackground = $0 }))
                Text("Small, blurry or turned-away faces are left out of Unnamed and Review.")
                Divider()
                Button("Hidden Faces (\(idx.hiddenFaces.count.formatted()))…") { showHiddenFaces = true }.disabled(idx.hiddenFaces.isEmpty)
            } label: { Label("Faces", systemImage: "eye") }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Picker("Sort", selection: Binding(get: { idx.sortMode }, set: { idx.sortMode = $0 })) {
                    Text("Sort by Name").tag("name")
                    Text("Sort by Number of Photos").tag("count")
                    Text("Sort by Custom Order").tag("custom")
                }
                .pickerStyle(.inline)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Custom Order: drag someone to the left or right edge of another person to place them there")
            Image(systemName: "person.crop.circle").imageScale(.small).foregroundStyle(.secondary)
            Slider(value: $scale, in: 0.7...1.6).frame(width: 90).help("Face size")
            Image(systemName: "person.crop.circle").imageScale(.large).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 24).padding(.vertical, 7)
    }

    var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(picked.count) selected").fontWeight(.medium)
            Button("Name…") { naming = Array(picked) }
            if picked.count > 1, picked.contains(where: { $0.hasPrefix("p") }) || picked.filter({ $0.hasPrefix("g") }).count > 1 {
                Text("— or drag them onto a person to merge").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Button("Deselect") { picked = [] }
        }
        .controlSize(.small)
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(.bar)
    }

    func section(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }
    /// Click opens; ⌘- or ⇧-click picks.
    func tap(_ key: String, open: @escaping () -> Void) {
        let m = NSEvent.modifierFlags
        if m.contains(.command) || m.contains(.shift) { if picked.contains(key) { picked.remove(key) } else { picked.insert(key) } }
        else { picked = []; open() }
    }
    /// What a drag carries: the whole selection if this one's in it, otherwise just this one.
    func payload(_ key: String) -> String { (picked.contains(key) ? picked.sorted() : [key]).joined(separator: ",") }
    func ring(_ on: Bool) -> some View { Circle().stroke(Color.accentColor, lineWidth: on ? 4 : 0) }

    func personGrid(_ ps: [Person], size: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size), spacing: 20)], alignment: .leading, spacing: 20) {
            ForEach(ps) { p in
                let key = "p\(p.id)"
                VStack(spacing: 6) {
                    FaceCircle(faceId: idx.keyFace(p), size: size - 12).overlay(ring(picked.contains(key)))
                    Text(p.name).font(size > 120 ? .headline : .callout).lineLimit(1)
                    Text("\(idx.count(person: p.id).formatted())").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: size)
                .contentShape(Rectangle())
                .onTapGesture { tap(key) { ui.personAll = false; ui.source = .person(p.id); ui.mode = .browser } }
                .contextMenu { PersonMenu(person: p) }
                .draggable(payload(key)) { FaceCircle(faceId: idx.keyFace(p), size: 48) }
                .dropDestination(for: String.self) { items, loc in
                    // Custom Order: dropping on the left or right edge places them; in the middle it merges
                    if idx.sortMode == "custom", items.count == 1, let s = items.first, !s.contains(","), s.hasPrefix("p"),
                       let from = Int(s.dropFirst()), from != p.id, loc.x < size * 0.28 || loc.x > size * 0.72 {
                        idx.move(from, nextTo: p.id, after: loc.x > size * 0.5); return true
                    }
                    return dropOnPerson(items, p)
                }
            }
        }
    }
    func groupTile(_ g: (group: Int, count: Int, face: Int)) -> some View {
        let key = "g\(g.group)"
        return VStack(spacing: 6) {
            FaceCircle(faceId: g.face, size: 92).overlay(ring(picked.contains(key)))
                .onTapGesture { tap(key) { ui.source = .faceGroup(g.group); ui.mode = .browser } }
            Button("Add Name") { naming = picked.contains(key) ? Array(picked) : [key] }
                .buttonStyle(.borderless).font(.callout)
            Text("\(g.count) photo\(g.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 104)
        .contextMenu {
            Button("Add Name…") { naming = picked.contains(key) ? Array(picked) : [key] }
            Button("Hide These Faces") {
                let keys = picked.contains(key) ? Array(picked) : [key]
                for k in keys where k.hasPrefix("g") { if let x = Int(k.dropFirst()) { idx.hide(group: x, lib: lib) } }
                picked = []
            }
        }
        .draggable(payload(key)) { FaceCircle(faceId: g.face, size: 48) }
        .dropDestination(for: String.self) { items, _ in
            let keys = items.flatMap { $0.split(separator: ",").map(String.init) }.filter { $0 != key }
            guard !keys.isEmpty else { return false }
            if keys.contains(where: { $0.hasPrefix("p") }) { return false }     // drop people onto people, not onto groups
            idx.mergeGroups(keys, into: g.group, lib: lib); picked = []; return true
        }
    }
    func dropOnPerson(_ items: [String], _ p: Person) -> Bool {
        let keys = items.flatMap { $0.split(separator: ",").map(String.init) }.filter { $0 != "p\(p.id)" }
        guard !keys.isEmpty else { return false }
        let people = keys.filter { $0.hasPrefix("p") }.compactMap { Int($0.dropFirst()) }.compactMap { idx.people[$0]?.name }
        if !people.isEmpty, !Library.confirm("Merge \(people.joined(separator: ", ")) into “\(p.name)”?", "Their photos all become \(p.name)'s.", ok: "Merge") { return false }
        idx.merge(keys: keys, into: p.id, lib: lib); picked = []
        return true
    }
}

struct NamingKeys: Identifiable { let keys: [String]; var id: String { keys.joined(separator: ",") } }

/// A name box with the names you've already used listed underneath as you type.
struct NameField: View {
    @Binding var text: String
    var prompt = "Name"
    let onSubmit: (String) -> Void
    @State private var idx = FaceIndex.shared
    @FocusState private var focused: Bool
    var body: some View {
        let matches = idx.names(matching: text).filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        VStack(alignment: .leading, spacing: 0) {
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onAppear { focused = true }
            if focused && !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { n in
                        Button { text = n; onSubmit(n) } label: {
                            HStack(spacing: 8) {
                                if let p = idx.person(named: n) { FaceCircle(faceId: idx.keyFace(p), size: 20) }
                                Text(n); Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)).shadow(radius: 4, y: 2))
                .padding(.top, 2)
            }
        }
    }
}

/// "Who is this?" — names one or several groups at once (an existing name adds them to that person).
struct NameSheet: View {
    let keys: [String]
    let onName: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var idx = FaceIndex.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: -10) {
                ForEach(keys.prefix(5), id: \.self) { k in
                    let face: Int? = k.hasPrefix("g") ? Int(k.dropFirst()).flatMap { idx.faceIds(group: $0).first } : Int(k.dropFirst()).flatMap { idx.people[$0] }.flatMap { idx.keyFace($0) }
                    FaceCircle(faceId: face, size: 56).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                }
            }
            Text(keys.count == 1 ? "Who is this?" : "Who are these \(keys.count)?").font(.headline)
            NameField(text: $text, prompt: "Name") { n in guard !n.trimmingCharacters(in: .whitespaces).isEmpty else { return }; onName(n); dismiss() }
            Text("Picking a name that's already used adds these to that person.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Name") { onName(text); dismiss() }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Right-click a person: Rename, Favourite, Remove Name, Hide.
struct PersonMenu: View {
    let person: Person
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let idx = FaceIndex.shared
        Button("Rename…") {
            if let n = Library.ask("Rename", "A new name for \(person.name). Using someone else's name merges the two.", value: person.name, ok: "Rename") { idx.rename(person.id, to: n, lib: lib) }
        }
        Button(person.favorite ? "Remove from Favourites" : "Add to Favourites") { idx.setFavorite(person.id, !person.favorite, lib: lib) }
        Divider()
        if person.hidden { Button("Show \(person.name) Again") { idx.setHidden(person.id, false, lib: lib) } }
        else { Button("Hide \(person.name)") { idx.setHidden(person.id, true, lib: lib) } }
        Button("Remove Name") {
            if Library.confirm("Remove the name “\(person.name)”?", "Their faces go back to Unnamed. Photos aren't touched.", ok: "Remove Name") {
                if ui.source == .person(person.id) { ui.source = .people }
                idx.forget(person.id, lib: lib)
            }
        }
    }
}

/// A face, cut from the photo's thumbnail and shown in a circle.
struct FaceCircle: View {
    let faceId: Int?
    let size: CGFloat
    @Environment(Library.self) private var lib
    @State private var img: CGImage?
    private static let cache = NSCache<NSNumber, CGImageBox>()

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let img { Image(decorative: img, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.tertiary) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
        .task(id: faceId) { img = await load() }
    }
    func load() async -> CGImage? {
        guard let fid = faceId else { return nil }
        if let c = Self.cache.object(forKey: fid as NSNumber) { return c.image }
        guard let f = FaceIndex.shared.faces[fid], let p = lib.byId[f.photo] else { return nil }
        let rot = f.rot
        let out: CGImage? = await Task.detached(priority: .userInitiated) {
            guard var cg = ThumbBuilder.shared.image(p, .thumb) else { return nil }
            if rot % 4 != 0, let r = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).rotated(rot).cgImage(forProposedRect: nil, context: nil, hints: nil) { cg = r }
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            let r = f.rect
            let side = max(r.width * W, r.height * H) * 1.7
            let c = CGPoint(x: r.midX * W, y: r.midY * H)
            var crop = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side).integral
            crop = crop.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            return cg.cropping(to: crop)
        }.value
        if let out { Self.cache.setObject(CGImageBox(out), forKey: fid as NSNumber) }
        return out
    }
}

/// Above a person's (or an unnamed group's) photos: who it is, Summary / Show All, Review, naming.
struct PersonHeader: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @State private var idx = FaceIndex.shared
    @State private var name = ""
    @State private var reviewing: ReviewTarget?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { ui.source = .people } label: { Label("People", systemImage: "chevron.left") }.buttonStyle(.borderless).padding(.top, 6)
            switch ui.source {
            case .person(let id):
                if let p = idx.people[id] {
                    FaceCircle(faceId: idx.keyFace(p), size: 34)
                    Text(p.name).font(.title3.weight(.semibold)).padding(.top, 4)
                    Button { idx.setFavorite(id, !p.favorite, lib: lib) } label: { Image(systemName: p.favorite ? "heart.fill" : "heart") }
                        .buttonStyle(.borderless).help(p.favorite ? "Remove from Favourites" : "Add to Favourites").padding(.top, 7)
                    let total = idx.count(person: id)
                    Picker("", selection: Binding(get: { ui.personAll }, set: { ui.personAll = $0 })) {
                        Text("Summary").tag(false); Text("Show All (\(total.formatted()))").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 4)
                    Spacer()
                    let auto = idx.autoFaces.values.filter { $0 == id }.count
                    if auto > 0 {
                        Button { reviewing = ReviewTarget(id: id, auto: true) } label: { Label("\(auto.formatted()) Added Automatically", systemImage: "wand.and.stars") }
                            .help("Faces named \(p.name) for you — check them").padding(.top, 4)
                    }
                    let n = idx.suggestionCounts[id] ?? 0
                    if n > 0 {
                        Button { reviewing = ReviewTarget(id: id) } label: { Label("Review \(n.formatted()) Suggestion\(n == 1 ? "" : "s")", systemImage: "person.crop.circle.badge.questionmark") }
                            .help("Faces that might be \(p.name) — confirm them").padding(.top, 4)
                    }
                    if ui.selection.count >= 1 {
                        Button("Not \(p.name)") { idx.remove(photos: ui.selection, from: id, lib: lib); ui.selection = [] }
                            .help("The selected photos aren't \(p.name) — take them off").padding(.top, 4)
                    }
                    Menu { PersonMenu(person: p) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().padding(.top, 5)
                }
            case .together(let k):
                let ids = k.split(separator: ",").compactMap { Int($0) }
                HStack(spacing: -8) { ForEach(ids, id: \.self) { i in FaceCircle(faceId: idx.people[i].flatMap { idx.keyFace($0) }, size: 30) } }
                Text(idx.groupName(ids)).font(.title3.weight(.semibold)).padding(.top, 4)
                Spacer()
            case .faceGroup(let g):
                FaceCircle(faceId: idx.faceIds(group: g).first, size: 34)
                NameField(text: $name, prompt: "Who is this?") { n in
                    if let pid = idx.name(group: g, as: n, lib: lib) { ui.personAll = false; ui.source = .person(pid); name = "" }
                }
                .frame(width: 240)
                Text("Type a name and press Return — or pick one already used to add these photos to that person.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
            default: EmptyView()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .sheet(item: $reviewing) { t in ReviewSheet(person: t.id, checkingAuto: t.auto) }
        .task(id: "\(idx.version)|\(String(describing: ui.source))") { if case .person(let id) = ui.source { idx.refreshCount(id) } }
    }
}

struct ReviewQueue: Identifiable { let ids: [Int]; var id: String { ids.map(String.init).joined(separator: ",") } }
struct ReviewTarget: Identifiable { let id: Int; var auto = false; var key: String { "\(id)\(auto)" } }

/// Review (Apple Photos' "Confirm Additional Photos"), made quick:
/// faces that look alike come as one row, so one click answers the whole row; everything starts as Yes;
/// Confirm & Next carries straight on to the next batch. Keyboard: arrows move, Space flips Yes/No, H hides, Return confirms.
/// With `checkingAuto`, it lists the faces that were named automatically instead.
struct ReviewSheet: View {
    let person: Int
    var checkingAuto = false
    var queue: [Int] = []                       // Review All: these people, one after another
    @State private var who: Int?
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var idx = FaceIndex.shared
    @State private var rows: [[Int]] = []
    @State private var answer: [Int: Answer] = [:]
    @State private var cursor = 0
    @State private var loading = true
    @State private var confirmedSoFar = 0
    @FocusState private var focused: Bool
    enum Answer { case yes, no, hide }

    var pid: Int { who ?? person }
    var order: [Int] { rows.flatMap { $0 } }
    var position: Int? { queue.firstIndex(of: pid) }
    /// Review All: on to the next person with faces to look at (nil = that was the last).
    func nextPerson() -> Int? {
        guard let i = position else { return nil }
        return queue.dropFirst(i + 1).first { (idx.suggestionCounts[$0] ?? 1) > 0 }
    }
    var body: some View {
        let name = idx.people[pid]?.name ?? "them"
        let all = order
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FaceCircle(faceId: idx.people[pid].flatMap { idx.keyFace($0) }, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkingAuto ? "Added to \(name) automatically" : "Is this \(name)?").font(.title3.weight(.semibold))
                    Text(checkingAuto ? "These were named for you. Click any that aren't \(name)." : "Each row looks like one person — answer the whole row with its buttons, or click single faces.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if confirmedSoFar > 0 { Text("\(confirmedSoFar.formatted()) confirmed").font(.callout).foregroundStyle(.secondary) }
                if let i = position, queue.count > 1 {
                    Text("Person \(i + 1) of \(queue.count)").font(.callout).foregroundStyle(.secondary)
                    if let n = nextPerson() { Button("Skip to \(idx.people[n]?.name.split(separator: " ").first.map(String.init) ?? "Next")") { who = n; load() }.controlSize(.small) }
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
                    Text(checkingAuto ? "Nothing left to check." : "All caught up — no more faces look like \(name).").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(rows.indices, id: \.self) { r in rowView(r, name: name, all: all) }
                        }
                        .padding(6)
                    }
                    .onChange(of: cursor) { _, c in if c < all.count { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(all[c], anchor: .center) } } }
                }
            }
            HStack {
                let n = count
                Text("\(n.yes) yes · \(n.no) no\(n.hide > 0 ? " · \(n.hide) hidden" : "")").foregroundStyle(.secondary).monospacedDigit()
                Text("← → move · Space yes/no · H hide · Return confirm").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(checkingAuto ? "Confirm" : "Confirm & Next") { confirm() }
                    .keyboardShortcut(.defaultAction).disabled(rows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-8); return .handled }
        .onKeyPress(.downArrow) { move(8); return .handled }
        .onKeyPress(.space) { flip(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "hH")) { _ in hideCurrent(); return .handled }
        .onAppear { focused = true; load() }
    }

    func rowView(_ r: Int, name: String, all: [Int]) -> some View {
        let row = rows[r]
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(r == rows.count - 1 && rows.count > 1 && !looksAlike(row) ? "\(row.count) other face\(row.count == 1 ? "" : "s")" : row.count == 1 ? "1 face" : "\(row.count) faces that look alike").font(.callout.weight(.medium))
                Spacer()
                Button { set(row, .yes) } label: { Label("Yes", systemImage: "checkmark") }
                Button { set(row, .no) } label: { Label("Not \(first)", systemImage: "xmark") }
                Button { set(row, .hide) } label: { Label("Hide", systemImage: "eye.slash") }
                    .help("Strangers, crowds or posters — hide these faces from People")
            }
            .controlSize(.small)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(row, id: \.self) { f in faceView(f, current: all.indices.contains(cursor) && all[cursor] == f).id(f) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }
    func faceView(_ f: Int, current: Bool) -> some View {
        let a = answer[f] ?? .yes
        return ZStack(alignment: .bottomTrailing) {
            FaceCircle(faceId: f, size: 76).opacity(a == .yes ? 1 : 0.35)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: current ? 3 : 0))
            Image(systemName: a == .yes ? "checkmark.circle.fill" : a == .no ? "xmark.circle.fill" : "eye.slash.circle.fill")
                .font(.title3).symbolRenderingMode(.palette)
                .foregroundStyle(.white, a == .yes ? Color.green : a == .no ? Color.red : Color.gray)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let i = order.firstIndex(of: f) { cursor = i }; answer[f] = a == .yes ? .no : .yes }
        .contextMenu {
            Button("Yes") { answer[f] = .yes }
            Button("No") { answer[f] = .no }
            Button("Hide This Face") { answer[f] = .hide }
        }
    }

    var count: (yes: Int, no: Int, hide: Int) {
        var y = 0, n = 0, h = 0
        for f in order { switch answer[f] ?? .yes { case .yes: y += 1; case .no: n += 1; case .hide: h += 1 } }
        return (y, n, h)
    }
    func set(_ fs: [Int], _ a: Answer) { for f in fs { answer[f] = a } }
    /// The last row may be the leftover single faces rather than one look-alike set.
    func looksAlike(_ row: [Int]) -> Bool {
        guard row.count > 1, let a = idx.faces[row[0]]?.emb, a.count == 512 else { return row.count > 1 }
        return row.dropFirst().allSatisfy { f in (idx.faces[f]?.emb).map { $0.count == 512 && zip(a, $0).reduce(0) { $0 + $1.0 * $1.1 } > 0.45 } ?? false }
    }
    func move(_ d: Int) { let n = order.count; guard n > 0 else { return }; cursor = min(n - 1, max(0, cursor + d)) }
    func flip() { let o = order; guard o.indices.contains(cursor) else { return }; let f = o[cursor]; answer[f] = (answer[f] ?? .yes) == .yes ? .no : .yes }
    func hideCurrent() { let o = order; guard o.indices.contains(cursor) else { return }; let f = o[cursor]; answer[f] = answer[f] == .hide ? .yes : .hide }

    func load() {
        loading = true; answer = [:]; cursor = 0
        if checkingAuto {
            let ids = idx.autoFaceIds(person: pid).prefix(150).map { (face: $0, score: Float(1)) }
            rows = FaceIndex.rows(Array(ids), idx.faces); loading = false
        } else {
            idx.loadSuggestions(for: pid) { list in
                // Review All: when someone's done, carry straight on with the next person
                if list.isEmpty, let n = nextPerson() { who = n; load(); return }
                rows = FaceIndex.rows(list, idx.faces); loading = false
            }
        }
    }
    func confirm() {
        let o = order
        let yes = o.filter { (answer[$0] ?? .yes) == .yes }, no = o.filter { answer[$0] == .no }, hide = o.filter { answer[$0] == .hide }
        idx.review(yes: yes, no: no, hide: hide, person: pid, checkingAuto: checkingAuto, lib: lib)
        confirmedSoFar += yes.count
        if checkingAuto {
            // anything you said yes to is now confirmed; show what's left (if more than one batch)
            if idx.autoFaceIds(person: pid).isEmpty { dismiss() } else { load() }
        } else {
            load()                                        // straight on to the next batch
        }
    }
}

/// People ▸ Hidden Faces…: everything you've hidden, to bring back.
struct HiddenFacesSheet: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var idx = FaceIndex.shared
    var body: some View {
        let ids = idx.hiddenFaces.filter { idx.faces[$0] != nil }.sorted()
        VStack(alignment: .leading, spacing: 12) {
            Text("Hidden Faces").font(.title3.weight(.semibold))
            Text("Click a face to show it in People again.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                    ForEach(ids, id: \.self) { f in
                        FaceCircle(faceId: f, size: 64).onTapGesture { idx.hide(faces: [f], false, lib: lib) }.help("Show again")
                    }
                }
                .padding(4)
            }
            HStack {
                Text("\(ids.count.formatted()) hidden").foregroundStyle(.secondary)
                Spacer()
                Button("Show All Again") { idx.hide(faces: ids, false, lib: lib) }.disabled(ids.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}

/// A Group card: their best photo together, with their names.
struct GroupCard: View {
    let people: [Int]
    let cover: Int
    let count: Int
    @Environment(Library.self) private var lib
    @State private var img: CGImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            if let img { Image(decorative: img, scale: 1).resizable().scaledToFill().frame(width: 170, height: 120).clipped() }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(FaceIndex.shared.groupName(people)).font(.callout.weight(.semibold)).lineLimit(2)
                Text("\(count) photos").font(.caption2).opacity(0.8)
            }
            .foregroundStyle(.white).padding(8)
        }
        .frame(width: 170, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .task(id: cover) {
            guard let p = lib.byId[cover] else { return }
            img = await Images.shared.cg(p, .thumb)
        }
    }
}

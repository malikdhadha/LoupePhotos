import SwiftUI

/// New / Edit Smart Collection: a name, "match all / any", and a list of rules, with a live count.
struct SmartCollectionEditor: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @State var album: Album
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Smart Collection" : "Edit Smart Collection").font(.headline)
            TextField("Name", text: $album.name).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("Match")
                Picker("", selection: $album.match) { Text("all").tag("all"); Text("any").tag("any") }.labelsHidden().fixedSize()
                Text("of the following rules:")
            }
            VStack(spacing: 8) {
                ForEach($album.rules) { $r in
                    RuleRow(rule: $r) { album.rules.removeAll { $0.id == r.id } }
                }
            }
            Button { album.rules.append(SmartRule.make("keyword")) } label: { Label("Add Rule", systemImage: "plus") }
            Divider()
            HStack {
                Text("\(lib.smartPhotos(album).count.formatted()) photos match right now").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    if isNew { lib.albums.append(album); lib.libChanged() } else { lib.updateCollection(album) }
                    ui.source = .album(album.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
    }
}

struct RuleRow: View {
    @Binding var rule: SmartRule
    let remove: () -> Void
    @Environment(Library.self) private var lib

    var body: some View {
        let field = SmartRule.fields.first { $0.key == rule.f } ?? SmartRule.fields[0]
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { rule.f }, set: { f in let id = rule.id; rule = SmartRule.make(f, firstCollection: lib.albums.first { $0.type == "album" }?.id); rule.id = id })) {
                ForEach(SmartRule.fields, id: \.key) { Text($0.name).tag($0.key) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: $rule.op) { ForEach(field.ops, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 150)
            value
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Remove this rule")
        }
    }

    @ViewBuilder var value: some View {
        switch rule.f {
        case "rating":
            Picker("", selection: $rule.v) { ForEach(0...5, id: \.self) { n in Text(n == 0 ? "No stars" : String(repeating: "★", count: n)).tag(String(n)) } }.labelsHidden().frame(width: 130)
        case "label":
            if rule.op == "is" || rule.op == "not" {
                Picker("", selection: $rule.v) { ForEach(PhotoLabel.all) { l in Text(l.name).tag(l.id) } }.labelsHidden().frame(width: 130)
            }
        case "type":
            Picker("", selection: $rule.v) { ForEach(["RAW", "HEIC", "JPEG", "PNG", "Other"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
        case "person":
            if rule.op == "is" || rule.op == "not" {
                Picker("", selection: $rule.v) {
                    Text("Choose…").tag("")
                    ForEach(FaceIndex.shared.people.values.map(\.name).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 180)
            }
        case "album":
            Picker("", selection: $rule.v) {
                ForEach(lib.albums.filter { $0.type == "album" }) { a in Text(lib.collectionPath(a).isEmpty ? a.name : lib.collectionPath(a) + " › " + a.name).tag(a.id) }
            }
            .labelsHidden().frame(width: 200)
        case "date":
            switch rule.op {
            case "last": HStack(spacing: 4) { TextField("30", text: $rule.v).frame(width: 60); Text("days") }
            case "year": TextField("2026", text: $rule.v).frame(width: 80)
            case "month":
                Picker("", selection: $rule.v) {
                    ForEach(1...12, id: \.self) { m in Text(Calendar.current.monthSymbols[m - 1]).tag(String(m)) }
                }
                .labelsHidden().frame(width: 130)
            default:
                DatePicker("", selection: Binding(get: { SmartRule.dayFormat.date(from: rule.v) ?? Date() },
                                                  set: { rule.v = SmartRule.dayFormat.string(from: $0) }), displayedComponents: .date)
                    .labelsHidden().fixedSize()
            }
        case "flag", "gps", "rejected":
            EmptyView()
        default:
            TextField(rule.f == "keyword" ? "Keyword" : rule.f == "place" ? "Country, city or place" : rule.f == "search" ? "e.g. beach at sunset" : "Text", text: $rule.v).frame(minWidth: 160)
        }
    }
}

import SwiftUI

/// Quick Collection (B) — a scratch collection while you cull, like Lightroom's.
extension Library {
    static let quickID = "quick-collection"
    var quick: Album? { albums.first { $0.id == Library.quickID } }
    /// B: adds the selection to the Quick Collection, or takes it out if it is all there already.
    func toggleQuick(_ ps: [Photo]) {
        if quick == nil { albums.append(Album(id: Library.quickID, type: "album", name: "Quick Collection", parent: nil, ids: [])) }
        guard let i = albums.firstIndex(where: { $0.id == Library.quickID }) else { return }
        let ids = Set(albums[i].ids)
        if ps.allSatisfy({ ids.contains($0.id) }) { albums[i].ids.removeAll { id in ps.contains { $0.id == id } } }
        else { for p in ps where !ids.contains(p.id) { albums[i].ids.append(p.id) } }
        libChanged()
        status = "Quick Collection: \(albums[i].ids.count) photo\(albums[i].ids.count == 1 ? "" : "s")"
    }
    func clearQuick() { if let i = albums.firstIndex(where: { $0.id == Library.quickID }) { albums[i].ids = []; libChanged() } }
    /// Turns the Quick Collection into a real collection and empties it.
    func saveQuick(as name: String) -> Album? {
        guard let q = quick, !q.ids.isEmpty else { return nil }
        let a = newCollection(type: "album", name: name, parent: nil, ids: q.ids)
        clearQuick()
        return a
    }

    /// How many photos carry each keyword (a parent counts its children's photos too).
    func keywordCounts() -> [String: Int] {
        var c: [String: Int] = [:]
        for p in photos where p.deleted == nil && !p.rejected {
            var seen = Set<String>()
            for k in p.keywords {
                let parts = k.split(separator: "/").map(String.init)
                for i in 1...max(1, parts.count) { seen.insert(parts.prefix(i).joined(separator: "/")) }
            }
            for k in seen { c[k, default: 0] += 1 }
        }
        return c
    }
}

/// K: the keyword panel for the selected photos — what they have, add more, one-click recent keywords.
struct KeywordPanel: View {
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @AppStorage("recentKeywords") private var recentRaw = ""

    var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        let t = ui.targets(lib)
        let onAll = Set(t.flatMap(\.keywords)).sorted()
        let q = text.lowercased()
        let suggestions = q.isEmpty ? [] : lib.allKeywords.filter { $0.lowercased().contains(q) && !onAll.contains($0) }.prefix(8)
        VStack(alignment: .leading, spacing: 12) {
            Text("Keywords for \(t.count) photo\(t.count == 1 ? "" : "s")").font(.headline)
            if !onAll.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(onAll, id: \.self) { k in
                        HStack(spacing: 4) {
                            Text(k.replacingOccurrences(of: "/", with: " › "))
                            Button { lib.removeKeyword(t, k) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
            }
            TextField("Type a keyword and press Return (Parent/Child for nesting)", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(text, t) }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions), id: \.self) { k in
                        Button { add(k, t) } label: { Text(k.replacingOccurrences(of: "/", with: " › ")).frame(maxWidth: .infinity, alignment: .leading) }
                            .buttonStyle(.plain).padding(.vertical, 2)
                    }
                }
            }
            if !recent.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(recent, id: \.self) { k in
                        Button(k.replacingOccurrences(of: "/", with: " › ")) { add(k, t) }.controlSize(.small)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(18)
        .frame(width: 440)
    }

    func add(_ k: String, _ t: [Photo]) {
        let k = k.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " > ", with: "/")
        guard !k.isEmpty else { return }
        lib.addKeyword(t, k)
        recentRaw = ([k] + recent.filter { $0 != k }).prefix(12).joined(separator: "\n")
        text = ""
    }
}

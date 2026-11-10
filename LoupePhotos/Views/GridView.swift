import SwiftUI
import AppKit

struct PhotoMenu: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    var body: some View {
        let t = ui.selection.contains(photo.id) ? ui.targets(lib) : [photo]
        Menu("Rating") { ForEach(0...5, id: \.self) { n in Button(n == 0 ? "None" : String(repeating: "★", count: n)) { lib.setRating(t, n) } } }
        Button(photo.flag ? "Unflag" : "Flag") { lib.toggleFlag(t) }
        Button(photo.rejected ? "Not Rejected" : "Reject") { lib.toggleReject(t) }
        if case .person(let pid) = ui.source, t.count == 1,
           let face = FaceIndex.shared.faces(inPhoto: photo.id).filter({ $0.person == pid && $0.rect != .zero }).max(by: { $0.quality < $1.quality }) {
            Button("Make Key Photo") { FaceIndex.shared.setKeyFace(face.id, lib: lib) }
        }
        Menu("Color Label") {
            ForEach(PhotoLabel.all) { l in Button(l.name) { lib.setLabel(t, l.id) } }
            Divider(); Button("None") { lib.setLabel(t, nil) }
        }
        Divider()
        Button("Rotate Left") { lib.rotate(t, -1) }
        Button("Rotate Right") { lib.rotate(t, 1) }
        Divider()
        if !lib.albums.filter({ $0.type == "album" }).isEmpty {
            Menu("Add to Album") { ForEach(lib.albums.filter { $0.type == "album" }) { a in Button(a.name) { lib.addToAlbum(a.id, t) } } }
        }
        Button("New Album with \(t.count == 1 ? "This Photo" : "\(t.count) Photos")…") { ui.selection = Set(t.map(\.id)); ui.newAlbum(lib) }
        Divider()
        Menu("Open With") {
            ForEach(Outside.apps(for: photo.url).prefix(12), id: \.self) { a in Button(Outside.name(a)) { Outside.open(t, with: a) } }
        }
        Button("Set as Desktop Picture") { Outside.setDesktop(photo, lib: lib) }
        Divider()
        Button("Go to Folder") { ui.goToFolder(photo) }
        if Library.gps(photo) != nil {
            Button("Show on Map") { ui.showOnMap(photo) }
            Button("Copy Location") { ui.primary = photo.id; ui.copyLocation(lib) }
        }
        if ui.copiedLocation != nil { Button("Paste Location") { ui.pasteLocation(lib) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(t.map(\.url)) }
        Divider()
        Button(t.count > 1 ? "Delete \(t.count) Photos…" : "Delete…") {
            if !ui.selection.contains(photo.id) { ui.selection = []; ui.primary = photo.id }
            ui.deleteTargets(lib)
        }
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

extension NSImage {
    /// The image turned by quarter turns (Loupe Photos stores rotation as 0–3 quarter turns clockwise).
    func rotated(_ q: Int) -> NSImage {
        let q = ((q % 4) + 4) % 4
        guard q != 0, let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let w = cg.width, h = cg.height, nw = q % 2 == 1 ? h : w, nh = q % 2 == 1 ? w : h
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let out = ctx.makeImage() else { return self }
        return NSImage(cgImage: out, size: NSSize(width: nw, height: nh))
    }
}

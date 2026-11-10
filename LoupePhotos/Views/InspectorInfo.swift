import SwiftUI
import MapKit
import ImageIO

/// Everything the camera recorded, read from the file when asked for (kept for the last few photos).
final class ExifCache {
    static let shared = ExifCache()
    private let cache = NSCache<NSNumber, NSDictionary>()
    init() { cache.countLimit = 64 }
    func props(_ p: Photo) async -> [String: Any] {
        if let d = cache.object(forKey: p.id as NSNumber) as? [String: Any] { return d }
        let url = p.url
        let d: [String: Any] = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [String: Any] else { return [:] }
            return props
        }.value
        cache.setObject(d as NSDictionary, forKey: p.id as NSNumber)
        return d
    }
}

/// The camera strip at the top of the Info (Aperture's): camera and lens, then ISO · focal length · EV · aperture · shutter,
/// with the file type and white balance as badges.
struct CameraStrip: View {
    let photo: Photo
    @State private var props: [String: Any] = [:]
    var body: some View {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(photo.camera.isEmpty ? "Unknown camera" : photo.camera).font(.callout.weight(.semibold))
                    if !photo.lens.isEmpty { Text(photo.lens).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                HStack(spacing: 4) {
                    if let wb = exif[kCGImagePropertyExifWhiteBalance as String] as? Int { badge(wb == 0 ? "AWB" : "WB") }
                    badge(photo.isRaw ? "RAW" : photo.ext.uppercased())
                }
            }
            HStack(spacing: 0) {
                cell((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first.map { "ISO \($0)" })
                cell((exif[kCGImagePropertyExifFocalLength as String] as? Double).map { "\(Int($0.rounded())) mm" })
                cell((exif[kCGImagePropertyExifExposureBiasValue as String] as? Double).map { String(format: "%+.1f ev", $0).replacingOccurrences(of: "+0.0", with: "0") })
                cell((exif[kCGImagePropertyExifFNumber as String] as? Double).map { $0.truncatingRemainder(dividingBy: 1) == 0 ? "ƒ/\(Int($0))" : String(format: "ƒ/%.1f", $0) })
                cell((exif[kCGImagePropertyExifExposureTime as String] as? Double).map { $0 >= 1 ? String(format: "%.1f s", $0) : "1/\(Int((1 / $0).rounded()))" }, last: true)
            }
            .font(.caption.monospacedDigit())
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .task(id: photo.id) { props = await ExifCache.shared.props(photo) }
    }
    func badge(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.bold)).padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.6)))
            .foregroundStyle(.secondary)
    }
    func cell(_ t: String?, last: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(t ?? "—").frame(maxWidth: .infinity).lineLimit(1).minimumScaleFactor(0.8)
            if !last { Divider().frame(height: 12) }
        }
    }
}

/// The Info section: pick a view (Basic, IPTC…, EXIF, Custom) and edit the fields in it.
struct MetadataSection: View {
    let photo: Photo
    let targets: [Photo]
    @AppStorage("meta.view") private var viewName = MetadataView.basic.rawValue
    @State private var customizing = false
    @Environment(Library.self) private var lib
    var body: some View {
        let view = MetadataView(rawValue: viewName) ?? .basic
        let _ = lib.version
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INFO").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Picker("", selection: $viewName) { ForEach(MetadataView.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .labelsHidden().fixedSize().controlSize(.small)
                if view == .custom {
                    Button { customizing = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("Choose the fields")
                        .popover(isPresented: $customizing) { CustomFieldsPicker() }
                }
            }
            if view == .exif { ExifList(photo: photo) }
            else {
                ForEach(view.fields) { f in IPTCRow(photo: photo, targets: targets, field: f) }
            }
        }
    }
}

struct CustomFieldsPicker: View {
    @State private var chosen = Set(MetadataView.customFields)
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fields in Custom").font(.headline).padding(.bottom, 4)
            ForEach(IPTCField.Group.allCases, id: \.self) { g in
                Text(g.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(IPTCField.allCases.filter { $0.group == g }) { f in
                    Toggle(f.label, isOn: Binding(get: { chosen.contains(f) }, set: { on in
                        if on { chosen.insert(f) } else { chosen.remove(f) }
                        MetadataView.customFields = IPTCField.allCases.filter { chosen.contains($0) }
                    }))
                }
            }
        }
        .padding(14).frame(width: 240)
    }
}

/// One editable IPTC field. Changes apply to every selected photo when you press Return or leave the field.
struct IPTCRow: View {
    let photo: Photo
    let targets: [Photo]
    let field: IPTCField
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(Library.self) private var lib
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(field.label).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing).lineLimit(1)
            TextField("", text: $draft, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
        }
        .font(.callout)
        .onAppear { draft = photo.iptc(field) }
        .onChange(of: photo.id) { _, _ in draft = photo.iptc(field) }
    }
    func commit() {
        guard draft != photo.iptc(field) else { return }
        lib.setIPTC(targets, [field.rawValue: draft], replace: true)
    }
}

/// EXIF view: what the camera recorded, read from the file.
struct ExifList: View {
    let photo: Photo
    @State private var rows: [(String, String)] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline) {
                    Text(r.0).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                    Text(r.1).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
            if rows.isEmpty { Text("No camera data in this file.").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: photo.id) {
            let p = await ExifCache.shared.props(photo)
            var out: [(String, String)] = []
            func add(_ dict: [String: Any]?, _ keys: [(CFString, String)]) {
                guard let dict else { return }
                for (k, label) in keys { if let v = dict[k as String] { out.append((label, Self.text(v))) } }
            }
            let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let gps = p[kCGImagePropertyGPSDictionary as String] as? [String: Any]
            add(tiff, [(kCGImagePropertyTIFFMake, "Make"), (kCGImagePropertyTIFFModel, "Model"), (kCGImagePropertyTIFFSoftware, "Software")])
            add(exif, [(kCGImagePropertyExifLensModel, "Lens"), (kCGImagePropertyExifDateTimeOriginal, "Taken"), (kCGImagePropertyExifExposureTime, "Shutter (s)"),
                       (kCGImagePropertyExifFNumber, "Aperture (ƒ)"), (kCGImagePropertyExifISOSpeedRatings, "ISO"), (kCGImagePropertyExifFocalLength, "Focal length (mm)"),
                       (kCGImagePropertyExifFocalLenIn35mmFilm, "35 mm equivalent"), (kCGImagePropertyExifExposureBiasValue, "Exposure comp. (ev)"),
                       (kCGImagePropertyExifExposureProgram, "Program"), (kCGImagePropertyExifMeteringMode, "Metering"), (kCGImagePropertyExifFlash, "Flash"),
                       (kCGImagePropertyExifWhiteBalance, "White balance"), (kCGImagePropertyExifBodySerialNumber, "Camera serial"),
                       (kCGImagePropertyExifLensSerialNumber, "Lens serial"), (kCGImagePropertyExifColorSpace, "Colour space")])
            add(p, [(kCGImagePropertyPixelWidth, "Width (px)"), (kCGImagePropertyPixelHeight, "Height (px)"), (kCGImagePropertyDPIWidth, "DPI")])
            add(gps, [(kCGImagePropertyGPSLatitude, "Latitude"), (kCGImagePropertyGPSLongitude, "Longitude"), (kCGImagePropertyGPSAltitude, "Altitude (m)")])
            rows = out
        }
    }
    nonisolated static func text(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map { text($0) }.joined(separator: ", ") }
        if let d = v as? Double { return d == d.rounded() ? String(Int(d)) : String(format: "%.4g", d) }
        return "\(v)"
    }
}

/// The map under the Info (Aperture's): where the photo was taken. Click the pin to open it in the Map view;
/// "Move Pin" then a click puts the selected photos at that spot; photos with no location can be given one by name.
struct InspectorMap: View {
    let photo: Photo
    let targets: [Photo]
    @Environment(Library.self) private var lib
    @Environment(UIState.self) private var ui
    @AppStorage("inspector.map") private var showMap = true
    @State private var moving = false
    @State private var search = ""
    @State private var results: [MKMapItem] = []
    var body: some View {
        let _ = lib.version
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LOCATION").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Button(showMap ? "Hide Map" : "Show Map") { showMap.toggle() }.buttonStyle(.borderless).controlSize(.small)
            }
            if let c = Library.gps(photo) {
                if showMap {
                    MapReader { proxy in
                        Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 6000, longitudinalMeters: 6000))) {
                            Annotation("", coordinate: c) {
                                Button { ui.showOnMap(photo) } label: {
                                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red, .white).shadow(radius: 2)
                                }.buttonStyle(.plain).help("Open in the Map view")
                            }
                        }
                        .id("\(photo.id)-\(c.latitude)-\(c.longitude)")
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(moving ? Color.accentColor : .clear, lineWidth: 2))
                        .onTapGesture { pt in
                            guard moving, let to = proxy.convert(pt, from: .local) else { return }
                            lib.setLocation(targets, to); moving = false
                            PlaceNamer.shared.nameMissing(lib)
                        }
                    }
                }
                HStack {
                    Toggle("Move Pin", isOn: $moving).toggleStyle(.button).controlSize(.small)
                        .help("Then click on the map where the photo was taken")
                    Spacer()
                    Button("Show on Map") { ui.showOnMap(photo) }.controlSize(.small)
                }
            } else {
                HStack {
                    TextField("Add a location — a place name", text: $search).textFieldStyle(.roundedBorder).onSubmit(find)
                    Button("Find", action: find).controlSize(.small)
                }
                ForEach(results, id: \.self) { item in
                    Button { place(item) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "").font(.callout)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        }
        .onChange(of: photo.id) { _, _ in moving = false; results = []; search = "" }
    }
    func find() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let r = MKLocalSearch.Request(); r.naturalLanguageQuery = q
        MKLocalSearch(request: r).start { resp, _ in results = Array((resp?.mapItems ?? []).prefix(5)) }
    }
    func place(_ item: MKMapItem) {
        lib.setLocation(targets, item.placemark.coordinate)
        results = []; search = ""
        PlaceNamer.shared.nameMissing(lib)
    }
}

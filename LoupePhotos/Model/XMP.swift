import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writing metadata into the photo files (XMP), the way Lightroom Classic does — off by default: the catalog is the
/// place it's kept, and Settings ▸ Metadata turns this on. RAW files get a sidecar (IMG_1234.xmp) beside them;
/// JPEG, HEIC and TIFF can have it written inside the file, or a sidecar too. An existing sidecar (from Lightroom,
/// with its develop settings) is updated, never replaced: only the fields Loupe Photos manages are changed.
enum XMPSync {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "xmp.auto") }
    static var embed: Bool { UserDefaults.standard.object(forKey: "xmp.embed") as? Bool ?? true }
    /// Changes to these fields are written when XMP is on.
    static let fields: Set<String> = ["rating", "label", "rejected", "keywords", "caption", "iptc", "name"]
    private static let queue = DispatchQueue(label: "xmp.write", qos: .utility)

    /// Everything that goes into a photo's XMP, copied on the main thread.
    struct Snap {
        let url: URL, isRaw: Bool, rating: Int, rejected: Bool, label: String?, keywords: [String], caption: String, iptc: [String: String]
        init(_ p: Photo) {
            url = p.url; isRaw = p.isRaw; rating = p.rating; rejected = p.rejected; label = p.label
            keywords = p.keywords; caption = p.caption; iptc = p.iptc
        }
    }
    static func sidecar(for u: URL) -> URL { u.deletingPathExtension().appendingPathExtension("xmp") }

    /// Writes these photos' metadata to their files in the background. `done` (main thread) gets how many failed.
    static func write(_ ps: [Photo], done: ((Int) -> Void)? = nil) {
        let snaps = ps.filter { !$0.missing }.map(Snap.init)
        guard !snaps.isEmpty else { done?(0); return }
        let embedOn = embed
        queue.async {
            var failed = 0
            for s in snaps {
                autoreleasepool {
                    let ok: Bool
                    if !s.isRaw && embedOn && !FileManager.default.fileExists(atPath: sidecar(for: s.url).path) { ok = writeEmbedded(s) || writeSidecar(s) }
                    else { ok = writeSidecar(s) }
                    if !ok { failed += 1 }
                }
            }
            DispatchQueue.main.async { done?(failed) }
        }
    }

    // MARK: the XMP itself
    static let ns: [(String, String)] = [
        ("dc", "http://purl.org/dc/elements/1.1/"), ("xmp", "http://ns.adobe.com/xap/1.0/"),
        ("photoshop", "http://ns.adobe.com/photoshop/1.0/"), ("Iptc4xmpCore", "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"),
        ("xmpRights", "http://ns.adobe.com/xap/1.0/rights/"), ("lr", "http://ns.adobe.com/lightroom/1.0/"),
    ]
    /// The properties Loupe Photos owns (removed and written again on every update).
    static let managed = ["xmp:Rating", "xmp:Label", "dc:title", "dc:description", "dc:subject", "lr:hierarchicalSubject", "dc:creator", "dc:rights",
                          "xmpRights:UsageTerms", "photoshop:Headline", "photoshop:City", "photoshop:State", "photoshop:Country", "photoshop:Credit",
                          "photoshop:Source", "photoshop:Instructions", "photoshop:TransmissionReference", "photoshop:AuthorsPosition",
                          "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode", "Iptc4xmpCore:CreatorContactInfo"]
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// The managed properties as XML elements (children of rdf:Description).
    static func elements(_ s: Snap) -> String {
        var x = ""
        func simple(_ name: String, _ v: String) { if !v.isEmpty { x += "<\(name)>\(esc(v))</\(name)>\n" } }
        func alt(_ name: String, _ v: String) { if !v.isEmpty { x += "<\(name)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(esc(v))</rdf:li></rdf:Alt></\(name)>\n" } }
        func bag(_ name: String, _ vs: [String], seq: Bool = false) {
            guard !vs.isEmpty else { return }
            let t = seq ? "rdf:Seq" : "rdf:Bag"
            x += "<\(name)><\(t)>" + vs.map { "<rdf:li>\(esc($0))</rdf:li>" }.joined() + "</\(t)></\(name)>\n"
        }
        let i = s.iptc
        simple("xmp:Rating", s.rejected ? "-1" : (s.rating > 0 ? String(s.rating) : ""))
        simple("xmp:Label", PhotoLabel.find(s.label)?.name ?? "")
        alt("dc:title", i["title"] ?? "")
        alt("dc:description", s.caption)
        // keywords: every level for dc:subject (as Lightroom exports), the whole path for Lightroom's hierarchy
        var subject: [String] = []
        for k in s.keywords { for part in k.split(separator: "/").map(String.init) where !subject.contains(part) { subject.append(part) } }
        bag("dc:subject", subject)
        bag("lr:hierarchicalSubject", s.keywords.filter { $0.contains("/") }.map { $0.replacingOccurrences(of: "/", with: "|") })
        bag("dc:creator", (i["creator"] ?? "").isEmpty ? [] : [i["creator"]!], seq: true)
        alt("dc:rights", i["copyright"] ?? "")
        alt("xmpRights:UsageTerms", i["usageTerms"] ?? "")
        simple("photoshop:Headline", i["headline"] ?? "")
        simple("photoshop:City", i["city"] ?? ""); simple("photoshop:State", i["state"] ?? ""); simple("photoshop:Country", i["country"] ?? "")
        simple("photoshop:Credit", i["credit"] ?? ""); simple("photoshop:Source", i["source"] ?? "")
        simple("photoshop:Instructions", i["instructions"] ?? ""); simple("photoshop:TransmissionReference", i["jobId"] ?? "")
        simple("photoshop:AuthorsPosition", i["creatorJob"] ?? "")
        simple("Iptc4xmpCore:Location", i["location"] ?? ""); simple("Iptc4xmpCore:CountryCode", i["countryCode"] ?? "")
        let contact = [("Iptc4xmpCore:CiEmailWork", i["email"] ?? ""), ("Iptc4xmpCore:CiTelWork", i["phone"] ?? ""), ("Iptc4xmpCore:CiUrlWork", i["website"] ?? "")].filter { !$0.1.isEmpty }
        if !contact.isEmpty {
            x += "<Iptc4xmpCore:CreatorContactInfo rdf:parseType=\"Resource\">" + contact.map { "<\($0.0)>\(esc($0.1))</\($0.0)>" }.joined() + "</Iptc4xmpCore:CreatorContactInfo>\n"
        }
        return x
    }
    static func packet(_ s: Snap) -> String {
        let decl = ns.map { "xmlns:\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Loupe Photos">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" \(decl)>
        \(elements(s))</rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    // MARK: sidecars
    /// Updates (or makes) the .xmp beside the photo, keeping everything else in it.
    static func writeSidecar(_ s: Snap) -> Bool {
        let u = sidecar(for: s.url)
        guard FileManager.default.fileExists(atPath: u.path),
              let doc = try? XMLDocument(contentsOf: u, options: [.nodePreserveAll]) else {
            return (try? packet(s).data(using: .utf8)?.write(to: u, options: .atomic)) != nil
        }
        guard let desc = (try? doc.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement else {
            return (try? packet(s).data(using: .utf8)?.write(to: u, options: .atomic)) != nil
        }
        for (p, uri) in ns where desc.namespace(forPrefix: p) == nil {
            desc.addNamespace(XMLNode.namespace(withName: p, stringValue: uri) as! XMLNode)
        }
        // take out what we manage — as child elements or as attributes (Lightroom writes simple values as attributes)
        for name in managed {
            for c in desc.elements(forName: name) { desc.removeChild(at: c.index) }
            desc.removeAttribute(forName: name)
        }
        let decl = ns.map { "xmlns:\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
        let wrapper = "<w xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" \(decl)>\(elements(s))</w>"
        guard let frag = try? XMLElement(xmlString: wrapper) else { return false }
        for c in frag.children ?? [] { if let e = c.copy() as? XMLNode { desc.addChild(e) } }
        let data = doc.xmlData(options: [.nodePrettyPrint])
        return (try? data.write(to: u, options: .atomic)) != nil
    }

    // MARK: inside the file
    /// JPEG, HEIC, TIFF, PNG: the XMP merged into the file's own metadata. The picture itself isn't recompressed.
    static func writeEmbedded(_ s: Snap) -> Bool {
        guard let data = packet(s).data(using: .utf8), let meta = CGImageMetadataCreateFromXMPData(data as CFData),
              let src = CGImageSourceCreateWithURL(s.url as CFURL, nil), let type = CGImageSourceGetType(src) else { return false }
        let tmp = s.url.deletingLastPathComponent().appendingPathComponent(".apxmp-" + s.url.lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) else { try? FileManager.default.removeItem(at: tmp); return false }
        do { _ = try FileManager.default.replaceItemAt(s.url, withItemAt: tmp); return true }
        catch { try? FileManager.default.removeItem(at: tmp); return false }
    }

    // MARK: reading back
    /// Metadata ▸ Read Metadata from Files: what's in the files (sidecar first, then inside the file) replaces the catalog's.
    static func read(_ ps: [Photo], lib: Library) {
        var changedPs: [Photo] = []
        for p in ps where !p.missing {
            guard let meta = metadata(p.url) else { continue }
            func str(_ path: String) -> String? {
                guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString), let v = CGImageMetadataTagCopyValue(tag) else { return nil }
                if let s = v as? String { return s }
                if let arr = v as? [CGImageMetadataTag], let f = arr.first, let s = CGImageMetadataTagCopyValue(f) as? String { return s }
                return nil
            }
            func list(_ path: String) -> [String] {
                guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString), let v = CGImageMetadataTagCopyValue(tag) else { return [] }
                if let arr = v as? [CGImageMetadataTag] { return arr.compactMap { CGImageMetadataTagCopyValue($0) as? String } }
                if let s = v as? String { return [s] }
                return []
            }
            if let r = str("xmp:Rating"), let n = Int(r) { if n < 0 { p.rejected = true } else { p.rating = min(5, n) } }
            if let l = str("xmp:Label") { p.label = PhotoLabel.all.first { $0.name.lowercased() == l.lowercased() }?.id }
            if let c = str("dc:description") { p.caption = c }
            let hier = list("lr:hierarchicalSubject").map { $0.replacingOccurrences(of: "|", with: "/") }
            let flat = list("dc:subject")
            if !hier.isEmpty || !flat.isEmpty {
                // nested keywords as their full path; plain ones that aren't just a level of a nested one
                let levels = Set(hier.flatMap { $0.split(separator: "/").map(String.init) })
                p.keywords = hier + flat.filter { !levels.contains($0) }
            }
            var d = p.iptc
            let map: [(IPTCField, String)] = [(.title, "dc:title"), (.copyright, "dc:rights"), (.creator, "dc:creator"), (.usageTerms, "xmpRights:UsageTerms"),
                (.headline, "photoshop:Headline"), (.city, "photoshop:City"), (.state, "photoshop:State"), (.country, "photoshop:Country"),
                (.credit, "photoshop:Credit"), (.source, "photoshop:Source"), (.instructions, "photoshop:Instructions"),
                (.jobId, "photoshop:TransmissionReference"), (.creatorJob, "photoshop:AuthorsPosition"), (.location, "Iptc4xmpCore:Location"),
                (.countryCode, "Iptc4xmpCore:CountryCode"), (.email, "Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiEmailWork"),
                (.phone, "Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiTelWork"), (.website, "Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiUrlWork")]
            for (f, path) in map { if let v = str(path), !v.isEmpty { d[f.rawValue] = v } }
            if d.isEmpty { p.raw.removeValue(forKey: "iptc") } else { p.raw["iptc"] = d }
            changedPs.append(p)
        }
        if !changedPs.isEmpty { lib.changed(changedPs, ["rating", "rejected", "label", "caption", "keywords", "iptc"]) }
        lib.status = "Read metadata from \(changedPs.count.formatted()) file\(changedPs.count == 1 ? "" : "s")."
    }
    /// A photo's XMP: its sidecar if there is one, else what's inside the file.
    static func metadata(_ u: URL) -> CGImageMetadata? {
        var base: CGImageMetadata?
        let side = sidecar(for: u)
        if let d = try? Data(contentsOf: side) { base = CGImageMetadataCreateFromXMPData(d as CFData) }
        if base == nil, let src = CGImageSourceCreateWithURL(u as CFURL, nil) { base = CGImageSourceCopyMetadataAtIndex(src, 0, nil) }
        guard let b = base, let m = CGImageMetadataCreateMutableCopy(b) else { return base }
        CGImageMetadataRegisterNamespaceForPrefix(m, "http://ns.adobe.com/lightroom/1.0/" as CFString, "lr" as CFString, nil)
        return m
    }
}

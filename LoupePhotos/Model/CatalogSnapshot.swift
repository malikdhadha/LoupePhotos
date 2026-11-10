import Foundation

/// A fast copy of the photo list, for opening quickly (the catalog database stays the master).
///
/// When you quit, every photo is written to "<catalog>.apsnap" in a compact binary form, and a matching stamp is put
/// in the database. Next launch, if the stamp still matches, the photos are read from this file (a few hundred
/// milliseconds) instead of decoding 120,000 database rows of text (about 1.5 seconds). The first change to any photo
/// removes the stamp, so a copy that's out of date — after a crash, a restore, or the Electron app writing — is never
/// used: the database is read as before. Deleting the file just means one slower launch.
enum CatalogSnapshot {
    static let magic: [UInt8] = Array("APSNAP01".utf8)

    // MARK: writing
    static func write(_ photos: [Photo], to url: URL, stamp: String) -> Bool {
        var body = Data(); body.reserveCapacity(photos.count * 220)
        var offsets: [UInt64] = []; offsets.reserveCapacity(photos.count)
        func i64(_ v: Int) { var x = Int64(v).littleEndian; withUnsafeBytes(of: &x) { body.append(contentsOf: $0) } }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { body.append(contentsOf: $0) } }
        func i32(_ v: Int) { var x = Int32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { body.append(contentsOf: $0) } }
        func str(_ s: String) { let u = Array(s.utf8); i32(u.count); body.append(contentsOf: u) }
        for p in photos {
            offsets.append(UInt64(body.count))
            i64(p.id); i64(p.size)
            f64(p.mtime); f64(p.added); f64(p.date); f64(p.deleted ?? .nan)
            i32(p.w); i32(p.h); i32(p.rating); i32(p.rot)
            var flags: UInt8 = 0
            if p.dateFromFile { flags |= 1 }; if p.flag { flags |= 2 }; if p.rejected { flags |= 4 }; if p.missing { flags |= 8 }; if p.label != nil { flags |= 16 }
            body.append(flags)
            str(p.path); str(p.fid); str(p.ext); str(p.camera); str(p.lens); str(p.exposure); str(p.label ?? ""); str(p.caption); str(p.name)
            i32(p.keywords.count); for k in p.keywords { str(k) }
            if p.raw.isEmpty { i32(0) }
            else if let j = try? JSONSerialization.data(withJSONObject: p.raw) { i32(j.count); body.append(j) }
            else { i32(0) }
        }
        var out = Data(magic)
        let st = Array(stamp.utf8)
        var n = Int32(st.count).littleEndian; withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }; out.append(contentsOf: st)
        var c = Int64(photos.count).littleEndian; withUnsafeBytes(of: &c) { out.append(contentsOf: $0) }
        for o in offsets { var x = o.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append(body)
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    // MARK: reading
    /// The stamp written in the file, without reading the rest.
    static func stamp(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 12 + 256), head.count >= 12, Array(head.prefix(8)) == magic else { return nil }
        let n = Int(head.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian)
        guard n >= 0, head.count >= 12 + n else { return nil }
        return String(decoding: head.subdata(in: 12..<(12 + n)), as: UTF8.self)
    }

    /// The photos (in the order they were written), decoded in parallel; nil if the file is missing or damaged.
    static func read(_ url: URL) -> [Photo]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 20 else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [Photo]? in
            guard Array(buf.prefix(8)) == magic else { return nil }
            var pos = 8
            func i32(_ p: inout Int) -> Int { let v = buf.loadUnaligned(fromByteOffset: p, as: Int32.self).littleEndian; p += 4; return Int(v) }
            let sn = i32(&pos); guard sn >= 0, pos + sn + 8 <= buf.count else { return nil }
            pos += sn
            let count = Int(buf.loadUnaligned(fromByteOffset: pos, as: Int64.self).littleEndian); pos += 8
            guard count >= 0, pos + count * 8 <= buf.count else { return nil }
            let table = pos, base = pos + count * 8
            let chunks = max(1, min(32, count / 2000))
            var parts = [[Photo]?](repeating: nil, count: chunks)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * count / chunks, hi = (c + 1) * count / chunks
                var out: [Photo] = []; out.reserveCapacity(hi - lo)
                var ok = true
                for i in lo..<hi {
                    var p = base + Int(buf.loadUnaligned(fromByteOffset: table + i * 8, as: UInt64.self).littleEndian)
                    guard p >= base, p + 70 <= buf.count else { ok = false; break }
                    func r64() -> Int { let v = buf.loadUnaligned(fromByteOffset: p, as: Int64.self).littleEndian; p += 8; return Int(v) }
                    func rf() -> Double { let v = Double(bitPattern: buf.loadUnaligned(fromByteOffset: p, as: UInt64.self).littleEndian); p += 8; return v }
                    func r32() -> Int { let v = buf.loadUnaligned(fromByteOffset: p, as: Int32.self).littleEndian; p += 4; return Int(v) }
                    func rs() -> String? {
                        let n = r32(); guard n >= 0, p + n <= buf.count else { return nil }
                        let s = String(decoding: UnsafeRawBufferPointer(rebasing: buf[p..<(p + n)]), as: UTF8.self); p += n; return s
                    }
                    let id = r64(), size = r64()
                    let mtime = rf(), added = rf(), date = rf(), del = rf()
                    let w = r32(), h = r32(), rating = r32(), rot = r32()
                    let flags = buf[p]; p += 1
                    guard let path = rs(), let fid = rs(), let ext = rs(), let camera = rs(), let lens = rs(), let exposure = rs(),
                          let label = rs(), let caption = rs(), let name = rs() else { ok = false; break }
                    let kn = r32(); guard kn >= 0, kn < 100_000 else { ok = false; break }
                    var kws: [String] = []; kws.reserveCapacity(kn)
                    for _ in 0..<kn { guard let k = rs() else { ok = false; break }; kws.append(k) }
                    guard ok else { break }
                    let rn = r32(); guard rn >= 0, p + rn <= buf.count else { ok = false; break }
                    var raw: [String: Any] = [:]
                    if rn > 0 {
                        raw = (try? JSONSerialization.jsonObject(with: Data(UnsafeRawBufferPointer(rebasing: buf[p..<(p + rn)])))) as? [String: Any] ?? [:]
                    }
                    out.append(Photo(id: id, path: path, fid: fid, ext: ext, size: size, mtime: mtime, added: added, date: date,
                                     dateFromFile: flags & 1 != 0, w: w, h: h, camera: camera, lens: lens, exposure: exposure,
                                     rating: rating, flag: flags & 2 != 0, label: flags & 16 != 0 ? label : nil, rejected: flags & 4 != 0,
                                     keywords: kws, caption: caption, name: name, rot: rot, deleted: del.isNaN ? nil : del,
                                     missing: flags & 8 != 0, raw: raw))
                }
                lock.lock(); parts[c] = ok ? out : nil; lock.unlock()
            }
            var all: [Photo] = []; all.reserveCapacity(count)
            for p in parts { guard let p else { return nil }; all.append(contentsOf: p) }
            return all.count == count ? all : nil
        }
    }
}

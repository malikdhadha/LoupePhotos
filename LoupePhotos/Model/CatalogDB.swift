import Foundation
import SQLite3

/// The catalog as a SQLite database (`<name>.apdb`), like Lightroom Classic's .lrcat.
/// Each photo is one row, so rating a photo writes just that row — no more rewriting the whole catalog —
/// and a half-finished write can never damage it (SQLite's write-ahead log).
/// Rows hold the same fields the JSON catalog had, so converting back (File ▸ Export Catalog as JSON) loses nothing.
final class CatalogDB {
    private var db: OpaquePointer?
    let url: URL
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS photos (id INTEGER PRIMARY KEY, data BLOB NOT NULL)")
        exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        // People: every face found (where, how good, its 512-number fingerprint, who it is) and the people you've named
        exec("CREATE TABLE IF NOT EXISTS faces (id INTEGER PRIMARY KEY, photo INTEGER NOT NULL, x REAL, y REAL, w REAL, h REAL, rot INTEGER, q REAL, emb BLOB, person INTEGER, grp INTEGER)")
        exec("CREATE INDEX IF NOT EXISTS faces_photo ON faces(photo)")
        exec("CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, key INTEGER, fav INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0)")
        exec("CREATE TABLE IF NOT EXISTS scanned (photo INTEGER PRIMARY KEY, n INTEGER)")
        exec("CREATE TABLE IF NOT EXISTS notperson (face INTEGER, person INTEGER, PRIMARY KEY (face, person))")   // "No, that isn't them"
        // Search: each photo's MobileCLIP fingerprint (512 half-floats), text read from it, and Apple's scene labels
        exec("CREATE TABLE IF NOT EXISTS hiddenface (face INTEGER PRIMARY KEY)")              // faces you've hidden from People
        exec("CREATE TABLE IF NOT EXISTS autoface (face INTEGER PRIMARY KEY, person INTEGER, score REAL)")  // named automatically, not yet checked
        if !hasColumn("autoface", "score") { exec("ALTER TABLE autoface ADD COLUMN score REAL") }
        exec("CREATE TABLE IF NOT EXISTS clip (photo INTEGER PRIMARY KEY, emb BLOB, words TEXT, labels TEXT)")
    }
    deinit { close() }
    func close() { if db != nil { sqlite3_close(db); db = nil } }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if let err { NSLog("catalog db: \(String(cString: err)) — \(sql)"); sqlite3_free(err) }
        return ok
    }

    // MARK: reading
    var photoCount: Int {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photos", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(st, 0))
    }
    /// Every photo row's raw bytes (decoded by the caller, in parallel).
    func photoRows() -> [Data] {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT data FROM photos", -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [Data] = []
        out.reserveCapacity(max(0, photoCount))
        while sqlite3_step(st) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(st, 0))
            if let p = sqlite3_column_blob(st, 0), n > 0 { out.append(Data(bytes: p, count: n)) }
        }
        return out
    }
    func value(_ key: String) -> Any? {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM kv WHERE key = ?", -1, &st, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(st, 1, key, -1, CatalogDB.TRANSIENT)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        let n = Int(sqlite3_column_bytes(st, 0))
        guard let p = sqlite3_column_blob(st, 0), n > 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n), options: [.fragmentsAllowed])
    }

    // MARK: writing (call from one serial queue)
    /// The fast catalog copy matches this database (CatalogSnapshot): the first change to any photo un-stamps it.
    var snapStamped = false
    private func unstamp() { if snapStamped { exec("DELETE FROM kv WHERE key = 'snapGen'"); snapStamped = false } }
    func writePhotos(_ rows: [(Int, Data)]) {
        guard !rows.isEmpty else { return }
        unstamp()
        exec("BEGIN")
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO photos (id, data) VALUES (?, ?)", -1, &st, nil) == SQLITE_OK {
            for (id, d) in rows {
                sqlite3_bind_int64(st, 1, Int64(id))
                _ = d.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(d.count), CatalogDB.TRANSIENT) }
                if sqlite3_step(st) != SQLITE_DONE { NSLog("catalog db: write failed for \(id)") }
                sqlite3_reset(st)
            }
        }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
    func deletePhotos(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        unstamp()
        exec("BEGIN")
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM photos WHERE id = ?", -1, &st, nil) == SQLITE_OK {
            for id in ids { sqlite3_bind_int64(st, 1, Int64(id)); sqlite3_step(st); sqlite3_reset(st) }
        }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
    func setValue(_ key: String, _ data: Data) {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", -1, &st, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(st, 1, key, -1, CatalogDB.TRANSIENT)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(data.count), CatalogDB.TRANSIENT) }
        sqlite3_step(st)
    }
    /// Folds the write-ahead log back into the main file (on quit), so the .apdb is one tidy file.
    func checkpoint() { exec("PRAGMA wal_checkpoint(TRUNCATE)") }

    // MARK: faces and people
    struct FaceRow { let id: Int; let photo: Int; let x, y, w, h: Double; let rot: Int; let q: Double; let emb: Data; let person: Int?; let grp: Int? }
    func readFaces() -> [FaceRow] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT id, photo, x, y, w, h, rot, q, emb, person, grp FROM faces", -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [FaceRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(st, 8))
            let emb = sqlite3_column_blob(st, 8).map { Data(bytes: $0, count: n) } ?? Data()
            out.append(FaceRow(id: Int(sqlite3_column_int64(st, 0)), photo: Int(sqlite3_column_int64(st, 1)),
                               x: sqlite3_column_double(st, 2), y: sqlite3_column_double(st, 3), w: sqlite3_column_double(st, 4), h: sqlite3_column_double(st, 5),
                               rot: Int(sqlite3_column_int(st, 6)), q: sqlite3_column_double(st, 7), emb: emb,
                               person: sqlite3_column_type(st, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 9)),
                               grp: sqlite3_column_type(st, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 10))))
        }
        return out
    }
    func readPeople() -> [(id: Int, name: String, key: Int?, fav: Bool, hidden: Bool)] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT id, name, key, fav, hidden FROM people", -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [(Int, String, Int?, Bool, Bool)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(st, 0)), String(cString: sqlite3_column_text(st, 1)),
                        sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 2)),
                        sqlite3_column_int(st, 3) != 0, sqlite3_column_int(st, 4) != 0))
        }
        return out.map { (id: $0.0, name: $0.1, key: $0.2, fav: $0.3, hidden: $0.4) }
    }
    func readScanned() -> Set<Int> {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT photo FROM scanned", -1, &st, nil) == SQLITE_OK else { return [] }
        var out = Set<Int>()
        while sqlite3_step(st) == SQLITE_ROW { out.insert(Int(sqlite3_column_int64(st, 0))) }
        return out
    }
    /// One photo's results: its faces (may be none) and the note that it has been looked at.
    func saveScan(_ faces: [FaceRow], photos: [(Int, Int)]) {
        exec("BEGIN")
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO faces (id, photo, x, y, w, h, rot, q, emb, person, grp) VALUES (?,?,?,?,?,?,?,?,?,?,?)", -1, &st, nil) == SQLITE_OK {
            for f in faces {
                sqlite3_bind_int64(st, 1, Int64(f.id)); sqlite3_bind_int64(st, 2, Int64(f.photo))
                sqlite3_bind_double(st, 3, f.x); sqlite3_bind_double(st, 4, f.y); sqlite3_bind_double(st, 5, f.w); sqlite3_bind_double(st, 6, f.h)
                sqlite3_bind_int(st, 7, Int32(f.rot)); sqlite3_bind_double(st, 8, f.q)
                _ = f.emb.withUnsafeBytes { sqlite3_bind_blob(st, 9, $0.baseAddress, Int32(f.emb.count), CatalogDB.TRANSIENT) }
                if let p = f.person { sqlite3_bind_int64(st, 10, Int64(p)) } else { sqlite3_bind_null(st, 10) }
                if let g = f.grp { sqlite3_bind_int64(st, 11, Int64(g)) } else { sqlite3_bind_null(st, 11) }
                sqlite3_step(st); sqlite3_reset(st)
            }
        }
        sqlite3_finalize(st)
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO scanned (photo, n) VALUES (?, ?)", -1, &st, nil) == SQLITE_OK {
            for (p, n) in photos { sqlite3_bind_int64(st, 1, Int64(p)); sqlite3_bind_int(st, 2, Int32(n)); sqlite3_step(st); sqlite3_reset(st) }
        }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
    /// Who each face belongs to (named person, or an unnamed group).
    func setAssignments(_ a: [(id: Int, person: Int?, grp: Int?)]) {
        guard !a.isEmpty else { return }
        exec("BEGIN")
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE faces SET person = ?, grp = ? WHERE id = ?", -1, &st, nil) == SQLITE_OK {
            for x in a {
                if let p = x.person { sqlite3_bind_int64(st, 1, Int64(p)) } else { sqlite3_bind_null(st, 1) }
                if let g = x.grp { sqlite3_bind_int64(st, 2, Int64(g)) } else { sqlite3_bind_null(st, 2) }
                sqlite3_bind_int64(st, 3, Int64(x.id)); sqlite3_step(st); sqlite3_reset(st)
            }
        }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
    func savePerson(id: Int, name: String, key: Int?, fav: Bool, hidden: Bool) {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO people (id, name, key, fav, hidden) VALUES (?,?,?,?,?)", -1, &st, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(st, 1, Int64(id)); sqlite3_bind_text(st, 2, name, -1, CatalogDB.TRANSIENT)
        if let key { sqlite3_bind_int64(st, 3, Int64(key)) } else { sqlite3_bind_null(st, 3) }
        sqlite3_bind_int(st, 4, fav ? 1 : 0); sqlite3_bind_int(st, 5, hidden ? 1 : 0)
        sqlite3_step(st)
    }
    func readNotPerson() -> [Int: Set<Int>] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT face, person FROM notperson", -1, &st, nil) == SQLITE_OK else { return [:] }
        var out: [Int: Set<Int>] = [:]
        while sqlite3_step(st) == SQLITE_ROW { out[Int(sqlite3_column_int64(st, 0)), default: []].insert(Int(sqlite3_column_int64(st, 1))) }
        return out
    }
    func addNotPerson(_ pairs: [(face: Int, person: Int)]) {
        guard !pairs.isEmpty else { return }
        exec("BEGIN")
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO notperson (face, person) VALUES (?, ?)", -1, &st, nil) == SQLITE_OK {
            for p in pairs { sqlite3_bind_int64(st, 1, Int64(p.face)); sqlite3_bind_int64(st, 2, Int64(p.person)); sqlite3_step(st); sqlite3_reset(st) }
        }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
    func deletePerson(_ id: Int) { exec("DELETE FROM people WHERE id = \(id)") }
    func deleteFaces(ofPhotos ids: [Int]) {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init).joined(separator: ",")
        exec("DELETE FROM faces WHERE photo IN (\(list))"); exec("DELETE FROM scanned WHERE photo IN (\(list))")
    }

    // MARK: search index
    struct ClipRow { let photo: Int; let emb: Data; let words: String; let labels: String }
    func readClip() -> [ClipRow] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT photo, emb, words, labels FROM clip", -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [ClipRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(st, 1))
            let e = n > 0 ? sqlite3_column_blob(st, 1).map { Data(bytes: $0, count: n) } ?? Data() : Data()
            let w = sqlite3_column_text(st, 2).map { String(cString: $0) } ?? ""
            let l = sqlite3_column_text(st, 3).map { String(cString: $0) } ?? ""
            out.append(ClipRow(photo: Int(sqlite3_column_int64(st, 0)), emb: e, words: w, labels: l))
        }
        return out
    }
    func saveClip(_ rows: [ClipRow]) {
        guard !rows.isEmpty else { return }
        exec("BEGIN")
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO clip (photo, emb, words, labels) VALUES (?,?,?,?)", -1, &st, nil) == SQLITE_OK {
            for r in rows {
                sqlite3_bind_int64(st, 1, Int64(r.photo))
                _ = r.emb.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(r.emb.count), CatalogDB.TRANSIENT) }
                sqlite3_bind_text(st, 3, r.words, -1, CatalogDB.TRANSIENT)
                sqlite3_bind_text(st, 4, r.labels, -1, CatalogDB.TRANSIENT)
                sqlite3_step(st); sqlite3_reset(st)
            }
        }
        sqlite3_finalize(st)
        exec("COMMIT")
    }
    func deleteClip(ofPhotos ids: [Int]?) {
        guard let ids else { exec("DELETE FROM clip"); return }
        guard !ids.isEmpty else { return }
        exec("DELETE FROM clip WHERE photo IN (\(ids.map(String.init).joined(separator: ",")))")
    }

    // MARK: hidden and automatically-named faces
    func readHiddenFaces() -> Set<Int> {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT face FROM hiddenface", -1, &st, nil) == SQLITE_OK else { return [] }
        var out = Set<Int>()
        while sqlite3_step(st) == SQLITE_ROW { out.insert(Int(sqlite3_column_int64(st, 0))) }
        return out
    }
    func setHiddenFaces(_ ids: [Int], _ on: Bool) {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init)
        if on { exec("BEGIN"); for i in list { exec("INSERT OR IGNORE INTO hiddenface (face) VALUES (\(i))") }; exec("COMMIT") }
        else { exec("DELETE FROM hiddenface WHERE face IN (\(list.joined(separator: ",")))") }
    }
    func readAutoFaces() -> [Int: (person: Int, score: Float)] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT face, person, score FROM autoface", -1, &st, nil) == SQLITE_OK else { return [:] }
        var out: [Int: (person: Int, score: Float)] = [:]
        while sqlite3_step(st) == SQLITE_ROW { out[Int(sqlite3_column_int64(st, 0))] = (Int(sqlite3_column_int64(st, 1)), Float(sqlite3_column_double(st, 2))) }
        return out
    }
    func addAutoFaces(_ rows: [(face: Int, person: Int, score: Float)]) {
        guard !rows.isEmpty else { return }
        exec("BEGIN"); for p in rows { exec("INSERT OR REPLACE INTO autoface (face, person, score) VALUES (\(p.face), \(p.person), \(p.score))") }; exec("COMMIT")
    }
    private func hasColumn(_ table: String, _ col: String) -> Bool {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK else { return false }
        while sqlite3_step(st) == SQLITE_ROW { if let n = sqlite3_column_text(st, 1), String(cString: n) == col { return true } }
        return false
    }
    func removeAutoFaces(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        exec("DELETE FROM autoface WHERE face IN (\(ids.map(String.init).joined(separator: ",")))")
    }

    /// Settings ▸ People ▸ Start Over: every face, person and answer goes.
    func resetFaces() {
        exec("BEGIN")
        for t in ["faces", "people", "scanned", "notperson", "hiddenface", "autoface"] { exec("DELETE FROM \(t)") }
        exec("COMMIT")
    }
}

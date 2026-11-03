// Catalog.swift – Capture Review
// One SQLite catalog per Capture One session: <Session>/.capturereview/catalog.sqlite
// It travels and backs up with the session.
//
// What it's for:
//   - IDENTITY: every RAW gets a permanent image_id. Files are matched by the Mac's file ID
//     (survives renames and moves on the same drive), then by a content fingerprint (size +
//     SHA-256 of the first and last 1 MB: survives copies to another drive). The filename is
//     only where the image is right now.
//   - HISTORY: added / renamed / moved / deleted (Trash or gone) / restored, with timestamps.
//   - WHAT WAS SENT: the adjustments each variant had when its proof went out, so a re-grade
//     can be judged against what the client actually sees (VisualChange), across relaunches.
//
// The catalog is a record, not the truth: the folders on disk say what exists, the server says
// what the client did. If this file is lost or damaged, delete it; it rebuilds from disk.

import Foundation
import SQLite3
import CryptoKit

nonisolated struct CatalogEvent: Sendable {
    enum Kind: String, Sendable { case created, added, renamed, moved, deleted, restored }
    let kind: Kind
    let imageID: String
    let name: String       // file name now (or when it was last seen)
    let detail: String     // readable, for the log
}

nonisolated struct CatalogImage: Sendable {
    var id: String
    var fileID: Int64
    var volumeID: Int64
    var size: Int64
    var fingerprint: String          // "" = not computed yet
    var relPath: String              // session-relative, e.g. "Capture/Set_01/A.CR3"
    var state: String                // present | missing | deleted
    var firstSeen: Double
    var stateChanged: Double

    var filename: String { (relPath as NSString).lastPathComponent }
    var folder: String { (relPath as NSString).deletingLastPathComponent }
}

nonisolated enum SQLValue: Sendable {
    case text(String), int(Int64), real(Double), null
}

actor Catalog {
    nonisolated let sessionRoot: URL
    nonisolated let fileURL: URL
    /// Permanent id of this session (its gallery is keyed on it). Changes only when the user says a
    /// copied session is a new job.
    private(set) var sessionID: String
    /// Session folder name recorded the last time the catalog was opened (nil = first time).
    /// A different name usually means the session folder was copied for a new job.
    nonisolated let storedSessionName: String?

    private let db: OpaquePointer?
    private var images: [String: CatalogImage] = [:]
    private var pathIndex: [String: String] = [:]          // relPath -> image_id (not deleted)
    private var sent: [String: String] = [:]               // "image_id#position" -> live text sent
    private var sentDisk: [String: [String]] = [:]
    /// The session has been catalogued once (an empty session is not "first run" forever)
    private var initialScanDone = false
    /// Events not yet written to the upload log (any caller's scan adds to it; the window drains it)
    private var undelivered: [CatalogEvent] = []         // "image_id#position" -> settings-file entries after the send

    /// A file that vanished is only called deleted after it has stayed gone this long
    /// (a move or rename shows up again in the next scan).
    private let deleteGrace: TimeInterval = 10
    /// Fingerprints for images catalogued before they had one, filled in a few per scan.
    private let fingerprintsPerScan = 20

    nonisolated static let rawExtensions: Set<String> =
        ["cr3", "cr2", "nef", "arw", "raf", "iiq", "3fr", "fff", "dng", "orf", "rw2", "tif", "tiff"]
    /// Session folders scanned (top level + one level of subfolders, like the Capture folder list).
    nonisolated static let scannedFolders = ["Capture", "Selects", "Trash"]

    init?(sessionRoot: URL) {
        self.sessionRoot = sessionRoot.standardizedFileURL
        let dir = self.sessionRoot.appendingPathComponent(".capturereview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("catalog.sqlite")

        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { sqlite3_close(handle); return nil }
        db = handle

        Self.exec(handle, """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS images(
            image_id TEXT PRIMARY KEY,
            file_id INTEGER, volume_id INTEGER, size INTEGER, fingerprint TEXT,
            rel_path TEXT, filename TEXT, state TEXT,
            first_seen REAL, state_changed REAL);
        CREATE INDEX IF NOT EXISTS images_path ON images(rel_path);
        CREATE TABLE IF NOT EXISTS variants(
            image_id TEXT, position INTEGER, c1_variant_id TEXT,
            sent_live TEXT, sent_at REAL, proof_path TEXT, thumb_path TEXT, quality TEXT,
            PRIMARY KEY(image_id, position));
        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL, image_id TEXT, kind TEXT, detail TEXT);
        """)

        // v2: settings-file baseline per variant (added once; checked first so SQLite logs nothing)
        var hasSentDisk = false
        Self.query(handle, "SELECT 1 FROM pragma_table_info('variants') WHERE name='sent_disk'") { _ in hasSentDisk = true }
        if !hasSentDisk { Self.exec(handle, "ALTER TABLE variants ADD COLUMN sent_disk TEXT") }

        // Session identity: made once, kept forever (galleries will be keyed on this, not the name)
        var sid = ""
        Self.query(handle, "SELECT value FROM meta WHERE key='session_id'") { sid = Self.text($0, 0) }
        if sid.isEmpty {
            sid = UUID().uuidString
            Self.run(handle, "INSERT OR REPLACE INTO meta(key, value) VALUES('session_id', ?)", [.text(sid)])
            Self.run(handle, "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', '1')", [])
        }
        sessionID = sid
        var storedName: String?
        Self.query(handle, "SELECT value FROM meta WHERE key='session_name'") { storedName = Self.text($0, 0) }
        storedSessionName = storedName

        var loaded: [String: CatalogImage] = [:]
        Self.query(handle, """
        SELECT image_id, file_id, volume_id, size, fingerprint, rel_path, state, first_seen, state_changed FROM images
        """) { s in
            let img = CatalogImage(id: Self.text(s, 0), fileID: sqlite3_column_int64(s, 1),
                                   volumeID: sqlite3_column_int64(s, 2), size: sqlite3_column_int64(s, 3),
                                   fingerprint: Self.text(s, 4), relPath: Self.text(s, 5), state: Self.text(s, 6),
                                   firstSeen: sqlite3_column_double(s, 7), stateChanged: sqlite3_column_double(s, 8))
            loaded[img.id] = img
        }
        images = loaded
        var scanned = false
        Self.query(handle, "SELECT 1 FROM meta WHERE key='initial_scan'") { _ in scanned = true }
        initialScanDone = scanned || !loaded.isEmpty
        var loadedSent: [String: String] = [:]
        Self.query(handle, "SELECT image_id, position, sent_live FROM variants WHERE sent_live IS NOT NULL") { s in
            loadedSent["\(Self.text(s, 0))#\(sqlite3_column_int(s, 1))"] = Self.text(s, 2)
        }
        sent = loadedSent
        var loadedDisk: [String: [String]] = [:]
        Self.query(handle, "SELECT image_id, position, sent_disk FROM variants WHERE sent_disk IS NOT NULL") { s in
            loadedDisk["\(Self.text(s, 0))#\(sqlite3_column_int(s, 1))"] =
                Self.text(s, 2).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        sentDisk = loadedDisk
        var index: [String: String] = [:]
        for img in loaded.values where img.state != "deleted" { index[img.relPath] = img.id }
        pathIndex = index
    }

    deinit { sqlite3_close(db) }

    /// Events since the last call (from every scan, whoever ran it).
    func drainEvents() -> [CatalogEvent] {
        defer { undelivered = [] }
        return undelivered
    }

    // MARK: - Session identity

    /// Records the session folder's current name (same job, possibly renamed or moved).
    func setSessionName(_ name: String) {
        Self.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('session_name', ?)", [.text(name)])
    }

    /// A copied session used for a NEW job: new session id (so a new gallery), and nothing counts
    /// as sent any more. Image identities and history are kept.
    func startNewJob(name: String) -> String {
        let old = sessionID
        sessionID = UUID().uuidString
        Self.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('session_id', ?)", [.text(sessionID)])
        Self.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('session_name', ?)", [.text(name)])
        Self.run(db, "DELETE FROM meta WHERE key='gallery_id'", [])
        Self.run(db, "INSERT INTO events(at, image_id, kind, detail) VALUES(?,?,?,?)",
                 [.real(Date().timeIntervalSince1970), .text(""), .text("new_job"),
                  .text("Session copied for a new job (was \(old))")])
        forgetSent()
        return sessionID
    }

    /// The gallery this session publishes to (remembered so the session opens offline too).
    func storedGalleryID() -> UUID? {
        var value = ""
        Self.query(db, "SELECT value FROM meta WHERE key='gallery_id'") { value = Self.text($0, 0) }
        return UUID(uuidString: value)
    }

    func setGalleryID(_ id: UUID) {
        Self.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('gallery_id', ?)", [.text(id.uuidString)])
    }

    /// Whether this image is currently in the Capture folders (false: deleted, missing, or moved out).
    func isInCapture(uid: String) -> Bool {
        guard let img = images[uid] else { return true }        // unknown: don't block the upload
        return img.state != "deleted" && img.relPath.hasPrefix("Capture/")
    }

    /// RAW file names on disk per Capture folder ("" = Capture root), for the folder list.
    func capturedFiles() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for img in images.values where img.state == "present" && img.relPath.hasPrefix("Capture/") {
            let rel = img.relPath.dropFirst("Capture/".count)
            let parts = rel.split(separator: "/")
            let folder = parts.count > 1 ? String(parts[0]) : ""
            out[folder, default: []].insert(String(parts.last ?? Substring(rel)))
        }
        return out
    }

    /// Every image the catalog knows (for syncing the gallery).
    func snapshot() -> [CatalogImage] { Array(images.values) }

    /// The permanent id of the image at this Capture path ("Set_01/A.CR3"), if catalogued.
    func imageUID(captureRel: String) -> String? { imageID(captureRel: captureRel) }

    // MARK: - Scanning

    nonisolated private struct DiskFile {
        let rel: String
        let url: URL
        let fileID: Int64
        let volumeID: Int64
        let size: Int64
        let modified: Date
    }

    /// Compares the session folders with the catalog and records what changed.
    /// Cheap enough to run every few seconds (one directory listing + one stat per RAW;
    /// fingerprints only for files it hasn't seen before).
    @discardableResult
    func scan() -> [CatalogEvent] {
        let files = listDisk()
        let now = Date().timeIntervalSince1970
        let firstRun = !initialScanDone
        var events: [CatalogEvent] = []
        var seen = Set<String>()
        var dirty = Set<String>()

        var byFile: [String: String] = [:]
        var byPath: [String: String] = [:]
        for img in images.values {
            if img.fileID != 0 { byFile["\(img.volumeID):\(img.fileID)"] = img.id }
            if img.state != "deleted" || byPath[img.relPath] == nil { byPath[img.relPath] = img.id }
        }

        func match(_ id: String, _ f: DiskFile) {
            guard var img = images[id] else { return }
            seen.insert(id)
            let oldRel = img.relPath, oldState = img.state
            let inTrash = f.rel.hasPrefix("Trash/")
            let newState = inTrash ? "deleted" : "present"
            var changed = false

            if img.fileID != f.fileID || img.volumeID != f.volumeID {
                img.fileID = f.fileID; img.volumeID = f.volumeID; changed = true
            }
            if img.size != f.size { img.size = f.size; img.fingerprint = ""; changed = true }

            if oldRel != f.rel {
                img.relPath = f.rel; changed = true
                let oldName = (oldRel as NSString).lastPathComponent
                if inTrash && oldState != "deleted" {
                    events.append(.init(kind: .deleted, imageID: id, name: f.url.lastPathComponent,
                                        detail: "\(oldRel) moved to Trash"))
                } else if oldRel.hasPrefix("Trash/") && !inTrash {
                    events.append(.init(kind: .restored, imageID: id, name: f.url.lastPathComponent,
                                        detail: "restored from Trash to \(f.rel)"))
                } else if (oldRel as NSString).deletingLastPathComponent == (f.rel as NSString).deletingLastPathComponent {
                    events.append(.init(kind: .renamed, imageID: id, name: f.url.lastPathComponent,
                                        detail: "\(oldName) → \(f.url.lastPathComponent)"))
                } else {
                    events.append(.init(kind: .moved, imageID: id, name: f.url.lastPathComponent,
                                        detail: "\(oldRel) → \(f.rel)"))
                }
            } else if oldState == "deleted" && !inTrash {
                events.append(.init(kind: .restored, imageID: id, name: f.url.lastPathComponent,
                                    detail: "back at \(f.rel)"))
            }
            if oldState != newState { img.state = newState; img.stateChanged = now; changed = true }
            images[id] = img
            if changed { dirty.insert(id) }
        }

        var unmatched: [DiskFile] = []
        for f in files {
            if let id = byFile["\(f.volumeID):\(f.fileID)"], !seen.contains(id) { match(id, f) }
            else if let id = byPath[f.rel], !seen.contains(id) { match(id, f) }      // same place, replaced file
            else { unmatched.append(f) }
        }

        for f in unmatched {
            // Still being written (tethered transfer): catalogue it next scan, once complete
            if !firstRun, now - f.modified.timeIntervalSince1970 < 2 { continue }
            let fp = firstRun ? "" : Self.fingerprint(f.url, size: f.size)
            if !fp.isEmpty, let other = images.values.first(where: {
                !seen.contains($0.id) && $0.size == f.size && $0.fingerprint == fp
            }) {
                match(other.id, f)                                     // copied/moved across drives
                continue
            }
            let id = UUID().uuidString
            images[id] = CatalogImage(id: id, fileID: f.fileID, volumeID: f.volumeID, size: f.size,
                                      fingerprint: fp, relPath: f.rel,
                                      state: f.rel.hasPrefix("Trash/") ? "deleted" : "present",
                                      firstSeen: now, stateChanged: now)
            seen.insert(id)
            dirty.insert(id)
            if !firstRun {
                events.append(.init(kind: .added, imageID: id, name: f.url.lastPathComponent, detail: f.rel))
            }
        }

        // Gone from every scanned folder: missing first, deleted after the grace period
        for (id, var img) in images where !seen.contains(id) {
            if img.state == "present" {
                img.state = "missing"; img.stateChanged = now
                images[id] = img; dirty.insert(id)
            } else if img.state == "missing", now - img.stateChanged >= deleteGrace {
                img.state = "deleted"; img.stateChanged = now
                images[id] = img; dirty.insert(id)
                events.append(.init(kind: .deleted, imageID: id, name: img.filename,
                                    detail: "\(img.relPath) is no longer in the session"))
            }
        }

        // Back-fill fingerprints for images catalogued without one (first run), a few at a time
        if !firstRun {
            var budget = fingerprintsPerScan
            for (id, var img) in images where budget > 0 && img.fingerprint.isEmpty && img.state == "present" {
                budget -= 1
                img.fingerprint = Self.fingerprint(sessionRoot.appendingPathComponent(img.relPath), size: img.size)
                if !img.fingerprint.isEmpty { images[id] = img; dirty.insert(id) }
            }
        }

        if firstRun {
            initialScanDone = true
            Self.run(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('initial_scan', ?)",
                     [.text(String(Date().timeIntervalSince1970))])
            events.append(.init(kind: .created, imageID: "", name: "Catalog",
                                detail: "Catalog created: \(images.count) images (session \(sessionID.prefix(8)))"))
        }
        save(dirty: dirty, events: events)
        undelivered.append(contentsOf: events)

        var index: [String: String] = [:]
        for img in images.values where img.state != "deleted" { index[img.relPath] = img.id }
        pathIndex = index
        return events
    }

    private func listDisk() -> [DiskFile] {
        let fm = FileManager.default
        var out: [DiskFile] = []
        for top in Self.scannedFolders {
            let base = sessionRoot.appendingPathComponent(top)
            var dirs: [(url: URL, rel: String)] = [(base, top)]
            let subs = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for s in subs where s.lastPathComponent != "CaptureOne"
                && (try? s.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append((s, top + "/" + s.lastPathComponent))
            }
            for (dir, rel) in dirs {
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                where !name.hasPrefix(".") && Self.rawExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    let url = dir.appendingPathComponent(name)
                    guard let a = try? fm.attributesOfItem(atPath: url.path),
                          (a[.type] as? FileAttributeType) == .typeRegular else { continue }
                    out.append(DiskFile(rel: rel + "/" + name, url: url,
                                        fileID: (a[.systemFileNumber] as? NSNumber)?.int64Value ?? 0,
                                        volumeID: (a[.systemNumber] as? NSNumber)?.int64Value ?? 0,
                                        size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                                        modified: (a[.modificationDate] as? Date) ?? .distantPast))
                }
            }
        }
        return out
    }

    private func save(dirty: Set<String>, events: [CatalogEvent]) {
        guard !dirty.isEmpty || !events.isEmpty else { return }
        Self.exec(db, "BEGIN")
        for id in dirty {
            guard let i = images[id] else { continue }
            Self.run(db, """
            INSERT INTO images(image_id, file_id, volume_id, size, fingerprint, rel_path, filename, state, first_seen, state_changed)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(image_id) DO UPDATE SET file_id=excluded.file_id, volume_id=excluded.volume_id,
              size=excluded.size, fingerprint=excluded.fingerprint, rel_path=excluded.rel_path,
              filename=excluded.filename, state=excluded.state, state_changed=excluded.state_changed
            """, [.text(i.id), .int(i.fileID), .int(i.volumeID), .int(i.size), .text(i.fingerprint),
                  .text(i.relPath), .text(i.filename), .text(i.state), .real(i.firstSeen), .real(i.stateChanged)])
        }
        let now = Date().timeIntervalSince1970
        for e in events {
            Self.run(db, "INSERT INTO events(at, image_id, kind, detail) VALUES(?,?,?,?)",
                     [.real(now), .text(e.imageID), .text(e.kind.rawValue), .text(e.detail)])
        }
        Self.exec(db, "COMMIT")
    }

    // MARK: - What was sent (re-grade baseline)

    /// `captureRel` is the uploader's path inside Capture: "Set_01/A.CR3" or "A.CR3".
    private func imageID(captureRel: String) -> String? {
        let rel = "Capture/" + captureRel
        if let id = pathIndex[rel] { return id }
        scan()                                    // brand-new file the 3 s scan hasn't seen yet
        return pathIndex[rel]
    }

    /// Adjustments the client's proof was made with (nil = not recorded).
    func sentLive(captureRel: String, position: Int) -> String? {
        guard let id = pathIndex["Capture/" + captureRel] else { return nil }
        return sent["\(id)#\(position)"]
    }

    /// Records what went out with a proof.
    func recordSent(captureRel: String, position: Int, variantID: String, live: String,
                    proofPath: String, thumbPath: String, quality: String) {
        guard !live.isEmpty, let id = imageID(captureRel: captureRel) else { return }
        sent["\(id)#\(position)"] = live
        Self.run(db, """
        INSERT INTO variants(image_id, position, c1_variant_id, sent_live, sent_at, proof_path, thumb_path, quality)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(image_id, position) DO UPDATE SET c1_variant_id=excluded.c1_variant_id,
          sent_live=excluded.sent_live, sent_at=excluded.sent_at, proof_path=excluded.proof_path,
          thumb_path=excluded.thumb_path, quality=excluded.quality
        """, [.text(id), .int(Int64(position)), .text(variantID), .text(live),
              .real(Date().timeIntervalSince1970), .text(proofPath), .text(thumbPath), .text(quality)])
    }

    /// For proofs sent before the catalog existed: when Capture One's adjustments still match
    /// the uploaded fingerprint exactly, adopt them as the baseline (only if none is recorded).
    func adoptBaseline(captureRel: String, position: Int, variantID: String, live: String) {
        guard !live.isEmpty, let id = pathIndex["Capture/" + captureRel], sent["\(id)#\(position)"] == nil else { return }
        sent["\(id)#\(position)"] = live
        Self.run(db, """
        INSERT INTO variants(image_id, position, c1_variant_id, sent_live, sent_at) VALUES(?,?,?,?,?)
        ON CONFLICT(image_id, position) DO UPDATE SET sent_live=excluded.sent_live, c1_variant_id=excluded.c1_variant_id
        """, [.text(id), .int(Int64(position)), .text(variantID), .text(live), .real(Date().timeIntervalSince1970)])
    }

    /// Settings-file entries recorded at the first flush after the proof went out (nil = none).
    func diskBaseline(captureRel: String, position: Int) -> [String]? {
        guard let id = pathIndex["Capture/" + captureRel] else { return nil }
        return sentDisk["\(id)#\(position)"]
    }

    /// Records the settings-file entries that match the client's proof. `overwrite` false:
    /// only if none is recorded yet (proofs sent before the catalog existed).
    func recordDiskBaseline(captureRel: String, position: Int, entries: [String], overwrite: Bool) {
        guard !entries.isEmpty, let id = imageID(captureRel: captureRel) else { return }
        let key = "\(id)#\(position)"
        if !overwrite, sentDisk[key] != nil { return }
        sentDisk[key] = entries
        Self.run(db, """
        INSERT INTO variants(image_id, position, sent_disk) VALUES(?,?,?)
        ON CONFLICT(image_id, position) DO UPDATE SET sent_disk=excluded.sent_disk
        """, [.text(id), .int(Int64(position)), .text(entries.joined(separator: "\n"))])
    }

    /// Test reset: the gallery was wiped, so nothing counts as sent any more.
    func forgetSent() {
        sent = [:]
        sentDisk = [:]
        Self.exec(db, "DELETE FROM variants")
    }

    // MARK: - Fingerprint

    /// Size + SHA-256 of the first and last 1 MB. Reading 2 MB is fast, and a rename or move
    /// never changes the bytes.
    nonisolated static func fingerprint(_ url: URL, size: Int64) -> String {
        guard size > 0, let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let chunk = 1 << 20
        var hasher = SHA256()
        hasher.update(data: Data("\(size):".utf8))
        if let head = try? h.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(2 * chunk) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SQLite helpers

    nonisolated private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    nonisolated private static func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    nonisolated private static func prepare(_ db: OpaquePointer?, _ sql: String, _ args: [SQLValue]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .int(let v):  sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            case .null:        sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    nonisolated private static func run(_ db: OpaquePointer?, _ sql: String, _ args: [SQLValue]) {
        guard let stmt = prepare(db, sql, args) else { return }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    nonisolated private static func query(_ db: OpaquePointer?, _ sql: String, _ args: [SQLValue] = [],
                              _ row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(db, sql, args) else { return }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        sqlite3_finalize(stmt)
    }

    nonisolated private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}

// CosMonitor.swift – Capture Review
// Diagnostics: records everything Capture One does to the session's settings files
// (<folder>/CaptureOne/Settings*/<RAW>.cos), plus every re-grade decision the planner makes.
//
// Written to ~/Library/Logs/CaptureReview/<session>-settings.log (tab-separated):
//   time (ms)  source (Files / Planner / Monitor)  file  event  detail
//
// Per write: which settings changed (old → new, per variant), including the bookkeeping keys the
// fingerprint ignores (marked [ignored]); variants added/removed (clones); layers/masks added or
// removed; file size; whether the file was replaced (new inode) or rewritten in place; seconds
// since the previous write; and reads that hit a half-written file.

import Foundation
import CoreServices

/// Thread-safe line writer for the settings log.
nonisolated final class CosLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "capture-review.settings-log")
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter

    init(session: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CaptureReview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(session)-settings.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path,
                                           contents: Data("time\tsource\tfile\tevent\tdetail\n".utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit { try? handle?.close() }

    func write(source: String, file: String, event: String, detail: String) {
        let time = Date()
        queue.async { [self] in
            func clean(_ s: String) -> String {
                s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            let line = "\(formatter.string(from: time))\t\(source)\t\(clean(file))\t\(clean(event))\t\(clean(detail))\n"
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }
}

/// Watches the session's settings folders with FSEvents and logs every change in detail.
/// All state lives on one serial queue (FSEvents delivers there too), so events stay in order.
nonisolated final class CosMonitor: @unchecked Sendable {
    private let root: URL
    private let log: CosLog
    private let queue = DispatchQueue(label: "capture-review.settings-monitor", qos: .utility)
    private var stream: FSEventStreamRef?

    nonisolated private struct Snapshot {
        var variants: [[String]]     // per variant: every entry, ignored keys included
        var size: Int64
        var inode: Int64
        var modified: Date
        var loggedAt: Date
    }
    private var known: [String: Snapshot] = [:]      // session-relative path -> last read

    init(sessionRoot: URL, log: CosLog) {
        root = sessionRoot.standardizedFileURL
        self.log = log
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Reads every existing settings file first (so the first write already shows a diff),
    /// then starts watching. Runs in the background.
    func start() {
        queue.async { [self] in
            let t0 = Date()
            var count = 0
            for file in settingsFiles() {
                guard let snap = read(file) else { continue }
                known[relative(file.path)] = snap
                count += 1
            }
            log.write(source: "Monitor", file: root.lastPathComponent, event: "started",
                      detail: String(format: "read %d settings files in %.1f s; watching for changes", count,
                                     Date().timeIntervalSince(t0)))
            startStream()
        }
    }

    // MARK: - Watching

    private func startStream() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<CosMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            for i in 0..<min(count, list.count) { monitor.handle(path: list[i], flags: flags[i]) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    /// One FSEvents event (on `queue`).
    private func handle(path: String, flags: FSEventStreamEventFlags) {
        guard path.contains("/CaptureOne/Settings") else { return }
        let rel = relative(path)
        let name = (path as NSString).lastPathComponent
        let what = Self.describe(flags)
        let fm = FileManager.default

        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            if known.removeValue(forKey: rel) != nil || name.lowercased().hasSuffix(".cos") {
                log.write(source: "Files", file: rel, event: "removed", detail: "flags: \(what)")
            }
            return
        }
        if (attrs[.type] as? FileAttributeType) == .typeDirectory { return }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast

        // Temp files, masks and anything else Capture One writes in the settings folders
        guard name.lowercased().hasSuffix(".cos") else {
            log.write(source: "Files", file: rel, event: "other file",
                      detail: "flags: \(what) · \(Self.kb(size))")
            return
        }

        let previous = known[rel]
        // FSEvents often reports one write twice: skip if nothing about the file changed
        if let previous, previous.size == size, previous.inode == inode, previous.modified == modified { return }

        var notes = ["flags: \(what)", Self.kb(size)]
        if let previous {
            if previous.inode != inode { notes.append("replaced (new inode)") } else { notes.append("rewritten in place") }
            notes.append(String(format: "%.1f s since last write", Date().timeIntervalSince(previous.loggedAt)))
        } else {
            notes.append("first time seen")
        }

        guard var snap = read(URL(fileURLWithPath: path), size: size, inode: inode, modified: modified) else {
            log.write(source: "Files", file: rel, event: "unreadable",
                      detail: "couldn't parse (Capture One mid-write?) · " + notes.joined(separator: " · "))
            return
        }
        snap.loggedAt = Date()
        known[rel] = snap

        guard let previous else {
            let entries = snap.variants.reduce(0) { $0 + $1.count }
            log.write(source: "Files", file: rel, event: "new settings file",
                      detail: "\(snap.variants.count) variant(s), \(entries) entries · " + notes.joined(separator: " · "))
            return
        }

        var changes: [String] = []
        if previous.variants.count != snap.variants.count {
            changes.append("variants \(previous.variants.count)→\(snap.variants.count)"
                           + (snap.variants.count > previous.variants.count ? " (clone added)" : " (variant removed)"))
        }
        for i in 0..<max(previous.variants.count, snap.variants.count) {
            let before = i < previous.variants.count ? previous.variants[i] : []
            let after = i < snap.variants.count ? snap.variants[i] : []
            let diff = Self.diff(before, after)
            if !diff.isEmpty { changes.append("v\(i + 1): " + diff.joined(separator: "; ")) }
        }
        log.write(source: "Files", file: rel,
                  event: changes.isEmpty ? "rewritten, no setting changes" : "modified",
                  detail: (changes.isEmpty ? "" : changes.joined(separator: " || ") + " · ") + notes.joined(separator: " · "))
    }

    // MARK: - Reading

    private func read(_ url: URL) -> Snapshot? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return read(url, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                    inode: (a[.systemFileNumber] as? NSNumber)?.int64Value ?? 0,
                    modified: (a[.modificationDate] as? Date) ?? .distantPast)
    }

    private func read(_ url: URL, size: Int64, inode: Int64, modified: Date) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let reader = CosAdjustmentReader()
        reader.keepIgnored = true
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return Snapshot(variants: reader.entries, size: size, inode: inode, modified: modified, loggedAt: Date())
    }

    /// Every .cos in the session's Capture and Selects folders (and one level of subfolders).
    private func settingsFiles() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        for top in ["Capture", "Selects"] {
            let base = root.appendingPathComponent(top)
            dirs.append(base)
            for s in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
            where s.lastPathComponent != "CaptureOne"
                && (try? s.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append(s)
            }
        }
        var out: [URL] = []
        for dir in dirs {
            let c1 = dir.appendingPathComponent("CaptureOne")
            for sub in (try? fm.contentsOfDirectory(atPath: c1.path)) ?? [] where sub.hasPrefix("Settings") {
                let folder = c1.appendingPathComponent(sub)
                for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where f.lowercased().hasSuffix(".cos") {
                    out.append(folder.appendingPathComponent(f))
                }
            }
        }
        return out
    }

    private func relative(_ path: String) -> String {
        let r = root.path
        return path.hasPrefix(r) ? String(path.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
    }

    // MARK: - Formatting

    /// Entry-level differences between two reads of one variant.
    static func diff(_ before: [String], _ after: [String]) -> [String] {
        func split(_ list: [String]) -> (values: [String: String], structure: Set<String>) {
            var values: [String: String] = [:], structure = Set<String>()
            for e in list {
                if e.hasPrefix("<") { structure.insert(e); continue }
                guard let bar = e.firstIndex(of: "|") else { continue }
                let rest = e[e.index(after: bar)...]
                guard let eq = rest.firstIndex(of: "=") else { continue }
                let path = String(e[..<bar]), key = String(rest[..<eq])
                values[path.isEmpty ? key : "\(short(path, 30))/\(key)"] = String(rest[rest.index(after: eq)...])
            }
            return (values, structure)
        }
        let a = split(before), b = split(after)
        var out: [String] = []
        for key in Set(a.values.keys).union(b.values.keys).sorted() {
            let x = a.values[key], y = b.values[key]
            if x == y { continue }
            let name = String(key.split(separator: "/").last ?? Substring(key))
            let tag = CosAdjustmentReader.isIgnored(name) ? "[ignored] " : ""
            switch (x, y) {
            case (nil, let y?): out.append("\(tag)+\(key)=\(short(y, 60))")
            case (let x?, nil): out.append("\(tag)-\(key) (was \(short(x, 60)))")
            case (let x?, let y?): out.append("\(tag)\(key) \(short(x, 60))→\(short(y, 60))")
            default: break
            }
        }
        for s in b.structure.subtracting(a.structure).sorted() { out.append("+structure \(short(s, 80))") }
        for s in a.structure.subtracting(b.structure).sorted() { out.append("-structure \(short(s, 80))") }
        return out
    }

    static func describe(_ f: FSEventStreamEventFlags) -> String {
        let names: [(Int, String)] = [
            (kFSEventStreamEventFlagItemCreated, "created"), (kFSEventStreamEventFlagItemRemoved, "removed"),
            (kFSEventStreamEventFlagItemRenamed, "renamed"), (kFSEventStreamEventFlagItemModified, "modified"),
            (kFSEventStreamEventFlagItemInodeMetaMod, "inode-meta"), (kFSEventStreamEventFlagItemXattrMod, "xattr"),
            (kFSEventStreamEventFlagItemChangeOwner, "owner"), (kFSEventStreamEventFlagItemFinderInfoMod, "finder-info")
        ]
        let set = names.filter { Int(f) & $0.0 != 0 }.map(\.1)
        return set.isEmpty ? String(format: "0x%x", f) : set.joined(separator: ",")
    }

    static func kb(_ bytes: Int64) -> String { String(format: "%.1f KB", Double(bytes) / 1024) }

    static func short(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}

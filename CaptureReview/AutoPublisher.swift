// AutoPublisher.swift – Capture Review, Phase 2 (v3: built for large sessions)
// Watches the session's Capture folder with FSEvents.
// NEW FRAMES are published automatically. RE-GRADES are detected but held: the window shows
// how many are waiting and you push them with Publish (clients never see half-done grades).
// Ratings + color tags from every fresh read are passed to RatingSync (two-way, live).
//
// Four kinds of check, cheapest first:
//   1. New frame / settings file written  -> QUICK inventory of that folder (ids, files, no
//      adjustments), live adjustments read only for the new or changed images
//   2. Selection check every `selectionSeconds` -> reads only the images selected in
//      Capture One (that's where you re-grade). Images stay watched for `watchSeconds`
//      after you click off them, so a grade finished just before moving on still goes out.
//   3. Settings-file flush (Capture One writes .cos about once a minute) -> covered by 1,
//      catches edits made without the image being selected
//   4. FULL sweep every `sweepSeconds`, only when no frames have landed for a minute –
//      the safety net. Costs ~13 ms per image in Capture One, so it stays rare.

import Foundation
import Observation
import CoreServices

/// Which kind of check a publish run is.
nonisolated enum PublishScope: Sendable {
    case full                    // every variant, with live adjustments (Publish button, sweep)
    case quick                   // every variant, adjustments only where needed (new frames)
    case only([C1Variant])       // just these (selection check), already read live
}

/// What one publish run did, so auto-publish knows whether to check again.
nonisolated struct PublishOutcome: Sendable {
    var summary: String
    var queued = 0
    var needsRecheck = false     // Capture One hadn't indexed a file yet, was importing, or a grade is settling
    var busy = false             // another publish was already running
    var regradesWaiting: Int?    // re-graded images held for a manual Publish (nil = not checked this run)
}

@Observable @MainActor
final class AutoPublisher {
    var enabled = false {
        didSet { enabled ? start() : stop() }
    }
    /// Seconds to wait after the last change before publishing.
    var settleSeconds: Double = 3
    /// Ticked folders ("" = Capture root). Kept in sync by the window.
    var folders = Set<String>()

    private(set) var status = "Off"
    private(set) var lastRun: Date?

    /// Does the actual work (the same publish the buttons use). Set by the window.
    var publish: ((_ folders: [String], _ scope: PublishScope) async -> PublishOutcome)?
    /// Receives every FRESH selection read (ratings + color tags go to the gallery). Set by the window.
    var reportMarks: ((_ variants: [C1Variant]) async -> Void)?

    /// How often to read Capture One's selection for re-grades.
    var selectionSeconds: Double = 3
    /// How long an image stays watched after it was last selected.
    var watchSeconds: Double = 120
    /// Full sweep interval (only while no frames are landing).
    var sweepSeconds: Double = 300
    /// No full sweep until frames have stopped landing for this long.
    private let sweepQuietSeconds: Double = 60

    private var captureRoot: URL?
    private var watcher: FolderWatcher?
    /// RAW path -> (its folder, when it or its settings last changed)
    private var changed: [String: (folder: String, at: Date)] = [:]
    /// Folders to check again (not indexed yet, importing, or a grade still settling)
    private var recheck: [String: Date] = [:]
    /// Recently selected variants: last live reading and when it was last selected
    private var watched: [String: (variant: C1Variant, lastSelected: Date)] = [:]
    private var ticker: Task<Void, Never>?
    private var running = false
    private var rechecks = 0
    private var lastSelectionCheck = Date.distantPast
    private var lastSweep = Date()
    private var lastFrameAt = Date.distantPast
    private var selectionBroken = false

    func setSession(_ sessionRoot: URL) {
        captureRoot = sessionRoot.appendingPathComponent("Capture").standardizedFileURL
        if enabled { start() }
    }

    // MARK: - Watching

    private func start() {
        stop()
        guard let captureRoot else { status = "Choose a session first"; return }
        watcher = FolderWatcher(path: captureRoot.path) { [weak self] paths in
            self?.handle(paths)
        }
        lastSweep = Date()
        selectionBroken = false
        ticker = Task { [weak self] in                      // checks once a second
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        status = folders.isEmpty ? "Watching (tick folders to auto-publish)" : watchingText
    }

    private func stop() {
        watcher = nil
        ticker?.cancel()
        ticker = nil
        changed.removeAll()
        recheck.removeAll()
        watched.removeAll()
        if !enabled { status = "Off" }
    }

    /// Check these folders on the next tick (e.g. a folder that just appeared and was ticked:
    /// frames that landed before it was ticked were ignored by the watcher).
    func checkSoon(_ newFolders: [String]) {
        let now = Date()
        for f in newFolders { recheck[f] = now }
    }

    private var watchingText: String {
        "Watching \(folders.count) folder\(folders.count == 1 ? "" : "s")"
    }

    /// Records which RAW files changed: the RAW itself, or its Capture One settings
    /// (<folder>/CaptureOne/Settings*/<RAW name>.cos). Everything else is ignored.
    private func handle(_ paths: [String]) {
        guard enabled, let root = captureRoot?.path else { return }
        let now = Date()
        for path in paths {
            guard path.hasPrefix(root) else { continue }
            let rel = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = rel.split(separator: "/").map(String.init)
            guard let name = parts.last, !parts.contains(where: { $0.hasPrefix(".") }) else { continue }

            var folder: String
            var raw: String
            var isFrame = false
            if name.lowercased().hasSuffix(".cos") {
                // [<folder>/]CaptureOne/Settings…/<RAW>.cos
                guard let c1 = parts.firstIndex(of: "CaptureOne") else { continue }
                folder = c1 == 0 ? "" : parts[c1 - 1]
                guard c1 <= 1 else { continue }                       // only top-level capture folders
                raw = String(name.dropLast(4))
            } else if ProofUploader.rawExtensions.contains((name as NSString).pathExtension.lowercased()) {
                guard parts.count <= 2 else { continue }
                folder = parts.count == 2 ? parts[0] : ""
                raw = name
                isFrame = true
            } else {
                continue                                              // previews, cache, proxies…
            }
            guard folders.contains(folder) else { continue }
            let rawPath = folder.isEmpty ? "\(root)/\(raw)" : "\(root)/\(folder)/\(raw)"
            changed[rawPath] = (folder, now)
            if isFrame { lastFrameAt = now }
        }
    }

    /// Once a second: decide which check (if any) to run.
    private func tick() async {
        guard enabled, !running, publish != nil, !folders.isEmpty else { return }
        let now = Date()

        // 1. New frames / settings files that have been quiet for the settle time, plus rechecks
        let ready = changed.filter { now.timeIntervalSince($0.value.at) >= settleSeconds }.map(\.key)
        var batch = Set(ready.compactMap { changed[$0]?.folder })
        for (folder, due) in recheck where due <= now { batch.insert(folder) }
        batch = batch.filter { folders.contains($0) }
        if !batch.isEmpty {
            ready.forEach { changed[$0] = nil }
            batch.forEach { recheck[$0] = nil }
            await run(Array(batch), .quick, label: "Uploading")
            return
        }

        // 2. Selection check: only the images selected in Capture One
        if !selectionBroken, now.timeIntervalSince(lastSelectionCheck) >= selectionSeconds {
            lastSelectionCheck = now
            running = true
            let result = await CaptureOneScripts.selection()
            running = false
            switch result {
            case .failure(let failure):
                // Fall back to settings-file checks and sweeps; say so instead of retrying forever
                selectionBroken = true
                status = "Selection check unavailable (\(failure.message)). Using settings-file checks."
            case .success(let selection):
                if !selection.variants.isEmpty { await reportMarks?(selection.variants) }
                let stamp = Date()
                for v in selection.variants { watched[v.id] = (v, stamp) }
                watched = watched.filter { stamp.timeIntervalSince($0.value.lastSelected) < watchSeconds }
                if !watched.isEmpty {
                    await run(Array(folders), .only(watched.values.map { $0.variant }), label: nil)
                    return
                }
            }
        }

        // 3. Full sweep: rare, and never while frames are still landing
        if changed.isEmpty,
           now.timeIntervalSince(lastSweep) >= sweepSeconds,
           now.timeIntervalSince(lastFrameAt) >= sweepQuietSeconds {
            lastSweep = now
            await run(Array(folders), .full, label: "Full check of")
        }
    }

    /// Runs one publish and handles the outcome. `label` nil = quiet (selection checks
    /// only update the status when they actually send something).
    private func run(_ batch: [String], _ scope: PublishScope, label: String?) async {
        guard let publish else { return }
        running = true
        if let label {
            status = "\(label) \(batch.map { $0.isEmpty ? "Capture" : $0 }.sorted().joined(separator: ", "))…"
        }
        let outcome = await publish(batch, scope)
        running = false
        lastRun = Date()

        if outcome.busy {
            // a manual publish was running: try these folders again shortly
            if case .only = scope { return }                     // the next selection check covers it
            batch.forEach { recheck[$0] = Date().addingTimeInterval(2) }
            status = "Waiting for the current publish to finish…"
            return
        }
        if outcome.queued > 0 || (label != nil && outcome.needsRecheck) {
            status = outcome.summary
        } else if label != nil {
            status = "\(watchingText) · up to date"
        }

        // Selection checks repeat on their own every few seconds; folder checks need a recheck
        if case .only = scope { return }
        if outcome.needsRecheck, rechecks < 10 {
            rechecks += 1
            batch.forEach { recheck[$0] = Date().addingTimeInterval(3) }
        } else if !outcome.needsRecheck {
            rechecks = 0
        }
    }
}

/// Thin wrapper around an FSEvents stream: file-level events for a folder tree,
/// delivered on the main queue, about once a second at most.
nonisolated final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([String]) -> Void

    init(path: String, latency: Double = 0.5, handler: @escaping @MainActor ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.handler(Array(paths.prefix(count))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

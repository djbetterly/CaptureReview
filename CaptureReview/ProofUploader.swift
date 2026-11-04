// ProofUploader.swift – Capture Review, Phase 2 step 1
// (variants, thumbnails, versioned filenames, quality profiles)
//
// Flow per variant:
//   Capture One renders a 2048 px master into Output/_proof as <RAW name>_v<position>.jpg
//   -> app makes a ~400 px thumbnail and a proof sized for the current quality profile
//   -> uploads thumbnail first, then proof (newest frames first, 4 at a time)
//   -> upserts the variant's row, deletes the previous version's files, deletes the master
//
// Storage names are versioned (<name>_<fingerprint><quality>_t/_p.jpg), so a re-grade or a
// quality upgrade always gets a new URL and browsers/CDN can cache images forever.
// Requires supabase-swift v2.

import Foundation
import Observation
import CryptoKit
import Supabase

nonisolated struct ImageRow: Encodable, Sendable {
    let gallery_id: UUID
    let rel_path: String
    let folder_path: String
    let filename: String
    let variant_id: String
    let variant_position: Int
    let display_name: String
    let storage_path: String
    let thumb_path: String
    let quality: String
    let source_stamp: String
    let proof_bytes: Int
    let thumb_bytes: Int
    let image_uid: String?            // session catalog's permanent image id (renames keep it)
}

nonisolated struct VariantIDPatch: Encodable, Sendable {
    let variant_id: String
}

nonisolated struct StampPatch: Encodable, Sendable {
    let source_stamp: String
}

/// What's stored in `source_stamp`: "L:<live fingerprint>|D:<disk fingerprint>".
/// Live = Capture One's in-memory adjustments + crop (current). Disk = the settings file
/// (lags up to a minute; blank until Capture One flushes it after the image was sent).
nonisolated struct Stamp: Sendable {
    var live = ""
    var disk = ""

    init(live: String, disk: String) { self.live = live; self.disk = disk }

    init(_ text: String?) {
        for part in (text ?? "").split(separator: "|") {
            if part.hasPrefix("L:") { live = String(part.dropFirst(2)) }
            if part.hasPrefix("D:") { disk = String(part.dropFirst(2)) }
        }
        // A settings fingerprint made with an older ignore list can't be compared with a new one:
        // treat it as "not recorded yet", so the next flush is adopted quietly (no re-send).
        if !disk.hasPrefix(CosAdjustmentReader.digestVersion) { disk = "" }
        // Same for live fingerprints read the old way
        if !live.hasPrefix(CaptureOneScripts.liveVersion) { live = "" }
    }

    var text: String { "L:\(live)|D:\(disk)" }
}

/// Live numbers for the progress bar. Main thread, drives SwiftUI.
@Observable @MainActor
final class UploadStats {
    var total = 0              // variants expected in the current publish
    var uploaded = 0
    var waitingOnDisk = 0      // rendered by Capture One, not yet uploaded
    var inFlight = 0
    var retries = 0
    var startedAt: Date?

    // Sizes (this publish)
    var bytesSent = 0               // thumbnails + proofs
    var proofBytes = 0
    var thumbBytes = 0
    var lastUpload = ""             // e.g. "Shot_01-001 · proof 142 KB (Wi-Fi) · thumb 28 KB · 0.41 s"

    /// Adds a publish to the queue. If the previous batch is finished, starts fresh;
    /// if uploads are still running (auto-publish while shooting), extends the total instead.
    func begin(total newTotal: Int) {
        if uploaded >= total {
            total = newTotal; uploaded = 0; retries = 0; startedAt = Date()
            bytesSent = 0; proofBytes = 0; thumbBytes = 0; lastUpload = ""
        } else {
            total += newTotal
        }
    }

    func recordUpload(name: String, thumb: Int, proof: Int, quality: UploadQuality, seconds: Double) {
        uploaded += 1
        thumbBytes += thumb
        proofBytes += proof
        bytesSent += thumb + proof
        lastUpload = "\(name) · proof \(Self.kb(proof)) (\(quality.label)) · thumb \(Self.kb(thumb)) · "
                   + String(format: "%.2f s", seconds)
    }

    var sizeSummary: String {
        guard uploaded > 0 else { return "" }
        return "Sent \(Self.mb(bytesSent)) · avg proof \(Self.kb(proofBytes / uploaded)) · avg thumb \(Self.kb(thumbBytes / uploaded))"
    }

    static func kb(_ bytes: Int) -> String { "\(Int((Double(bytes) / 1024).rounded())) KB" }
    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    var perMinute: Double {
        guard let startedAt, uploaded > 0 else { return 0 }
        return Double(uploaded) / max(Date().timeIntervalSince(startedAt), 1) * 60
    }

    var bottleneck: String {
        guard total > 0, uploaded < total else { return total > 0 ? "Done" : "" }
        if waitingOnDisk == 0 && inFlight == 0 { return "Waiting on Capture One to render" }
        if waitingOnDisk > 8 { return "Upload is the bottleneck" }
        return "Uploading"
    }
}

/// One folder's line in the folder list.
nonisolated struct FolderSyncStatus: Sendable, Equatable {
    var shots = 0              // RAW files in the folder on disk
    var galleryFrames = 0      // of those names, frames the client can see
    var galleryImages = 0      // client-visible images incl. clones (variants)
    var notUploaded = 0        // on disk, not in the gallery
    var notOnDisk = 0          // in the gallery, no longer on disk (sync pending)
    var uploading = 0          // rendering / uploading now
    var regradesWaiting = 0    // re-graded, held for Upload Re-grades
    var hidden = false         // unpublished: the client can't see this folder

    var inSync: Bool { notUploaded == 0 && notOnDisk == 0 && uploading == 0 && regradesWaiting == 0 }

    /// "3 to upload · 1 re-grade waiting"
    var problems: String {
        var p: [String] = []
        let toUpload = max(notUploaded - uploading, 0)
        if uploading > 0 { p.append("\(uploading) uploading") }
        if toUpload > 0 { p.append("\(toUpload) to upload") }
        if notOnDisk > 0 { p.append("\(notOnDisk) to remove from server") }
        if regradesWaiting > 0 { p.append("\(regradesWaiting) re-grade\(regradesWaiting == 1 ? "" : "s") waiting") }
        return p.joined(separator: " · ")
    }
}

/// A gallery's name, link (slug) and access code (Mac app only; read with the secret key).
nonisolated struct GalleryAccess: Decodable, Sendable {
    let name: String
    let slug: String
    let access_code: String?
}
nonisolated struct CodePatch: Encodable, Sendable { let access_code: String }

enum PublishMode: Sendable {
    case changed     // new variants + re-graded ones (normal Publish)
    case all         // everything selected (Republish All)
    case upgrade     // already-published variants sent at a different quality than the current setting
}

/// What a publish will do, worked out before anything is sent to Capture One.
nonisolated struct PublishPlan: Sendable {
    var variantIDs: [String] = []
    var new = 0
    var changed = 0
    var inProgress = 0           // already rendering or uploading from an earlier publish
    var inProgressChanged = 0    // re-graded while still in flight: check again once it lands
    var notInCaptureOne = 0      // not ready yet: not listed by Capture One, or its settings still being written
    var regradeSettling = 0      // re-graded but still changing: sent once it settles
    var regradesWaiting = 0      // re-graded images held for a manual Publish (whole session, not just this check)
    var upgraded = 0
    var skipped = 0
    var duplicates: [String] = []
    var error: String?
    /// Where the compare time went (for the log): "sync 0.2 · rows 0.3 · live 56 in 40.1 · files 1.2 · decide 0.4"
    var timing = ""

    var summary: String {
        var parts = ["\(new) new", "\(changed) changed"]
        if upgraded > 0 { parts.append("\(upgraded) at a different quality") }
        parts.append("\(skipped) up to date")
        if inProgress + inProgressChanged > 0 { parts.append("\(inProgress + inProgressChanged) still uploading") }
        return parts.joined(separator: ", ")
    }
}

actor ProofUploader {
    private struct Pending: Sendable {
        let folder: String
        let raw: String
        let variantID: String
        let position: Int
        let stamp: String              // live fingerprint at publish time
        let liveText: String           // the readable adjustments behind it (recorded in the catalog)
        let imageUID: String?          // session catalog's permanent id for the RAW
        let displayName: String
        let oldPaths: [String]
    }

    private struct ExistingRow: Decodable, Sendable {
        let rel_path: String
        let variant_id: String?
        let variant_position: Int?
        let source_stamp: String?
        let quality: String?
        let storage_path: String?
        let thumb_path: String?
        var image_uid: String? = nil
        var deleted_at: String? = nil
    }

    static let rawExtensions: Set<String> =
        ["cr3", "cr2", "nef", "arw", "raf", "iiq", "3fr", "fff", "dng", "orf", "rw2", "tif", "tiff"]

    private let client: SupabaseClient
    private let galleryID: UUID
    private let captureRoot: URL          // <Session>/Capture
    private let proofDir: URL             // <Session>/Output/_proof
    private let stats: UploadStats
    private let quality: QualitySettings
    private let log: UploadLog
    /// Session catalog: image identity and what each proof was sent with (re-grade baseline).
    private let catalog: Catalog?
    /// Detailed settings-file / re-grade decision log (<session>-settings.log)
    private let cosLog: CosLog?

    /// "<RAW stem>_v<position>" -> what to do with that rendered master
    private var pending: [String: Pending] = [:]
    private var lastSizes: [String: Int] = [:]
    /// Last seen Capture One settings per variant, to report what changed (diagnostics)
    private var lastSettings: [String: Set<String>] = [:]
    /// Rows already in Supabase, kept locally so routine checks don't query the database.
    /// Updated after every upload/patch; refreshed from Supabase every 5 minutes.
    private var rowCache: [String: ExistingRow]?
    private var rowCacheTime = Date.distantPast
    /// Rows changed locally (uploads, stamp/id patches), so a 5-minute refresh from Supabase that
    /// was already in flight can't overwrite them with an older copy (that made a just-uploaded
    /// frame look "new" again and sent it twice).
    private var localWrites: [String: (row: ExistingRow, at: Date)] = [:]

    private func cacheRow(_ key: String, _ row: ExistingRow) {
        rowCache?[key] = row
        localWrites[key] = (row, Date())
    }
    /// Last live fingerprint seen per variant and since when (re-grade debounce)
    private var lastLive: [String: (live: String, since: Date)] = [:]
    /// Parsed settings files keyed by RAW path, reused until the file changes on disk
    private var diskCache: [String: (date: Date, parsed: (digests: [String], entries: [[String]], ready: Bool))] = [:]
    /// Seconds a re-grade must stay unchanged before it's sent (auto-publish only)
    private let regradeSettle: TimeInterval = 5
    /// Re-graded variants held back for a manual Publish ("rel_path#position")
    private var waitingRegrades = Set<String>()
    /// Readable live adjustments at the time each variant was sent (or last confirmed unchanged),
    /// so a detected re-grade can say exactly which values changed. Memory only.
    private var sentLiveText: [String: String] = [:]
    /// Retry backoff per rendered master: wait before trying a failed upload again
    private var retryAfter: [String: (date: Date, attempts: Int)] = [:]
    private static let backoff: [TimeInterval] = [5, 15, 30, 60, 120]
    /// Thumbnails already uploaded for a master, so retries only re-send the proof
    private var thumbDone: [String: String] = [:]
    private var pollTask: Task<Void, Never>?

    init(supabaseURL: URL, serviceKey: String, galleryID: UUID, sessionRoot: URL,
         stats: UploadStats, quality: QualitySettings, log: UploadLog, catalog: Catalog? = nil, cosLog: CosLog? = nil) {
        client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: serviceKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
        self.galleryID = galleryID
        self.stats = stats
        self.quality = quality
        self.log = log
        self.catalog = catalog
        self.cosLog = cosLog
        captureRoot = sessionRoot.appendingPathComponent("Capture").standardizedFileURL
        proofDir = sessionRoot.appendingPathComponent("Output/_proof")
    }

    // MARK: - Planning

    /// Decides which variants to render. `variants` comes from the Capture One inventory;
    /// only those whose RAW sits directly in one of `folders` ("" = Capture root) are used.
    /// `debounce`: wait until a re-grade has stopped changing for `regradeSettle` seconds
    /// before sending it (auto-publish), so dragging a slider doesn't send in-between versions.
    /// `scoped`: `variants` is only a few images (the Capture One selection), not whole folders,
    /// so RAWs missing from the list are expected and not counted as "not ready".
    /// Variants with an empty `live` (quick inventory) get their live fingerprint read here, but
    /// only when it matters: new images, forced/quality re-sends, and settings files that changed.
    /// `holdRegrades`: don't send re-graded images; count them as waiting for a manual Publish
    /// (auto-publish sends only new frames, so clients never see half-finished grades).
    func planBatch(variants: [C1Variant], folders: [String], mode: PublishMode,
                   debounce: Bool = false, scoped: Bool = false, holdRegrades: Bool = false) async -> PublishPlan {
        var plan = PublishPlan()
        let target = await MainActor.run { quality.effective }

        // Renames, moves, deletes and restores go to the gallery FIRST: otherwise a renamed RAW
        // would look like a new frame and be uploaded a second time.
        let tStart = Date()
        await syncCatalog()
        let tSync = Date()

        let existing: [String: ExistingRow]
        do { existing = try await existingRows() }
        catch {
            plan.error = "Couldn't check existing uploads: \(error.localizedDescription)"
            return plan
        }

        // folder directory path -> folder name
        var folderForDir: [String: String] = [:]
        for f in folders {
            let dir = f.isEmpty ? captureRoot : captureRoot.appendingPathComponent(f)
            folderForDir[dir.standardizedFileURL.path] = f
        }

        // Keep only variants in the selected folders; count variants per RAW for display names
        var selected: [(variant: C1Variant, folder: String)] = []
        var variantsPerRaw: [String: Int] = [:]
        for v in variants {
            let dir = URL(fileURLWithPath: v.rawPath).deletingLastPathComponent().standardizedFileURL.path
            guard let folder = folderForDir[dir] else { continue }
            selected.append((v, folder))
            variantsPerRaw[v.rawPath, default: 0] += 1
        }

        // RAW files on disk in the selected folders that Capture One didn't list (it may not
        // have indexed a brand-new capture yet). Auto-publish checks again shortly.
        if !scoped {
            let listed = Set(selected.map { URL(fileURLWithPath: $0.variant.rawPath).standardizedFileURL.path })
            for (dirPath, _) in folderForDir {
                for file in (try? FileManager.default.contentsOfDirectory(atPath: dirPath)) ?? []
                where !file.hasPrefix(".") && Self.rawExtensions.contains((file as NSString).pathExtension.lowercased()) {
                    let path = URL(fileURLWithPath: dirPath).appendingPathComponent(file).standardizedFileURL.path
                    if !listed.contains(path) { plan.notInCaptureOne += 1 }
                }
            }
        }

        let tRows = Date()
        var digestCache: [String: (digests: [String], entries: [[String]], ready: Bool)] = [:]

        // Quick inventory: read live adjustments only for the variants that need them.
        // (Reading every variant's adjustments costs ~13 ms each – 10 s at 800 images.)
        var needLive: [String] = []
        for (v, folder) in selected where v.live.isEmpty {
            let rawURL = URL(fileURLWithPath: v.rawPath)
            let relPath = folder.isEmpty ? rawURL.lastPathComponent : "\(folder)/\(rawURL.lastPathComponent)"
            guard let old = existing["\(relPath)#\(v.position)"], mode == .changed else {
                needLive.append(v.id)                       // new, or forced / quality re-send
                continue
            }
            let parsed = digestCache[v.rawPath]
                ?? diskDigests(raw: rawURL.lastPathComponent, rawPath: v.rawPath, in: rawURL.deletingLastPathComponent())
            digestCache[v.rawPath] = parsed
            let index = parsed.digests.indices.contains(v.position - 1) ? v.position - 1 : parsed.digests.count - 1
            let disk = (parsed.ready && index >= 0) ? parsed.digests[index] : ""
            let oldDisk = Stamp(old.source_stamp).disk
            if !disk.isEmpty, !oldDisk.isEmpty, disk != oldDisk { needLive.append(v.id) }   // settings file changed
        }
        let tFiles = Date()
        var liveSecs = 0.0
        if !needLive.isEmpty {
            let names = folders.map { $0.isEmpty ? "Capture" : $0 }
            let tLive = Date()
            let live = await CaptureOneScripts.liveFingerprints(variantIDs: needLive, collectionNames: names)
            liveSecs = Date().timeIntervalSince(tLive)
            let wanted = Set(needLive)
            var filled: [(variant: C1Variant, folder: String)] = []
            for entry in selected {
                guard wanted.contains(entry.variant.id) else { filled.append(entry); continue }
                guard let text = live[entry.variant.id] else {
                    plan.notInCaptureOne += 1               // couldn't read it this time: check again shortly
                    continue
                }
                filled.append((variant: entry.variant.withLive(text: text), folder: entry.folder))
            }
            selected = filled
        }
        var queued: [String: Pending] = [:]
        var reasons: [String] = []
        var keyFolder: [String: String] = [:]

        for (v, folder) in selected {
            let rawURL = URL(fileURLWithPath: v.rawPath)
            let raw = rawURL.lastPathComponent
            let stem = rawURL.deletingPathExtension().lastPathComponent
            let relPath = folder.isEmpty ? raw : "\(folder)/\(raw)"

            // Disk copy of the settings (Capture One flushes these about once a minute).
            // Used only as a backup for edits the live read can't see (layers, color editor).
            let parsed = digestCache[v.rawPath] ?? diskDigests(raw: raw, rawPath: v.rawPath, in: rawURL.deletingLastPathComponent())
            digestCache[v.rawPath] = parsed
            let index = parsed.digests.indices.contains(v.position - 1) ? v.position - 1 : parsed.digests.count - 1
            let disk = (parsed.ready && index >= 0) ? parsed.digests[index] : ""     // "" = not on disk yet / unreadable
            let settings = (parsed.ready && index >= 0) ? Set(parsed.entries[index]) : []

            // Diagnostics: when a variant's fingerprint changes, log exactly which settings changed
            let settingsKey = "\(relPath)#\(v.position)"
            if let previous = lastSettings[settingsKey], previous != settings {
                let changedKeys = Set(previous.symmetricDifference(settings).map { entry -> String in
                    if entry.hasPrefix("<") {                                   // structure: "<DL >@path"
                        return String(entry.split(separator: "@", maxSplits: 1).first ?? Substring(entry))
                    }
                    let setting = entry.split(separator: "|", maxSplits: 1).last ?? Substring(entry)
                    return String(setting.split(separator: "=", maxSplits: 1).first ?? setting)
                }).sorted()
                await addLog(name: stem + (v.position > 1 ? " (v\(v.position))" : ""), kind: .info,
                             note: "Settings changed: " + changedKeys.prefix(12).joined(separator: ", ")
                                 + (changedKeys.count > 12 ? " (+\(changedKeys.count - 12) more)" : ""))
            }
            if !settings.isEmpty {
                if lastSettings[settingsKey] == nil { VisualChange.noteDisk(Array(settings)) }   // fills Re-grade rules
                lastSettings[settingsKey] = settings
            }
            if !v.liveText.isEmpty, sentLiveText[settingsKey] == nil { VisualChange.noteLive(v.liveText) }

            // Read the row cache NOW, not the snapshot from the start of planning: reading live
            // adjustments can take seconds while Capture One renders, and an upload that finished
            // in the meantime would otherwise look "new" and be sent twice.
            let old = rowCache?["\(relPath)#\(v.position)"] ?? existing["\(relPath)#\(v.position)"]
            if let oldID = old?.variant_id, oldID != v.id {
                // Capture One re-numbered this variant (it does this as a new import finishes).
                // Same image, so not a change; the stored id is refreshed on the next upload.
                await addLog(name: stem + (v.position > 1 ? " (v\(v.position))" : ""), kind: .info,
                             note: "Capture One changed variant id \(oldID) to \(v.id)")
                await updateVariantID(relPath: relPath, position: v.position, id: v.id)
            }

            let oldStamp = Stamp(old?.source_stamp)

            // Already rendering/uploading from an earlier publish: don't queue it twice
            let flightKey = "\(stem)_v\(v.position)"
            if mode == .changed, let inFlight = pending[flightKey] {
                if v.live.isEmpty || inFlight.stamp == v.live { plan.inProgress += 1 } else { plan.inProgressChanged += 1 }
                continue
            }

            let label = stem + (v.position > 1 ? " (v\(v.position))" : "")
            switch mode {
            case .all:
                if old == nil { plan.new += 1 } else { plan.changed += 1 }
                reasons.append("\(label) forced")
            case .changed:
                // Settings file changed since the last check of this variant: visible, or just noise /
                // a nudge below the threshold? (Judged against the file as it was after the last send.)
                let diskEntries = (parsed.ready && index >= 0) ? parsed.entries[index] : []
                let diskChanged = old != nil && !disk.isEmpty && !oldStamp.disk.isEmpty && oldStamp.disk != disk
                let diskVisible = diskChanged
                    ? await isVisibleDiskChange(relPath: relPath, position: v.position, label: label, now: diskEntries)
                    : false
                if old == nil {
                    plan.new += 1
                    reasons.append("\(label) new")
                } else if !v.live.isEmpty, oldStamp.live.isEmpty {
                    // Stored fingerprint is from an older way of reading Capture One: record the
                    // current one as the baseline (no re-send, no flag)
                    await updateStamp(relPath: relPath, position: v.position,
                                      stamp: Stamp(live: v.live, disk: oldStamp.disk).text)
                    if !v.liveText.isEmpty { sentLiveText[settingsKey] = v.liveText }
                    plan.skipped += 1
                    continue
                } else if !v.live.isEmpty, oldStamp.live != v.live, !diskVisible,
                          await !isVisibleChange(relPath: relPath, position: v.position, key: settingsKey,
                                                 label: label, now: v.liveText) {
                    // Adjustments changed, but not enough to see on a proof (rounding noise, a tiny
                    // nudge). Remember the new fingerprint locally so it isn't re-checked every pass;
                    // the baseline stays what was SENT, so small changes that add up still count.
                    cacheStampLocally(relPath: relPath, position: v.position,
                                      stamp: Stamp(live: v.live, disk: diskChanged ? disk : oldStamp.disk).text)
                    if waitingRegrades.remove(settingsKey) != nil {
                        await addLog(name: label, kind: .info, note: "Re-grade below the visible threshold, not sent")
                    }
                    plan.skipped += 1
                    continue
                } else if !v.live.isEmpty, oldStamp.live != v.live {
                    // Capture One's live adjustments or crop changed: a re-grade.
                    // Auto-publish holds it for a manual Publish. Otherwise, with debounce,
                    // wait until it has stopped changing for a few seconds.
                    if holdRegrades {
                        if waitingRegrades.insert(settingsKey).inserted {
                            await addLog(name: label, kind: .info, note: "Re-graded in Capture One, waiting for Publish")
                            await logLiveChange(label: label, key: settingsKey, now: v.liveText)
                        }
                        continue
                    }
                    if debounce {
                        let seen = lastLive[settingsKey]
                        if seen?.live != v.live {
                            lastLive[settingsKey] = (v.live, Date())
                            plan.regradeSettling += 1
                            continue
                        }
                        if let seen, Date().timeIntervalSince(seen.since) < regradeSettle {
                            plan.regradeSettling += 1
                            continue
                        }
                    }
                    lastLive[settingsKey] = nil
                    plan.changed += 1
                    reasons.append("\(label) re-graded")
                    await logLiveChange(label: label, key: settingsKey, now: v.liveText)
                } else if diskChanged {
                    // Live adjustments unchanged but the settings file changed: an edit the live
                    // read can't see (local layers, color editor), caught at the next flush.
                    // Below the threshold (e.g. the flush of a nudge): note it locally, send nothing.
                    if !diskVisible {
                        cacheStampLocally(relPath: relPath, position: v.position,
                                          stamp: Stamp(live: oldStamp.live, disk: disk).text)
                        if waitingRegrades.remove(settingsKey) != nil {
                            await addLog(name: label, kind: .info, note: "Settings change below the visible threshold, not sent")
                        }
                        plan.skipped += 1
                        continue
                    }
                    if holdRegrades {
                        if waitingRegrades.insert(settingsKey).inserted {
                            await addLog(name: label, kind: .info, note: "Settings file changed, waiting for Publish")
                        }
                        continue
                    }
                    plan.changed += 1
                    reasons.append("\(label) settings file changed")
                } else {
                    // Unchanged. If Capture One has now flushed this image's settings for the first
                    // time since it was sent, record them quietly as the new baseline (no re-send).
                    if !disk.isEmpty, oldStamp.disk.isEmpty {
                        let live = v.live.isEmpty ? oldStamp.live : v.live    // quick inventory: keep the stored one
                        await updateStamp(relPath: relPath, position: v.position,
                                          stamp: Stamp(live: live, disk: disk).text)
                        // First flush after the send: this is the file the client's proof matches
                        await catalog?.recordDiskBaseline(captureRel: relPath, position: v.position,
                                                          entries: diskEntries, overwrite: true)
                        cosLog?.write(source: "Planner", file: label, event: "disk baseline",
                                      detail: "first settings flush after send recorded (\(diskEntries.count) entries)")
                    } else if !disk.isEmpty, oldStamp.disk == disk {
                        // Sent before the catalog existed: the file still matches, adopt it as the baseline
                        await catalog?.recordDiskBaseline(captureRel: relPath, position: v.position,
                                                          entries: diskEntries, overwrite: false)
                    }
                    // Back to how it was published (e.g. the re-grade was undone): nothing waiting.
                    // (A quick read has no live value, so it can't tell; leave the flag alone then.)
                    if !v.live.isEmpty {
                        waitingRegrades.remove(settingsKey)
                        if !v.liveText.isEmpty {
                            sentLiveText[settingsKey] = v.liveText
                            await catalog?.adoptBaseline(captureRel: relPath, position: v.position,
                                                         variantID: v.id, live: v.liveText)
                        }
                    }
                    plan.skipped += 1
                    continue
                }
            case .upgrade:
                // Re-send anything that went out at a different quality than the current setting
                guard let old, old.quality != target.rawValue else { plan.skipped += 1; continue }
                plan.upgraded += 1
                reasons.append("\(label) quality")
            }

            let key = "\(stem)_v\(v.position)"
            if let other = keyFolder[key], other != folder { plan.duplicates.append(stem) }
            keyFolder[key] = folder

            let display = (variantsPerRaw[v.rawPath] ?? 1) > 1 ? "\(stem) (v\(v.position))" : stem
            queued[key] = Pending(folder: folder, raw: raw, variantID: v.id, position: v.position,
                                  stamp: v.live,
                                  liveText: v.liveText,
                                  imageUID: await catalog?.imageUID(captureRel: relPath),
                                  displayName: display,
                                  oldPaths: [old?.storage_path, old?.thumb_path].compactMap { $0 })
            plan.variantIDs.append(v.id)
            waitingRegrades.remove(settingsKey)                 // being sent now
            if !v.liveText.isEmpty { sentLiveText[settingsKey] = v.liveText }
        }
        plan.regradesWaiting = waitingRegrades.count
        let tEnd = Date()
        plan.timing = String(format: "sync %.1f · rows %.1f · files %.1f · live %d in %.1f · decide %.1f",
                             tSync.timeIntervalSince(tStart), tRows.timeIntervalSince(tSync),
                             tFiles.timeIntervalSince(tRows), needLive.count, liveSecs,
                             tEnd.timeIntervalSince(tFiles) - liveSecs)

        // Diagnostics: one line per publish saying why each image is being sent
        if !reasons.isEmpty {
            await addLog(name: "Publish", kind: .info,
                         note: reasons.prefix(15).joined(separator: "; ")
                             + (reasons.count > 15 ? " (+\(reasons.count - 15) more)" : ""))
        }

        if plan.duplicates.isEmpty && !plan.variantIDs.isEmpty {
            pending.merge(queued) { _, new in new }
            await MainActor.run { stats.begin(total: plan.variantIDs.count) }
        }
        return plan
    }

    // MARK: - Catalog sync (renames, moves, deletes, restores)

    nonisolated private struct Move: Encodable, Sendable {
        let uid: String
        let rel_path: String
        let folder_path: String
        let filename: String
        let stem: String
        let deleted: Bool
    }
    nonisolated private struct MovesParams: Encodable, Sendable {
        let p_gallery: String
        let p_moves: [Move]
    }
    private var syncingCatalog = false
    private var lastSyncFailureLog = Date.distantPast

    /// Makes the gallery match the session catalog. Stateless: every pass compares the catalog with
    /// the server rows (by image id) and fixes every difference, so a missed pass or an offline
    /// stretch heals itself on the next one.
    ///   renamed / moved inside Capture -> row follows (same row id: client ratings stay)
    ///   deleted (Trash, or gone for 10 s) or moved out of Capture -> hidden, ratings kept
    ///   back in Capture -> shown again with its ratings
    /// Rows without an image id (uploaded before the catalog) are never touched.
    func syncCatalog() async {
        guard let catalog, !syncingCatalog else { return }
        syncingCatalog = true
        defer { syncingCatalog = false }

        await catalog.scan()
        let images = await catalog.snapshot()
        guard let rows = try? await existingRows() else { return }
        var byUID: [String: ExistingRow] = [:]
        for r in rows.values {
            guard let uid = r.image_uid else { continue }
            // prefer the visible row if there are several (variants share one path anyway)
            if byUID[uid] == nil || (byUID[uid]?.deleted_at != nil && r.deleted_at == nil) { byUID[uid] = r }
        }
        guard !byUID.isEmpty else { return }

        var moves: [Move] = []
        var notes: [(name: String, note: String)] = []
        for img in images where img.state != "missing" {            // missing = still deciding (grace period)
            guard let row = byUID[img.id] else { continue }         // never published
            let hidden = row.deleted_at != nil
            let prefix = "Capture/"
            let visible = img.state == "present" && img.relPath.hasPrefix(prefix)
            if visible {
                let rel = String(img.relPath.dropFirst(prefix.count))
                guard hidden || row.rel_path != rel else { continue }
                moves.append(Self.move(uid: img.id, rel: rel, deleted: false))
                notes.append((img.filename, hidden ? "Restored on the gallery as \(rel)"
                                                   : "Renamed on the gallery: \(row.rel_path) → \(rel)"))
            } else if !hidden {
                moves.append(Self.move(uid: img.id, rel: row.rel_path, deleted: true))
                notes.append((img.filename, img.relPath.hasPrefix("Trash/")
                    ? "Hidden on the gallery (moved to Trash in Capture One; ratings kept)"
                    : "Hidden on the gallery (no longer in the Capture folders; ratings kept)"))
            }
        }
        guard !moves.isEmpty else { return }

        do {
            _ = try await client.rpc("app_apply_moves",
                                     params: MovesParams(p_gallery: galleryID.uuidString, p_moves: moves)).execute()
        } catch {
            if Date().timeIntervalSince(lastSyncFailureLog) > 60 {
                lastSyncFailureLog = Date()
                await addLog(name: "Gallery sync", kind: .failed,
                             note: "\(moves.count) rename/delete change(s) not sent yet, retrying: \(error.localizedDescription)")
            }
            return
        }
        for n in notes { await addLog(name: n.name, kind: .info, note: n.note) }
        // Reload the rows so the planner sees the new names (no stale copies of the old ones)
        rowCache = nil
        rowCacheTime = .distantPast
        localWrites = [:]
    }

    nonisolated private static func move(uid: String, rel: String, deleted: Bool) -> Move {
        let filename = (rel as NSString).lastPathComponent
        let folder = (rel as NSString).deletingLastPathComponent
        return Move(uid: uid, rel_path: rel, folder_path: folder, filename: filename,
                    stem: (filename as NSString).deletingPathExtension, deleted: deleted)
    }

    // MARK: - Folder visibility (Publish to Client / Unpublish)

    nonisolated private struct VisibilityRow: Codable, Sendable {
        let gallery_id: String
        let folder_path: String
        let hidden: Bool
    }
    private var hiddenFolders: [String: Bool] = [:]
    private var visibilityLoaded = Date.distantPast

    /// Folder -> hidden from the client. Folders without a row are published (the default).
    /// Cached; re-read from the server every 30 s or when asked.
    func folderVisibility(refresh: Bool = false) async -> [String: Bool] {
        if refresh || Date().timeIntervalSince(visibilityLoaded) > 30 {
            if let rows: [VisibilityRow] = try? await client.from("folder_visibility")
                .select("gallery_id, folder_path, hidden")
                .eq("gallery_id", value: galleryID.uuidString)
                .execute().value {
                hiddenFolders = Dictionary(rows.map { ($0.folder_path, $0.hidden) }, uniquingKeysWith: { a, _ in a })
                visibilityLoaded = Date()
            }
        }
        return hiddenFolders
    }

    /// Hide a folder from the client (it keeps uploading and syncing) or publish it (the client
    /// sees all of it at once). Ratings are kept either way.
    func setFolderHidden(_ folder: String, _ hidden: Bool) async -> Bool {
        do {
            try await client.from("folder_visibility")
                .upsert(VisibilityRow(gallery_id: galleryID.uuidString, folder_path: folder, hidden: hidden),
                        onConflict: "gallery_id,folder_path")
                .execute()
        } catch {
            await addLog(name: folder.isEmpty ? "Capture (root)" : folder, kind: .failed,
                         note: "Couldn't \(hidden ? "unpublish" : "publish") the folder: \(error.localizedDescription)")
            return false
        }
        hiddenFolders[folder] = hidden
        await addLog(name: folder.isEmpty ? "Capture (root)" : folder, kind: .info,
                     note: hidden ? "Unpublished: hidden from the client (still uploading)" : "Published to the client")
        return true
    }

    /// "New folders: Hidden": hide folders that have no setting yet and nothing uploaded
    /// (folders the client can already see are never hidden by this).
    func applyDefaultVisibility(folders: [String], hidden: Bool) async {
        guard hidden, !folders.isEmpty else { return }
        let vis = await folderVisibility(refresh: true)
        let rows = (try? await existingRows()) ?? [:]
        var withImages = Set<String>()
        for row in rows.values where row.deleted_at == nil && !row.rel_path.hasPrefix(".") {
            let parts = row.rel_path.split(separator: "/")
            withImages.insert(parts.count > 1 ? String(parts[0]) : "")
        }
        for f in folders where vis[f] == nil && !withImages.contains(f) {
            _ = await setFolderHidden(f, true)
        }
    }

    // MARK: - Shot counts for the admin page ("awaiting upload")

    nonisolated private struct StatsRow: Encodable, Sendable {
        let gallery_id: String
        let folder_path: String
        let shots: Int
    }
    private var reportedShots: [String: Int] = [:]
    private var lastShotReport = Date.distantPast

    /// Sends each folder's RAW count to the server when it changed (at most every 30 s).
    func reportShotCounts(_ shots: [String: Set<String>]) async {
        let counts = shots.mapValues(\.count)
        guard counts != reportedShots, Date().timeIntervalSince(lastShotReport) > 30 else { return }
        lastShotReport = Date()
        let rows = counts.map { StatsRow(gallery_id: galleryID.uuidString, folder_path: $0.key, shots: $0.value) }
        guard !rows.isEmpty else { return }
        do {
            try await client.from("folder_stats").upsert(rows, onConflict: "gallery_id,folder_path").execute()
            reportedShots = counts
        } catch { /* offline: try again in 30 s */ }
    }

    // MARK: - Delete a folder from the gallery

    nonisolated private struct PathRow: Decodable, Sendable {
        let storage_path: String?
        let thumb_path: String?
    }

    /// Removes one Capture folder's images from the gallery: proof and thumbnail files, database
    /// rows, and with them any client ratings. Anything still queued for that folder is dropped.
    /// RAW files and the Capture One session are not touched. The caller unticks the folder so
    /// it isn't published again.
    func deleteFolderFromGallery(_ folder: String) async -> String {
        // 1. Stop anything still on its way for this folder
        let fm = FileManager.default
        for (key, item) in pending where item.folder == folder {
            pending[key] = nil
            retryAfter[key] = nil
            thumbDone[key] = nil
            try? fm.removeItem(at: proofDir.appendingPathComponent(key + ".jpg"))
        }
        waitingRegrades = waitingRegrades.filter { key in
            let rel = key.split(separator: "#").first.map(String.init) ?? key
            let parts = rel.split(separator: "/")
            return (parts.count > 1 ? String(parts[0]) : "") != folder
        }

        // 2. Files, then rows (marks go with the rows: ON DELETE CASCADE)
        var removedFiles = 0
        var count = 0
        do {
            var paths: [String] = []
            var from = 0
            while true {
                let page: [PathRow] = try await client.from("images")
                    .select("storage_path, thumb_path")
                    .eq("gallery_id", value: galleryID.uuidString)
                    .eq("folder_path", value: folder)
                    .range(from: from, to: from + 999)
                    .execute().value
                count += page.count
                for r in page { paths += [r.storage_path, r.thumb_path].compactMap { $0 } }
                if page.count < 1000 { break }
                from += 1000
            }
            let bucket = client.storage.from("proofs")
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = Array(paths[start..<min(start + 500, paths.count)])
                _ = try? await bucket.remove(paths: chunk)
                removedFiles += chunk.count
            }
            try await client.from("images")
                .delete()
                .eq("gallery_id", value: galleryID.uuidString)
                .eq("folder_path", value: folder)
                .execute()
        } catch {
            return "Couldn't delete \(folder.isEmpty ? "Capture" : folder) from the gallery: \(error.localizedDescription)"
        }
        rowCache = nil
        rowCacheTime = .distantPast
        localWrites = [:]
        let name = folder.isEmpty ? "Capture (root)" : folder
        await addLog(name: name, kind: .info,
                     note: "Deleted from the gallery: \(count) image(s), \(removedFiles) file(s); folder unticked")
        return "Deleted \(count) image\(count == 1 ? "" : "s") of \(name) from the server. The folder is unticked; tick it and upload to put it back."
    }

    // MARK: - Client access (link + code)

    /// The gallery's name, link (slug) and access code.
    func galleryAccess() async -> GalleryAccess? {
        try? await client.from("galleries")
            .select("name, slug, access_code")
            .eq("id", value: galleryID.uuidString)
            .single()
            .execute().value
    }

    /// Replaces the access code. Anyone using the old code is asked for the new one.
    func setAccessCode(_ code: String) async -> Bool {
        do {
            _ = try await client.from("galleries")
                .update(CodePatch(access_code: code))
                .eq("id", value: galleryID.uuidString)
                .execute()
            return true
        } catch { return false }
    }

    /// A new 8-character code like K7QM-4TXP (no 0/O or 1/I/L, easy to read out on set).
    nonisolated static func newAccessCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var g = SystemRandomNumberGenerator()                // cryptographically secure on macOS
        let chars = (0..<8).map { _ in alphabet.randomElement(using: &g)! }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    /// Per-folder sync state for the folder list: shots on disk vs what the client can see,
    /// plus anything still on its way (uploads, re-grades waiting for Publish).
    func folderStatus(shots: [String: Set<String>]) async -> [String: FolderSyncStatus] {
        let rows = (try? await existingRows()) ?? [:]
        var galleryRaws: [String: Set<String>] = [:]
        var galleryImages: [String: Int] = [:]
        for row in rows.values where row.deleted_at == nil && !row.rel_path.hasPrefix(".") {
            let parts = row.rel_path.split(separator: "/")
            let folder = parts.count > 1 ? String(parts[0]) : ""
            galleryRaws[folder, default: []].insert(String(parts.last ?? Substring(row.rel_path)))
            galleryImages[folder, default: 0] += 1
        }
        var uploading: [String: Int] = [:]
        for item in pending.values { uploading[item.folder, default: 0] += 1 }
        var regrades: [String: Int] = [:]
        for key in waitingRegrades {
            let rel = key.split(separator: "#").first.map(String.init) ?? key
            let parts = rel.split(separator: "/")
            regrades[parts.count > 1 ? String(parts[0]) : "", default: 0] += 1
        }
        let hidden = await folderVisibility()
        var out: [String: FolderSyncStatus] = [:]
        for folder in Set(shots.keys).union(galleryRaws.keys).union(uploading.keys).union(regrades.keys).union(hidden.keys) {
            let onDisk = shots[folder] ?? [], inGallery = galleryRaws[folder] ?? []
            out[folder] = FolderSyncStatus(shots: onDisk.count, galleryFrames: inGallery.count,
                                           galleryImages: galleryImages[folder] ?? 0,
                                           notUploaded: onDisk.subtracting(inGallery).count,
                                           notOnDisk: inGallery.subtracting(onDisk).count,
                                           uploading: uploading[folder] ?? 0,
                                           regradesWaiting: regrades[folder] ?? 0,
                                           hidden: hidden[folder] ?? false)
        }
        return out
    }

    /// Images in the gallery per capture folder ("" = Capture root). Uses the local row cache,
    /// which every upload updates, so it's cheap to call every few seconds.
    func uploadedCounts() async -> [String: Int] {
        guard let rows = try? await existingRows() else { return [:] }
        var counts: [String: Int] = [:]
        for row in rows.values where row.deleted_at == nil && !row.rel_path.hasPrefix(".") {
            let parts = row.rel_path.split(separator: "/")
            counts[parts.count > 1 ? String(parts[0]) : "", default: 0] += 1
        }
        return counts
    }

    /// Diagnostics: logs which Capture One adjustment values differ from what was sent,
    /// e.g. "Changed: expo 0.0→1.2". Keys are Capture One's 4-letter AppleScript codes.
    private func logLiveChange(label: String, key: String, now: String) async {
        guard let before = sentLiveText[key], !now.isEmpty else { return }
        let diff = Self.describeLiveChange(before: before, after: now)
        await addLog(name: label, kind: .info, note: "Live values changed: " + (diff.isEmpty ? "(none found)" : diff))
    }

    /// Compares two readable adjustment texts ("{key=value,…}#crop") field by field.
    static func describeLiveChange(before: String, after: String) -> String {
        func fields(_ text: String) -> [String: String] {
            let halves = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            var out: [String: String] = ["crop": halves.count > 1 ? String(halves[1]) : ""]
            var body = Substring(halves.first ?? "")
            if body.hasPrefix("{"), body.hasSuffix("}") { body = body.dropFirst().dropLast() }
            var depth = 0, current = ""
            func flush() {
                guard let eq = current.firstIndex(of: "=") else { current = ""; return }
                out[String(current[..<eq])] = String(current[current.index(after: eq)...])
                current = ""
            }
            for ch in body {
                if ch == "{" || ch == "[" { depth += 1 }
                if ch == "}" || ch == "]" { depth -= 1 }
                if ch == ",", depth == 0 { flush() } else { current.append(ch) }
            }
            flush()
            return out
        }
        let a = fields(before), b = fields(after)
        let keys = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
        if keys.isEmpty { return rawDifference(before, after) }
        let short = { (s: String?) in s.map { $0.count > 40 ? String($0.prefix(40)) + "…" : $0 } ?? "–" }
        return keys.prefix(10).map { "\($0) \(short(a[$0]))→\(short(b[$0]))" }.joined(separator: "; ")
            + (keys.count > 10 ? " (+\(keys.count - 10) more)" : "")
    }

    /// Fallback when no field-level difference is found: the text around the first changed character.
    static func rawDifference(_ a: String, _ b: String) -> String {
        let x = Array(a), y = Array(b)
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        if i == x.count && i == y.count { return "(identical text)" }
        let from = max(0, i - 60)
        let snip = { (c: [Character]) in String(c[min(from, c.count)..<min(i + 60, c.count)]) }
        return "at char \(i) of \(x.count)/\(y.count): …\(snip(x))… → …\(snip(y))…"
    }

    /// Whether the adjustments now differ VISIBLY from what the client's proof was made with.
    /// No recorded baseline (sent before the catalog existed, or the text couldn't be read):
    /// treat any change as visible, as before.
    private func isVisibleChange(relPath: String, position: Int, key: String, label: String,
                                 now: String) async -> Bool {
        guard !now.isEmpty else { return true }
        let sent = await catalog?.sentLive(captureRel: relPath, position: position) ?? sentLiveText[key]
        guard let sent, !sent.isEmpty else {
            cosLog?.write(source: "Planner", file: label, event: "live: no baseline",
                          detail: "nothing recorded for the sent proof, any change counts as a re-grade")
            return true
        }
        let result = VisualChange.analyze(sent: sent, now: now)
        cosLog?.write(source: "Planner", file: label,
                      event: result.visible.isEmpty ? "live: below threshold, not sent" : "live: visible re-grade",
                      detail: "visible: " + (result.visible.isEmpty ? "none" : result.visible.joined(separator: "; "))
                          + " | minor: " + (result.minor.isEmpty ? "none" : result.minor.joined(separator: "; ")))
        return !result.visible.isEmpty
    }

    /// Same for the settings file, against the entries recorded at the first flush after the send.
    private func isVisibleDiskChange(relPath: String, position: Int, label: String, now: [String]) async -> Bool {
        guard !now.isEmpty,
              let base = await catalog?.diskBaseline(captureRel: relPath, position: position), !base.isEmpty else {
            cosLog?.write(source: "Planner", file: label, event: "disk: no baseline",
                          detail: "settings file changed, nothing recorded to compare with: counts as a change")
            return true
        }
        let result = VisualChange.analyzeDisk(sent: base, now: now)
        cosLog?.write(source: "Planner", file: label,
                      event: result.visible.isEmpty ? "disk: below threshold, not sent" : "disk: visible change",
                      detail: "visible: " + (result.visible.isEmpty ? "none" : result.visible.joined(separator: "; "))
                          + " | minor: " + (result.minor.isEmpty ? "none" : result.minor.joined(separator: "; ")))
        return !result.visible.isEmpty
    }

    /// Updates the cached fingerprint only (no database write: on a dead link, hundreds of
    /// writes would each wait for a timeout).
    private func cacheStampLocally(relPath: String, position: Int, stamp: String) {
        guard let r = rowCache?["\(relPath)#\(position)"] else { return }
        cacheRow("\(relPath)#\(position)", ExistingRow(
            rel_path: r.rel_path, variant_id: r.variant_id, variant_position: r.variant_position,
            source_stamp: stamp, quality: r.quality, storage_path: r.storage_path, thumb_path: r.thumb_path, image_uid: r.image_uid, deleted_at: r.deleted_at))
    }

    /// Updates the stored fingerprint without re-sending the image.
    private func updateStamp(relPath: String, position: Int, stamp: String) async {
        if let r = rowCache?["\(relPath)#\(position)"] {
            cacheRow("\(relPath)#\(position)", ExistingRow(
                rel_path: r.rel_path, variant_id: r.variant_id, variant_position: r.variant_position,
                source_stamp: stamp, quality: r.quality, storage_path: r.storage_path, thumb_path: r.thumb_path, image_uid: r.image_uid, deleted_at: r.deleted_at))
        }
        _ = try? await client.from("images")
            .update(StampPatch(source_stamp: stamp))
            .eq("gallery_id", value: galleryID.uuidString)
            .eq("rel_path", value: relPath)
            .eq("variant_position", value: position)
            .execute()
    }

    /// Keeps the stored Capture One id current, so client ratings reach the right variant.
    private func updateVariantID(relPath: String, position: Int, id: String) async {
        if let r = rowCache?["\(relPath)#\(position)"] {
            cacheRow("\(relPath)#\(position)", ExistingRow(
                rel_path: r.rel_path, variant_id: id, variant_position: r.variant_position,
                source_stamp: r.source_stamp, quality: r.quality, storage_path: r.storage_path, thumb_path: r.thumb_path, image_uid: r.image_uid, deleted_at: r.deleted_at))
        }
        _ = try? await client.from("images")
            .update(VariantIDPatch(variant_id: id))
            .eq("gallery_id", value: galleryID.uuidString)
            .eq("rel_path", value: relPath)
            .eq("variant_position", value: position)
            .execute()
    }

    /// "rel_path#variant_position" -> existing row, paged 1000 at a time.
    private func existingRows() async throws -> [String: ExistingRow] {
        if let rowCache, Date().timeIntervalSince(rowCacheTime) < 300 { return rowCache }
        let started = Date()
        var result: [String: ExistingRow] = [:]
        var from = 0
        while true {
            let rows: [ExistingRow] = try await client.from("images")
                .select("rel_path, variant_id, variant_position, source_stamp, quality, storage_path, thumb_path, image_uid, deleted_at")
                .eq("gallery_id", value: galleryID.uuidString)
                .range(from: from, to: from + 999)
                .execute().value
            for r in rows { result["\(r.rel_path)#\(r.variant_position ?? 1)"] = r }
            if rows.count < 1000 { break }
            from += 1000
        }
        // Anything written locally while this fetch was running is newer than what it returned
        for (key, write) in localWrites where write.at >= started { result[key] = write.row }
        localWrites = localWrites.filter { $0.value.at >= started }
        rowCache = result
        rowCacheTime = Date()
        return result
    }

    /// Parses a RAW's settings file only when it changed on disk since last time.
    private func diskDigests(raw: String, rawPath: String, in dir: URL)
        -> (digests: [String], entries: [[String]], ready: Bool) {
        let c1 = dir.appendingPathComponent("CaptureOne")
        let fm = FileManager.default
        var newest: Date?
        for sub in (try? fm.contentsOfDirectory(atPath: c1.path)) ?? [] where sub.hasPrefix("Settings") {
            let cos = c1.appendingPathComponent(sub).appendingPathComponent(raw + ".cos")
            if let d = (try? fm.attributesOfItem(atPath: cos.path))?[.modificationDate] as? Date,
               d > (newest ?? .distantPast) { newest = d }
        }
        if let newest, let cached = diskCache[rawPath], cached.date == newest { return cached.parsed }
        let parsed = Self.variantDigests(raw: raw, in: dir)
        if let newest, parsed.ready { diskCache[rawPath] = (newest, parsed) }
        return parsed
    }

    /// One adjustments-only fingerprint per variant, in the order the .cos file lists them
    /// (which follows variant position). Ratings, tags, metadata and render history are ignored.
    /// `ready` is false while the settings file can't be read completely (Capture One is
    /// mid-write); after 30 s it's treated as ready anyway so nothing gets stuck.
    static func variantDigests(raw: String, in dir: URL) -> (digests: [String], entries: [[String]], ready: Bool) {
        let fm = FileManager.default
        let c1 = dir.appendingPathComponent("CaptureOne")
        var newest: (url: URL, date: Date)?
        for sub in (try? fm.contentsOfDirectory(atPath: c1.path)) ?? [] where sub.hasPrefix("Settings") {
            let cos = c1.appendingPathComponent(sub).appendingPathComponent(raw + ".cos")
            if let d = (try? fm.attributesOfItem(atPath: cos.path))?[.modificationDate] as? Date,
               d > (newest?.date ?? .distantPast) {
                newest = (cos, d)
            }
        }
        // No settings file yet: Capture One hasn't finished taking the image in. Not ready.
        guard let cos = newest?.url, let date = newest?.date else { return ([], [], false) }
        let old = Date().timeIntervalSince(date) > 30

        // Capture One rewrites settings files in place (e.g. right after rendering a proof),
        // so a read can catch one half-written. An unreadable file means "unknown, check again",
        // never "the grade changed".
        guard let data = try? Data(contentsOf: cos) else { return ([], [], old) }
        let reader = CosAdjustmentReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), !reader.digests.isEmpty else { return ([], [], old) }

        // A complete, readable file is ready, even Capture One's skeleton for a new image:
        // Capture One only writes the full settings once it renders or edits the image.
        return (reader.digests, reader.entries, true)
    }

    // MARK: - Watching

    func start() {
        pollTask?.cancel()
        pollTask = Task {
            await speedTest()
            while !Task.isCancelled {
                await scan()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { pollTask?.cancel() }

    /// ~512 KB test upload when a session is chosen, so Auto starts from a real number.
    private func speedTest() async {
        await MainActor.run { quality.resetMeasurements() }
        let path = "\(galleryID.uuidString)/_speedtest.bin"
        let data = Data((0..<524_288).map { _ in UInt8.random(in: 0...255) })
        let t0 = Date()
        do {
            try await client.storage.from("proofs").upload(path, data: data,
                options: FileOptions(contentType: "application/octet-stream", upsert: true))
            let seconds = Date().timeIntervalSince(t0)
            _ = try? await client.storage.from("proofs").remove(paths: [path])
            let mbps = Double(data.count) * 8 / max(seconds, 0.001) / 1_000_000
            await MainActor.run {
                quality.record(bytes: data.count, seconds: seconds)
                quality.seed(mbps: mbps)
            }
            await addLog(name: "Speed test", kind: .info, bytes: data.count, seconds: seconds,
                         note: "512 KB test upload")
        } catch {
            await MainActor.run {
                quality.recordFailure()
                quality.seed(mbps: 0.05)
            }
            await addLog(name: "Speed test", kind: .failed, note: error.localizedDescription)
        }
    }

    private func scan() async {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: proofDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") }
        await MainActor.run { stats.waitingOnDisk = names.count }

        // Files whose size is stable across two polls (Capture One finished writing)
        var ready: [(url: URL, date: Date)] = []
        let now = Date()
        for name in names {
            let key = (name as NSString).deletingPathExtension
            if let wait = retryAfter[key], wait.date > now { continue }     // backing off after a failure
            let url = proofDir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            if size > 0, lastSizes[name] == size {
                lastSizes[name] = nil
                ready.append((url, (attrs?[.modificationDate] as? Date) ?? .distantPast))
            } else {
                lastSizes[name] = size
            }
        }
        ready.sort { $0.date > $1.date }                     // newest frames first

        let parallel = await MainActor.run { quality.recommendedParallel }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for item in ready {
                if running >= parallel { await group.next(); running -= 1 }
                group.addTask { await self.handle(item.url) }
                running += 1
            }
        }
    }

    private func handle(_ master: URL) async {
        let key = master.deletingPathExtension().lastPathComponent      // Shot_01-001_v1
        guard let item = pending[key] else {
            // Left over from a cancelled run or a restart: it can't be matched to a variant
            // safely, so drop it. Publishing again re-renders anything still needed.
            await addLog(name: master.lastPathComponent, kind: .discarded,
                         note: "Not part of the current publish (left over from an earlier run)")
            try? FileManager.default.removeItem(at: master)
            return
        }

        // Deleted in Capture One while waiting to upload: don't bring it back
        if let uid = item.imageUID, let catalog, await !catalog.isInCapture(uid: uid) {
            await addLog(name: item.displayName, kind: .discarded, note: "Deleted in Capture One before it uploaded")
            try? FileManager.default.removeItem(at: master)
            pending[key] = nil
            retryAfter[key] = nil
            thumbDone[key] = nil
            return
        }

        await MainActor.run { stats.inFlight += 1 }
        do {
            try await upload(master, item, key: key)
            try? FileManager.default.removeItem(at: master)
            pending[key] = nil
            retryAfter[key] = nil
            thumbDone[key] = nil
        } catch {
            let attempts = (retryAfter[key]?.attempts ?? 0) + 1
            let delay = Self.backoff[min(attempts - 1, Self.backoff.count - 1)]
            retryAfter[key] = (Date().addingTimeInterval(delay), attempts)
            await MainActor.run { quality.recordFailure() }
            await addLog(name: item.displayName, kind: .failed,
                         note: "Attempt \(attempts), retrying in \(Int(delay)) s: \(error.localizedDescription)")
            await MainActor.run { stats.retries += 1 }
        }
        await MainActor.run { stats.inFlight -= 1 }
    }

    private func upload(_ master: URL, _ item: Pending, key: String) async throws {
        let profile = await MainActor.run { quality.effective }
        let relPath = item.folder.isEmpty ? item.raw : "\(item.folder)/\(item.raw)"

        // Disk part is left blank: Capture One's next flush is recorded quietly as the baseline.
        let stamp = item.stamp

        guard let thumb = ImageEncoder.jpeg(from: master, maxPixel: UploadQuality.thumbMaxPixel,
                                            quality: UploadQuality.thumbQuality,
                                            maxBytes: UploadQuality.thumbBudget),
              let proof = ImageEncoder.jpeg(from: master, maxPixel: profile.proofMaxPixel,
                                            quality: profile.proofQuality,
                                            maxBytes: profile.proofBudget)
        else { throw CocoaError(.fileReadCorruptFile) }

        let stem = (item.raw as NSString).deletingPathExtension
        let variantPart = item.position > 1 ? "_v\(item.position)" : ""
        let version = String(stamp.prefix(8)) + profile.code
        let profileLabel = profile.label
        let base = "\(galleryID.uuidString)/" + (item.folder.isEmpty ? "" : "\(item.folder)/")
                 + "\(stem)\(variantPart)_\(version)"
        // Thumbnails are identical at every quality, so their name only changes with a re-grade.
        // That way a retry at a different quality doesn't re-send the thumbnail.
        let thumbBase = "\(galleryID.uuidString)/" + (item.folder.isEmpty ? "" : "\(item.folder)/")
                      + "\(stem)\(variantPart)_\(String(stamp.prefix(8)))"
        let thumbPath = thumbBase + "_t.jpg"
        let proofPath = base + "_p.jpg"

        // Images never change under a given name, so let browsers and the CDN cache for a year
        let options = FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true)
        let bucket = client.storage.from("proofs")

        if thumbDone[key] != thumbPath {                                        // retries skip the thumbnail
            let tt = Date()
            try await bucket.upload(thumbPath, data: thumb.data, options: options)  // grid first
            thumbDone[key] = thumbPath
            let thumbSeconds = Date().timeIntervalSince(tt)
            await addLog(name: item.displayName, kind: .thumb, width: thumb.width, height: thumb.height,
                         bytes: thumb.data.count, seconds: thumbSeconds,
                         note: String(format: "q %.2f", thumb.quality))
        }

        let t0 = Date()
        try await bucket.upload(proofPath, data: proof.data, options: options)
        let seconds = Date().timeIntervalSince(t0)
        await MainActor.run { quality.record(bytes: proof.data.count, seconds: seconds) }
        await addLog(name: item.displayName, kind: .proof, quality: profileLabel,
                     width: proof.width, height: proof.height, bytes: proof.data.count, seconds: seconds,
                     note: String(format: "q %.2f", proof.quality)
                         + (proof.width < profile.proofMaxPixel && proof.height < profile.proofMaxPixel
                            ? " · master smaller than \(profile.proofMaxPixel) px, check the Proof recipe" : ""))

        let row = ImageRow(gallery_id: galleryID, rel_path: relPath, folder_path: item.folder,
                           filename: item.raw, variant_id: item.variantID,
                           variant_position: item.position, display_name: item.displayName,
                           storage_path: proofPath, thumb_path: thumbPath,
                           quality: profile.rawValue, source_stamp: Stamp(live: stamp, disk: "").text,
                           proof_bytes: proof.data.count, thumb_bytes: thumb.data.count,
                           image_uid: item.imageUID)
        // Folder deleted from the gallery while this was uploading: don't put it back
        guard pending[key] != nil else { throw CancellationError() }
        try await client.from("images")
            .upsert(row, onConflict: "gallery_id,rel_path,variant_position")
            .execute()
        cacheRow("\(relPath)#\(item.position)", ExistingRow(
            rel_path: relPath, variant_id: item.variantID, variant_position: item.position,
            source_stamp: row.source_stamp, quality: row.quality,
            storage_path: proofPath, thumb_path: thumbPath, image_uid: item.imageUID))

        await catalog?.recordSent(captureRel: relPath, position: item.position, variantID: item.variantID,
                                  live: item.liveText, proofPath: proofPath, thumbPath: thumbPath,
                                  quality: profile.rawValue)

        // Remove the previous version's files (old grade or old quality)
        let stale = item.oldPaths.filter { $0 != thumbPath && $0 != proofPath }
        if !stale.isEmpty { _ = try? await bucket.remove(paths: stale) }

        await MainActor.run {
            stats.recordUpload(name: item.displayName, thumb: thumb.data.count, proof: proof.data.count,
                               quality: profile, seconds: seconds)
        }
    }

    private func addLog(name: String, kind: UploadLogEntry.Kind, quality: String = "",
                        width: Int = 0, height: Int = 0, bytes: Int = 0, seconds: Double = 0,
                        note: String = "") async {
        let entry = UploadLogEntry(time: Date(), name: name, kind: kind, quality: quality,
                                   width: width, height: height, bytes: bytes, seconds: seconds, note: note)
        await MainActor.run { log.add(entry) }
    }

    // MARK: - TEMPORARY test reset (remove before real jobs)

    /// Deletes this gallery's files from Storage, its rows from `images`
    /// (marks go with them via cascade), and every local proof JPEG.
    func resetGallery() async -> String {
        pollTask?.cancel()
        var removedFiles = 0
        var problems: [String] = []

        do {
            let bucket = client.storage.from("proofs")
            let root = galleryID.uuidString
            var paths: [String] = []
            for item in try await bucket.list(path: root, options: SearchOptions(limit: 10000)) {
                if item.id == nil {
                    let sub = "\(root)/\(item.name)"
                    for f in try await bucket.list(path: sub, options: SearchOptions(limit: 10000)) where f.id != nil {
                        paths.append("\(sub)/\(f.name)")
                    }
                } else {
                    paths.append("\(root)/\(item.name)")
                }
            }
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = Array(paths[start..<min(start + 500, paths.count)])
                _ = try await bucket.remove(paths: chunk)
                removedFiles += chunk.count
            }
        } catch {
            problems.append("storage: \(error.localizedDescription)")
        }

        do {
            try await client.from("images")
                .delete()
                .eq("gallery_id", value: galleryID.uuidString)
                .execute()
        } catch {
            problems.append("rows: \(error.localizedDescription)")
        }

        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: proofDir.path)) ?? []
        where name.lowercased().hasSuffix(".jpg") {
            try? fm.removeItem(at: proofDir.appendingPathComponent(name))
        }
        try? fm.removeItem(at: proofDir.appendingPathComponent("_uploaded"))

        pending = [:]
        lastSizes = [:]
        rowCache = nil
        localWrites = [:]
        lastLive = [:]
        waitingRegrades = []
        sentLiveText = [:]
        diskCache = [:]
        retryAfter = [:]
        thumbDone = [:]
        await catalog?.forgetSent()
        await MainActor.run {
            stats.total = 0; stats.uploaded = 0; stats.waitingOnDisk = 0
            stats.inFlight = 0; stats.retries = 0; stats.startedAt = nil
            stats.bytesSent = 0; stats.proofBytes = 0; stats.thumbBytes = 0; stats.lastUpload = ""
        }

        start()
        return problems.isEmpty
            ? "Reset done: \(removedFiles) files and all rows deleted, local cache cleared."
            : "Reset partly failed (\(problems.joined(separator: "; ")))."
    }
}

/// Walks a Capture One .cos file and fingerprints the adjustment values of each
/// variant (<VAR>) separately, skipping data that changes without a re-grade.
nonisolated final class CosAdjustmentReader: NSObject, XMLParserDelegate {
    private(set) var digests: [String] = []
    /// Per variant: the individual settings that went into the digest (also used for diagnostics).
    /// Settings:   "<path>|Key=Value"      e.g. "DL|Exposure=0.3"
    /// Structure:  "<Name attrs>@<path>"   e.g. "<DL >@"   (layers, masks, sections)
    private(set) var entries: [[String]] = []
    private var current: [String] = []
    private var path: [String] = []        // structural elements we're inside (within a VAR)
    private var inVar = false
    private var skipDepth = 0

    /// Process history is rewritten every time proofs are rendered.
    /// Settings log: keep the keys the fingerprint ignores (so we can see Capture One write them).
    var keepIgnored = false

    static let ignoredElements: Set<String> = ["PHS"]
    static let ignoredKeys: Set<String> = [
        "LastMetadataModificationDate", "LowResProcessCounter", "UUID", "ProductID",
        // Values Capture One calculates for its dehaze tool when an image is viewed
        // (the user's dehaze setting itself, DehazeAmount/DehazeColor, is still tracked)
        "CalculatedDehazeColor", "DehazeLevelHigh", "DehazeLevelLow",
        // Capture One fills these in on its own a few seconds after import (lens profile and
        // sharpening defaults), so every new frame looked "changed" at the next settings flush
        "LensDiffractionCorrectionEnabled", "UsmMethod",
        // Bookkeeping that changes without the picture changing (seen on 2 Nov: renders bump the
        // counter; applying a style rewrites its name/source even when the values come out the same,
        // and the values themselves are tracked separately)
        "HighResProcessCounter", "Name", "StyleSource", "StyleModified"
    ]
    /// Rating, color tag and metadata fields. (Color_Tag_Index was missing: tagging an image
    /// in Capture One flagged it as re-graded.)
    static let ignoredPrefixes = [
        "Basic_", "Content_", "Status_", "Image_", "Contact_", "Iptc", "IPTC", "Origin_", "Workflow_",
        "Color_Tag", "Rating"
    ]
    /// Bookkeeping key the fingerprint skips (ratings, tags, metadata, counters).
    static func isIgnored(_ key: String) -> Bool {
        ignoredKeys.contains(key) || ignoredPrefixes.contains(where: { key.hasPrefix($0) })
    }

    /// Changes whenever the ignore list changes, so old fingerprints aren't compared with new ones.
    static let digestVersion = "v4-"

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "VAR" { inVar = true; current = []; path = []; skipDepth = 0; return }
        guard inVar else { return }
        if skipDepth > 0 || Self.ignoredElements.contains(name) { skipDepth += 1; return }

        let where_ = path.joined(separator: "/")
        if name == "E", let key = attributes["K"] {
            if !keepIgnored, Self.isIgnored(key) { return }
            current.append("\(where_)|\(key)=\(attributes["V"] ?? "")")
        } else {
            let attrs = attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            current.append("<\(name) \(attrs)>@\(where_)")
            path.append(attrs.isEmpty ? name : "\(name)(\(attrs))")
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "VAR" {
            inVar = false
            // Order-independent: Capture One may write the same settings in a different order
            // when it rewrites the file (e.g. after rendering), which must not count as a change.
            let canonical = current.sorted().joined(separator: "\n")
            let hash = SHA256.hash(data: Data(canonical.utf8))
            digests.append(Self.digestVersion + hash.map { String(format: "%02x", $0) }.joined())
            entries.append(current)
            return
        }
        guard inVar else { return }
        if skipDepth > 0 { skipDepth -= 1; return }
        if name != "E", !path.isEmpty { path.removeLast() }
    }
}

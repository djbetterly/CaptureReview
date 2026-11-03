// RatingSync.swift – Capture Review (v2: shared rating + color tag, two-way)
// Keeps ONE rating and ONE color tag per variant in step between Capture One and the gallery.
// Last change wins, from either side.
//
//   Gallery -> Capture One: Supabase realtime pings the app when `marks` changes (10 s poll as
//     a safety net). Rows changed since the last sync are pulled; the ones the CLIENT made are
//     applied to Capture One in one batched AppleScript run.
//   Capture One -> Gallery: every Capture One read the app already makes (selection check every
//     3 s, new-frame and settings-file checks, full checks) reports ratings/tags here. Anything
//     different from what the database holds is written back, marked source = 'studio', and the
//     gallery shows it live.
//
// Echo protection: the app remembers what the database holds per image, so a value it just
// applied to Capture One isn't sent straight back, and a Capture One read that started before an
// apply finished is ignored for a few seconds.

import Foundation
import Observation
import AppKit
import Supabase

nonisolated struct MarkImageRef: Decodable, Sendable {
    let rel_path: String
    let variant_position: Int?
    let folder_path: String
    let variant_id: String?
}

nonisolated struct MarkChange: Decodable, Sendable {
    let rating: Int?
    let color_tag: String?
    let source: String?
    let updated_at: String
    let images: MarkImageRef
}

/// One row written to `marks`. Encodes nil color_tag as null, so clearing a tag clears it.
nonisolated struct MarkUpsert: Encodable, Sendable {
    let image_id: String
    let reviewer: String
    let rating: Int
    let color_tag: String?
    let source: String

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(image_id, forKey: .image_id)
        try c.encode(reviewer, forKey: .reviewer)
        try c.encode(rating, forKey: .rating)
        try c.encode(color_tag, forKey: .color_tag)          // null when nil
        try c.encode(source, forKey: .source)
    }
    enum CodingKeys: String, CodingKey { case image_id, reviewer, rating, color_tag, source }
}

nonisolated struct ImageKeyRow: Decodable, Sendable {
    let id: String
    let rel_path: String
    let variant_position: Int?
}

/// Status line for the window.
@Observable @MainActor
final class SyncStatus {
    var message = "Rating sync off"
    var applied = 0          // client changes applied to Capture One this session
    var sent = 0             // Capture One changes sent to the gallery this session
    var lastSync: Date?
}

actor RatingSync {
    private let client: SupabaseClient
    private let galleryID: UUID
    private let captureRoot: URL
    private let status: SyncStatus
    /// The shared mark row. (The column is called reviewer for historical reasons; there's one row per image.)
    private let reviewer = "client"
    /// Ignore Capture One reads for this long after applying a gallery change to that image.
    private let echoWindow: TimeInterval = 10

    private var lastSeen: String?            // newest updated_at already handled
    private var ready = false                // first full pull done: only then trust Capture One diffs
    private var known: [String: C1Mark] = [:]          // "rel_path#position" -> what the database holds
    private var recentlyApplied: [String: Date] = [:]  // key -> when a gallery change was applied to C1
    private var imageIDs: [String: String] = [:]       // key -> images.id
    private var imageIDsLoaded = Date.distantPast

    private var syncing = false
    private var runAgain = false
    private var debounce: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var channel: RealtimeChannelV2?

    init(supabaseURL: URL, serviceKey: String, galleryID: UUID, sessionRoot: URL, status: SyncStatus) {
        client = SupabaseClient(
            supabaseURL: supabaseURL,
            supabaseKey: serviceKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
        self.galleryID = galleryID
        self.status = status
        captureRoot = sessionRoot.appendingPathComponent("Capture").standardizedFileURL
    }

    func start() {
        listenTask = Task { await listen() }
        pollTask = Task {
            while !Task.isCancelled {
                await syncNow()                              // first run loads + applies existing marks
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() async {
        listenTask?.cancel()
        pollTask?.cancel()
        debounce?.cancel()
        if let channel { await channel.unsubscribe() }
    }

    // MARK: - Realtime

    private func listen() async {
        let ch = client.channel("marks-\(galleryID.uuidString)")
        channel = ch
        let changes = ch.postgresChange(AnyAction.self, schema: "public", table: "marks")
        await ch.subscribe()
        await setMessage("Listening for ratings and color tags")
        for await _ in changes {
            scheduleSync()
        }
    }

    /// Waits a moment so a burst of clicks becomes one Capture One update.
    private func scheduleSync() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    // MARK: - Gallery -> Capture One

    func syncNow() async {
        if syncing { runAgain = true; return }
        syncing = true
        repeat {
            runAgain = false
            await pullAndApply()
        } while runAgain
        syncing = false
    }

    private func pullAndApply() async {
        var rows: [MarkChange] = []
        do {
            // Page through (the first pull reads every mark in the gallery)
            var from = 0
            while true {
                var query = client.from("marks")
                    .select("rating, color_tag, source, updated_at, images!inner(rel_path, variant_position, folder_path, variant_id, gallery_id)")
                    .eq("images.gallery_id", value: galleryID.uuidString)
                    .eq("reviewer", value: reviewer)
                if let lastSeen { query = query.gt("updated_at", value: lastSeen) }
                let page: [MarkChange] = try await query.order("updated_at").range(from: from, to: from + 999).execute().value
                rows += page
                if page.count < 1000 { break }
                from += 1000
            }
        } catch {
            await setMessage("Couldn't read ratings: \(error.localizedDescription)")
            return
        }
        guard !rows.isEmpty else { ready = true; return }

        // Latest value per image (rows are oldest first, so later ones win).
        // Studio rows are our own writes: just remember them. Client rows go to Capture One.
        var latest: [String: (mark: C1Mark, fromClient: Bool, variantID: String?, folder: String)] = [:]
        for row in rows {
            let key = "\(row.images.rel_path)#\(row.images.variant_position ?? 1)"
            let mark = C1Mark(rating: row.rating ?? 0, colorTag: C1Mark.colorNumber(row.color_tag))
            latest[key] = (mark, row.source != "studio", row.images.variant_id, row.images.folder_path)
        }

        var toApply: [String: C1Mark] = [:]               // variant id -> mark
        var applyKeys: [String] = []
        var folders = Set<String>()
        for (key, entry) in latest where entry.fromClient {
            guard let id = entry.variantID else { continue }
            toApply[id] = entry.mark
            applyKeys.append(key)
            folders.insert(entry.folder.isEmpty ? "Capture" : entry.folder)
        }

        var applied = 0
        if !toApply.isEmpty {
            switch await CaptureOneScripts.applyMarks(toApply, collectionNames: Array(folders)) {
            case .success(let text): applied = Int(text) ?? 0
            case .failure(let message):
                await setMessage("Capture One error: \(message)")     // retried on the next sync
                return
            }
        }

        // Only after a successful apply: remember the database state and move on
        let now = Date()
        for (key, entry) in latest { known[key] = entry.mark }
        for key in applyKeys { recentlyApplied[key] = now }
        lastSeen = rows.last?.updated_at
        ready = true

        if applied > 0 {
            await MainActor.run {
                status.applied += applied
                status.lastSync = Date()
                status.message = "Applied \(applied) client change\(applied == 1 ? "" : "s") to Capture One"
            }
        }
    }

    // MARK: - Capture One -> Gallery

    /// Called with every fresh Capture One read (never with older, remembered readings).
    /// Sends ratings/tags that differ from what the database holds.
    func reportCaptureOne(_ variants: [C1Variant]) async {
        guard ready else { return }                      // wait for the first pull, or we'd overwrite the client
        let now = Date()
        recentlyApplied = recentlyApplied.filter { now.timeIntervalSince($0.value) < echoWindow }

        var changes: [(key: String, mark: C1Mark)] = []
        for v in variants {
            guard let rating = v.rating, let tag = v.colorTag, let key = imageKey(v) else { continue }
            if recentlyApplied[key] != nil { continue }    // read may predate our own apply
            let mark = C1Mark(rating: rating, colorTag: tag)
            if mark != (known[key] ?? C1Mark(rating: 0, colorTag: 0)) { changes.append((key, mark)) }
        }
        guard !changes.isEmpty else { return }

        // Only images that are in the gallery (newer ones get picked up after they upload)
        if changes.contains(where: { imageIDs[$0.key] == nil }) { await loadImageIDs() }
        let rows = changes.compactMap { change -> MarkUpsert? in
            guard let id = imageIDs[change.key] else { return nil }
            return MarkUpsert(image_id: id, reviewer: reviewer, rating: change.mark.rating,
                              color_tag: change.mark.colorName, source: "studio")
        }
        guard !rows.isEmpty else { return }

        do {
            _ = try await client.from("marks").upsert(rows, onConflict: "image_id,reviewer").execute()
        } catch {
            await setMessage("Couldn't send Capture One ratings: \(error.localizedDescription)")
            return
        }
        for change in changes where imageIDs[change.key] != nil { known[change.key] = change.mark }
        let count = rows.count
        await MainActor.run {
            status.sent += count
            status.lastSync = Date()
            status.message = "Sent \(count) Capture One change\(count == 1 ? "" : "s") to the gallery"
        }
    }

    /// "Folder/IMG_1234.CR3#1" for a variant, or nil if it isn't inside the Capture folder.
    private func imageKey(_ v: C1Variant) -> String? {
        let path = URL(fileURLWithPath: v.rawPath).standardizedFileURL.path
        let root = captureRoot.path + "/"
        guard path.hasPrefix(root) else { return nil }
        return "\(path.dropFirst(root.count))#\(v.position)"
    }

    /// Image ids for the gallery, refreshed at most every 20 s.
    private func loadImageIDs() async {
        guard Date().timeIntervalSince(imageIDsLoaded) > 20 else { return }
        imageIDsLoaded = Date()
        var map: [String: String] = [:]
        var from = 0
        do {
            while true {
                let page: [ImageKeyRow] = try await client.from("images")
                    .select("id, rel_path, variant_position")
                    .eq("gallery_id", value: galleryID.uuidString)
                    .range(from: from, to: from + 999)
                    .execute().value
                for row in page { map["\(row.rel_path)#\(row.variant_position ?? 1)"] = row.id }
                if page.count < 1000 { break }
                from += 1000
            }
            imageIDs = map
        } catch {
            await setMessage("Couldn't read gallery images: \(error.localizedDescription)")
        }
    }

    private func setMessage(_ text: String) async {
        await MainActor.run { status.message = text }
    }
}

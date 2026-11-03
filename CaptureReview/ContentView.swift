// ContentView.swift – Capture Review (v14: Keychain secret key, client link + access code, test tools hidden)

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var sessionURL: URL?
    @State private var folders: [String] = []          // "" = Capture root
    @State private var selection = Set<String>()
    @State private var uploader: ProofUploader?
    @State private var ratingSync: RatingSync?
    @State private var catalog: Catalog?
    @State private var cosLog: CosLog?
    @State private var cosMonitor: CosMonitor?
    @State private var galleryName = ""
    // "Same job or new job?" when a session's folder name differs from its catalog
    @State private var showCopyPrompt = false
    @State private var copyURL: URL?
    @State private var copyCatalog: Catalog?
    @State private var copyOldName = ""
    @State private var status = "Choose a Capture One session folder"
    @State private var stats = UploadStats()
    @State private var syncStatus = SyncStatus()
    @State private var quality = QualitySettings()
    @State private var log = UploadLog()
    @State private var confirmReset = false
    @State private var busy = false
    @State private var auto = AutoPublisher()
    @State private var regradesWaiting = 0
    @State private var uploadedCounts: [String: Int] = [:]     // folder -> images in the gallery
    @State private var serviceKey = Keychain.readSecretKey() ?? ""   // Supabase SECRET key, from the Keychain
    @State private var keyEntry = ""
    @State private var access: GalleryAccess?                  // client link + code
    @State private var confirmNewCode = false
    @AppStorage("showTestTools") private var showTestTools = false

    var body: some View {
        if serviceKey.isEmpty { keySetup } else { main }
    }

    /// First run on a Mac: the secret key goes into the Keychain, never into the app's code.
    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Supabase").font(.headline)
            Text("Paste the project's SECRET key (Supabase: Project Settings > API Keys). It's stored in this Mac's Keychain and never leaves this Mac except to talk to Supabase.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("sb_secret_…", text: $keyEntry)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Save to Keychain") {
                    let key = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard key.hasPrefix("sb_secret_") || key.hasPrefix("eyJ") else {
                        status = "That doesn't look like a secret key (it should start with sb_secret_)."
                        return
                    }
                    if Keychain.saveSecretKey(key) { serviceKey = key; keyEntry = ""; status = "Choose a Capture One session folder" }
                    else { status = "The Keychain refused to save the key." }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keyEntry.isEmpty)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 220, alignment: .topLeading)
    }

    // The window is built from small sections: one giant view makes Swift's type-checker give up.
    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("Choose Session Folder…") { chooseSession() }
            if let sessionURL {
                Text(sessionURL.lastPathComponent).font(.headline)
                if !galleryName.isEmpty {
                    Text("Gallery: \(galleryName)").font(.caption).foregroundStyle(.secondary)
                }
                folderSection
                qualitySection
                regradeBanner
                actionsSection
                autoSection
                galleryButtons
                accessSection
                testToolsSection
            }
            progressSection
            ratingsSection
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 520, alignment: .topLeading)
        .onChange(of: selection) { _, new in auto.folders = new }
        .onChange(of: regradesWaiting) { _, n in
            NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil          // count on the Dock icon
        }
        .onAppear { connectAutoPublisher() }
        .confirmationDialog("Is this the same job?", isPresented: $showCopyPrompt, titleVisibility: .visible) {
            Button("Same job (keep its gallery)") {
                guard let url = copyURL, let cat = copyCatalog else { return }
                Task { await cat.setSessionName(url.lastPathComponent); openSession(url, cat) }
            }
            Button("New job (new gallery)") {
                guard let url = copyURL, let cat = copyCatalog else { return }
                Task { _ = await cat.startNewJob(name: url.lastPathComponent); openSession(url, cat) }
            }
            Button("Cancel", role: .cancel) { copyCatalog = nil; copyURL = nil }
        } message: {
            Text("This session was last opened as \u{201C}\(copyOldName)\u{201D}. If the folder was copied for a different job, choose New job so it gets its own gallery.")
        }
        .task {
            // Per-folder upload counts, refreshed every 3 s from the uploader's local cache
            while !Task.isCancelled {
                if let uploader { uploadedCounts = await uploader.uploadedCounts() }
                refreshFolders()
                if let catalog {
                    await catalog.scan()
                    logCatalog(await catalog.drainEvents())
                }
                // Renames / deletes reach the gallery even when nothing is being published
                if let uploader { await uploader.syncCatalog() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var folderSection: some View {
        HStack {
            Text("Capture folders").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { selection = Set(folders.filter { !$0.isEmpty }) }
            Button("None") { selection = [] }
        }
        .controlSize(.small)

        List(folders, id: \.self) { folder in folderRow(folder) }
            .frame(minHeight: 160)

        if !selection.isEmpty {
            Text(tickedTotalText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func folderRow(_ folder: String) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { selection.contains(folder) },
                set: { on in if on { selection.insert(folder) } else { selection.remove(folder) } }
            )) {
                Text(folder.isEmpty ? "(Capture root)" : folder)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let n = uploadedCounts[folder], n > 0 {
                Text("\(n) uploaded").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var tickedTotalText: String {
        let total = selection.reduce(0) { $0 + (uploadedCounts[$1] ?? 0) }
        return "Ticked folders: \(total) image\(total == 1 ? "" : "s") in the gallery"
    }

    @ViewBuilder private var qualitySection: some View {
        Picker("Upload quality", selection: $quality.mode) {
            ForEach(QualitySettings.Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        Text(quality.summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
    }

    // Re-grades waiting for a manual push
    @ViewBuilder private var regradeBanner: some View {
        if regradesWaiting > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(regradeText).font(.callout)
                Spacer()
                Button("Publish Changes") { publish(.changed) }
                    .disabled(selection.isEmpty || busy)
            }
            .padding(8)
            .background(Color.orange.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var regradeText: String {
        "\(regradesWaiting) image\(regradesWaiting == 1 ? "" : "s") re-graded in Capture One, not in the gallery yet"
    }

    private var actionsSection: some View {
        HStack {
            Button(selection.count > 1 ? "Publish \(selection.count) Folders" : "Publish Folder") { publish(.changed) }
                .keyboardShortcut(.defaultAction)
                .help("Uploads new variants and ones you've re-graded since they were published")
            Button("Apply Quality") { publish(.upgrade) }
                .help("Re-sends published variants that went out at a different quality than the current setting")
            Button("Republish All") { publish(.all) }
                .help("Re-renders and re-uploads every variant in the selected folders")
        }
        .disabled(selection.isEmpty || busy)
    }

    @ViewBuilder private var autoSection: some View {
        HStack(spacing: 12) {
            Toggle("Auto-publish ticked folders", isOn: $auto.enabled)
                .toggleStyle(.switch)
            Stepper("Settle \(Int(auto.settleSeconds)) s", value: $auto.settleSeconds, in: 0...15)
                .help("Wait this long after the last new frame before rendering")
        }
        Text(autoStatusText)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
    }

    private var autoStatusText: String {
        var text = "Auto: " + auto.status
        if let last = auto.lastRun {
            text += " · last run " + last.formatted(date: .omitted, time: .standard)
        }
        return text
    }

    private var galleryButtons: some View {
        HStack {
            Button("Open Gallery") { openGallery() }
            Button("Upload Log") { log.showWindow() }
            Button("Settings Log") {
                if let url = cosLog?.url { NSWorkspace.shared.open(url) }
                else { status = "Choose a session first" }
            }
            .help("Everything Capture One writes to the settings (.cos) files, and every re-grade decision")
            Spacer()
            Toggle("Show test tools", isOn: $showTestTools)
                .toggleStyle(.checkbox).controlSize(.small)
        }
    }

    // Client access: the link and code you send the client
    private var accessSection: some View {
        GroupBox("Client access") {
            if let access {
                accessDetails(access)
            } else {
                Text("Loading link…").font(.caption).foregroundStyle(.secondary).padding(4)
            }
        }
    }

    private func accessDetails(_ access: GalleryAccess) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(clientLink(access))
                    .font(.callout).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copy Link") { copy(clientLink(access)); status = "Gallery link copied" }
            }
            HStack {
                Text("Code")
                Text(access.access_code ?? "none")
                    .font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy Code") { copy(access.access_code ?? ""); status = "Access code copied" }
                Button("New Code…") { confirmNewCode = true }
                    .confirmationDialog("Make a new access code?", isPresented: $confirmNewCode) {
                        Button("New Code", role: .destructive) { newCode() }
                    } message: {
                        Text("Anyone using the current code will be asked for the new one.")
                    }
            }
            Text("Send the link and the code separately. The code is only asked for once per browser.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(4)
    }

    // Test tools (off by default): wipe the test gallery, change the Keychain key
    @ViewBuilder private var testToolsSection: some View {
        if showTestTools {
            HStack {
                Button("Reset Test Gallery…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Delete all uploaded proofs, their database rows and ratings, and the local proof cache?",
                                        isPresented: $confirmReset) {
                        Button("Delete Everything", role: .destructive) { resetGallery() }
                    } message: {
                        Text("Only affects this gallery. RAW files and your Capture One session are not touched.")
                    }
                Button("Change Secret Key…") { forgetSecretKey() }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var progressSection: some View {
        if stats.total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(min(stats.uploaded, stats.total)), total: Double(stats.total)) {
                    Text("Uploaded \(stats.uploaded) of \(stats.total)")
                }
                Text(progressText).font(.caption).monospacedDigit()
                Text(stats.bottleneck).font(.caption.bold())
                if !stats.sizeSummary.isEmpty {
                    Text(stats.sizeSummary).font(.caption).monospacedDigit()
                }
                if !stats.lastUpload.isEmpty {
                    Text("Last: " + stats.lastUpload)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var progressText: String {
        var text = "\(stats.waitingOnDisk) rendered, waiting  ·  \(stats.inFlight) uploading now  ·  \(Int(stats.perMinute)) per min"
        if stats.retries > 0 { text += "  ·  \(stats.retries) retries" }
        return text
    }

    @ViewBuilder private var ratingsSection: some View {
        if sessionURL != nil {
            HStack(spacing: 6) {
                Text("Ratings & tags:").font(.caption.bold())
                Text(syncStatus.message).font(.caption)
                if let last = syncStatus.lastSync {
                    Text(syncText(last)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func syncText(_ last: Date) -> String {
        "·  \(syncStatus.applied) from client  ·  \(syncStatus.sent) from Capture One  ·  last "
            + last.formatted(date: .omitted, time: .standard)
    }

    // MARK: - Wiring

    private func connectAutoPublisher() {
        auto.publish = { folders, scope in
            let outcome = await runPublish(folders, .changed, scope: scope, isAuto: true)
            if !outcome.busy, !(isSelection(scope) && outcome.queued == 0) { status = outcome.summary }
            return outcome
        }
        auto.reportMarks = { variants in
            await ratingSync?.reportCaptureOne(variants)
        }
    }

    private func forgetSecretKey() {
        Keychain.deleteSecretKey()
        serviceKey = ""
        Task {
            await uploader?.stop(); await ratingSync?.stop()
            uploader = nil; ratingSync = nil; sessionURL = nil
        }
    }

    // MARK: - Session

    private func chooseSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Same session chosen again: don't rebuild the uploader (that dropped everything still
        // queued for upload). New folders show up on their own; just refresh now.
        if let current = sessionURL, current.standardizedFileURL == url.standardizedFileURL, uploader != nil {
            refreshFolders()
            status = "Same session: folders refreshed, uploads kept running"
            return
        }

        // The session catalog decides which gallery this session publishes to. Without it,
        // nothing is published (it would risk mixing jobs).
        guard let cat = Catalog(sessionRoot: url) else {
            status = "Couldn't open the session catalog (.capturereview in the session folder). Nothing will be published."
            return
        }
        let name = url.lastPathComponent
        if let stored = cat.storedSessionName, stored != name {
            // Folder renamed, or copied from another job: ask before choosing the gallery
            copyURL = url
            copyCatalog = cat
            copyOldName = stored
            showCopyPrompt = true
            return
        }
        Task {
            await cat.setSessionName(name)
            openSession(url, cat)
        }
    }

    /// Opens a session with its catalog: folders, logs, its own gallery, uploader and rating sync.
    private func openSession(_ url: URL, _ cat: Catalog) {
        sessionURL = url
        selection = []
        folders = Self.captureFolders(in: url)
        log.start(session: url.lastPathComponent)
        auto.setSession(url)
        access = nil
        galleryName = ""

        // Detailed log of what Capture One does to the settings files, plus re-grade decisions
        let settingsLog = CosLog(session: url.lastPathComponent)
        let monitor = CosMonitor(sessionRoot: url, log: settingsLog)
        monitor.start()
        cosLog = settingsLog
        cosMonitor = monitor

        Task {
            await uploader?.stop()
            await ratingSync?.stop()
            uploader = nil
            ratingSync = nil
            await cat.scan()
            logCatalog(await cat.drainEvents())
            catalog = cat

            // This session's gallery: remembered in the catalog (works offline), else found by the
            // session id on the server, else created and named after the session folder.
            let galleryID: UUID
            if let known = await cat.storedGalleryID() {
                galleryID = known
            } else {
                status = "Finding this session's gallery…"
                do {
                    let ref = try await GalleryDirectory.resolve(supabaseURL: Config.supabaseURL, serviceKey: serviceKey,
                                                                 sessionUID: await cat.sessionID,
                                                                 sessionName: url.lastPathComponent)
                    galleryID = ref.id
                    await cat.setGalleryID(ref.id)
                    log.add(UploadLogEntry(time: Date(), name: "Gallery", kind: .info, quality: "", width: 0, height: 0,
                                           bytes: 0, seconds: 0,
                                           note: (ref.created ? "Gallery created: " : "Gallery loaded: ")
                                               + "\(ref.name) (\(ref.id.uuidString.prefix(8)))"))
                } catch {
                    status = "Couldn't reach the server to set up this session's gallery (\(error.localizedDescription)). "
                        + "Nothing will be published; choose the session again once online."
                    log.add(UploadLogEntry(time: Date(), name: "Gallery", kind: .failed, quality: "", width: 0, height: 0,
                                           bytes: 0, seconds: 0, note: "No gallery: \(error.localizedDescription)"))
                    return
                }
            }

            let up = ProofUploader(supabaseURL: Config.supabaseURL,
                                   serviceKey: serviceKey,
                                   galleryID: galleryID,
                                   sessionRoot: url,
                                   stats: stats,
                                   quality: quality,
                                   log: log,
                                   catalog: cat,
                                   cosLog: settingsLog)
            await up.start()
            uploader = up
            access = await up.galleryAccess()
            galleryName = access?.name ?? ""

            let rs = RatingSync(supabaseURL: Config.supabaseURL,
                                serviceKey: serviceKey,
                                galleryID: galleryID,
                                sessionRoot: url,
                                status: syncStatus)
            await rs.start()
            ratingSync = rs

            status = "Watching Output/_proof"
        }
    }

    /// Writes catalog events (renames, moves, deletes, restores, new frames) to the upload log.
    /// New frames aren't logged here: the publish lines already cover them.
    private func logCatalog(_ events: [CatalogEvent]) {
        for e in events where e.kind != .added {
            let label: String
            switch e.kind {
            case .created:  label = "Catalog"
            case .renamed:  label = "Renamed"
            case .moved:    label = "Moved"
            case .deleted:  label = "Deleted"
            case .restored: label = "Restored"
            case .added:    label = "Added"
            }
            log.add(UploadLogEntry(time: Date(), name: e.name, kind: .info, quality: "", width: 0, height: 0,
                                   bytes: 0, seconds: 0, note: "\(label): \(e.detail)"))
        }
    }

    /// "" (Capture root) plus every subfolder of <session>/Capture, sorted.
    private static func captureFolders(in session: URL) -> [String] {
        let capture = session.appendingPathComponent("Capture")
        let subfolders = ((try? FileManager.default.contentsOfDirectory(
            at: capture, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { $0 != "CaptureOne" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [""] + subfolders
    }

    /// Picks up folders added, renamed or removed in Capture One without re-choosing the session.
    /// Runs every 3 s (one directory listing, cheap). While auto-publish is on, a new folder is
    /// ticked automatically, so frames shot into it reach the gallery without a click.
    private func refreshFolders() {
        guard let sessionURL else { return }
        let now = Self.captureFolders(in: sessionURL)
        guard now != folders else { return }
        let added = now.filter { !folders.contains($0) }
        let removed = folders.filter { !now.contains($0) }
        folders = now
        if !removed.isEmpty { selection.subtract(removed) }
        if auto.enabled, !added.isEmpty {
            selection.formUnion(added)
            auto.folders = selection           // before the next tick, not after SwiftUI's onChange
            auto.checkSoon(added)
        }
        for f in added {
            log.add(UploadLogEntry(time: Date(), name: "Folders", kind: .info, quality: "", width: 0, height: 0,
                                   bytes: 0, seconds: 0,
                                   note: "Folder added: \(f)" + (auto.enabled ? " (ticked for auto-publish)" : "")))
        }
        for f in removed {
            log.add(UploadLogEntry(time: Date(), name: "Folders", kind: .info, quality: "", width: 0, height: 0,
                                   bytes: 0, seconds: 0, note: "Folder gone from Capture: \(f)"))
        }
        if !added.isEmpty {
            status = "New folder: " + added.joined(separator: ", ")
                + (auto.enabled ? " (ticked, auto-publishing)" : " (tick it to publish)")
        }
    }

    // MARK: - Publish

    /// Button entry point: always a full check (reads every variant's live adjustments).
    private func publish(_ mode: PublishMode) {
        let chosen = folders.filter { selection.contains($0) }
        Task { status = await runPublish(chosen, mode, scope: .full).summary }
    }

    private func isSelection(_ scope: PublishScope) -> Bool {
        if case .only = scope { return true }
        return false
    }

    /// The whole publish: ask Capture One for variants, compare with what's uploaded,
    /// render only what's needed. Used by the buttons and by auto-publish.
    private func runPublish(_ chosen: [String], _ mode: PublishMode,
                            scope: PublishScope, isAuto: Bool = false) async -> PublishOutcome {
        let outcome = await runPublishSteps(chosen, mode, scope: scope, isAuto: isAuto)
        if let waiting = outcome.regradesWaiting { regradesWaiting = waiting }
        return outcome
    }

    private func runPublishSteps(_ chosen: [String], _ mode: PublishMode,
                                 scope: PublishScope, isAuto: Bool) async -> PublishOutcome {
        guard let uploader else { return PublishOutcome(summary: "Choose a session first") }
        guard !busy else { return PublishOutcome(summary: "Busy", busy: true) }
        busy = true
        defer { busy = false }
        let names = chosen.map { $0.isEmpty ? "Capture" : $0 }
        let scoped = isSelection(scope)
        if !scoped { status = "Reading variants from Capture One…" }

        // 1. Which variants exist (and, for a full check, their live adjustments)
        let t0 = Date()
        var variants: [C1Variant] = []
        var unstable: [String] = []
        var checkName = isAuto ? "Auto check" : "Publish check"
        switch scope {
        case .only(let list):
            variants = list
            checkName = "Selection check"
        case .full, .quick:
            let full: Bool
            if case .full = scope { full = true } else { full = false }
            if isAuto && full { checkName = "Full check" }
            // Capture One importing mid-read: wait a moment and read again (up to 3 tries)
            for attempt in 1...3 {
                switch await CaptureOneScripts.inventory(collectionNames: names, withAdjustments: full) {
                case .success(let inventory):
                    variants = inventory.variants
                    unstable = inventory.unstable
                case .failure(let failure):
                    return PublishOutcome(summary: "AppleScript error reading variants: \(failure.message)")
                }
                if unstable.isEmpty || attempt == 3 { break }
                try? await Task.sleep(for: .seconds(1))
            }
            // Fresh read of every variant: send any Capture One rating/tag changes to the gallery
            await ratingSync?.reportCaptureOne(variants)
        }

        // 2. Compare with what's already uploaded (and what's still in flight)
        if !scoped { status = "Checking what's already uploaded…" }
        let t1 = Date()
        // Auto-publish sends new frames only; re-grades wait for the Publish button
        let plan = await uploader.planBatch(variants: variants, folders: chosen, mode: mode,
                                            debounce: isAuto, scoped: scoped, holdRegrades: isAuto)
        let t2 = Date()

        // Timing for every check, so large sessions show where the time goes.
        // Selection checks run every few seconds: logged only when they send something.
        if !scoped || !plan.variantIDs.isEmpty {
            let importing = unstable.isEmpty ? "" : " · importing, re-read: \(unstable.joined(separator: ", "))"
            log.add(UploadLogEntry(time: Date(), name: checkName, kind: .info,
                                   quality: "", width: 0, height: 0, bytes: 0,
                                   seconds: t2.timeIntervalSince(t0),
                                   note: String(format: "%d variants · Capture One %.2f s · compare %.2f s",
                                                variants.count, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1))
                                       + importing))
        }
        if let error = plan.error { return PublishOutcome(summary: error) }
        if !plan.duplicates.isEmpty {
            return PublishOutcome(summary: "Same filename in more than one selected folder (e.g. \(plan.duplicates[0])). Publish those folders separately.")
        }
        let recheck = plan.notInCaptureOne > 0 || plan.inProgressChanged > 0 || plan.regradeSettling > 0 || !unstable.isEmpty
        var waiting = plan.notInCaptureOne > 0 ? " · \(plan.notInCaptureOne) not ready in Capture One yet" : ""
        if !unstable.isEmpty { waiting += " · Capture One was importing, checking again shortly" }
        if plan.variantIDs.isEmpty {
            return PublishOutcome(summary: "Nothing to publish: \(plan.summary)\(waiting).", needsRecheck: recheck,
                                  regradesWaiting: plan.regradesWaiting)
        }

        // 3. Render only those variants, in one Capture One command
        switch await CaptureOneScripts.process(variantIDs: plan.variantIDs, collectionNames: names) {
        case .success(let count):
            return PublishOutcome(summary: "\(plan.summary)\(waiting). Rendering \(count) variant\(count == "1" ? "" : "s").",
                                  queued: Int(count) ?? 0, needsRecheck: recheck,
                                  regradesWaiting: plan.regradesWaiting)
        case .failure(let message):
            return PublishOutcome(summary: "AppleScript error while processing: \(message)")
        }
    }

    // MARK: - Other actions

    /// Opens the client gallery in the default browser.
    /// Web address: adds ?g=<gallery id>. Local index.html: opens as-is (uses its DEFAULT_GALLERY).
    /// The link you send the client (no code in it).
    private func clientLink(_ a: GalleryAccess) -> String {
        var parts = URLComponents(string: Config.galleryPage)
        parts?.queryItems = [URLQueryItem(name: "g", value: a.slug)]
        return parts?.url?.absoluteString ?? Config.galleryPage
    }

    /// Opens the gallery for you, with the code built in (#code=… stays in your browser,
    /// is never sent to the server in the address, and is removed from the bar after opening).
    private func openGallery() {
        guard let access else { status = "Choose a session first (the gallery link loads with it)"; return }
        var link = clientLink(access)
        if let code = access.access_code { link += "#code=" + code }
        guard let url = URL(string: link) else { status = "Gallery address in Config.swift is not valid"; return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func newCode() {
        guard let uploader else { return }
        let code = ProofUploader.newAccessCode()
        Task {
            if await uploader.setAccessCode(code) {
                access = await uploader.galleryAccess()
                status = "New access code: \(code)"
            } else {
                status = "Couldn't change the code (check the connection)"
            }
        }
    }

    private func resetGallery() {
        guard let uploader else { return }
        status = "Resetting…"
        Task { status = await uploader.resetGallery() }
    }
}

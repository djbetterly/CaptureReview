// UploadLog.swift – Capture Review
// A live log of every file sent: size, pixel dimensions, upload time and speed.
// Shown in its own window (newest first) and also written to
// ~/Library/Logs/CaptureReview/<session>.log so you can review a shoot afterwards.

import SwiftUI
import AppKit
import Observation

nonisolated struct UploadLogEntry: Identifiable, Sendable {
    enum Kind: String, Sendable { case thumb = "Thumb", proof = "Proof", failed = "Failed", discarded = "Discarded", info = "Info" }

    let id = UUID()
    let time: Date
    let name: String
    let kind: Kind
    let quality: String        // "Wi-Fi", "Cellular"… or "" for thumbnails/errors
    let width: Int
    let height: Int
    let bytes: Int
    let seconds: Double
    let note: String

    var mbps: Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0 }
    var sizeText: String { bytes > 0 ? "\(Int((Double(bytes) / 1024).rounded())) KB" : "" }
    var dimensionsText: String { width > 0 ? "\(width) × \(height)" : "" }
    var secondsText: String { seconds > 0 ? String(format: "%.2f s", seconds) : "" }
    var speedText: String { seconds > 0 ? String(format: "%.1f Mbps", mbps) : "" }
    var timeText: String { time.formatted(date: .omitted, time: .standard) }
}

@Observable @MainActor
final class UploadLog {
    private(set) var entries: [UploadLogEntry] = []      // newest first
    private(set) var logFileURL: URL?
    private var handle: FileHandle?
    private let maxEntries = 5000
    private var window: NSWindow?

    // MARK: - Recording

    /// Starts a log file for this session (appends if it already exists).
    func start(session: String) {
        try? handle?.close()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CaptureReview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "time\timage\ttype\tquality\twidth\theight\tbytes\tseconds\tmbps\tnote\n"
            FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        logFileURL = url
        add(.init(time: Date(), name: session, kind: .info, quality: "", width: 0, height: 0,
                  bytes: 0, seconds: 0, note: "Session opened"))
    }

    func add(_ entry: UploadLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }

        let line = [ISO8601DateFormatter().string(from: entry.time), entry.name, entry.kind.rawValue,
                    entry.quality, String(entry.width), String(entry.height), String(entry.bytes),
                    String(format: "%.3f", entry.seconds), String(format: "%.2f", entry.mbps), entry.note]
            .joined(separator: "\t") + "\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    func clear() { entries.removeAll() }       // the file on disk keeps the full history

    // MARK: - Summary

    var summary: String {
        let proofs = entries.filter { $0.kind == .proof }
        let thumbs = entries.filter { $0.kind == .thumb }
        let failed = entries.filter { $0.kind == .failed }.count
        guard !proofs.isEmpty || !thumbs.isEmpty else { return "No uploads yet" }
        let bytes = (proofs + thumbs).reduce(0) { $0 + $1.bytes }
        let speeds = proofs.suffix(20).map(\.mbps)          // most recent 20 proofs
        let avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        let avgProof = proofs.isEmpty ? 0 : proofs.reduce(0) { $0 + $1.bytes } / proofs.count
        return String(format: "%d proofs · %d thumbs · %.1f MB sent · avg proof %d KB · recent speed %.1f Mbps",
                      proofs.count, thumbs.count, Double(bytes) / 1_048_576, avgProof / 1024, avgSpeed)
            + (failed > 0 ? " · \(failed) failed" : "")
    }

    // MARK: - Window

    func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Upload Log"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: UploadLogView(log: self))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func revealLogFile() {
        if let logFileURL { NSWorkspace.shared.activateFileViewerSelecting([logFileURL]) }
    }
}

struct UploadLogView: View {
    var log: UploadLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(log.summary).font(.caption).monospacedDigit()
                Spacer()
                Button("Clear") { log.clear() }
                Button("Show Log File") { log.revealLogFile() }
            }
            .controlSize(.small)

            Table(log.entries) {
                TableColumn("Time") { Text($0.timeText).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("Image") { Text($0.name) }
                    .width(min: 120, ideal: 180)
                TableColumn("Type") { e in
                    Text(e.kind.rawValue)
                        .foregroundStyle(e.kind == .failed ? Color.red : e.kind == .discarded ? Color.orange : Color.primary)
                }
                .width(min: 60, ideal: 70)
                TableColumn("Quality") { Text($0.quality) }
                    .width(min: 60, ideal: 70)
                TableColumn("Dimensions") { Text($0.dimensionsText).monospacedDigit() }
                    .width(min: 90, ideal: 100)
                TableColumn("Size") { Text($0.sizeText).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Upload") { Text($0.secondsText).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Speed") { Text($0.speedText).monospacedDigit() }
                    .width(min: 70, ideal: 80)
                TableColumn("Note") { Text($0.note).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 300)
    }
}

// UploadQuality.swift – Capture Review
// Quality profiles (Cellular / Wi-Fi / Wired), the Auto choice, and the image encoder.
//
// Capture One renders ONE master per variant (2048 px, high quality).
// The app re-encodes that master for the active profile, so switching profile
// never costs a Capture One re-render.

import Foundation
import Observation
import Network
import ImageIO
import UniformTypeIdentifiers

nonisolated enum UploadQuality: String, CaseIterable, Sendable, Identifiable {
    case cellular, wifi, wired
    var id: String { rawValue }

    var label: String {
        switch self {                       // what the client gets, not the network
        case .cellular: "Small"
        case .wifi:     "Medium"
        case .wired:    "Large"
        }
    }
    /// Shown when hovering the picker
    var detail: String {
        switch self {
        case .cellular: "Small: 1280 px, about 160 KB per proof. For slow or metered connections."
        case .wifi:     "Medium: 2048 px, about 450 KB per proof."
        case .wired:    "Large: 2048 px at higher JPEG quality, about 600 KB per proof."
        }
    }
    var proofMaxPixel: Int  { self == .cellular ? 1280 : 2048 }
    /// Starting JPEG quality (ImageIO scale). Stepped down until the file fits `proofBudget`.
    var proofQuality: Double {
        switch self {
        case .cellular: 0.60
        case .wifi:     0.70
        case .wired:    0.85
        }
    }
    /// Target maximum proof size in bytes (very detailed frames may land a little over).
    var proofBudget: Int {
        switch self {
        case .cellular: 160 * 1024
        case .wifi:     450 * 1024      // 320 KB forced detailed 2048 px frames to q 0.40 (1,000-image test)
        case .wired:    600 * 1024
        }
    }
    /// Higher = better. Used by "Upgrade Quality".
    var rank: Int {
        switch self {
        case .cellular: 0
        case .wifi:     1
        case .wired:    2
        }
    }
    /// Short code added to storage filenames, so each quality gets its own name.
    var code: String {
        switch self {
        case .cellular: "c"
        case .wifi:     "w"
        case .wired:    "x"
        }
    }

    static let thumbMaxPixel = 400
    static let thumbQuality = 0.55
    static let thumbBudget = 25 * 1024
    /// Never encode below this quality, even if the file ends up over budget.
    static let qualityFloor = 0.40
}

/// The picker setting plus the live Auto decision. Main thread, drives the UI.
@Observable @MainActor
final class QualitySettings {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, cellular, wifi, wired
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:     "Auto"
            case .cellular: "Small"
            case .wifi:     "Medium"
            case .wired:    "Large"
            }
        }
    }

    var mode: Mode = .auto
    private(set) var autoChoice: UploadQuality = .wifi
    private(set) var measuredMbps: Double = 0           // rolling average, per upload
    private(set) var lowDataNetwork = false             // macOS Low Data Mode or expensive (e.g. iPhone hotspot)

    private var samples: [Double] = []
    private var samplesSinceChange = 0
    private let monitor = NWPathMonitor()

    // Per-upload speed thresholds (Mbps). A single small upload under-reports the
    // link's full speed, so these are deliberately low. Tune after a real shoot.
    // (Wired is never chosen by Auto, see tier(for:).)
    private let cellularBelow = 1.5

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained || path.isExpensive
            Task { @MainActor in self?.setLowData(constrained) }
        }
        monitor.start(queue: DispatchQueue(label: "capture-review.network"))
    }

    /// The quality to use for the next upload.
    var effective: UploadQuality {
        switch mode {
        case .auto:     autoChoice
        case .cellular: .cellular
        case .wifi:     .wifi
        case .wired:    .wired
        }
    }

    var summary: String {
        let speed = measuredMbps > 0 ? String(format: " · ~%.1f Mbps per upload", measuredMbps) : ""
        let low = lowDataNetwork ? " · Low Data network" : ""
        return mode == .auto ? "Auto (\(autoChoice.label))\(speed)\(low)" : "\(mode.label) (locked)\(speed)\(low)"
    }

    /// Feed every finished upload in. Drops quality quickly, raises it slowly.
    func record(bytes: Int, seconds: Double) {
        guard seconds > 0 else { return }
        addSample(Double(bytes) * 8 / seconds / 1_000_000)
    }

    /// A failed or timed-out upload counts as a very slow sample, so a dead link
    /// pushes Auto down instead of looking like "no data".
    func recordFailure() {
        addSample(0.05)
    }

    /// The session speed test sets Auto's starting point directly (one 512 KB upload
    /// measures the link better than small proofs do). Climbing later still needs a
    /// sustained good stretch; dropping is immediate.
    func seed(mbps: Double) {
        guard !lowDataNetwork else { change(to: .cellular); return }
        let start = tier(for: mbps)
        if start != autoChoice { autoChoice = start }
        samplesSinceChange = 0
    }

    /// Called when a session is chosen: old measurements don't describe the new network.
    func resetMeasurements() {
        samples.removeAll()
        measuredMbps = 0
        samplesSinceChange = 0
    }

    /// How many uploads to run at once. On a weak link, parallel uploads split the
    /// bandwidth and all time out together, so fewer is faster.
    var recommendedParallel: Int {
        let recent = recentMbps
        // Start cautiously: a link can pass the speed test and still drop packets.
        // Go to 4 only after a few real uploads have succeeded quickly.
        if samples.count < 4 { return lowDataNetwork ? 1 : 2 }
        if recent < 0.5 { return 1 }
        if recent < 2.0 || lowDataNetwork { return 2 }
        return 4
    }

    private var recentMbps: Double {
        let last = samples.suffix(3)
        return last.isEmpty ? 0 : last.reduce(0, +) / Double(last.count)
    }

    private func addSample(_ mbps: Double) {
        samples.append(mbps)
        if samples.count > 20 { samples.removeFirst() }
        measuredMbps = samples.reduce(0, +) / Double(samples.count)
        samplesSinceChange += 1
        decide()
    }

    private func setLowData(_ value: Bool) {
        lowDataNetwork = value
        decide()
    }

    /// Auto chooses between Cellular and Wi-Fi only. Wired (biggest files) is a manual
    /// choice: measured per-file speed depends on file size, so auto-picking Wired made it
    /// flip back and forth between Wired and Wi-Fi in testing.
    private func tier(for mbps: Double) -> UploadQuality {
        mbps < cellularBelow ? .cellular : .wifi
    }

    private func decide() {
        if lowDataNetwork { change(to: .cellular); return }
        guard !samples.isEmpty else { return }

        // Down: react to the last 3 uploads (a sudden drop shows up right away)
        let recentTier = tier(for: recentMbps)
        if recentTier.rank < autoChoice.rank {
            change(to: recentTier)
            return
        }
        // Up: only when both the recent and the longer average agree, after a sustained stretch
        let longTier = tier(for: measuredMbps)
        let upTier = longTier.rank < recentTier.rank ? longTier : recentTier
        if upTier.rank > autoChoice.rank, samplesSinceChange >= 15 {
            change(to: upTier)
        }
    }

    private func change(to quality: UploadQuality) {
        guard quality != autoChoice else { return }
        autoChoice = quality
        samplesSinceChange = 0
    }
}

nonisolated struct EncodedImage: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let quality: Double        // the JPEG quality that was actually used
}

/// Makes thumbnails and proofs from the Capture One master with ImageIO.
nonisolated enum ImageEncoder {
    /// Resizes to `maxPixel` (never enlarges), then encodes at `quality`, stepping the
    /// quality down in steps of 0.05 until the file fits `maxBytes`, never below `qualityFloor`.
    static func jpeg(from url: URL, maxPixel: Int, quality: Double, maxBytes: Int) -> EncodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var step = Int((quality * 100).rounded())
        let floorStep = Int((UploadQuality.qualityFloor * 100).rounded())
        var best: Data?
        while true {
            guard let data = encode(image, quality: Double(step) / 100) else { return nil }
            best = data
            if data.count <= maxBytes || step - 5 < floorStep { break }
            step -= 5
        }
        guard let best else { return nil }
        return EncodedImage(data: best, width: image.width, height: image.height, quality: Double(step) / 100)
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

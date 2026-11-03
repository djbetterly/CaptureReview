// RegradeRules.swift – Capture Review
// Which adjustments count as a re-grade, and how big a change has to be.
// Edited in Settings (Capture Review > Settings…, ⌘,). Saved per Mac, applies to every session.
//
// Rule keys:
//   "live:<code>"  a value from Capture One's live read, by its 4-letter AppleScript code (CVex = exposure)
//   "file:<Key>"   a value in the settings (.cos) file, by its key name (Exposure, GradationCurveY…)
// No rule = counts, with the built-in threshold (VisualChange).

import Foundation
import AppKit

nonisolated struct RegradeRule: Codable, Sendable, Equatable {
    var counts = true            // false: changes to this never trigger a re-grade
    var threshold: Double?       // nil: built-in threshold
}

/// Thread-safe store, readable from the uploader's background work.
nonisolated final class RegradeRules: @unchecked Sendable {
    static let shared = RegradeRules()

    private let lock = NSLock()
    private var rules: [String: RegradeRule] = [:]
    private var structure = true
    /// Every key seen in a live read or settings file, with its latest value (fills the Settings list)
    private var seen: [String: String] = [:]
    private var seenDirty = false
    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: "regradeRules"),
           let saved = try? JSONDecoder().decode([String: RegradeRule].self, from: data) { rules = saved }
        if defaults.object(forKey: "regradeStructure") != nil { structure = defaults.bool(forKey: "regradeStructure") }
        if let saved = defaults.dictionary(forKey: "regradeSeenKeys") as? [String: String] { seen = saved }
    }

    func rule(_ key: String) -> RegradeRule? { lock.withLock { rules[key] } }

    func set(_ key: String, _ rule: RegradeRule) {
        lock.withLock {
            if rule == RegradeRule() { rules[key] = nil } else { rules[key] = rule }
            if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "regradeRules") }
        }
    }

    /// Layers, masks and other sections added or removed in the settings file.
    var structureCounts: Bool {
        get { lock.withLock { structure } }
        set { lock.withLock { structure = newValue; defaults.set(newValue, forKey: "regradeStructure") } }
    }

    func resetAll() {
        lock.withLock {
            rules = [:]; structure = true
            defaults.removeObject(forKey: "regradeRules")
            defaults.removeObject(forKey: "regradeStructure")
        }
    }

    /// Records keys (and a recent value) as they're read. Saved at most every few seconds.
    func noteSeen(_ values: [String: String]) {
        lock.withLock {
            for (k, v) in values where seen[k] == nil || seen[k] != v {
                if seen[k] == nil { seenDirty = true }
                seen[k] = v
            }
        }
        flushSeenSoon()
    }

    func seenKeys() -> [String: String] { lock.withLock { seen } }

    private var flushScheduled = false
    private func flushSeenSoon() {
        let schedule: Bool = lock.withLock {
            guard seenDirty, !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [self] in
            let snapshot: [String: String] = lock.withLock {
                flushScheduled = false; seenDirty = false
                return seen
            }
            defaults.set(snapshot, forKey: "regradeSeenKeys")
        }
    }
}

/// Readable names for Capture One's 4-letter adjustment codes, from Capture One's own scripting
/// dictionary (.sdef inside the app). Empty if it can't be found; the codes are shown instead.
nonisolated enum CaptureOneDictionary {
    static func adjustmentNames() -> [String: String] {
        var apps: [URL] = NSWorkspace.shared.runningApplications
            .filter { ($0.localizedName ?? "").hasPrefix("Capture One") }
            .compactMap(\.bundleURL)
        apps.append(URL(fileURLWithPath: "/Applications/Capture One.app"))
        let fm = FileManager.default
        for app in apps {
            let res = app.appendingPathComponent("Contents/Resources")
            for f in (try? fm.contentsOfDirectory(atPath: res.path)) ?? [] where f.lowercased().hasSuffix(".sdef") {
                guard let data = try? Data(contentsOf: res.appendingPathComponent(f)) else { continue }
                let reader = SdefReader()
                let parser = XMLParser(data: data)
                parser.delegate = reader
                parser.parse()
                if !reader.names.isEmpty { return reader.names }
            }
        }
        return [:]
    }

    /// Collects property name/code pairs of the "adjustments" class (and extensions of it).
    private final class SdefReader: NSObject, XMLParserDelegate {
        var names: [String: String] = [:]
        private var inAdjustments = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "class" || name == "class-extension" {
                let cls = (attributes["name"] ?? attributes["extends"] ?? "").lowercased()
                if cls.contains("adjustment") || inAdjustments > 0 { inAdjustments += 1 }
            } else if name == "property", inAdjustments > 0, let code = attributes["code"], let n = attributes["name"] {
                names[code] = n
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if (name == "class" || name == "class-extension"), inAdjustments > 0 { inAdjustments -= 1 }
        }
    }
}

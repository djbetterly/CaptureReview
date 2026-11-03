// VisualChange.swift – Capture Review
// Decides whether a re-grade is big enough to matter on a proof.
//
// Clients see small JPEG previews to make selects from; they get the real files later.
// So a change only counts when it's visible on a proof. Rounding noise (Capture One rewrote
// 968 frames' color balance by ~0.0005 on 2 Nov) and tiny slider nudges are ignored.
//
// Always compared against what was SENT, not the last reading: many small nudges that add up
// to a visible change still trigger a re-grade once they cross the line.

import Foundation

nonisolated enum VisualChange {
    /// Per-setting threshold, keyed by Capture One's 4-letter AppleScript code (live read).
    /// A change counts when it is AT LEAST this big. Anything not listed uses `defaultTolerance`.
    /// Tune here after a real shoot.
    static let tolerance: [String: Double] = [
        "CVex": 0.1,       // exposure, stops: 0.01–0.09 is a nudge, 0.1 and up is a re-grade
        "CVwk": 50,        // white balance, kelvin
        "CVwt": 1.0,       // white balance tint
    ]
    /// The same thresholds for the settings file (.cos key names).
    static let diskTolerance: [String: Double] = [
        "Exposure": 0.1,
    ]
    /// Text settings whose change alone doesn't alter the picture
    /// (e.g. the white balance mode name; the kelvin/tint numbers carry the real change).
    static let ignoredText: Set<String> = ["CVwb"]

    /// Default thresholds (a change counts when it reaches them).
    /// Settings 0…~1.5 in size (saturations, amounts): 0.01. Larger (sliders, hues): 1% of the
    /// value, at least 0.5. Crop: 0.5% of the value, at least 2 px.
    static func defaultTolerance(key: String, _ a: Double, _ b: Double) -> Double {
        let m = max(abs(a), abs(b))
        if key == "crop" { return max(2, 0.005 * m) }
        if m <= 1.5 { return 0.01 }
        return max(0.5, 0.01 * m)
    }

    /// The settings that changed visibly between what was sent and now, e.g. ["CVex 0→0.46"].
    /// Empty = not worth re-sending.
    static func significantChanges(sent: String, now: String) -> [String] {
        analyze(sent: sent, now: now).visible
    }

    /// Live read: every changed setting, split into visible (re-grade) and minor (ignored).
    static func analyze(sent: String, now: String) -> (visible: [String], minor: [String]) {
        compare(fields(sent), fields(now), thresholds: tolerance, ignored: ignoredText)
    }

    /// Settings file: same idea for .cos entries ("path|Key=Value", structure "<Name attrs>@path").
    /// Any structural change (a layer, mask or section added/removed) is visible.
    static func analyzeDisk(sent: [String], now: [String]) -> (visible: [String], minor: [String]) {
        func split(_ list: [String]) -> (values: [String: String], structure: Set<String>) {
            var values: [String: String] = [:], structure = Set<String>()
            for e in list {
                if e.hasPrefix("<") { structure.insert(e); continue }
                guard let bar = e.firstIndex(of: "|") else { continue }
                let rest = e[e.index(after: bar)...]
                guard let eq = rest.firstIndex(of: "=") else { continue }
                let path = String(e[..<bar]), key = String(rest[..<eq])
                values[path.isEmpty ? key : "\(path)/\(key)"] = String(rest[rest.index(after: eq)...])
            }
            return (values, structure)
        }
        let a = split(sent), b = split(now)
        // thresholds are by .cos key name (last path component)
        var byFullKey: [String: Double] = [:]
        for k in Set(a.values.keys).union(b.values.keys) {
            let name = String(k.split(separator: "/").last ?? Substring(k))
            if let t = diskTolerance[name] { byFullKey[k] = t }
        }
        var result = compare(a.values, b.values, thresholds: byFullKey, ignored: [])
        for added in b.structure.subtracting(a.structure).sorted() { result.visible.append("+" + short(added)) }
        for removed in a.structure.subtracting(b.structure).sorted() { result.visible.append("-" + short(removed)) }
        return result
    }

    private static func compare(_ a: [String: String], _ b: [String: String],
                                thresholds: [String: Double], ignored: Set<String>)
        -> (visible: [String], minor: [String]) {
        var visible: [String] = [], minor: [String] = []
        for key in Set(a.keys).union(b.keys).sorted() {
            let x = a[key] ?? "", y = b[key] ?? ""
            if x == y { continue }
            let line = "\(key) \(short(x))→\(short(y))"
            let nx = numbers(x), ny = numbers(y)
            if !nx.isEmpty || !ny.isEmpty {
                // Numeric (or a list of numbers, e.g. a crop rectangle or curve): compare each number
                guard nx.count == ny.count else { visible.append(line); continue }
                let biggest = zip(nx, ny).map { p, q in
                    abs(p - q) / (thresholds[key] ?? defaultTolerance(key: key, p, q))
                }.max() ?? 0
                if biggest >= 1 - 1e-9 { visible.append(line) } else { minor.append(line) }
            } else if ignored.contains(key) {
                minor.append(line)
            } else {
                visible.append(line)                       // text setting (e.g. a profile name)
            }
        }
        return (visible, minor)
    }

    /// Splits Capture One's readable adjustments "{key=value,…}#crop" into fields.
    static func fields(_ text: String) -> [String: String] {
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

    /// Every number in a value: "-0.46" -> [-0.46]; "{0, 0, 6000, 4000}" -> [0, 0, 6000, 4000].
    /// A value with letters in it (e.g. "Daylight", "msng") has no numbers.
    static func numbers(_ value: String) -> [Double] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && $0 != "e" && $0 != "E" }) { return [] }
        var out: [Double] = []
        var token = ""
        for ch in trimmed {
            if ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" { token.append(ch) }
            else { if let d = Double(token) { out.append(d) }; token = "" }
        }
        if let d = Double(token) { out.append(d) }
        return out
    }

    private static func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(40)) + "…" : s }
}

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
    /// Per-setting tolerance, keyed by Capture One's 4-letter AppleScript code.
    /// Anything not listed uses `defaultTolerance`. Tune here after a real shoot.
    static let tolerance: [String: Double] = [
        "CVex": 0.05,      // exposure, stops
        "CVwk": 50,        // white balance, kelvin
        "CVwt": 1.0,       // white balance tint
    ]
    /// Text settings whose change alone doesn't alter the picture
    /// (e.g. the white balance mode name; the kelvin/tint numbers carry the real change).
    static let ignoredText: Set<String> = ["CVwb"]

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
        let a = fields(sent), b = fields(now)
        var out: [String] = []
        for key in Set(a.keys).union(b.keys).sorted() {
            let x = a[key] ?? "", y = b[key] ?? ""
            if x == y { continue }
            let nx = numbers(x), ny = numbers(y)
            if !nx.isEmpty || !ny.isEmpty {
                // Numeric (or a list of numbers, e.g. a crop rectangle): compare each number
                guard nx.count == ny.count else { out.append("\(key) \(x)→\(y)"); continue }
                let changed = zip(nx, ny).contains { p, q in
                    abs(p - q) > (tolerance[key] ?? defaultTolerance(key: key, p, q))
                }
                if changed { out.append("\(key) \(short(x))→\(short(y))") }
            } else if !ignoredText.contains(key) {
                out.append("\(key) \(short(x))→\(short(y))")     // text setting (e.g. a curve or profile name)
            }
        }
        return out
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

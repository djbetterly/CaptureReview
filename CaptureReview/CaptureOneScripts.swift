// CaptureOneScripts.swift – Capture Review
// Every AppleScript that talks to Capture One lives here.
// Scripts read each folder's collection directly, so the Capture One browser never changes.
// They use bulk property reads ("id of every variant") and text lookups instead of
// per-image Apple Events, which keeps large folders fast.
//
// v2 (large-session update):
//   - inventory re-reads the id list at the end; if Capture One was importing while we read,
//     that folder is reported as "unstable" and skipped instead of mixing up images
//   - inventory can skip adjustments (the slow part) – used when new frames land
//   - liveFingerprints reads adjustments for just the variants that need them
//   - selection reads only the variants selected in Capture One (re-grade check)
// v3: every read also returns rating + color tag (cheap), and applyMarks sets both

import Foundation
import AppKit
import CryptoKit

/// One Capture One variant, as reported by the inventory script.
nonisolated struct C1Variant: Sendable, Hashable {
    let id: String          // Capture One's variant id
    let position: Int       // 1, 2, 3… (matches the Variant Position naming token)
    let rawPath: String     // full POSIX path of the RAW file
    let live: String        // fingerprint of Capture One's in-memory adjustments + crop ("" = not read)
    let rating: Int?        // 0…5 (nil = not read)
    let colorTag: Int?      // 0 none, 1 red, 2 orange, 3 yellow, 4 green, 5 blue, 6 pink, 7 purple
    let liveText: String    // the readable adjustments + crop behind `live` (diagnostics: what changed)

    init(id: String, position: Int, rawPath: String, live: String,
         rating: Int? = nil, colorTag: Int? = nil, liveText: String = "") {
        self.id = id; self.position = position; self.rawPath = rawPath
        self.live = live; self.rating = rating; self.colorTag = colorTag; self.liveText = liveText
    }

    /// Fills in the live adjustments from their readable text.
    func withLive(text: String) -> C1Variant {
        C1Variant(id: id, position: position, rawPath: rawPath, live: CaptureOneScripts.fingerprint(text),
                  rating: rating, colorTag: colorTag, liveText: text)
    }
}

/// Rating + color tag for one variant, as Capture One stores them.
nonisolated struct C1Mark: Sendable, Hashable {
    var rating: Int          // 0…5
    var colorTag: Int        // 0 none, 1 red … 7 purple

    /// Gallery/database names for Capture One's color tag numbers.
    static let colorNames = ["", "red", "orange", "yellow", "green", "blue", "pink", "purple"]
    var colorName: String? { colorTag > 0 && colorTag < Self.colorNames.count ? Self.colorNames[colorTag] : nil }
    static func colorNumber(_ name: String?) -> Int { name.flatMap { colorNames.firstIndex(of: $0) } ?? 0 }
}

/// What an inventory found.
nonisolated struct C1Inventory: Sendable {
    var variants: [C1Variant] = []
    /// Collections that changed while being read (Capture One was importing). Their variants
    /// are left out so ids, files and adjustments never get paired up wrongly.
    var unstable: [String] = []
}

/// What the selection check found.
nonisolated struct C1Selection: Sendable {
    var variants: [C1Variant] = []
    var total = 0                // how many are selected (variants is empty when this is over the limit)
}

enum ScriptOutcome: Sendable {
    case success(String)
    case failure(String)
}

/// Runs off the main thread so the window never freezes while Capture One works.
/// All scripts go through ONE serial background queue: NSAppleScript isn't thread-safe,
/// and Capture One handles one request at a time anyway.
nonisolated enum CaptureOneScripts {
    private static let queue = DispatchQueue(label: "capture-review.applescript", qos: .userInitiated)

    /// Above this many selected variants, the selection check skips the live read
    /// (a select-all + style is caught by the settings-file check instead).
    static let selectionLimit = 60

    // MARK: - Inventory

    /// Lists every variant in the named collections with its id, position and RAW path.
    /// `withAdjustments`: also read the LIVE adjustments + crop (slow on big folders, about
    /// 13 ms per variant). Without it, `live` is "" and the planner asks for just the ones it needs.
    /// Each collection's id list is read again at the end; if it changed (an import landed
    /// mid-read), that collection is reported in `unstable` and its variants are left out.
    static func inventory(collectionNames: [String], withAdjustments: Bool) async -> Result<C1Inventory, ScriptFailure> {
        let adjustmentLines = withAdjustments ? """
                            set cvAdj to get properties of adjustments of every variant of cvCol
                            set cvCrop to get crop of every variant of cvCol
        """ : """
                            set cvAdj to {}
                            set cvCrop to {}
        """
        let source = """
        set cvNames to {\(list(collectionNames))}
        set cvOut to {}
        tell application "Capture One"
            tell current document
                set cvCols to get collections
                repeat with c from 1 to count of cvCols
                    set cvCol to item c of cvCols
                    if cvNames contains (name of cvCol) then
                        try
                            set cvIds to get id of every variant of cvCol
                            set cvPos to get position of every variant of cvCol
                            set cvFiles to get file of every variant of cvCol
        \(adjustmentLines)
                            set cvRate to get rating of every variant of cvCol
                            set cvTag to get color tag of every variant of cvCol
                            set cvIdsAfter to get id of every variant of cvCol
                            set cvPaths to {}
                            repeat with k from 1 to count of cvFiles
                                set end of cvPaths to POSIX path of (item k of cvFiles)
                            end repeat
                            set end of cvOut to {name of cvCol, cvIds, cvPos, cvPaths, cvAdj, cvCrop, cvRate, cvTag, cvIdsAfter}
                        end try
                    end if
                end repeat
            end tell
        end tell
        return cvOut
        """
        return await runParsed(source) { result in
            var seen = Set<String>()
            var inventory = C1Inventory()
            for c in items(result) {                         // one entry per matching collection
                let parts = items(c)
                guard parts.count == 9 else { continue }
                let name = flatten(parts[0])
                let ids = items(parts[1]), pos = items(parts[2]), paths = items(parts[3])
                let adj = items(parts[4]), crop = items(parts[5])
                let rate = items(parts[6]), tag = items(parts[7])

                // Changed while we read it, or lists of different lengths: don't trust any of it
                let stable = flatten(parts[1]) == flatten(parts[8])
                    && ids.count == pos.count && ids.count == paths.count
                    && ids.count == rate.count && ids.count == tag.count
                    && (!withAdjustments || (adj.count == ids.count && crop.count == ids.count))
                guard stable else {
                    if !inventory.unstable.contains(name) { inventory.unstable.append(name) }
                    continue
                }

                for k in ids.indices {
                    let id = flatten(ids[k])
                    guard seen.insert(id).inserted, let p = Int(flatten(pos[k])) else { continue }
                    let text = withAdjustments ? flatten(adj[k]) + "#" + flatten(crop[k]) : ""
                    inventory.variants.append(C1Variant(id: id, position: p, rawPath: flatten(paths[k]),
                                                        live: withAdjustments ? fingerprint(text) : "",
                                                        rating: Int(flatten(rate[k])) ?? 0,
                                                        colorTag: Int(flatten(tag[k])) ?? 0,
                                                        liveText: text))
                }
            }
            return inventory
        }
    }

    // MARK: - Live fingerprints for a few variants

    /// Reads the live adjustments + crop of just these variant ids. Returns id -> readable text
    /// (hash it with sha256 for the fingerprint; C1Variant.withLive(text:) does both).
    /// Each result is keyed by the id read from the same object as its adjustments,
    /// so a list that shifts mid-read can't pair one image's grade with another's id
    /// (an id that can't be read this time is simply missing; the caller tries again).
    static func liveFingerprints(variantIDs: [String], collectionNames: [String]) async -> [String: String] {
        guard !variantIDs.isEmpty else { return [:] }
        let source = """
        set cvTargets to "\(lookup(variantIDs))"
        set cvNames to {\(list(collectionNames))}
        set cvDone to ","
        set cvOut to {}
        tell application "Capture One"
            tell current document
                set cvCols to get collections
                repeat with c from 1 to count of cvCols
                    set cvCol to item c of cvCols
                    if cvNames contains (name of cvCol) then
                        set vs to {}
                        set cvIds to {}
                        try
                            set vs to get variants of cvCol
                            set cvIds to get id of every variant of cvCol
                        end try
                        repeat with k from 1 to count of cvIds
                            if k > (count of vs) then exit repeat
                            set cvKey to "," & ((item k of cvIds) as text) & ","
                            if (cvTargets contains cvKey) and (cvDone does not contain cvKey) then
                                try
                                    set cvV to item k of vs
                                    set cvId to (id of cvV) as text
                                    set end of cvOut to {cvId, properties of adjustments of cvV, crop of cvV}
                                    set cvDone to cvDone & cvId & ","
                                end try
                            end if
                        end repeat
                    end if
                end repeat
            end tell
        end tell
        return cvOut
        """
        let result = await runParsed(source) { result -> [String: String] in
            var out: [String: String] = [:]
            for entry in items(result) {
                let parts = items(entry)
                guard parts.count == 3 else { continue }
                out[flatten(parts[0])] = flatten(parts[1]) + "#" + flatten(parts[2])
            }
            return out
        }
        if case .success(let map) = result { return map }
        return [:]
    }

    // MARK: - Selection

    /// The variants currently selected in Capture One, with live fingerprints.
    /// Cheap (a few Apple Events per selected image), so it can run every few seconds.
    /// The fingerprint is built exactly like the inventory's, so the two always agree.
    static func selection() async -> Result<C1Selection, ScriptFailure> {
        let source = """
        set cvOut to {}
        tell application "Capture One"
            tell current document
                -- Capture One raises an error instead of returning an empty list when nothing is
                -- selected (e.g. an empty collection): that's just "no selection"
                set cvSel to {}
                try
                    set cvSel to selected variants
                end try
                set cvCount to count of cvSel
                if cvCount > \(selectionLimit) then return {cvCount, {}}
                repeat with k from 1 to cvCount
                    try
                        set cvV to item k of cvSel
                        set cvPath to POSIX path of (file of cvV)
                        set end of cvOut to {id of cvV, position of cvV, cvPath, properties of adjustments of cvV, crop of cvV, rating of cvV, color tag of cvV}
                    end try
                end repeat
            end tell
        end tell
        return {cvCount, cvOut}
        """
        return await runParsed(source) { result in
            var selection = C1Selection()
            let top = items(result)
            guard top.count == 2 else { return selection }
            selection.total = Int(flatten(top[0])) ?? 0
            for entry in items(top[1]) {
                let parts = items(entry)
                guard parts.count == 7, let p = Int(flatten(parts[1])) else { continue }
                let text = flatten(parts[3]) + "#" + flatten(parts[4])
                selection.variants.append(C1Variant(
                    id: flatten(parts[0]), position: p, rawPath: flatten(parts[2]),
                    live: fingerprint(text),
                    rating: Int(flatten(parts[5])) ?? 0, colorTag: Int(flatten(parts[6])) ?? 0,
                    liveText: text))
            }
            return selection
        }
    }

    // MARK: - Process

    /// Renders the given variant ids with the Proof recipe in ONE process command.
    static func process(variantIDs: [String], collectionNames: [String], recipe: String = "Proof") async -> ScriptOutcome {
        let source = """
        set cvTargets to "\(lookup(variantIDs))"
        set cvNames to {\(list(collectionNames))}
        set cvDone to ","
        set cvBatch to {}
        tell application "Capture One"
            tell current document
                set cvCols to get collections
                repeat with c from 1 to count of cvCols
                    set cvCol to item c of cvCols
                    if cvNames contains (name of cvCol) then
                        set vs to {}
                        set cvIds to {}
                        try
                            set vs to get variants of cvCol
                            set cvIds to get id of every variant of cvCol
                        end try
                        repeat with k from 1 to count of cvIds
                            if k > (count of vs) then exit repeat
                            set cvKey to "," & ((item k of cvIds) as text) & ","
                            if (cvTargets contains cvKey) and (cvDone does not contain cvKey) then
                                set end of cvBatch to item k of vs
                                set cvDone to cvDone & ((item k of cvIds) as text) & ","
                            end if
                        end repeat
                    end if
                end repeat
                if (count of cvBatch) > 0 then process cvBatch recipe \(quote(recipe))
            end tell
        end tell
        return (count of cvBatch) as text
        """
        return await run(source)
    }

    // MARK: - Ratings + color tags

    /// Sets rating and color tag by variant id.
    static func applyMarks(_ marks: [String: C1Mark], collectionNames: [String]) async -> ScriptOutcome {
        let ids = marks.keys.sorted()
        let source = """
        set cvTargets to "\(lookup(ids))"
        set cvIdList to {\(list(ids))}
        set cvRatings to {\(ids.map { String(marks[$0]?.rating ?? 0) }.joined(separator: ", "))}
        set cvTags to {\(ids.map { String(marks[$0]?.colorTag ?? 0) }.joined(separator: ", "))}
        set cvNames to {\(list(collectionNames))}
        set cvDone to ","
        set cvCount to 0
        tell application "Capture One"
            tell current document
                set cvCols to get collections
                repeat with c from 1 to count of cvCols
                    set cvCol to item c of cvCols
                    if cvNames contains (name of cvCol) then
                        set vs to {}
                        set cvIds to {}
                        try
                            set vs to get variants of cvCol
                            set cvIds to get id of every variant of cvCol
                        end try
                        repeat with k from 1 to count of cvIds
                            if k > (count of vs) then exit repeat
                            set cvId to (item k of cvIds) as text
                            set cvKey to "," & cvId & ","
                            if (cvTargets contains cvKey) and (cvDone does not contain cvKey) then
                                repeat with r from 1 to count of cvIdList
                                    if (item r of cvIdList) is cvId then
                                        set rating of (item k of vs) to (item r of cvRatings)
                                        set color tag of (item k of vs) to (item r of cvTags)
                                        exit repeat
                                    end if
                                end repeat
                                set cvDone to cvDone & cvId & ","
                                set cvCount to cvCount + 1
                            end if
                        end repeat
                    end if
                end repeat
            end tell
        end tell
        return cvCount as text
        """
        return await run(source)
    }

    // MARK: - Helpers

    struct ScriptFailure: Error, Sendable { let message: String }

    /// Runs a script and parses its raw result on the AppleScript queue (descriptors aren't Sendable).
    static func runParsed<T: Sendable>(_ source: String,
                                       parse: @escaping @Sendable (NSAppleEventDescriptor) -> T) async -> Result<T, ScriptFailure> {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    continuation.resume(returning: .failure(ScriptFailure(message: "\(error[NSAppleScript.errorMessage] ?? error)")))
                } else if let result {
                    continuation.resume(returning: .success(parse(result)))
                } else {
                    continuation.resume(returning: .failure(ScriptFailure(message: "No result")))
                }
            }
        }
    }

    /// Items of an AppleScript list (empty for anything else).
    static func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard d.descriptorType == typeAEList, d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    /// Turns any AppleScript value into stable text: records sorted by key, lists in order.
    /// References to other objects (curves, color editor) are skipped: they only name the
    /// object, not its contents.
    static func flatten(_ d: NSAppleEventDescriptor) -> String {
        // Records that carry a class (e.g. Capture One's adjustments record) have their own
        // descriptor type, not typeAERecord. Read them field by field like any record; before this
        // they were hashed as raw bytes, which include internal sizes and object references that
        // Capture One changes on its own after import (false "re-graded" flags).
        if d.descriptorType != typeAERecord, d.descriptorType != typeAEList, d.isRecordDescriptor {
            return flattenRecord(d)
        }
        switch d.descriptorType {
        case typeAEList:
            return "[" + items(d).map(flatten).joined(separator: ",") + "]"
        case typeAERecord:
            return flattenRecord(d)
        case typeObjectSpecifier:
            return "obj"
        case typeEnumerated, typeType:
            return fourCC(d.enumCodeValue != 0 ? d.enumCodeValue : d.typeCodeValue)
        default:
            return d.stringValue ?? d.data.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Record fields sorted by key. References to other objects are skipped (they name an
    /// object, not its contents, and can change without any edit).
    static func flattenRecord(_ d: NSAppleEventDescriptor) -> String {
        guard d.numberOfItems > 0 else { return "{}" }
        var pairs: [String] = []
        for i in 1...d.numberOfItems {
            guard let value = d.atIndex(i) else { continue }
            if value.descriptorType == typeObjectSpecifier { continue }
            pairs.append(fourCC(d.keywordForDescriptor(at: i)) + "=" + flatten(value))
        }
        return "{" + pairs.sorted().joined(separator: ",") + "}"
    }

    /// Version tag on every live fingerprint. Bumped whenever the way adjustments are read
    /// changes, so old fingerprints are re-recorded quietly instead of looking like re-grades.
    static let liveVersion = "l2-"
    static func fingerprint(_ text: String) -> String { liveVersion + sha256(text) }

    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a script on the AppleScript queue and resumes the caller when it finishes.
    static func run(_ source: String) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: runNow(source)) }
        }
    }

    private static func runNow(_ source: String) -> ScriptOutcome {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return .failure("\(error[NSAppleScript.errorMessage] ?? error)")
        }
        return .success(result?.stringValue ?? "")
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript list literal of quoted strings.
    static func list(_ items: [String]) -> String {
        items.map(quote).joined(separator: ", ")
    }

    /// ",id1,id2,id3," – fast membership test with `contains` in AppleScript.
    static func lookup(_ ids: [String]) -> String {
        "," + ids.joined(separator: ",") + ","
    }
}

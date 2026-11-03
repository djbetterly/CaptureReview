// RegradeRulesView.swift – Capture Review
// Settings > Re-grade rules: which adjustments count as a re-grade and how big a change must be.
// Proofs are small previews for picking selects; clients get the real files later, so only
// changes that are visible on a proof need to go out again.

import SwiftUI

struct RegradeRulesView: View {
    private struct Row: Identifiable, Equatable {
        let id: String            // rule key: "live:CVex" / "file:Exposure"
        let name: String
        let code: String
        let lastValue: String
        let defaultText: String
        var alsoFile: [String] = []   // settings-file keys this live adjustment also controls
        var counts: Bool
        var threshold: String     // "" = built-in
    }

    @State private var live: [Row] = []
    @State private var file: [Row] = []
    @State private var structureCounts = RegradeRules.shared.structureCounts
    @State private var search = ""
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Re-grade rules").font(.headline)
            Text("A frame counts as re-graded when a ticked setting changes by at least its threshold, compared with what the client's proof was made from. Untick anything that doesn't matter on a proof. A blank threshold uses the built-in default.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Toggle("Layers and masks added or removed count", isOn: $structureCounts)
                    .toggleStyle(.checkbox)
                    .onChange(of: structureCounts) { _, v in RegradeRules.shared.structureCounts = v }
            }
            List {
                ForEach(filtered(live + file)) { row in rowView(row) }
                if live.isEmpty && file.isEmpty {
                    Text("Nothing to show yet: open a session, then press Refresh.").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Reset to Defaults…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset every re-grade rule to the built-in defaults?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { RegradeRules.shared.resetAll(); load() }
                    }
                Spacer()
                Text("\(live.count + file.count) settings seen").font(.caption).foregroundStyle(.secondary)
                Button("Refresh") { load() }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { load() }
    }

    private func filtered(_ rows: [Row]) -> [Row] {
        let rows = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search) }
    }

    private func rowView(_ row: Row) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { current(row).counts },
                                 set: { v in edit(row.id) { $0.counts = v } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    Text((row.code == "settings file" ? "read from the settings file" : "live · \(row.code)")
                         + (row.alsoFile.isEmpty ? "" : " + settings file")
                         + (row.lastValue.isEmpty ? "" : " · now \(row.lastValue)"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            TextField(row.defaultText, text: Binding(get: { current(row).threshold },
                                                     set: { v in edit(row.id) { $0.threshold = v } }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .disabled(!current(row).counts)
                .help("Smallest change that counts. Blank = built-in (\(row.defaultText)).")
        }
    }

    // MARK: - Data

    private func current(_ row: Row) -> Row {
        (live.first { $0.id == row.id }) ?? (file.first { $0.id == row.id }) ?? row
    }

    private func edit(_ id: String, _ change: (inout Row) -> Void) {
        if let i = live.firstIndex(where: { $0.id == id }) { change(&live[i]); save(live[i]) }
        else if let i = file.firstIndex(where: { $0.id == id }) { change(&file[i]); save(file[i]) }
    }

    private func save(_ row: Row) {
        let t = Double(row.threshold.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        RegradeRules.shared.set(row.id, RegradeRule(counts: row.counts, threshold: t))
    }

    private func load() {
        let names = CaptureOneDictionary.adjustmentNames()
        let seen = RegradeRules.shared.seenKeys()
        var l: [Row] = [], f: [Row] = []
        // Every adjustment Capture One's dictionary defines is listed, seen or not
        var all = seen
        for code in names.keys where all["live:" + code] == nil { all["live:" + code] = "" }
        for (key, value) in all {
            let rule = RegradeRules.shared.rule(key) ?? RegradeRule()
            let threshold = rule.threshold.map { String($0) } ?? ""
            if key.hasPrefix("live:") {
                let code = String(key.dropFirst(5))
                let name = code == "crop" ? "crop" : (names[code] ?? code)
                l.append(Row(id: key, name: name, code: code, lastValue: value,
                             defaultText: VisualChange.tolerance[code].map { String($0) } ?? "auto",
                             counts: rule.counts, threshold: threshold))
            } else if key.hasPrefix("file:") {
                let k = String(key.dropFirst(5))
                f.append(Row(id: key, name: k, code: "settings file", lastValue: value,
                             defaultText: VisualChange.diskTolerance[k].map { String($0) } ?? "auto",
                             counts: rule.counts, threshold: threshold))
            }
        }
        // Settings-file keys that are the same setting as a live adjustment: shown on that row, not twice
        var linked: [String: [String]] = [:]
        f = f.filter { row in
            guard let code = RegradeRules.shared.linkedLiveCode(forFileKey: row.name) else { return true }
            linked["live:" + code, default: []].append(row.name)
            return false
        }
        for i in l.indices { l[i].alsoFile = (linked[l[i].id] ?? []).sorted() }
        live = l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        file = f.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        structureCounts = RegradeRules.shared.structureCounts
    }
}


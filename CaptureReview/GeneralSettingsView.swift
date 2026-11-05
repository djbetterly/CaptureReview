// GeneralSettingsView.swift – Capture Review
// Settings > General.

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("newFoldersHidden") private var newFoldersHidden = false
    @AppStorage("autoRegrades") private var autoRegrades = true

    var body: some View {
        Form {
            Picker("New folders", selection: $newFoldersHidden) {
                Text("Published: the client sees frames as they upload").tag(false)
                Text("Hidden: upload in the background, publish when ready").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text("Applies to folders that have nothing uploaded yet. Change any folder later with its ⋮ menu: Publish to Client or Unpublish. Hidden folders keep uploading and syncing; ratings are kept.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)
            Toggle("Auto-upload re-grades", isOn: $autoRegrades)
            Text("With auto-upload on, frames re-graded in Capture One are re-sent once the grade has stopped changing for 5 s. Only changes that pass the Re-grade Rules count. Off: re-grades wait for the Upload Re-grades button.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 560)
    }
}

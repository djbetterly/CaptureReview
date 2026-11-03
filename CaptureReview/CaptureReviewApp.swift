//
//  CaptureReviewApp.swift
//  CaptureReview
//
//  Created by DUSTIN BETTERLY on 10/30/26.
//

import SwiftUI

@main
struct CaptureReviewApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Capture Review > Settings… (⌘,)
        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                RegradeRulesView()
                    .tabItem { Label("Re-grade Rules", systemImage: "slider.horizontal.3") }
            }
        }
    }
}

//
//  LyricDriveApp.swift
//  LyricDrive
//
//  Created by Andres on 9/22/26.
//

import SwiftUI

@main
struct LyricDriveApp: App {
    @StateObject private var spotifyManager: SpotifyManager
    @StateObject private var lyricsManager: LyricsManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let spotifyManager = SpotifyManager()
        _spotifyManager = StateObject(wrappedValue: spotifyManager)
        _lyricsManager = StateObject(wrappedValue: LyricsManager(spotifyManager: spotifyManager))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(spotifyManager)
                .environmentObject(lyricsManager)
                .onOpenURL { url in
                    spotifyManager.handleAuthorizationCallback(url: url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                spotifyManager.appDidBecomeActive()
            case .inactive, .background:
                spotifyManager.appWillResignActive()
            @unknown default:
                break
            }
        }
    }
}

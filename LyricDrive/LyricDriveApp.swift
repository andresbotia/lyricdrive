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
        // Both managers come from the shared container so the CarPlay scene observes the exact
        // same instances (one App Remote connection, one playback clock, one lyrics pipeline).
        _spotifyManager = StateObject(wrappedValue: AppServices.shared.spotifyManager)
        _lyricsManager = StateObject(wrappedValue: AppServices.shared.lyricsManager)
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
                // While CarPlay is connected it still needs App Remote, so the phone scene
                // leaving the foreground must not disconnect it. CarPlaySceneDelegate applies
                // this same disconnect later if CarPlay goes away while the phone is backgrounded.
                if !AppServices.shared.isCarPlayConnected {
                    spotifyManager.appWillResignActive()
                }
            @unknown default:
                break
            }
        }
    }
}

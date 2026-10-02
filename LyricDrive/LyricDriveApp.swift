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
    @StateObject private var appleMusicManager: AppleMusicManager
    @StateObject private var nowPlaying: NowPlayingStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Both managers come from the shared container so the CarPlay scene observes the exact
        // same instances (one App Remote connection, one playback clock, one lyrics pipeline).
        _spotifyManager = StateObject(wrappedValue: AppServices.shared.spotifyManager)
        _lyricsManager = StateObject(wrappedValue: AppServices.shared.lyricsManager)
        _appleMusicManager = StateObject(wrappedValue: AppServices.shared.appleMusicManager)
        _nowPlaying = StateObject(wrappedValue: AppServices.shared.nowPlaying)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(spotifyManager)
                .environmentObject(lyricsManager)
                .environmentObject(appleMusicManager)
                .environmentObject(nowPlaying)
                .onOpenURL { url in
                    spotifyManager.handleAuthorizationCallback(url: url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Spotify's saved session stays dormant while Apple Music is active.
                if nowPlaying.activeService == .spotify {
                    spotifyManager.appDidBecomeActive()
                }
                nowPlaying.appDidBecomeActive()
            case .inactive, .background:
                // While CarPlay is connected it still needs App Remote (Spotify) and the playback
                // clock (Apple Music), so the phone scene leaving the foreground must not stop
                // them. CarPlaySceneDelegate applies the same later if CarPlay goes away while
                // the phone is backgrounded.
                if !AppServices.shared.isCarPlayConnected {
                    spotifyManager.appWillResignActive()
                    nowPlaying.appWillResignActive()
                }
            @unknown default:
                break
            }
        }
    }
}

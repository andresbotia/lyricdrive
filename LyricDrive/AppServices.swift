//
//  AppServices.swift
//  LyricDrive
//

import Foundation

/// The single owner of LyricDrive's long-lived managers.
///
/// Both the SwiftUI phone scene and the CarPlay template scene need the *same* `SpotifyManager`
/// (one App Remote connection, one playback clock, one session) and the *same* `LyricsManager`.
/// Scenes are created and destroyed independently by UIKit, so neither can own these — hence a
/// single shared container.
///
/// Deliberately minimal: it holds exactly the two managers the CarPlay scene needs to share with
/// the phone scene, and nothing else in the app was converted to a singleton.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let spotifyManager: SpotifyManager
    let lyricsManager: LyricsManager
    let liveActivityManager: LiveActivityManager

    /// `true` while a CarPlay template scene is connected. Set only by `CarPlaySceneDelegate`;
    /// read by the phone scene's lifecycle handling so backgrounding the iPhone UI doesn't drop
    /// the App Remote connection the car is using.
    var isCarPlayConnected = false

    private init() {
        // Preserves the original initialization order from LyricDriveApp.init():
        // SpotifyManager first, then LyricsManager built on top of that same instance.
        let spotifyManager = SpotifyManager()
        self.spotifyManager = spotifyManager
        let lyricsManager = LyricsManager(spotifyManager: spotifyManager)
        self.lyricsManager = lyricsManager
        self.liveActivityManager = LiveActivityManager(spotify: spotifyManager, lyrics: lyricsManager)
    }
}

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
/// Deliberately minimal: it holds the managers the CarPlay scene and widget intents need to share
/// with the phone scene, and nothing else in the app was converted to a singleton.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let spotifyManager: SpotifyManager
    let appleMusicManager: AppleMusicManager
    /// The active music service and its normalized playback state; feeds `LyricsManager`.
    let nowPlaying: NowPlayingStore
    let lyricsManager: LyricsManager
    let liveActivityManager: LiveActivityManager
    /// Shares normalized now-playing state with LyricDrive's widgets.
    let widgetSnapshotPublisher: WidgetSnapshotPublisher

    /// `true` while a CarPlay template scene is connected. Set only by `CarPlaySceneDelegate`;
    /// read by the phone scene's lifecycle handling so backgrounding the iPhone UI doesn't drop
    /// the App Remote connection the car is using.
    var isCarPlayConnected = false

    private init() {
        // Preserves the original initialization order from LyricDriveApp.init():
        // SpotifyManager first, then LyricsManager built on top of the active provider's state.
        // A saved Spotify session stays saved while Apple Music is active, but must not connect.
        let spotifyManager = SpotifyManager(connectsOnLaunch: NowPlayingStore.storedActiveService == .spotify)
        self.spotifyManager = spotifyManager
        let appleMusicManager = AppleMusicManager()
        self.appleMusicManager = appleMusicManager
        let nowPlaying = NowPlayingStore(spotify: spotifyManager, appleMusic: appleMusicManager)
        self.nowPlaying = nowPlaying
        let lyricsManager = LyricsManager(nowPlaying: nowPlaying)
        self.lyricsManager = lyricsManager
        self.liveActivityManager = LiveActivityManager(spotify: spotifyManager, lyrics: lyricsManager, nowPlaying: nowPlaying)
        let widgetSnapshotPublisher = WidgetSnapshotPublisher(
            spotify: spotifyManager,
            appleMusic: appleMusicManager,
            nowPlaying: nowPlaying,
            lyrics: lyricsManager,
            isCarPlayConnected: { AppServices.shared.isCarPlayConnected }
        )
        self.widgetSnapshotPublisher = widgetSnapshotPublisher

        // Widget playback buttons, performed in this process. Routed through the active service
        // exactly like the iPhone and CarPlay controls; each is a no-op without a current song.
        WidgetPlaybackRouter.handler = { [weak nowPlaying, weak widgetSnapshotPublisher] command in
            guard let nowPlaying else { return }
            // The Music app may have changed songs while LyricDrive was suspended.
            nowPlaying.resyncActiveService()
            switch command {
            case .previous: nowPlaying.previousTrack()
            case .playPause: nowPlaying.togglePlayPause()
            case .next: nowPlaying.nextTrack()
            }
            // Give the service a moment to report its new state, so the widget reloads with it.
            try? await Task.sleep(for: .milliseconds(600))
            nowPlaying.resyncActiveService()
            widgetSnapshotPublisher?.writeNow()
        }
    }
}

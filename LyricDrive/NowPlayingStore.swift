//
//  NowPlayingStore.swift
//  LyricDrive
//

import Combine
import Foundation
import UIKit

/// A provider-neutral description of the current track. SwiftUI views and `LyricsManager` read
/// this instead of any SDK type. Artwork is published separately (`NowPlayingStore.artwork`)
/// because it usually arrives after the track itself.
struct NowPlayingTrack: Equatable, Identifiable {
    let provider: MusicService
    /// Stable per track and unique across providers (e.g. a Spotify URI, `applemusic:…`).
    let id: String
    let title: String
    let artist: String
    /// Empty when unknown.
    let album: String
    /// `0` when unknown.
    let durationMs: Int
}

/// Owns which music service is active and republishes that service's playback state in
/// normalized form. The provider managers keep owning their SDKs; this only forwards their
/// published state and routes playback controls, so exactly one provider feeds the UI and the
/// lyrics pipeline at a time.
@MainActor
final class NowPlayingStore: ObservableObject {
    @Published private(set) var activeService: MusicService
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPaused = true
    /// The active provider's locally-interpolated playback position.
    @Published private(set) var playbackPositionMs = 0

    private let spotify: SpotifyManager
    private let appleMusic: AppleMusicManager
    private var bindings = Set<AnyCancellable>()

    private static let activeServiceKey = "musicService.active"

    /// The persisted active service. Existing installs have no stored value and keep Spotify.
    nonisolated static var storedActiveService: MusicService {
        UserDefaults.standard.string(forKey: activeServiceKey).flatMap(MusicService.init(rawValue:)) ?? .spotify
    }

    init(spotify: SpotifyManager, appleMusic: AppleMusicManager) {
        self.spotify = spotify
        self.appleMusic = appleMusic
        activeService = Self.storedActiveService
        bind(to: activeService, replayCurrentState: true)
        if activeService == .appleMusic {
            appleMusic.start()
        }
    }

    // MARK: - Switching

    /// Requests Apple Music access if it hasn't been decided yet and, once authorized, makes
    /// Apple Music the active service. Returns the resulting authorization status.
    @discardableResult
    func activateAppleMusic() async -> AppleMusicManager.Authorization {
        let status = await appleMusic.requestAuthorizationIfNeeded()
        guard status == .authorized else { return status }
        if activeService == .appleMusic {
            appleMusic.start()
        } else {
            switchTo(.appleMusic)
        }
        return status
    }

    /// Makes Spotify the active service and starts its existing connect flow: with a saved
    /// session that's a silent connect (or renewal); otherwise Spotify authorization.
    func activateSpotify() {
        switchTo(.spotify)
        spotify.connect()
    }

    /// Stops following Apple Music. With a saved Spotify session this returns to Spotify;
    /// otherwise to service selection. iOS's Music permission itself can only be changed in the
    /// Settings app.
    func stopUsingAppleMusic() {
        if spotify.hasAuthorizedSession {
            activateSpotify()
        } else {
            switchTo(.spotify)
        }
    }

    private func switchTo(_ service: MusicService) {
        guard service != activeService else { return }

        // Release the previous provider so its state can't leak into the UI, the lyrics
        // pipeline, CarPlay, or the Live Activity (the latter two are Spotify-only and gated on
        // Spotify's connection). Switching only disconnects Spotify; its saved session is kept
        // for switching back. Forgetting it is the separate "Disconnect Spotify" action.
        switch activeService {
        case .spotify:
            spotify.disconnect()
        case .appleMusic:
            appleMusic.stop()
        }

        activeService = service
        UserDefaults.standard.set(service.rawValue, forKey: Self.activeServiceKey)
        bind(to: service, replayCurrentState: false)

        if service == .appleMusic {
            appleMusic.start()
        }
    }

    /// - Parameter replayCurrentState: `false` when switching providers. Spotify keeps its
    ///   last-known track fields after disconnecting, so after a switch only
    ///   fresh updates are forwarded — never a song from before the switch.
    private func bind(to service: MusicService, replayCurrentState: Bool) {
        bindings.removeAll()
        let skip = replayCurrentState ? 0 : 1
        track = nil
        artwork = nil
        isPaused = true
        playbackPositionMs = 0

        switch service {
        case .spotify:
            // SpotifyManager publishes every other field before `trackURI` (and `@Published`
            // emits in willSet), so its metadata is already current here.
            spotify.$trackURI
                .dropFirst(skip)
                .sink { [weak self, weak spotify] trackURI in
                    guard let self, let spotify else { return }
                    let track = trackURI.isEmpty ? nil : NowPlayingTrack(
                        provider: .spotify,
                        id: trackURI,
                        title: spotify.trackName,
                        artist: spotify.artistName,
                        album: spotify.albumName,
                        durationMs: spotify.durationMs
                    )
                    if track != self.track { self.track = track }
                    // After a switch the artwork replay was skipped; if Spotify resumes the same
                    // song it won't re-assign artwork, so pick up what it already has.
                    if track != nil, self.artwork == nil, let artwork = spotify.albumArtwork {
                        self.artwork = artwork
                    }
                }
                .store(in: &bindings)
            spotify.$albumArtwork.dropFirst(skip).sink { [weak self] in self?.artwork = $0 }.store(in: &bindings)
            spotify.$isPaused.dropFirst(skip).sink { [weak self] in self?.isPaused = $0 }.store(in: &bindings)
            spotify.$playbackPositionMs.dropFirst(skip).sink { [weak self] in self?.playbackPositionMs = $0 }.store(in: &bindings)

        case .appleMusic:
            appleMusic.$track.sink { [weak self] in self?.track = $0 }.store(in: &bindings)
            appleMusic.$artwork.sink { [weak self] in self?.artwork = $0 }.store(in: &bindings)
            appleMusic.$isPaused.sink { [weak self] in self?.isPaused = $0 }.store(in: &bindings)
            appleMusic.$playbackPositionMs.sink { [weak self] in self?.playbackPositionMs = $0 }.store(in: &bindings)
        }
    }

    // MARK: - Lifecycle

    /// Spotify's own foreground handling stays in `LyricDriveApp`; Apple Music resyncs here.
    /// While Spotify is active, Apple Music's authorization is still re-read so service
    /// selection reflects access the user may have just granted in the Settings app.
    func appDidBecomeActive() {
        switch activeService {
        case .spotify: appleMusic.refreshAuthorization()
        case .appleMusic: appleMusic.appDidBecomeActive()
        }
    }

    func appWillResignActive() {
        if activeService == .appleMusic { appleMusic.appWillResignActive() }
    }

    // MARK: - Playback controls

    func previousTrack() {
        switch activeService {
        case .spotify: spotify.previousTrack()
        case .appleMusic: appleMusic.previousTrack()
        }
    }

    func togglePlayPause() {
        switch activeService {
        case .spotify: spotify.togglePlayPause()
        case .appleMusic: appleMusic.togglePlayPause()
        }
    }

    func nextTrack() {
        switch activeService {
        case .spotify: spotify.nextTrack()
        case .appleMusic: appleMusic.nextTrack()
        }
    }
}

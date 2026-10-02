//
//  AppleMusicManager.swift
//  LyricDrive
//

import Combine
import Foundation
import MediaPlayer
import MusicKit
import UIKit
import os

/// Follows playback in the user's Music app.
///
/// Built on `MPMusicPlayerController.systemMusicPlayer`, which mirrors the Music app's own
/// player: its now-playing item (full `MPMediaItem` metadata, library and streamed catalog
/// tracks alike), playback state, playback time, change notifications, and transport controls.
/// LyricDrive never sets a queue or starts its own playback — `ApplicationMusicPlayer` is not
/// used. MusicKit provides authorization, account status, and a catalog fallback for artwork and
/// metadata that streamed items leave empty.
///
/// Playback position uses the same model as `SpotifyManager`: an authoritative anchor (the
/// player's reported time plus a monotonic timestamp) interpolated by a ~10Hz local clock while
/// playing, re-anchored on every state/item change and whenever a once-per-second check finds
/// drift (e.g. a seek made in the Music app, which posts no notification of its own).
@MainActor
final class AppleMusicManager: ObservableObject {

    enum Authorization: Equatable {
        case notDetermined, authorized, denied, restricted

        init(_ status: MusicAuthorization.Status) {
            switch status {
            case .authorized: self = .authorized
            case .denied: self = .denied
            case .restricted: self = .restricted
            case .notDetermined: self = .notDetermined
            @unknown default: self = .denied
            }
        }
    }

    @Published private(set) var authorization = Authorization(MusicAuthorization.currentStatus)
    @Published private(set) var isRequestingAuthorization = false
    /// Whether the account can stream the Apple Music catalog. `nil` until checked, or if the
    /// check failed. Library tracks play without a subscription, so this is informational only.
    @Published private(set) var canPlayCatalogContent: Bool?

    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPaused = true
    @Published private(set) var playbackPositionMs = 0

    /// Created on first use, so it's never touched before the user chooses Apple Music.
    private lazy var player = MPMusicPlayerController.systemMusicPlayer

    private var isObserving = false
    private var observers = Set<AnyCancellable>()
    private var clockTimer: Timer?
    private var ticksSinceDriftCheck = 0
    private var anchorPositionMs = 0
    private var anchorUptime = ProcessInfo.processInfo.systemUptime
    private var catalogTask: Task<Void, Never>?
    /// Catalog values for fields the current item left empty. Kept per track so later player
    /// notifications (which rebuild the track from the item) don't drop them again.
    private var catalogMetadata: CatalogMetadata?
    private var subscriptionTask: Task<Void, Never>?

    /// Re-anchor when the player's reported time differs from the interpolated one by more.
    private static let driftToleranceMs = 750
    private static let artworkSize = CGSize(width: 300, height: 300)

    // MARK: - Authorization

    /// Asks for access only when it hasn't been decided yet — never re-prompts after a denial.
    func requestAuthorizationIfNeeded() async -> Authorization {
        var status = Authorization(MusicAuthorization.currentStatus)
        if status == .notDetermined {
            isRequestingAuthorization = true
            status = Authorization(await MusicAuthorization.request())
            isRequestingAuthorization = false
        }
        authorization = status
        log("authorization status=\(status)")
        return status
    }

    /// Re-reads the current status without prompting, e.g. after the user returns from the
    /// Settings app having changed LyricDrive's Apple Music access.
    func refreshAuthorization() {
        let status = Authorization(MusicAuthorization.currentStatus)
        if status != authorization {
            authorization = status
            log("authorization refreshed: \(status)")
        }
    }

    // MARK: - Lifecycle

    /// Begins following the Music app. A no-op (other than clearing state) until authorized.
    func start() {
        authorization = Authorization(MusicAuthorization.currentStatus)
        guard authorization == .authorized else {
            log("start skipped: authorization=\(authorization)")
            stopObserving()
            clearPlayback()
            return
        }

        if !isObserving {
            isObserving = true
            player.beginGeneratingPlaybackNotifications()
            NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.log("now playing item changed")
                    self?.refreshNowPlaying()
                }
                .store(in: &observers)
            NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.log("playback state changed")
                    self?.refreshNowPlaying()
                }
                .store(in: &observers)
        }

        refreshSubscription()
        refreshNowPlaying()
    }

    /// Stops following the Music app and clears everything it published.
    func stop() {
        stopObserving()
        clearPlayback()
        subscriptionTask?.cancel()
        subscriptionTask = nil
        canPlayCatalogContent = nil
    }

    /// Resync after returning to the foreground — playback, skips, seeks, or a permission change
    /// may all have happened in the meantime.
    func appDidBecomeActive() {
        start()
    }

    /// The Music app keeps playing on its own; only the local clock stops while backgrounded.
    func appWillResignActive() {
        stopClock()
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        observers.removeAll()
        player.endGeneratingPlaybackNotifications()
        stopClock()
    }

    private func clearPlayback() {
        catalogTask?.cancel()
        catalogTask = nil
        catalogMetadata = nil
        stopClock()
        track = nil
        artwork = nil
        isPaused = true
        anchorPositionMs = 0
        playbackPositionMs = 0
    }

    private func refreshSubscription() {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            do {
                let subscription = try await MusicSubscription.current
                guard !Task.isCancelled else { return }
                self?.canPlayCatalogContent = subscription.canPlayCatalogContent
                self?.log("subscription canPlayCatalogContent=\(subscription.canPlayCatalogContent)")
            } catch {
                self?.canPlayCatalogContent = nil
                self?.log("subscription check failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Now playing

    private func refreshNowPlaying() {
        guard isObserving else { return }

        let item = player.nowPlayingItem
        let newTrack = item.map { catalogMetadata?.filling(Self.makeTrack(from: $0)) ?? Self.makeTrack(from: $0) }
        if newTrack != track {
            let trackChanged = newTrack?.id != track?.id
            track = newTrack
            if trackChanged {
                log("current item: \(newTrack.map { "\($0.title) — \($0.artist) [\($0.id)]" } ?? "none")")
                loadDetails(for: item, track: newTrack)
            }
        }

        let state = player.playbackState
        // Seeking and interruptions don't advance at normal speed; treat them as paused and let
        // the next state change re-anchor.
        isPaused = newTrack == nil || state != .playing
        reanchor(toSeconds: player.currentPlaybackTime)
        log("playback state=\(state.rawValue) position=\(anchorPositionMs)ms")

        if isPaused {
            stopClock()
        } else {
            startClock()
        }
    }

    private static func makeTrack(from item: MPMediaItem) -> NowPlayingTrack {
        let title = item.title ?? ""
        let artist = item.artist ?? item.albumArtist ?? ""
        if title.isEmpty || artist.isEmpty {
            logStatic("metadata incomplete: title=\(!title.isEmpty) artist=\(!artist.isEmpty)")
        }
        let duration = item.playbackDuration
        let storeID = item.playbackStoreID

        // Library items have a persistent ID; streamed catalog items may only have a store ID.
        let key: String
        if item.persistentID != 0 {
            key = "\(item.persistentID)"
        } else if !storeID.isEmpty, storeID != "0" {
            key = "store:\(storeID)"
        } else {
            key = "meta:\(title)|\(artist)"
        }

        return NowPlayingTrack(
            provider: .appleMusic,
            id: "applemusic:\(key)",
            title: title,
            artist: artist,
            album: item.albumTitle ?? "",
            durationMs: duration.isFinite && duration > 0 ? Int((duration * 1000).rounded()) : 0
        )
    }

    // MARK: - Artwork and catalog details

    /// Fields a streamed item may be missing, filled from the Apple Music catalog. Only fills
    /// gaps — never overrides what the Music app reported — and only for the track it was
    /// fetched for.
    private struct CatalogMetadata {
        let trackID: String
        let title: String
        let artist: String
        let album: String
        let durationMs: Int

        func filling(_ track: NowPlayingTrack) -> NowPlayingTrack {
            guard track.id == trackID else { return track }
            return NowPlayingTrack(
                provider: track.provider,
                id: track.id,
                title: track.title.isEmpty ? title : track.title,
                artist: track.artist.isEmpty ? artist : track.artist,
                album: track.album.isEmpty ? album : track.album,
                durationMs: track.durationMs > 0 ? track.durationMs : durationMs
            )
        }
    }

    private static func isIncomplete(_ track: NowPlayingTrack) -> Bool {
        track.title.isEmpty || track.artist.isEmpty || track.album.isEmpty || track.durationMs <= 0
    }

    /// Runs once per track change, never on clock ticks. Uses the item's own artwork; for
    /// streamed tracks missing artwork or metadata, one catalog lookup fills the gaps. Filled
    /// metadata republishes `track` (same `id`), which lets `LyricsManager` look up lyrics again
    /// once if the lookup fields changed.
    private func loadDetails(for item: MPMediaItem?, track: NowPlayingTrack?) {
        catalogTask?.cancel()
        catalogTask = nil
        catalogMetadata = nil
        artwork = nil
        guard let item, let track else { return }

        if let image = item.artwork?.image(at: Self.artworkSize) {
            artwork = image
        }
        let needsArtwork = artwork == nil
        let needsMetadata = Self.isIncomplete(track)
        guard needsArtwork || needsMetadata else { return }

        let storeID = item.playbackStoreID
        guard !storeID.isEmpty, storeID != "0" else {
            log("no catalog ID: artworkMissing=\(needsArtwork) metadataIncomplete=\(needsMetadata)")
            return
        }

        let trackID = track.id
        catalogTask = Task { [weak self] in
            do {
                var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(storeID))
                request.limit = 1
                let response = try await request.response()
                guard !Task.isCancelled, let self, self.track?.id == trackID, let song = response.items.first else {
                    self?.log("catalog details unavailable")
                    return
                }

                if needsMetadata {
                    self.applyCatalogMetadata(from: song, trackID: trackID)
                }

                guard needsArtwork,
                      let url = song.artwork?.url(width: Int(Self.artworkSize.width), height: Int(Self.artworkSize.height)),
                      url.scheme == "https" || url.scheme == "http" else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, self.track?.id == trackID, let image = UIImage(data: data) else { return }
                self.artwork = image
            } catch {
                self?.log("catalog lookup failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyCatalogMetadata(from song: Song, trackID: String) {
        guard let current = track, current.id == trackID else { return }
        let duration = song.duration ?? 0
        let metadata = CatalogMetadata(
            trackID: trackID,
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            durationMs: duration.isFinite && duration > 0 ? Int((duration * 1000).rounded()) : 0
        )
        catalogMetadata = metadata
        let enriched = metadata.filling(current)
        if enriched != current {
            log("catalog metadata filled: \(enriched.title) — \(enriched.artist) [\(trackID)]")
            track = enriched
        }
    }

    // MARK: - Playback clock

    private func reanchor(toSeconds seconds: TimeInterval) {
        anchorPositionMs = seconds.isFinite ? max(Int((seconds * 1000).rounded()), 0) : 0
        anchorUptime = ProcessInfo.processInfo.systemUptime
        ticksSinceDriftCheck = 0
        updateInterpolatedPosition()
    }

    private func updateInterpolatedPosition() {
        var positionMs = anchorPositionMs
        if !isPaused {
            positionMs += Int(((ProcessInfo.processInfo.systemUptime - anchorUptime) * 1000).rounded())
        }
        let durationMs = track?.durationMs ?? 0
        playbackPositionMs = durationMs > 0 ? min(max(positionMs, 0), durationMs) : max(positionMs, 0)
    }

    private func startClock() {
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func clockTick() {
        updateInterpolatedPosition()
        ticksSinceDriftCheck += 1
        guard ticksSinceDriftCheck >= 10 else { return }
        ticksSinceDriftCheck = 0

        // Catches seeks made in the Music app, which don't post a notification.
        let reported = player.currentPlaybackTime
        guard reported.isFinite else { return }
        let reportedMs = Int((reported * 1000).rounded())
        if abs(reportedMs - playbackPositionMs) > Self.driftToleranceMs {
            log("position anchor refresh: drift=\(reportedMs - playbackPositionMs)ms")
            reanchor(toSeconds: reported)
        }
    }

    // MARK: - Playback controls

    /// Each control is a safe no-op without access or a current item; the resulting state comes
    /// back through the player's notifications.
    func togglePlayPause() {
        guard isObserving, track != nil else { return }
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func nextTrack() {
        guard isObserving, track != nil else { return }
        player.skipToNextItem()
    }

    /// Like the Music app: restarts the song if more than 3s in, otherwise goes back one.
    func previousTrack() {
        guard isObserving, track != nil else { return }
        if player.currentPlaybackTime > 3 {
            player.skipToBeginning()
            reanchor(toSeconds: 0)
        } else {
            player.skipToPreviousItem()
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        Self.logStatic(message)
    }

    private static func logStatic(_ message: String) {
        #if DEBUG
        Logger(subsystem: "com.andresbotia.LyricDrive", category: "AppleMusic").debug("\(message, privacy: .public)")
        #endif
    }
}

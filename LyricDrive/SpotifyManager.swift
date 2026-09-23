//
//  SpotifyManager.swift
//  LyricDrive
//

import Combine
import Darwin
import Foundation
import SpotifyiOS
import UIKit

final class SpotifyManager: NSObject, ObservableObject {

    static let clientID = "1294b9c52c284018bed1a49c50d84998"
    static let redirectURL = URL(string: "lyricdrive-login://callback")!

    @Published private(set) var isConnected = false
    @Published private(set) var trackName = ""
    @Published private(set) var artistName = ""
    @Published private(set) var albumName = ""
    @Published private(set) var durationMs = 0
    @Published private(set) var isPaused = true
    @Published private(set) var trackURI = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var albumArtwork: UIImage?

    /// The continuously-advancing, locally-interpolated playback position. This is what UI (and,
    /// later, lyric-line selection) should read. It is derived from the authoritative anchor below
    /// on every clock tick, never advanced by blindly adding a fixed step per timer fire.
    @Published private(set) var playbackPositionMs = 0

    /// The last playback position Spotify itself reported, i.e. the authoritative anchor.
    private var authoritativePositionMs: Int = 0

    /// The monotonic local time (`ProcessInfo.processInfo.systemUptime`) at which
    /// `authoritativePositionMs` was captured. Monotonic, not wall-clock, so system clock changes
    /// (DST, NTP sync, user changing the time) can't corrupt synchronization.
    private var authoritativeTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// The most recently obtained access token. Kept separately from
    /// `appRemote.connectionParameters` so lifecycle callbacks can check "do we have a
    /// token at all" without depending on App Remote's own connection object.
    private var accessToken: String?

    /// Guards against firing a second `appRemote.connect()` while one is already in flight.
    private var isConnecting = false

    /// Ensures the local-transport-not-ready retry only ever fires once per connection attempt.
    private var hasRetriedConnection = false

    /// Drives the ~10Hz local playback clock. Only runs while App Remote is connected.
    private var playbackClockTimer: Timer?

    private lazy var configuration: SPTConfiguration = {
        let configuration = SPTConfiguration(clientID: Self.clientID, redirectURL: Self.redirectURL)
        // Spotify's official sample requires a non-nil (can be blank) playURI: without it, the
        // Spotify app won't resume playback after authorization and App Remote's local transport
        // never comes up, which surfaces as "Connection refused" on ::1:9095.
        configuration.playURI = ""
        return configuration
    }()

    /// Drives authorization via the Spotify app (or web fallback), free of the deprecated
    /// `UIApplication.openURL(_:)` path that `SPTAppRemote.authorizeAndPlayURI` used internally.
    private lazy var sessionManager: SPTSessionManager = {
        SPTSessionManager(configuration: configuration, delegate: self)
    }()

    private lazy var appRemote: SPTAppRemote = {
        let appRemote = SPTAppRemote(configuration: configuration, logLevel: .debug)
        appRemote.delegate = self
        return appRemote
    }()

    /// Kicks off authorization (if needed) and connects App Remote once a token is available.
    func connect() {
        errorMessage = nil

        if accessToken != nil {
            connectAppRemote()
        } else {
            // Minimum scope required for App Remote playback control.
            sessionManager.initiateSession(with: [.appRemoteControl], options: .default)
        }
    }

    func disconnect() {
        appRemote.disconnect()
        handleDisconnected()
    }

    /// Called from the app's `.onOpenURL` handler with the `lyricdrive-login://callback` redirect.
    func handleAuthorizationCallback(url: URL) {
        _ = sessionManager.application(UIApplication.shared, open: url, options: [:])
    }

    /// Called when the app resigns active / moves to background.
    func appWillResignActive() {
        if appRemote.isConnected {
            appRemote.disconnect()
            handleDisconnected()
        }
    }

    /// Called when the app becomes active again (e.g. returning from the Spotify app switch).
    func appDidBecomeActive() {
        if accessToken != nil, !appRemote.isConnected {
            connectAppRemote()
        }
    }

    /// The single place that actually calls `appRemote.connect()`. Verifies a token exists,
    /// assigns it, and refuses to start a second attempt while one is already in flight.
    private func connectAppRemote(isRetry: Bool = false) {
        guard let accessToken else {
            errorMessage = "No Spotify access token available. Tap Connect Spotify to authorize."
            return
        }
        guard !appRemote.isConnected, !isConnecting else { return }

        if !isRetry {
            hasRetriedConnection = false
        }

        isConnecting = true
        appRemote.connectionParameters.accessToken = accessToken
        appRemote.connect()
    }

    private func handleDisconnected() {
        isConnected = false
        isConnecting = false
        stopPlaybackClock()
    }

    // MARK: - Playback clock

    /// Re-anchors the local playback clock to Spotify's authoritative state. Called on every
    /// `playerStateDidChange` (which covers seek, pause, resume, and track-change — Spotify
    /// reports a full new state for all of them) as well as right after (re)connecting.
    private func applyAuthoritativeState(from playerState: SPTAppRemotePlayerState) {
        let newTrackURI = playerState.track.uri
        let trackChanged = newTrackURI != trackURI

        // Publish every other piece of metadata before `trackURI` itself, so anything reacting
        // to a `trackURI` change (e.g. LyricsManager) already sees the correct duration/album
        // for the *new* track rather than a stale value from the previous one.
        trackName = playerState.track.name
        artistName = playerState.track.artist.name
        albumName = playerState.track.album.name
        durationMs = Int(playerState.track.duration)
        isPaused = playerState.isPaused

        if trackChanged {
            albumArtwork = nil
            requestArtwork(for: playerState.track, trackURI: newTrackURI)
        }

        trackURI = newTrackURI

        authoritativePositionMs = playerState.playbackPosition
        authoritativeTimestamp = ProcessInfo.processInfo.systemUptime

        // Reflect the new anchor immediately rather than waiting for the next timer tick.
        updateInterpolatedPosition()
    }

    /// Fetches artwork for `track` via App Remote's image API (no Web API involved). Guards
    /// against a callback for a track we've since moved on from overwriting current artwork.
    private func requestArtwork(for track: SPTAppRemoteTrack, trackURI requestedTrackURI: String) {
        appRemote.imageAPI?.fetchImage(forItem: track, with: CGSize(width: 300, height: 300), callback: { [weak self] result, error in
            guard let self, self.trackURI == requestedTrackURI else { return }
            guard error == nil, let image = result as? UIImage else { return }
            self.albumArtwork = image
        })
    }

    /// Recomputes `playbackPositionMs` from the authoritative anchor plus elapsed monotonic time.
    /// Never adds a fixed increment per call — that would accumulate timer-firing drift.
    private func updateInterpolatedPosition() {
        let rawPositionMs: Int
        if isPaused {
            rawPositionMs = authoritativePositionMs
        } else {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - authoritativeTimestamp) * 1000
            rawPositionMs = authoritativePositionMs + Int(elapsedMs.rounded())
        }
        playbackPositionMs = min(max(rawPositionMs, 0), max(durationMs, 0))
    }

    private func startPlaybackClock() {
        stopPlaybackClock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateInterpolatedPosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackClockTimer = timer
    }

    private func stopPlaybackClock() {
        playbackClockTimer?.invalidate()
        playbackClockTimer = nil
    }

    /// Renders every piece of diagnostic information an `NSError` can carry, so failures are
    /// fully visible in the UI rather than needing a console attached.
    private func fullDescription(of error: NSError) -> String {
        var parts = [
            "domain: \(error.domain)",
            "code: \(error.code)",
            "description: \(error.localizedDescription)",
        ]
        if let failureReason = error.localizedFailureReason {
            parts.append("failureReason: \(failureReason)")
        }
        if let recoverySuggestion = error.localizedRecoverySuggestion {
            parts.append("recoverySuggestion: \(recoverySuggestion)")
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlyingError: \(underlying)")
        }
        return parts.joined(separator: " | ")
    }

    /// `true` if the failure looks like Spotify's local App Remote transport simply wasn't up
    /// yet right after the app switch (the "Connection refused" on ::1:9095 case), as opposed to
    /// a real authorization/connection error worth surfacing without a retry.
    private func isLocalTransportNotReadyError(_ error: NSError) -> Bool {
        if error.domain == SPTAppRemoteErrorDomain,
           error.code == SPTAppRemoteErrorCode.connectionAttemptFailedError.rawValue {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(ECONNREFUSED) {
            return true
        }
        return false
    }
}

// MARK: - SPTSessionManagerDelegate

extension SpotifyManager: SPTSessionManagerDelegate {

    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        accessToken = session.accessToken
        appRemote.connectionParameters.accessToken = session.accessToken
        connectAppRemote()
    }

    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        accessToken = session.accessToken
        appRemote.connectionParameters.accessToken = session.accessToken
        connectAppRemote()
    }

    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        errorMessage = fullDescription(of: error as NSError)
    }
}

// MARK: - SPTAppRemoteDelegate

extension SpotifyManager: SPTAppRemoteDelegate {

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        isConnected = true
        isConnecting = false
        hasRetriedConnection = false
        errorMessage = nil

        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            if let error = error {
                self?.errorMessage = self?.fullDescription(of: error as NSError)
            }
        })

        // Establish a fresh timing anchor from the current state, then start the local clock.
        appRemote.playerAPI?.getPlayerState { [weak self] result, error in
            guard let self, error == nil, let playerState = result as? SPTAppRemotePlayerState else { return }
            self.applyAuthoritativeState(from: playerState)
            self.startPlaybackClock()
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        handleDisconnected()

        guard let nsError = error as NSError? else { return }

        let description = fullDescription(of: nsError)
        errorMessage = description
        print("SpotifyManager: App Remote connection attempt failed — \(description)")

        if !hasRetriedConnection, isLocalTransportNotReadyError(nsError) {
            hasRetriedConnection = true
            print("SpotifyManager: retrying App Remote connection once after local transport was not ready")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.connectAppRemote(isRetry: true)
            }
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        handleDisconnected()

        if let nsError = error as NSError? {
            let description = fullDescription(of: nsError)
            errorMessage = description
            print("SpotifyManager: App Remote disconnected with error — \(description)")
        }
    }
}

// MARK: - SPTAppRemotePlayerStateDelegate

extension SpotifyManager: SPTAppRemotePlayerStateDelegate {

    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        // Covers seek, pause, resume, and track-change alike — Spotify always reports a full
        // new state, so re-anchoring unconditionally here handles all of them uniformly.
        applyAuthoritativeState(from: playerState)
    }
}

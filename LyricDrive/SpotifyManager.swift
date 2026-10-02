//
//  SpotifyManager.swift
//  LyricDrive
//

import Combine
import Darwin
import Foundation
import SpotifyiOS
import UIKit
import os

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

    /// `true` when App Remote couldn't connect specifically because Spotify's local transport
    /// isn't listening yet (the app is installed/authorized but asleep) — as opposed to a real
    /// authorization problem. The UI should offer a "Reconnect Spotify" action instead of "Connect".
    @Published private(set) var requiresSpotifyWake = false

    /// `true` for the whole span of an SDK-driven wake attempt: from the moment
    /// `wakeSpotifyAndReconnect()` calls `initiateSession` through the redirect callback and the
    /// subsequent App Remote connection attempt. The UI should show a "connecting" state rather
    /// than the wake button while this is `true`.
    @Published private(set) var isWakingSpotify = false

    /// The continuously-advancing, locally-interpolated playback position. This is what UI (and,
    /// later, lyric-line selection) should read. It is derived from the authoritative anchor below
    /// on every clock tick, never advanced by blindly adding a fixed step per timer fire.
    @Published private(set) var playbackPositionMs = 0

    /// Changes only when Spotify supplies a fresh playback anchor (including seeks), not on
    /// interpolation ticks. CarPlay uses this to update the system's elapsed-time anchor.
    @Published private(set) var playbackAnchorRevision = 0

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

    /// The full authorized session (access + refresh token, expiration, scope), mirrored to and
    /// restored from the Keychain via `sessionStore` so the user isn't re-prompted on every
    /// relaunch/rebuild/TestFlight update.
    private var currentSession: SPTSession?

    private let sessionStore = SpotifySessionStore()

    /// `true` once Spotify has been authorized (a session exists, restored or fresh), whether or
    /// not App Remote is currently connected. Read-only UI hint for "Connect" vs. "Reconnect".
    var hasAuthorizedSession: Bool { currentSession != nil }

    /// Guards against firing a second `appRemote.connect()` while one is already in flight.
    /// Published (read-only) so the UI can show a "Connecting…" state.
    @Published private(set) var isConnecting = false

    /// Bounds the standalone transport retry to one retry per sequence.
    private var hasRetriedConnection = false

    /// `true` while a bounded automatic reconnect sequence started for CarPlay is in progress
    /// (see `reconnectForCarPlay()`). Read-only for UI, e.g. to show "Connecting…" rather than a
    /// reconnect prompt while retries are still pending.
    @Published private(set) var isAutoReconnecting = false

    /// Delays before each remaining automatic retry of the current CarPlay reconnect sequence.
    private var autoReconnectDelays: [TimeInterval] = []
    // Published (still private) only so SwiftUI re-reads `hasPendingReconnect` when it changes.
    @Published private var autoReconnectTask: Task<Void, Never>?
    private var reconnectDeadlineTask: Task<Void, Never>?
    private var usedCarPlayActivationRetry = false
    private var lastFailureWasTransport = false
    // Published (still private) for the same reason as `autoReconnectTask`.
    @Published private var renewalInFlight = false
    private var reconnectAfterRenewal = false
    private var renewalAttempted = false
    private var renewalSucceeded = false
    private var reconnectTrigger: ReconnectTrigger = .sessionRestore
    private var reconnectAttempt = 0

    /// Read-only for UI: `true` while a silent session renewal or a scheduled reconnect retry is
    /// still pending, so the UI keeps showing "Reconnecting" between attempts.
    var hasPendingReconnect: Bool { renewalInFlight || autoReconnectTask != nil }

    enum ReconnectTrigger: String {
        case sessionRestore, carPlayDidConnect, carPlaySceneDidBecomeActive
        case phoneSceneDidBecomeActive, manualReconnect
    }

    /// No tokens or arbitrary SDK userInfo are logged. Only diagnostic error fields.
    private func logReconnect(_ event: String, error: NSError? = nil) {
        #if DEBUG
        var detail = ""
        var current = error
        for _ in 0..<6 {
            guard let value = current else { break }
            detail += " [domain=\(value.domain) code=\(value.code) description=\(value.localizedDescription) reason=\(value.localizedFailureReason ?? "")]"
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let message = "timestamp=\(Date().ISO8601Format()) trigger=\(reconnectTrigger.rawValue) attempt=\(reconnectAttempt) savedSession=\(currentSession != nil) renewalAttempted=\(renewalAttempted) renewalSucceeded=\(renewalSucceeded) remoteConnected=\(appRemote.isConnected) wake=\(requiresSpotifyWake) auto=\(isAutoReconnecting) event=\(event)\(detail)"
        Logger(subsystem: "com.andresbotia.LyricDrive", category: "SpotifyReconnect").debug("\(message, privacy: .public)")
        #endif
    }

    private func renewSession() {
        reconnectAfterRenewal = true
        guard !renewalInFlight else { return }
        renewalInFlight = true
        renewalAttempted = true
        logReconnect("renewal requested")
        sessionManager.renewSession()
    }

    /// Spotify's local transport often only comes up once the car has resumed playback, which can
    /// take several seconds after CarPlay connects. Attempts: immediately, then after these
    /// delays (≈1.5s, 4.5s, 10.5s after the first failure) — four in total.
    private static let carPlayRetryDelays: [TimeInterval] = [1.5, 3, 6]

    /// Drives the ~10Hz local playback clock. Only runs while App Remote is connected.
    private var playbackClockTimer: Timer?

    #if DEBUG && targetEnvironment(simulator)
    /// Index into `CarPlayDemo.tracks` while the DEBUG simulator demo is running (see bottom).
    private var demoTrackIndex: Int?
    private var demoAutoAdvance: AnyCancellable?
    #endif

    private lazy var configuration: SPTConfiguration = {
        let configuration = SPTConfiguration(clientID: Self.clientID, redirectURL: Self.redirectURL)
        // Spotify's official sample requires a non-nil (can be blank) playURI: without it, the
        // Spotify app won't resume playback after authorization and App Remote's local transport
        // never comes up, which surfaces as "Connection refused" on ::1:9095.
        configuration.playURI = ""
        return configuration
    }()

    /// Drives authorization via the installed Spotify app only (`.clientOnly`, never a web/Safari
    /// fallback — App Remote is useless without the Spotify app anyway), free of the deprecated
    /// `UIApplication.openURL(_:)` path that `SPTAppRemote.authorizeAndPlayURI` used internally.
    private lazy var sessionManager: SPTSessionManager = {
        SPTSessionManager(configuration: configuration, delegate: self)
    }()

    /// Logs whether the SDK believes the Spotify app is installed. Purely diagnostic — we still
    /// attempt `.clientOnly` authorization regardless, since forcing that option already
    /// guarantees no web-auth fallback, so a false negative here can't cause one either.
    private func logSpotifyInstallStatus() {
        print("Spotify app installed: \(sessionManager.isSpotifyAppInstalled)")
    }

    private lazy var appRemote: SPTAppRemote = {
        let appRemote = SPTAppRemote(configuration: configuration, logLevel: .debug)
        appRemote.delegate = self
        return appRemote
    }()

    override init() {
        super.init()
        #if DEBUG && targetEnvironment(simulator)
        if CarPlayDemo.isEnabled {
            startCarPlayDemo()
            return
        }
        #endif
        restoreSessionFromKeychain()
    }

    /// Loads any previously-authorized session from the Keychain and, if present, wires it up
    /// without ever showing Spotify's interactive authorization screen: a valid session connects
    /// immediately, an expired one triggers a silent renewal.
    private func restoreSessionFromKeychain() {
        guard let restoredSession = sessionStore.loadSession() else {
            print("SpotifyManager: No stored Spotify session")
            return
        }

        print("SpotifyManager: Spotify session restored from Keychain")
        currentSession = restoredSession
        sessionManager.session = restoredSession
        accessToken = restoredSession.accessToken
        appRemote.connectionParameters.accessToken = restoredSession.accessToken

        if restoredSession.isExpired {
            print("SpotifyManager: Spotify session renewal requested")
            renewSession()
        } else {
            connectAppRemote()
        }
    }

    /// Connects App Remote using a valid/restorable session, silently renews one that has
    /// expired, or — only when neither is available — starts interactive PKCE authorization.
    func connect() {
        cancelAutomaticReconnect()
        reconnectTrigger = .manualReconnect
        reconnectAttempt = 0
        renewalAttempted = renewalInFlight
        renewalSucceeded = false
        errorMessage = nil

        if let currentSession, !currentSession.isExpired, accessToken != nil {
            connectAppRemote()
        } else if currentSession != nil {
            print("SpotifyManager: Spotify session renewal requested")
            renewSession()
        } else {
            print("SpotifyManager: Spotify authorization required")
            logSpotifyInstallStatus()
            sessionManager.initiateSession(with: [.appRemoteControl], options: .clientOnly)
        }
    }

    /// Logs out of Spotify entirely: disconnects App Remote, discards the in-memory session and
    /// access token, and deletes the persisted session from the Keychain. No UI currently calls
    /// this — it exists so a future logout control has a single, correct place to hook into.
    func disconnectAndForgetSpotify() {
        reconnectAfterRenewal = false
        cancelAutomaticReconnect()
        stopPlaybackClock()
        if appRemote.isConnected {
            appRemote.disconnect()
        }

        currentSession = nil
        sessionManager.session = nil
        accessToken = nil
        appRemote.connectionParameters.accessToken = nil
        sessionStore.deleteSession()

        isConnected = false
        isConnecting = false
        hasRetriedConnection = false
        requiresSpotifyWake = false
        isWakingSpotify = false
        errorMessage = nil
    }

    /// Bootstraps Spotify's local App Remote transport via an SDK-driven app switch —
    /// `SPTSessionManager.initiateSession(with:options: .clientOnly)`. This exact call was
    /// verified against a minimal, isolated diagnostic target (SpotifyDiagnostic) on the same
    /// physical device: it performed a real app switch, obtained a fresh session, and shortly
    /// after that App Remote's local transport came up. A second diagnostic path,
    /// `appRemote.authorizeAndPlayURI("")`, was verified NOT to work on this iOS/SDK
    /// combination — it hits the deprecated `UIApplication.openURL(_:)` path, iOS force-fails
    /// it ("BUG IN CLIENT OF UIKIT"), and the call returns `false` without doing anything. Do
    /// not reintroduce `authorizeAndPlayURI` here.
    ///
    /// This is NOT a re-authorization — for an already-approved app, Spotify redirects straight
    /// back without prompting the user, and the existing Keychain session is left untouched
    /// unless Spotify itself reports a genuine authorization failure. Only ever called from
    /// explicit user action (the "Reconnect Spotify" button), never automatically, and guarded
    /// against overlapping calls, so this can't turn into a loop of app switches.
    func bootstrapSpotifyAppRemote() {
        guard !isWakingSpotify else { return }

        guard currentSession != nil else {
            // No session to bootstrap with — shouldn't normally be reachable from the wake UI,
            // but fall back to the standard authorization entry point if it somehow is.
            connect()
            return
        }

        cancelAutomaticReconnect()
        reconnectTrigger = .manualReconnect
        reconnectAttempt = 0
        renewalAttempted = renewalInFlight
        renewalSucceeded = false
        logReconnect("manual wake before")
        print("SpotifyManager: Starting Spotify SDK wake app-switch")
        requiresSpotifyWake = false
        isWakingSpotify = true
        errorMessage = nil
        hasRetriedConnection = false

        logSpotifyInstallStatus()
        sessionManager.initiateSession(with: [.appRemoteControl], options: .clientOnly)
    }

    func disconnect() {
        reconnectAfterRenewal = false
        cancelAutomaticReconnect()
        appRemote.disconnect()
        handleDisconnected()
    }

    // MARK: - Playback controls

    /// Transport controls used by the CarPlay scene (and available to any other UI layer). These
    /// keep `SPTAppRemote`/`playerAPI` encapsulated here rather than handing SDK objects out.
    /// Player state itself is not written locally — Spotify pushes a fresh
    /// `playerStateDidChange`, which re-anchors the clock and updates `isPaused` as usual.
    /// Every control is a safe no-op when App Remote isn't connected.
    func previousTrack() {
        #if DEBUG && targetEnvironment(simulator)
        if demoTrackIndex != nil { return demoPreviousTrack() }
        #endif
        guard let playerAPI = connectedPlayerAPI(for: "previousTrack") else { return }
        playerAPI.skip(toPrevious: playbackControlCallback)
    }

    func nextTrack() {
        #if DEBUG && targetEnvironment(simulator)
        if demoTrackIndex != nil { return demoNextTrack() }
        #endif
        guard let playerAPI = connectedPlayerAPI(for: "nextTrack") else { return }
        playerAPI.skip(toNext: playbackControlCallback)
    }

    func togglePlayPause() {
        #if DEBUG && targetEnvironment(simulator)
        if demoTrackIndex != nil { return demoTogglePlayPause() }
        #endif
        guard let playerAPI = connectedPlayerAPI(for: "togglePlayPause") else { return }
        if isPaused {
            playerAPI.resume(playbackControlCallback)
        } else {
            playerAPI.pause(playbackControlCallback)
        }
    }

    private func connectedPlayerAPI(for action: String) -> SPTAppRemotePlayerAPI? {
        guard appRemote.isConnected, let playerAPI = appRemote.playerAPI else {
            print("SpotifyManager: Ignoring \(action) — App Remote not connected")
            return nil
        }
        return playerAPI
    }

    private var playbackControlCallback: SPTAppRemoteCallback {
        { [weak self] _, error in
            if let error {
                self?.errorMessage = self?.fullDescription(of: error as NSError)
            }
        }
    }

    /// Called from the app's `.onOpenURL` handler with the `lyricdrive-login://callback` redirect.
    func handleAuthorizationCallback(url: URL) {
        _ = sessionManager.application(UIApplication.shared, open: url, options: [:])
    }

    /// Called when the app resigns active / moves to background.
    func appWillResignActive() {
        reconnectAfterRenewal = false
        cancelAutomaticReconnect()
        if appRemote.isConnected || isConnecting {
            appRemote.disconnect()
            handleDisconnected()
        }
    }

    /// Called when the app becomes active again (e.g. returning from the Spotify app switch).
    func appDidBecomeActive() {
        if !isAutoReconnecting && !isConnecting && !isWakingSpotify && autoReconnectTask == nil {
            reconnectTrigger = .phoneSceneDidBecomeActive
            reconnectAttempt = 0
            renewalAttempted = renewalInFlight
            renewalSucceeded = false
            reconnectIfAuthorized()
        }
    }

    /// Reconnects App Remote from the existing session — silently renewing it first if expired —
    /// without ever starting interactive authorization. A no-op when there's no token or App
    /// Remote is already connected. Also used when a CarPlay scene connects.
    func reconnectIfAuthorized() {
        guard accessToken != nil, !appRemote.isConnected, autoReconnectTask == nil else { return }

        if let currentSession, currentSession.isExpired {
            print("SpotifyManager: Spotify session renewal requested")
            renewSession()
        } else {
            print("SpotifyManager: Reconnecting App Remote")
            connectAppRemote()
        }
    }

    /// Reconnect used by the CarPlay scene (on connect and whenever it becomes active again).
    /// Like `reconnectIfAuthorized()` — silent, never OAuth, never an app switch — but if the
    /// failure is specifically Spotify's local transport not being ready, it retries a few times
    /// on `carPlayRetryDelays` before falling back to the explicit "Reconnect Spotify" state.
    /// A no-op without a session, when already connected, or while a sequence is running.
    func reconnectForCarPlay(trigger: ReconnectTrigger) {
        if trigger == .carPlayDidConnect { usedCarPlayActivationRetry = false }
        guard accessToken != nil, !appRemote.isConnected, !isAutoReconnecting, !isWakingSpotify else { return }
        if trigger == .carPlaySceneDidBecomeActive {
            guard !usedCarPlayActivationRetry else { return }
            usedCarPlayActivationRetry = true
        }
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        reconnectTrigger = trigger
        reconnectAttempt = isConnecting ? 1 : 0
        renewalAttempted = renewalInFlight
        renewalSucceeded = false
        logReconnect("sequence start: wake before clear")
        requiresSpotifyWake = false
        isAutoReconnecting = true
        lastFailureWasTransport = false
        autoReconnectDelays = Self.carPlayRetryDelays
        // Hard ceiling includes SDK callback/renewal time, not just retry delays.
        reconnectDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(18))
            guard !Task.isCancelled, let self, self.isAutoReconnecting else { return }
            let needsWake = self.lastFailureWasTransport && !self.renewalInFlight
            self.cancelAutomaticReconnect()
            self.reconnectAfterRenewal = false
            self.isConnecting = false
            self.appRemote.disconnect()
            self.requiresSpotifyWake = needsWake
            self.logReconnect("sequence deadline: wake after")
        }
        reconnectIfAuthorized()
    }

    /// Stops any pending automatic retry. Called when CarPlay disconnects, on success, and when
    /// the session is dropped or can't be renewed.
    func cancelAutomaticReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        reconnectDeadlineTask?.cancel()
        reconnectDeadlineTask = nil
        autoReconnectDelays = []
        isAutoReconnecting = false
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

        reconnectAttempt += 1
        logReconnect("connect before")
        requiresSpotifyWake = false
        logReconnect("connect: wake after clear")
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
        playbackAnchorRevision &+= 1
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

    /// `true` if the failure looks like Spotify's local App Remote transport simply isn't
    /// listening (the app is installed/authorized but its App Remote service is asleep) —
    /// recognized by `NSPOSIXErrorDomain` `ECONNREFUSED` (61) in the underlying
    /// error chain. Generic SDK connection/stream wrappers alone are insufficient:
    /// they can also wrap auth or other fatal errors. This is never treated as an
    /// authorization problem — the saved session and access token are left untouched.
    private func isLocalTransportNotReadyError(_ error: NSError) -> Bool {
        return errorChainContainsTransportFailure(error, depth: 0)
    }

    private func errorChainContainsTransportFailure(_ error: NSError, depth: Int) -> Bool {
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ECONNREFUSED) {
            return true
        }
        guard depth < 5, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return errorChainContainsTransportFailure(underlying, depth: depth + 1)
    }
}

// MARK: - SPTSessionManagerDelegate

extension SpotifyManager: SPTSessionManagerDelegate {

    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        let wasWaking = isWakingSpotify
        if wasWaking {
            print("SpotifyManager: Spotify SDK wake callback received")
        }

        currentSession = session
        accessToken = session.accessToken
        sessionStore.save(session: session)
        appRemote.connectionParameters.accessToken = session.accessToken

        if wasWaking {
            print("SpotifyManager: Connecting App Remote after SDK wake")
        }
        connectAppRemote()
    }

    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        renewalInFlight = false
        renewalSucceeded = true
        guard currentSession != nil else { return }
        logReconnect("renewal succeeded")
        print("SpotifyManager: Spotify session renewed")
        currentSession = session
        accessToken = session.accessToken
        sessionStore.save(session: session)
        appRemote.connectionParameters.accessToken = session.accessToken
        if reconnectAfterRenewal {
            reconnectAfterRenewal = false
            connectAppRemote()
        }
    }

    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        renewalInFlight = false
        reconnectAfterRenewal = false
        logReconnect("renewal/session failed", error: error as NSError)
        cancelAutomaticReconnect()
        requiresSpotifyWake = false
        let description = fullDescription(of: error as NSError)
        print("SpotifyManager: Spotify session manager failed — \(description)")

        if isWakingSpotify {
            // The SDK wake attempt itself failed before ever reaching App Remote — return to the
            // wake-requestable state rather than leaving the UI stuck on "connecting".
            isWakingSpotify = false
            requiresSpotifyWake = true
        }
        errorMessage = description
        // Deliberately not touching `currentSession`/the Keychain here: a temporarily
        // unreachable network or a transient renewal error must not throw away a previously
        // good authorization. Only an explicit disconnectAndForgetSpotify() call does that —
        // interactive re-authorization should be something the user asks for via Connect,
        // not something triggered automatically by a failed background renewal.
    }
}

// MARK: - SPTAppRemoteDelegate

extension SpotifyManager: SPTAppRemoteDelegate {

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        logReconnect("connected: wake before clear")
        print("SpotifyManager: Spotify App Remote connected")
        cancelAutomaticReconnect()
        isConnected = true
        isConnecting = false
        hasRetriedConnection = false
        requiresSpotifyWake = false
        isWakingSpotify = false
        errorMessage = nil

        logReconnect("connected: wake after clear")
        if appRemote.playerAPI == nil { logReconnect("player API unavailable") }
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            self?.logReconnect("player state subscription success=\(error == nil)", error: error as NSError?)
            if let error = error {
                self?.errorMessage = self?.fullDescription(of: error as NSError)
            }
        })

        // Establish a fresh timing anchor from the current state, then start the local clock.
        appRemote.playerAPI?.getPlayerState { [weak self] result, error in
            self?.logReconnect("metadata refresh success=\(error == nil && result is SPTAppRemotePlayerState)", error: error as NSError?)
            guard let self, error == nil, let playerState = result as? SPTAppRemotePlayerState else { return }
            self.applyAuthoritativeState(from: playerState)
            self.startPlaybackClock()
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        guard isConnecting else {
            logReconnect("ignored failure from cancelled attempt", error: error as NSError?)
            return
        }
        handleDisconnected()

        logReconnect("connect failed: wake before", error: error as NSError?)
        guard let nsError = error as NSError? else {
            cancelAutomaticReconnect()
            isWakingSpotify = false
            requiresSpotifyWake = false
            errorMessage = "Spotify connection failed without an error description."
            logReconnect("unknown failure: wake after")
            return
        }

        let description = fullDescription(of: nsError)
        print("SpotifyManager: App Remote connection attempt failed — \(description)")

        guard isLocalTransportNotReadyError(nsError) else {
            // A genuine connection error unrelated to the transport-asleep case — surface it
            // as-is, and clear any stale wake-state UI.
            cancelAutomaticReconnect()
            isWakingSpotify = false
            requiresSpotifyWake = false
            errorMessage = description
            logReconnect("fatal failure: wake after", error: nsError)
            return
        }

        lastFailureWasTransport = true
        print("SpotifyManager: Spotify App Remote transport unavailable")

        if isAutoReconnecting, !autoReconnectDelays.isEmpty {
            // CarPlay sequence: wait for Spotify's transport (typically woken by the car resuming
            // playback) instead of asking the driver to tap Reconnect straight away. When the
            // delays run out, the `else` branch below surfaces the explicit Reconnect state.
            let delay = autoReconnectDelays.removeFirst()
            logReconnect("retry scheduled delay=\(delay) remaining=\(autoReconnectDelays.count)")
            hasRetriedConnection = true
            print("SpotifyManager: CarPlay reconnect retry in \(delay)s (\(autoReconnectDelays.count) more after that)")
            autoReconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.isAutoReconnecting else { return }
                self.autoReconnectTask = nil
                self.connectAppRemote(isRetry: true)
            }
            return
        }

        if !hasRetriedConnection {
            // Give it exactly one short chance to settle — this covers the common case where
            // Spotify has *just* become active (e.g. right after the SDK wake redirect) and its
            // local transport is still catching up.
            hasRetriedConnection = true
            logReconnect("standalone retry scheduled delay=0.75")
            print("SpotifyManager: retrying App Remote connection once after local transport was not ready")
            autoReconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.75))
                guard !Task.isCancelled, let self else { return }
                self.autoReconnectTask = nil
                self.connectAppRemote(isRetry: true)
            }
        } else {
            // The one retry also hit a sleeping transport — stop here rather than repeatedly
            // invoking the SDK wake against a process that isn't listening, and let the user
            // explicitly trigger it again.
            cancelAutomaticReconnect()
            isWakingSpotify = false
            requiresSpotifyWake = true
            logReconnect("transport retries exhausted: wake after")
            errorMessage = "Spotify needs to reconnect. Tap Reconnect Spotify to continue."
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

// MARK: - DEBUG simulator demo

#if DEBUG && targetEnvironment(simulator)
/// Fake playback for `--carplay-demo` (see `CarPlayDemo`). Publishes demo tracks through the same
/// properties and playback clock real Spotify state uses, so every UI path runs unchanged.
/// App Remote is never touched: no access token exists, so all reconnect paths stay no-ops.
extension SpotifyManager {

    fileprivate func startCarPlayDemo() {
        print("SpotifyManager: --carplay-demo active (DEBUG simulator only)")
        isConnected = true
        loadDemoTrack(at: 0, playing: true)
        startPlaybackClock()

        // Auto-advance at the end of each track, like a playlist would.
        demoAutoAdvance = $playbackPositionMs.sink { [weak self] positionMs in
            guard let self, !self.isPaused, self.durationMs > 0, positionMs >= self.durationMs else { return }
            let finishedTrack = self.demoTrackIndex
            // Deferred: this fires inside the property's willSet.
            DispatchQueue.main.async {
                guard self.demoTrackIndex == finishedTrack, self.playbackPositionMs >= self.durationMs else { return }
                self.demoNextTrack()
            }
        }
    }

    private func loadDemoTrack(at index: Int, playing: Bool) {
        let track = CarPlayDemo.tracks[index]
        demoTrackIndex = index
        // Same order as `applyAuthoritativeState`: metadata before `trackURI`.
        trackName = track.name
        artistName = track.artist
        albumName = track.album
        durationMs = track.durationMs
        isPaused = !playing
        albumArtwork = CarPlayDemo.artwork(for: track)
        trackURI = track.uri
        seekDemo(toMs: 0)
    }

    private func seekDemo(toMs positionMs: Int) {
        authoritativePositionMs = positionMs
        authoritativeTimestamp = ProcessInfo.processInfo.systemUptime
        updateInterpolatedPosition()
        playbackAnchorRevision &+= 1
    }

    fileprivate func demoTogglePlayPause() {
        // Re-anchor at the current position so pausing freezes, and resuming continues, from here.
        let positionMs = playbackPositionMs
        isPaused.toggle()
        seekDemo(toMs: positionMs)
    }

    fileprivate func demoNextTrack() {
        guard let index = demoTrackIndex else { return }
        loadDemoTrack(at: (index + 1) % CarPlayDemo.tracks.count, playing: !isPaused)
    }

    /// Like Spotify: restarts the current track if more than 3s in, otherwise goes back one.
    fileprivate func demoPreviousTrack() {
        guard let index = demoTrackIndex else { return }
        if playbackPositionMs > 3_000 {
            seekDemo(toMs: 0)
        } else {
            let count = CarPlayDemo.tracks.count
            loadDemoTrack(at: (index + count - 1) % count, playing: !isPaused)
        }
    }
}
#endif

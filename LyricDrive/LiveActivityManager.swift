import ActivityKit
import Combine
import UIKit
import os

/// Single internal kill switch for the lyric Live Activity. No user-facing toggle.
enum InternalFeatures {
    static let carPlayLiveActivityEnabled = true
}

/// Drives the lyric Live Activity — the surface CarPlay shows on its Dashboard, and the Lock
/// Screen / Dynamic Island on iPhone — from the normalized now-playing state of whichever music
/// service is active. Provider differences stay in `NowPlayingStore` and `MusicSessionState`.
///
/// Updates are local ActivityKit updates, sent on semantic changes only (a new active lyric
/// line, track, provider, lyric availability, or play/pause) — never on playback-clock ticks.
/// They can only be sent while LyricDrive has execution time; nothing here tries to keep the app
/// running. When updates stop, the last lyric window stays visible until the song should have
/// ended (`staleDate`). Content is built separately from delivery (`makeContent` vs. `send`), so
/// a push-update path could later deliver the same `ContentState`.
///
/// Rules:
/// - Start: the service is usable, a track is playing (not paused), its synced lyrics are loaded, and no
///   earlier request failure or user dismissal is waiting for a foreground opportunity.
/// - Update: whenever the content changes, including "Finding synced lyrics…" right after a
///   track change (so the previous song's lines are never shown under the new one) and "no
///   synced lyrics" for a song without them (kept, because a background restart for the next
///   song may not be allowed).
/// - End: immediately when the service is unusable (signed out, reconnect failed, access off) or
///   on a service switch; after `disconnectGrace` without a track or after a clean disconnect;
///   after `pausedLimit` paused. Never while Spotify is reconnecting.
@MainActor
final class LiveActivityManager {
    typealias ContentState = LyricDriveActivityAttributes.ContentState

    /// A clean disconnect or a missing track this long ends the activity (unchanged from the
    /// original prototype's 30 seconds).
    private static let disconnectGrace: Duration = .seconds(30)
    /// Paused this long ends the activity.
    private static let pausedLimit: Duration = .seconds(10 * 60)
    /// After the song should have ended, how long before the activity counts as stale.
    private static let songEndGrace: TimeInterval = 30
    /// Context lines around the current line (two before, two after mid-song).
    private static let contextLines = 4

    enum Reason: String {
        case launch, providerChanged, trackChanged, playbackChanged, lyricsChanged, lineChanged
        case sessionChanged, appBecameActive, carPlayConnected, carPlayBecameActive, activityStateChanged
        case scheduledEnd
    }

    enum EndReason: String {
        case featureDisabled, providerUnavailable, providerSwitched, providerDisconnected
        case noTrack, pausedTooLong
    }

    private enum Plan {
        case show(ContentState)
        /// Spotify is reconnecting or Apple Music access is being requested: leave as is.
        case hold
        case endAfter(Duration, EndReason)
        case end(EndReason)

        func calls(for reason: EndReason) -> Bool {
            switch self {
            case .show(let state): reason == .pausedTooLong && state.isPaused
            case .hold: false
            case .endAfter(_, let scheduled): scheduled == reason
            case .end: true
            }
        }
    }

    private let spotify: SpotifyManager
    private let appleMusic: AppleMusicManager
    private let lyrics: LyricsManager
    private let nowPlaying: NowPlayingStore
    private let isCarPlayConnected: () -> Bool

    private var activity: Activity<LyricDriveActivityAttributes>?
    private var lastContent: ContentState?
    /// The service whose content the activity shows. `nil` for an adopted activity until its
    /// first update (its old content is never read: it may predate the current format).
    private var activityProvider: MusicService?
    private var observers = Set<AnyCancellable>()
    private var activityStateTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var needsReconcile = false
    private var pendingReasons: [Reason] = []
    private var scheduledEnd: (reason: EndReason, task: Task<Void, Never>)?
    /// A scheduled end that has come due; carried out by the next reconcile.
    private var dueEnd: EndReason?

    /// A request failed (typically because LyricDrive wasn't in the foreground). No further
    /// requests until the next foreground or CarPlay activation, which retries once.
    private var pendingStart = false
    /// The user dismissed the activity. Respected until the iPhone app is opened or CarPlay
    /// connects again.
    private var dismissedByUser = false

    init(
        spotify: SpotifyManager,
        appleMusic: AppleMusicManager,
        lyrics: LyricsManager,
        nowPlaying: NowPlayingStore,
        isCarPlayConnected: @escaping () -> Bool
    ) {
        self.spotify = spotify
        self.appleMusic = appleMusic
        self.lyrics = lyrics
        self.nowPlaying = nowPlaying
        self.isCarPlayConnected = isCarPlayConnected

        guard InternalFeatures.carPlayLiveActivityEnabled else {
            Task { await Self.endAll(except: nil) }
            return
        }

        // Adopt an activity left by a previous launch: updating it is allowed from the
        // background, where requesting a new one may not be. Its content is replaced (or the
        // activity ended) on the first reconcile.
        if let existing = Activity<LyricDriveActivityAttributes>.activities.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            adopt(existing)
        }
        let keptID = activity?.id
        Task { await Self.endAll(except: keptID) }

        let triggers: [AnyPublisher<Reason, Never>] = [
            nowPlaying.$activeService.removeDuplicates().map { _ in .providerChanged }.eraseToAnyPublisher(),
            nowPlaying.$track.removeDuplicates().map { _ in .trackChanged }.eraseToAnyPublisher(),
            nowPlaying.$isPaused.removeDuplicates().map { _ in .playbackChanged }.eraseToAnyPublisher(),
            // Inputs to each provider's `MusicSessionState` (same set the CarPlay scene uses).
            spotify.$isConnected.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            spotify.$isConnecting.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            spotify.$isAutoReconnecting.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            spotify.$isWakingSpotify.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            spotify.$requiresSpotifyWake.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            spotify.$errorMessage.map { $0 != nil }.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            spotify.hasPendingReconnectPublisher.map { _ in .sessionChanged }.eraseToAnyPublisher(),
            appleMusic.$authorization.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            appleMusic.$isRequestingAuthorization.removeDuplicates().map { _ in .sessionChanged }.eraseToAnyPublisher(),
            // Lyrics. `currentLineIndex` is reassigned on every clock tick but only changes when
            // the active line does; playback position itself is deliberately not observed.
            lyrics.$state.map { _ in .lyricsChanged }.eraseToAnyPublisher(),
            lyrics.$lines.removeDuplicates().map { _ in .lyricsChanged }.eraseToAnyPublisher(),
            lyrics.$currentLineIndex.removeDuplicates().map { _ in .lineChanged }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] in self?.scheduleReconcile($0) }
            .store(in: &observers)
        scheduleReconcile(.launch)
    }

    // MARK: - Opportunities

    /// The iPhone app came to the foreground: the most reliable moment to request an activity.
    func appDidBecomeActive() {
        dismissedByUser = false
        handleOpportunity(.appBecameActive)
    }

    /// CarPlay connected — the start of a drive.
    func carPlayDidConnect() {
        dismissedByUser = false
        handleOpportunity(.carPlayConnected)
    }

    /// The driver opened LyricDrive on the car screen.
    func carPlayDidBecomeActive() {
        handleOpportunity(.carPlayBecameActive)
    }

    /// Allows one more request attempt if the last one failed, and re-sends the current content
    /// even if unchanged, so the activity is brought up to date (and un-staled) right away.
    private func handleOpportunity(_ reason: Reason) {
        guard InternalFeatures.carPlayLiveActivityEnabled else { return }
        if pendingStart {
            pendingStart = false
            trace("pending start cleared for one retry (\(reason.rawValue))")
        }
        lastContent = nil
        scheduleReconcile(reason)
    }

    // MARK: - Reconcile

    /// `@Published` emits in willSet; reconcile on the next turn so all related state is settled.
    /// Bursts coalesce, and ActivityKit calls never overlap.
    private func scheduleReconcile(_ reason: Reason) {
        pendingReasons.append(reason)
        needsReconcile = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            while self.needsReconcile {
                self.needsReconcile = false
                let reasons = self.pendingReasons
                self.pendingReasons = []
                await self.reconcile(reasons)
            }
            self.worker = nil
        }
    }

    private func reconcile(_ reasons: [Reason]) async {
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            // Ended by the system, or removed by the user (respected until a new opportunity).
            if activity.activityState == .dismissed { dismissedByUser = true }
            trace("activity \(activity.id) no longer active: \(String(describing: activity.activityState))")
            forgetActivity()
        }

        if let activityProvider, activityProvider != nowPlaying.activeService {
            // A service switch: end rather than update, so nothing from the previous service can
            // linger while the new one has no track yet. Switching happens in the foreground, so
            // a new request is allowed.
            await end(.providerSwitched)
        }

        let plan = plan()
        if let dueEnd {
            // Only if the condition that scheduled it still holds.
            self.dueEnd = nil
            if plan.calls(for: dueEnd) {
                await end(dueEnd)
                return
            }
        }

        switch plan {
        case .end(let reason):
            await end(reason)
        case .hold:
            cancelScheduledEnd()
        case .endAfter(let delay, let reason):
            scheduleEnd(after: delay, reason)
        case .show(let state):
            if state.isPaused {
                scheduleEnd(after: Self.pausedLimit, .pausedTooLong)
            } else {
                cancelScheduledEnd()
            }
            if activity != nil {
                await update(state, reasons)
            } else if state.status == .lyrics && !state.isPaused {
                await start(state, reasons)
            }
        }
    }

    private func plan() -> Plan {
        guard InternalFeatures.carPlayLiveActivityEnabled else { return .end(.featureDisabled) }

        let session: MusicSessionState = switch nowPlaying.activeService {
        case .spotify: MusicSessionState(spotify: spotify)
        case .appleMusic: MusicSessionState(appleMusic: appleMusic)
        }
        switch session.phase {
        case .connected:
            break
        case .connecting, .reconnecting:
            return .hold
        case .disconnected:
            // Clean disconnect, e.g. Spotify's App Remote when the iPhone app leaves the
            // foreground without CarPlay. Normally resumes on return.
            return .endAfter(Self.disconnectGrace, .providerDisconnected)
        case .notConnected, .needsUserAction:
            // Signed out, Spotify's reconnect gave up, or Apple Music access is off.
            return .end(.providerUnavailable)
        }

        guard let track = nowPlaying.track else {
            return .endAfter(Self.disconnectGrace, .noTrack)
        }
        return .show(makeContent(for: track))
    }

    // MARK: - Content

    private func makeContent(for track: NowPlayingTrack) -> ContentState {
        var state = ContentState(
            provider: track.provider.rawValue,
            trackID: String(track.id.prefix(120)),
            title: String(track.title.prefix(80)),
            artist: String(track.artist.prefix(80)),
            status: .findingLyrics,
            previousLines: [],
            currentLine: "",
            nextLines: [],
            lineIndex: nil,
            lineCount: 0,
            isPaused: nowPlaying.isPaused
        )
        // Lyrics still belonging to the previous track count as not loaded yet.
        guard lyrics.trackID == track.id else { return state }

        switch lyrics.state {
        case .idle, .loading:
            break
        case .plainOnly, .notFound, .error:
            state.status = .noLyrics
        case .synced:
            guard let window = lyrics.contextWindow(contextLines: Self.contextLines) else {
                state.status = .noLyrics
                break
            }
            state.status = .lyrics
            state.previousLines = window.previous.map { Self.displayText($0.text) }
            state.currentLine = window.current.map { Self.displayText($0.text) } ?? "♪"
            state.nextLines = window.next.map { Self.displayText($0.text) }
            state.lineIndex = lyrics.currentLineIndex
            state.lineCount = lyrics.lines.count
        }
        return state
    }

    /// Empty LRC lines mark instrumental breaks: "♪", as in the app and CarPlay. Capped so the
    /// payload stays well inside ActivityKit's size limit.
    private static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "♪" : String(trimmed.prefix(150))
    }

    /// Stale only on evidence the content is over: the song should have ended (or been paused
    /// for `pausedLimit`) without a newer update arriving.
    private func staleDate(for state: ContentState) -> Date? {
        if state.isPaused { return .now.addingTimeInterval(TimeInterval(Self.pausedLimit.components.seconds)) }
        guard let track = nowPlaying.track, track.durationMs > 0 else { return nil }
        let remainingMs = max(track.durationMs - nowPlaying.playbackPositionMs, 0)
        return .now.addingTimeInterval(TimeInterval(remainingMs) / 1000 + Self.songEndGrace)
    }

    // MARK: - ActivityKit

    private func start(_ state: ContentState, _ reasons: [Reason]) async {
        guard !pendingStart, !dismissedByUser else {
            trace("start skipped: pendingStart=\(pendingStart) dismissedByUser=\(dismissedByUser) \(describe(state))")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            trace("start skipped: Live Activities are turned off")
            return
        }
        trace("request attempt [\(reasonList(reasons))] \(describe(state))")
        do {
            // Local updates only (pushType: nil). A push-update path would pass `.token` here and
            // send the same ContentState from a server.
            let activity = try Activity.request(
                attributes: LyricDriveActivityAttributes(),
                content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                pushType: nil
            )
            adopt(activity)
            lastContent = state
            activityProvider = MusicService(rawValue: state.provider)
            trace("request succeeded: activity \(activity.id)")
        } catch {
            pendingStart = true
            trace("request failed, pendingStart=true: \(error.localizedDescription)")
        }
    }

    private func update(_ state: ContentState, _ reasons: [Reason]) async {
        guard let activity, state != lastContent || activity.activityState == .stale else { return }
        lastContent = state
        activityProvider = MusicService(rawValue: state.provider)
        await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state)))
        trace("update \(activity.id) [\(reasonList(reasons))] \(describe(state))")
    }

    private func end(_ reason: EndReason) async {
        cancelScheduledEnd()
        let id = activity?.id
        forgetActivity()
        guard id != nil || !Activity<LyricDriveActivityAttributes>.activities.isEmpty else { return }
        trace("end \(id ?? "(leftovers)"): \(reason.rawValue)")
        await Self.endAll(except: nil)
    }

    private func adopt(_ activity: Activity<LyricDriveActivityAttributes>) {
        self.activity = activity
        lastContent = nil
        activityProvider = nil
        activityStateTask?.cancel()
        activityStateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .dismissed || state == .ended else { continue }
                self?.scheduleReconcile(.activityStateChanged)
            }
        }
    }

    private func forgetActivity() {
        activityStateTask?.cancel()
        activityStateTask = nil
        activity = nil
        lastContent = nil
        activityProvider = nil
    }

    private static func endAll(except keptID: String?) async {
        for existing in Activity<LyricDriveActivityAttributes>.activities where existing.id != keptID {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Scheduled end

    private func scheduleEnd(after delay: Duration, _ reason: EndReason) {
        guard activity != nil, scheduledEnd?.reason != reason else { return }
        scheduledEnd?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduledEnd = nil
            self.dueEnd = reason
            self.scheduleReconcile(.scheduledEnd)
        }
        scheduledEnd = (reason, task)
    }

    private func cancelScheduledEnd() {
        scheduledEnd?.task.cancel()
        scheduledEnd = nil
    }

    // MARK: - Diagnostics (DEBUG only)

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        let lifecycle = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let line = "\(Date.now.ISO8601Format(.iso8601.time(includingFractionalSeconds: true))) app=\(lifecycle) carPlay=\(isCarPlayConnected()) pendingStart=\(pendingStart) \(message())"
        Self.logger.debug("\(line, privacy: .public)")
        #endif
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "com.andresbotia.LyricDrive", category: "LiveActivity")
    #endif

    private func reasonList(_ reasons: [Reason]) -> String {
        #if DEBUG
        Array(Set(reasons.map(\.rawValue))).sorted().joined(separator: ",")
        #else
        ""
        #endif
    }

    private func describe(_ state: ContentState) -> String {
        #if DEBUG
        let prefix = { (text: String?) in text.map { String($0.prefix(18)) } ?? "–" }
        return "provider=\(state.provider) track=\(state.trackID) status=\(state.status.rawValue) index=\(state.lineIndex.map(String.init) ?? "nil")/\(state.lineCount) paused=\(state.isPaused) prev=\"\(prefix(state.previousLines.last))\" cur=\"\(prefix(state.currentLine))\" next=\"\(prefix(state.nextLines.first))\""
        #else
        ""
        #endif
    }
}

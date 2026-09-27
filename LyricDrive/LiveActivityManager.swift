import ActivityKit
import Combine
import UIKit
import os

/// Single internal switch for the read-only prototype.
enum InternalFeatures {
    static let carPlayLiveActivityEnabled = true
}

@MainActor
final class LiveActivityManager {
    private let spotify: SpotifyManager
    private let lyrics: LyricsManager
    private var activity: Activity<LyricDriveActivityAttributes>?
    private var lastContent: LyricDriveActivityAttributes.ContentState?
    private var observers = Set<AnyCancellable>()
    private var worker: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var needsReconcile = false
    private var suppressStartsUntilForeground = false

    init(spotify: SpotifyManager, lyrics: LyricsManager) {
        self.spotify = spotify
        self.lyrics = lyrics
        guard InternalFeatures.carPlayLiveActivityEnabled else {
            Task { for activity in Activity<LyricDriveActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            } }
            return
        }
        // Published values emit in willSet. Defer reading until all related state is applied.
        let changes = Publishers.MergeMany([
            spotify.$isConnected.map { _ in () }.eraseToAnyPublisher(),
            spotify.$trackURI.map { _ in () }.eraseToAnyPublisher(),
            spotify.$trackName.map { _ in () }.eraseToAnyPublisher(),
            spotify.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            lyrics.$state.map { _ in () }.eraseToAnyPublisher(),
            lyrics.$currentLineIndex.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
        changes.sink { [weak self] in self?.scheduleReconcile() }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.suppressStartsUntilForeground = false
                self?.scheduleReconcile()
            }.store(in: &observers)
    }

    private func scheduleReconcile() {
        needsReconcile = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            while self.needsReconcile {
                self.needsReconcile = false
                await self.reconcile()
            }
            self.worker = nil
        }
    }

    private func reconcile() async {
        guard spotify.hasAuthorizedSession || spotify.isConnected else {
            await endAll()
            return
        }
        guard spotify.isConnected else {
            // Retain briefly during reconnect, but never retain readable stale lyrics.
            if disconnectTask == nil {
                disconnectTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, !self.spotify.isConnected else { return }
                    await self.endAll()
                }
            }
            return
        }
        disconnectTask?.cancel()
        disconnectTask = nil
        guard !spotify.trackURI.isEmpty, !spotify.trackName.isEmpty else {
            await endAll()
            return
        }
        var current = "No synced lyrics available"
        var next = ""
        let hasLyrics: Bool
        switch lyrics.state {
        case .synced:
            hasLyrics = true
            if let index = lyrics.currentLineIndex, lyrics.lines.indices.contains(index) {
                current = lyrics.lines[index].text.isEmpty ? "♪" : lyrics.lines[index].text
                if lyrics.lines.indices.contains(index + 1) { next = lyrics.lines[index + 1].text }
            } else {
                current = "♪"
                next = lyrics.lines.first?.text ?? ""
            }
        case .loading, .idle:
            hasLyrics = false
            current = "Finding synced lyrics…"
        default:
            hasLyrics = false
        }
        let state = LyricDriveActivityAttributes.ContentState(
            trackIdentifier: String(spotify.trackURI.prefix(120)),
            songTitle: String(spotify.trackName.prefix(120)),
            currentLyric: String(current.prefix(240)), nextLyric: String(next.prefix(240)),
            hasLyrics: hasLyrics, isPaused: spotify.isPaused)
        // Small payload; updates only on semantic changes, never playback clock ticks.
        if let activity, activity.activityState == .ended || activity.activityState == .dismissed {
            self.activity = nil
            lastContent = nil
            // Respect system/user dismissal until the next foreground opportunity.
            suppressStartsUntilForeground = true
            return
        }
        guard state != lastContent || activity == nil || activity?.activityState == .stale else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        if let activity {
            await activity.update(content)
            lastContent = state
        } else {
            // Local starts are permitted in the foreground. Background CarPlay starts may fail;
            // do not loop or add push/background capabilities to work around system policy.
            guard !suppressStartsUntilForeground, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                for existing in Activity<LyricDriveActivityAttributes>.activities {
                    await existing.end(nil, dismissalPolicy: .immediate)
                }
                activity = try Activity.request(attributes: LyricDriveActivityAttributes(), content: content)
                lastContent = state
            } catch {
                suppressStartsUntilForeground = true
                #if DEBUG
                Logger(subsystem: "com.andresbotia.LyricDrive", category: "LiveActivity")
                    .debug("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
                #endif
            }
        }
    }

    private func endAll() async {
        disconnectTask?.cancel()
        disconnectTask = nil
        activity = nil
        lastContent = nil
        for existing in Activity<LyricDriveActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }
}

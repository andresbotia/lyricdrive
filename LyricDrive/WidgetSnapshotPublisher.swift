//
//  WidgetSnapshotPublisher.swift
//  LyricDrive
//

import Combine
import CoreImage
import UIKit
import WidgetKit
import os

/// Writes the active service's normalized state to the App Group for LyricDrive's widgets, and
/// asks WidgetKit to reload them — only when something a widget shows has changed.
///
/// Reads the same sources as the iPhone UI and CarPlay (`NowPlayingStore`, `LyricsManager`,
/// `MusicSessionState`); it owns no playback or provider logic. Lyric line changes don't cause
/// writes: the snapshot carries the song's synced lines plus a playback anchor, and the widget
/// timeline schedules each line itself. A write happens on track, artwork, play/pause, lyrics,
/// provider, or connection changes, or when the playback anchor moves (a seek).
@MainActor
final class WidgetSnapshotPublisher {

    private let spotify: SpotifyManager
    private let appleMusic: AppleMusicManager
    private let nowPlaying: NowPlayingStore
    private let lyrics: LyricsManager
    private let isCarPlayConnected: () -> Bool
    private var cancellables = Set<AnyCancellable>()
    private var pendingWrite: Task<Void, Never>?
    private var lastWritten: WidgetSnapshot?
    /// Tracked from the lifecycle notifications: `applicationState` still reads `.active` while
    /// `willResignActive` is being delivered.
    private var isAppActive = UIApplication.shared.applicationState == .active
    /// The artwork file written for the current track, kept with its source image so each image
    /// is encoded once.
    private var writtenArtwork: (source: UIImage, trackID: String, fileName: String?, tint: [Double]?)?

    /// Anchor movements smaller than this are interpolation jitter, not seeks.
    private static let anchorTolerance: TimeInterval = 1.5
    private static let foregroundDelay: Duration = .milliseconds(400)
    /// In the background (e.g. driving with CarPlay) every reload counts against WidgetKit's
    /// daily budget, so a track change, its lyrics, and its artwork are coalesced into one.
    private static let backgroundDelay: Duration = .milliseconds(2500)
    private static let artworkPixelSide: CGFloat = 360

    init(
        spotify: SpotifyManager,
        appleMusic: AppleMusicManager,
        nowPlaying: NowPlayingStore,
        lyrics: LyricsManager,
        isCarPlayConnected: @escaping () -> Bool
    ) {
        self.spotify = spotify
        self.appleMusic = appleMusic
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.isCarPlayConnected = isCarPlayConnected

        let triggers: [AnyPublisher<Void, Never>] = [
            nowPlaying.$activeService.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            nowPlaying.$track.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            nowPlaying.$isPaused.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            nowPlaying.$artwork.map { $0.map(ObjectIdentifier.init) }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.$isConnected.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.$isConnecting.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.$isAutoReconnecting.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.$isWakingSpotify.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.$requiresSpotifyWake.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.$errorMessage.map { $0 != nil }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotify.hasPendingReconnectPublisher.map { _ in }.eraseToAnyPublisher(),
            appleMusic.$authorization.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            appleMusic.$isRequestingAuthorization.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            lyrics.$state.map { _ in }.eraseToAnyPublisher(),
            lyrics.$lines.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] in self?.scheduleWrite() }
            .store(in: &cancellables)

        // Ticks only matter when they reveal a seek; the check itself is a subtraction.
        nowPlaying.$playbackPositionMs
            .sink { [weak self] positionMs in
                guard let self, self.anchorMoved(toPositionMs: positionMs) else { return }
                self.scheduleWrite()
            }
            .store(in: &cancellables)

        // Leaving the foreground ends Spotify's App Remote connection (unless CarPlay keeps it)
        // and stops the local clocks, so record the final state now, before suspension.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.isAppActive = false
                self?.writeNow()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.isAppActive = true
                self?.scheduleWrite()
            }
            .store(in: &cancellables)

        scheduleWrite()
    }

    // MARK: - Scheduling

    /// `@Published` emits in `willSet`, so the write always reads settled values a moment later.
    private func scheduleWrite() {
        guard pendingWrite == nil else { return }
        let delay = isAppActive ? Self.foregroundDelay : Self.backgroundDelay
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.write()
        }
    }

    /// Writes immediately, e.g. after a widget playback command or before suspension.
    func writeNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    private func write() {
        let snapshot = makeSnapshot(now: Date())
        guard Self.differsMeaningfully(snapshot, from: lastWritten) else { return }
        WidgetSnapshotStore.save(snapshot)
        lastWritten = snapshot
        #if DEBUG
        Logger(subsystem: "com.andresbotia.LyricDrive", category: "Widgets").debug(
            "snapshot: \(snapshot.provider, privacy: .public) \(snapshot.status.rawValue, privacy: .public) track=\(snapshot.track?.id ?? "-", privacy: .public) paused=\(snapshot.isPaused) positionMs=\(snapshot.positionMs) live=\(snapshot.isLive) controls=\(snapshot.controlsAvailable) lyrics=\(snapshot.lyricsStatus.rawValue, privacy: .public) artwork=\(snapshot.artworkFileName != nil)"
        )
        #endif
        WidgetCenter.shared.reloadTimelines(ofKind: LyricDriveWidgetKind.lyrics)
        WidgetCenter.shared.reloadTimelines(ofKind: LyricDriveWidgetKind.compactLyrics)
        WidgetCenter.shared.reloadTimelines(ofKind: LyricDriveWidgetKind.playback)
    }

    private func anchorMoved(toPositionMs positionMs: Int) -> Bool {
        guard let lastWritten, lastWritten.isLive, lastWritten.track?.id == nowPlaying.track?.id else { return false }
        if lastWritten.isPaused != nowPlaying.isPaused { return false }
        if lastWritten.isPaused {
            return abs(positionMs - lastWritten.positionMs) > Int(Self.anchorTolerance * 1000)
        }
        let expected = lastWritten.estimatedPositionMs(at: Date())
        return abs(positionMs - expected) > Int(Self.anchorTolerance * 1000)
    }

    // MARK: - Snapshot

    /// Spotify's App Remote connection only lasts while LyricDrive is in the foreground or CarPlay
    /// is connected. Otherwise its snapshot is the last known state.
    private var isFollowingLive: Bool {
        isAppActive || isCarPlayConnected()
    }

    private func makeSnapshot(now: Date) -> WidgetSnapshot {
        let service = nowPlaying.activeService
        let current = nowPlaying.track
        let status: WidgetSnapshot.Status
        let isLive: Bool
        let controlsAvailable: Bool

        switch service {
        case .spotify:
            let session = MusicSessionState(spotify: spotify)
            switch session.phase {
            case .connected:
                status = current != nil ? .track : .noTrack
                isLive = isFollowingLive
            case .connecting, .reconnecting:
                status = current != nil ? .track : .connecting
                isLive = false
            case .disconnected, .needsUserAction:
                // Spotify keeps its last song after a disconnect; show it as last known.
                status = current != nil ? .track : .disconnected
                isLive = false
            case .notConnected:
                status = .needsSetup
                isLive = false
            }
            // Spotify commands need a live App Remote connection, which only exists while
            // LyricDrive is in the foreground or CarPlay is connected.
            controlsAvailable = status == .track && session.phase == .connected && isFollowingLive

        case .appleMusic:
            let session = MusicSessionState(appleMusic: appleMusic)
            switch session.phase {
            case .connected:
                // The system player's state is readable whenever LyricDrive runs, and the
                // manager's anchor stays valid while its clock is stopped in the background.
                status = current != nil ? .track : .noTrack
                isLive = true
            case .connecting:
                status = .connecting
                isLive = false
            default:
                status = session.appleMusicAuthorization == .denied || session.appleMusicAuthorization == .restricted
                    ? .accessDenied : .needsSetup
                isLive = false
            }
            // The system music player can be commanded whenever access is granted; the intent
            // runs in LyricDrive's process, which the system launches if needed.
            controlsAvailable = status == .track
        }

        let track = status == .track ? current : nil
        let artwork = track.map { prepareArtwork(for: $0.id) } ?? clearArtwork()

        var lyricsStatus = WidgetSnapshot.LyricsStatus.unavailable
        var lines: [WidgetSnapshot.Line] = []
        if track != nil {
            switch lyrics.state {
            case .idle, .loading:
                lyricsStatus = .loading
            case .synced where !lyrics.lines.isEmpty:
                lyricsStatus = .synced
                lines = lyrics.lines.map { WidgetSnapshot.Line(startMs: $0.startTimeMs, text: String($0.text.prefix(200))) }
            default:
                lyricsStatus = .unavailable
            }
        }

        var isPaused = nowPlaying.isPaused
        var positionMs = service == .appleMusic ? appleMusic.anchoredPositionMs : nowPlaying.playbackPositionMs
        var positionDate = now
        // Once LyricDrive stops receiving updates its own clock is no longer authoritative, so
        // later writes for the same song keep the timing captured when it was last live.
        if !isLive, let lastWritten, !lastWritten.isLive, lastWritten.status == .track,
           let track, lastWritten.track?.id == track.id {
            isPaused = lastWritten.isPaused
            positionMs = lastWritten.positionMs
            positionDate = lastWritten.positionDate
        }

        return WidgetSnapshot(
            provider: service.rawValue,
            providerName: service.displayName,
            status: status,
            track: track.map { WidgetSnapshot.Track(id: $0.id, title: $0.title, artist: $0.artist) },
            artworkFileName: artwork.fileName,
            tint: artwork.tint,
            isPaused: track == nil ? true : isPaused,
            lyricsStatus: lyricsStatus,
            lines: lines,
            positionMs: positionMs,
            positionDate: positionDate,
            durationMs: track?.durationMs ?? 0,
            isLive: isLive,
            controlsAvailable: controlsAvailable,
            writtenAt: now
        )
    }

    /// Only true changes count; the playback anchor counts only when it actually moved.
    private static func differsMeaningfully(_ snapshot: WidgetSnapshot, from previous: WidgetSnapshot?) -> Bool {
        guard let previous else { return true }
        var a = snapshot, b = previous
        a.positionMs = 0; a.positionDate = .distantPast; a.writtenAt = .distantPast
        b.positionMs = 0; b.positionDate = .distantPast; b.writtenAt = .distantPast
        if a != b { return true }
        guard snapshot.status == .track else { return false }
        let tolerance = Int(anchorTolerance * 1000)
        if snapshot.isPaused {
            return abs(snapshot.positionMs - previous.positionMs) > tolerance
        }
        return abs(snapshot.estimatedPositionMs(at: snapshot.positionDate) - previous.estimatedPositionMs(at: snapshot.positionDate)) > tolerance
    }

    // MARK: - Artwork

    /// Writes the current track's artwork once per image. `NowPlayingStore` clears artwork on
    /// every track and service change, so the image is always this track's.
    private func prepareArtwork(for trackID: String) -> (fileName: String?, tint: [Double]?) {
        guard let image = nowPlaying.artwork else { return clearArtwork() }
        if let writtenArtwork, writtenArtwork.source === image, writtenArtwork.trackID == trackID {
            return (writtenArtwork.fileName, writtenArtwork.tint)
        }
        let thumbnail = Self.thumbnail(of: image, pixelSide: Self.artworkPixelSide)
        let fileName = thumbnail.jpegData(compressionQuality: 0.85).flatMap {
            WidgetSnapshotStore.writeArtwork($0, trackID: trackID)
        }
        let tint = Self.averageColor(of: thumbnail)
        writtenArtwork = (image, trackID, fileName, tint)
        return (fileName, tint)
    }

    private func clearArtwork() -> (fileName: String?, tint: [Double]?) {
        if writtenArtwork != nil || lastWritten == nil {
            WidgetSnapshotStore.removeArtwork()
            writtenArtwork = nil
        }
        return (nil, nil)
    }

    /// Square, aspect-filled, at a size that's sharp in the largest widget without straining the
    /// widget extension's memory limit.
    private static func thumbnail(of image: UIImage, pixelSide: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = min(pixelSide, min(image.size.width * image.scale, image.size.height * image.scale))
        let canvas = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let fill = max(side / image.size.width, side / image.size.height)
            let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private static func averageColor(of image: UIImage) -> [Double]? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input,
                  kCIInputExtentKey: CIVector(cgRect: input.extent),
              ]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return pixel.prefix(3).map { Double($0) / 255 }
    }
}

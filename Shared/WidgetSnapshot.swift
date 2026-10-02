import Foundation

/// The App Group LyricDrive shares with its widget extension. Widgets run in their own process
/// and can't see the app's in-memory state or its standard defaults, so the app writes a small
/// snapshot (and the current artwork) here for them to read.
nonisolated enum LyricDriveAppGroup {
    static let identifier = "group.com.andresbotia.LyricDrive"

    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Widget kinds, shared so the app can reload exactly LyricDrive's widgets.
nonisolated enum LyricDriveWidgetKind {
    static let lyrics = "LyricDriveLyricsWidget"
    static let compactLyrics = "LyricDriveCompactLyricsWidget"
    static let playback = "LyricDrivePlaybackWidget"
}

/// What the widgets know about the active music service: written by the app on semantic
/// changes only (track, artwork, play/pause, lyrics, provider, connection), never per clock tick.
///
/// Playback position is stored as an anchor (`positionMs` at `positionDate`) so a widget
/// timeline can schedule each upcoming lyric line in advance. Those times are estimates: once
/// LyricDrive is suspended it can't see seeks, pauses, or skips made in the music app.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    nonisolated enum Status: String, Codable, Sendable {
        /// The active service has a current song (`track` is set).
        case track
        /// Connected, nothing playing.
        case noTrack
        /// Connecting or reconnecting, or waiting for the access prompt.
        case connecting
        /// The service has never been connected in LyricDrive.
        case needsSetup
        /// Spotify's saved session isn't connected and LyricDrive has no current song.
        case disconnected
        /// Apple Music access is denied or restricted.
        case accessDenied
    }

    nonisolated enum LyricsStatus: String, Codable, Sendable {
        case loading, synced, unavailable
    }

    nonisolated struct Track: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var artist: String
    }

    nonisolated struct Line: Codable, Equatable, Sendable {
        var startMs: Int
        var text: String
    }

    var version = Self.currentVersion
    /// `MusicService.rawValue` of the service this snapshot describes.
    var provider: String
    var providerName: String
    var status: Status
    var track: Track?
    /// File name in the App Group container; only ever this snapshot's track's artwork.
    var artworkFileName: String?
    /// An average color of the artwork (sRGB 0…1), for a soft background tint.
    var tint: [Double]?
    var isPaused: Bool
    var lyricsStatus: LyricsStatus
    /// Synced lines for the current track; empty unless `lyricsStatus == .synced`.
    var lines: [Line]
    var positionMs: Int
    var positionDate: Date
    var durationMs: Int
    /// `false` once LyricDrive has stopped receiving updates from the service (e.g. Spotify
    /// disconnected when the app left the foreground); the song then shows as last known.
    var isLive: Bool
    /// Whether Previous / Play-Pause / Next can reach the active service right now.
    var controlsAvailable: Bool
    var writtenAt: Date
}

extension WidgetSnapshot {
    /// Up to two lyric lines on each side of the current one.
    nonisolated struct LyricWindow: Equatable, Sendable {
        var previous2: String?
        var previous: String?
        var current: String?
        var next: String?
        var next2: String?
    }

    /// Estimated playback position, assuming playback continued uninterrupted since the snapshot.
    nonisolated func estimatedPositionMs(at date: Date) -> Int {
        guard !isPaused else { return positionMs }
        let elapsed = Int((date.timeIntervalSince(positionDate) * 1000).rounded())
        let position = positionMs + max(elapsed, 0)
        return durationMs > 0 ? min(position, durationMs) : position
    }

    /// When the current song is expected to end if it keeps playing; `nil` while paused or when
    /// the duration is unknown.
    nonisolated var estimatedEndDate: Date? {
        guard !isPaused, durationMs > 0 else { return nil }
        return positionDate.addingTimeInterval(Double(durationMs - positionMs) / 1000)
    }

    nonisolated func lyricWindow(at date: Date) -> LyricWindow {
        guard lyricsStatus == .synced, !lines.isEmpty else { return LyricWindow() }
        let position = estimatedPositionMs(at: date)
        func text(at index: Int) -> String? {
            lines.indices.contains(index) ? Self.displayText(lines[index].text) : nil
        }
        guard let index = lines.lastIndex(where: { $0.startMs <= position }) else {
            // Before the first timestamp: nothing is current yet; the first lines are next.
            return LyricWindow(current: nil, next: text(at: 0), next2: text(at: 1))
        }
        return LyricWindow(
            previous2: text(at: index - 2),
            previous: text(at: index - 1),
            current: text(at: index),
            next: text(at: index + 1),
            next2: text(at: index + 2)
        )
    }

    /// The dates after `start` at which the current lyric line changes, up to `end`.
    nonisolated func lineChangeDates(after start: Date, until end: Date, limit: Int) -> [Date] {
        guard !isPaused, lyricsStatus == .synced, !lines.isEmpty else { return [] }
        let startPosition = estimatedPositionMs(at: start)
        var dates: [Date] = []
        for line in lines where line.startMs > startPosition {
            // A few milliseconds late, so the entry's estimated position falls inside the line.
            let date = positionDate.addingTimeInterval(Double(line.startMs - positionMs) / 1000 + 0.05)
            guard date <= end, dates.count < limit else { break }
            dates.append(date)
        }
        return dates
    }

    /// Empty LRC lines mark instrumental breaks.
    nonisolated static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "♪" : trimmed
    }
}

/// Reads and writes the snapshot and its artwork in the App Group container.
nonisolated enum WidgetSnapshotStore {
    private static let snapshotKey = "widget.snapshot"
    private static let artworkPrefix = "widget-artwork-"

    static func load() -> WidgetSnapshot? {
        guard let data = LyricDriveAppGroup.defaults?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        LyricDriveAppGroup.defaults?.set(data, forKey: snapshotKey)
    }

    static func artworkURL(named fileName: String) -> URL? {
        LyricDriveAppGroup.containerURL?.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Writes the artwork for `trackID` under a per-track name and removes every other artwork
    /// file, so a widget can never pair one song's artwork with another song's snapshot.
    /// Returns the file name, or `nil` if it couldn't be written.
    static func writeArtwork(_ data: Data, trackID: String) -> String? {
        guard let container = LyricDriveAppGroup.containerURL else { return nil }
        let fileName = artworkPrefix + sanitized(trackID) + ".jpg"
        do {
            try data.write(to: container.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return nil
        }
        removeArtwork(except: fileName)
        return fileName
    }

    static func removeArtwork(except keep: String? = nil) {
        guard let container = LyricDriveAppGroup.containerURL,
              let files = try? FileManager.default.contentsOfDirectory(atPath: container.path) else { return }
        for file in files where file.hasPrefix(artworkPrefix) && file != keep {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(file))
        }
    }

    private static func sanitized(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(String(id.map { allowed.contains($0) ? $0 : "_" }).suffix(100))
    }
}

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

    /// The synced line current at song position `positionMs`; `nil` before the first timestamp
    /// or without synced lines.
    nonisolated func lineIndex(atPositionMs position: Int) -> Int? {
        guard lyricsStatus == .synced else { return nil }
        return lines.lastIndex { $0.startMs <= position }
    }

    /// The window around line `index`; `nil` means before the first line.
    nonisolated func lyricWindow(lineIndex index: Int?) -> LyricWindow {
        guard lyricsStatus == .synced, !lines.isEmpty else { return LyricWindow() }
        func text(at index: Int) -> String? {
            lines.indices.contains(index) ? Self.displayText(lines[index].text) : nil
        }
        guard let index else {
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

    /// One step of a lyric widget timeline: from `date`, line `lineIndex` is current.
    nonisolated struct LyricStep: Equatable, Sendable {
        var date: Date
        /// `nil` before the first line.
        var lineIndex: Int?
    }

    /// The lyric steps from `now` on, as absolute wall-clock dates on the playback anchor:
    ///
    ///     date = positionDate + (line.startMs − positionMs)
    ///
    /// The first step is `now`, with the line current then. Each later step is a line start
    /// after `now` and before `end`, with that line's index. Paused or unsynced snapshots get only
    /// the first step. `isComplete` is `false` when `limit` line steps cut the schedule short.
    nonisolated func lyricSchedule(from now: Date, until end: Date, limit: Int) -> (steps: [LyricStep], isComplete: Bool) {
        let nowPosition = estimatedPositionMs(at: now)
        var steps = [LyricStep(date: now, lineIndex: lineIndex(atPositionMs: nowPosition))]
        guard !isPaused, lyricsStatus == .synced else { return (steps, true) }
        for index in lines.indices where lines[index].startMs > nowPosition {
            let startMs = lines[index].startMs
            // Lines sharing a timestamp: only the last of them is ever current.
            if lines.indices.contains(index + 1), lines[index + 1].startMs == startMs { continue }
            let date = positionDate.addingTimeInterval(Double(startMs - positionMs) / 1000)
            guard date < end else { break }
            guard date > now else { continue }
            guard steps.count <= limit else { return (steps, false) }
            steps.append(LyricStep(date: date, lineIndex: index))
        }
        return (steps, true)
    }

    /// Empty LRC lines mark instrumental breaks.
    nonisolated static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "♪" : trimmed
    }
}

#if DEBUG
/// Debug builds only: a small log in the App Group shared by the app (snapshot writes) and the
/// widget extension (timeline builds), so a drive without Xcode attached can be read back
/// afterwards. The app prints and clears it when it becomes active.
nonisolated enum WidgetDebugLog {
    private static let key = "widget.debugLog"
    private static let limit = 400

    static func append(_ lines: [String]) {
        guard let defaults = LyricDriveAppGroup.defaults else { return }
        let stamp = timestamp(Date())
        var log = defaults.stringArray(forKey: key) ?? []
        log.append(contentsOf: lines.map { "\(stamp) \($0)" })
        defaults.set(Array(log.suffix(limit)), forKey: key)
    }

    static func drain() -> [String] {
        guard let defaults = LyricDriveAppGroup.defaults else { return [] }
        let log = defaults.stringArray(forKey: key) ?? []
        defaults.removeObject(forKey: key)
        return log
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
    }
}

extension WidgetSnapshot {
    /// Debug builds only: checks `lyricSchedule` against a fictional track with known answers.
    /// Returns report lines; the first says PASS or FAIL.
    nonisolated static func debugScheduleSelfCheck() -> [String] {
        let anchor = Date(timeIntervalSinceReferenceDate: 812_000_000) // a fixed, arbitrary date
        let lines = [(22_400, "Line zero"), (26_100, "Line one"), (28_900, "Line two"),
                     (31_500, "Line three"), (35_000, "Line four"), (39_200, "Line five"),
                     (44_750, "Line six"), (44_750, "Line six (same time)"), (52_000, "Line seven")]
        var snapshot = WidgetSnapshot(
            provider: "debug", providerName: "Debug", status: .track,
            track: Track(id: "debug:self-check", title: "Self Check", artist: "LyricDrive"),
            artworkFileName: nil, tint: nil, isPaused: false, lyricsStatus: .synced,
            lines: lines.map { Line(startMs: $0.0, text: $0.1) },
            positionMs: 30_000, positionDate: anchor, durationMs: 50_000,
            isLive: true, controlsAvailable: false, writtenAt: anchor
        )
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        // Playing, anchored at 30.0 s: line 2 now, then 3…6 at their offsets; line 7 is past the end.
        let end = anchor.addingTimeInterval(20)
        let playing = snapshot.lyricSchedule(from: anchor, until: end, limit: 150)
        let offsets = playing.steps.map { $0.date.timeIntervalSince(anchor) }
        check(playing.steps.map(\.lineIndex) == [2, 3, 4, 5, 7], "indices \(playing.steps.map(\.lineIndex))")
        check(zip(offsets, [0, 1.5, 5.0, 9.2, 14.75]).allSatisfy { abs($0 - $1) < 0.001 } && offsets.count == 5, "offsets \(offsets)")
        check(playing.isComplete, "playing schedule incomplete")

        // Built later from the same anchor: the past lines are skipped, the dates don't move.
        let later = snapshot.lyricSchedule(from: anchor.addingTimeInterval(6), until: end, limit: 150)
        check(later.steps.map(\.lineIndex) == [4, 5, 7], "later indices \(later.steps.map(\.lineIndex))")
        check(later.steps.dropFirst().first.map { abs($0.date.timeIntervalSince(anchor) - 9.2) < 0.001 } == true, "later dates moved")

        // The limit cuts the schedule short and says so.
        let limited = snapshot.lyricSchedule(from: anchor, until: end, limit: 2)
        check(limited.steps.count == 3 && !limited.isComplete, "limit \(limited.steps.count) \(limited.isComplete)")

        // Paused: only the current line.
        snapshot.isPaused = true
        let paused = snapshot.lyricSchedule(from: anchor.addingTimeInterval(60), until: end.addingTimeInterval(60), limit: 150)
        check(paused.steps.map(\.lineIndex) == [2], "paused \(paused.steps.map(\.lineIndex))")

        var report = [failures.isEmpty ? "schedule self-check PASS" : "schedule self-check FAIL: \(failures.joined(separator: "; "))"]
        report += playing.steps.map { "  +\(String(format: "%.3f", $0.date.timeIntervalSince(anchor)))s -> line \($0.lineIndex.map(String.init) ?? "-")" }
        return report
    }
}
#endif

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

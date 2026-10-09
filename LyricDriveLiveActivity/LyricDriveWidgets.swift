import AppIntents
import SwiftUI
import UIKit
import WidgetKit
#if DEBUG
import os
#endif

// MARK: - Timeline

struct LyricDriveEntry: TimelineEntry {
    let date: Date
    /// `nil` until LyricDrive has written its first snapshot (the app hasn't been opened yet).
    let snapshot: WidgetSnapshot?
    /// The song shown may no longer be what's playing: an estimated song end has passed, or a
    /// paused snapshot is old.
    let isStale: Bool
    /// The synced line this entry shows, fixed when the timeline was built (`nil` before the
    /// first line), so each entry renders on its own without recomputing playback position.
    let lineIndex: Int?

    init(date: Date, snapshot: WidgetSnapshot?, isStale: Bool, lineIndex: Int?) {
        self.date = date
        self.snapshot = snapshot
        self.isStale = isStale
        self.lineIndex = lineIndex
    }

    /// The line from the snapshot's playback anchor at `date` (placeholders, snapshots, previews).
    init(date: Date, snapshot: WidgetSnapshot?, isStale: Bool) {
        let lineIndex = snapshot.flatMap { $0.lineIndex(atPositionMs: $0.estimatedPositionMs(at: date)) }
        self.init(date: date, snapshot: snapshot, isStale: isStale, lineIndex: lineIndex)
    }

    var lyricWindow: WidgetSnapshot.LyricWindow {
        snapshot?.lyricWindow(lineIndex: lineIndex) ?? .init()
    }
}

/// Builds timelines from the snapshot LyricDrive writes to the App Group.
///
/// While a song with synced lyrics is playing, lyric widgets get one entry per remaining line,
/// dated in wall-clock time from the snapshot's playback anchor
/// (`positionDate + (line.startMs − positionMs)`), each carrying its own line index — so lines
/// keep advancing after iOS suspends LyricDrive. They are estimates: a pause, seek, or skip made
/// in the music app while LyricDrive is suspended isn't seen until the app runs again. After the
/// last entry (the estimated song end, or the last line scheduled) WidgetKit asks for a new
/// timeline, which picks up any snapshot written since.
struct LyricDriveTimelineProvider: TimelineProvider {
    /// Only used in debug logs.
    let kind: String
    /// Lyric widgets schedule an entry per line; the playback widget doesn't need them.
    let schedulesLyricLines: Bool

    private static let maxLineEntries = 150
    private static let horizon: TimeInterval = 30 * 60
    /// A paused song this old is probably not what the music app has queued anymore.
    private static let pausedStaleAfter: TimeInterval = 3 * 60 * 60
    private static let endGrace: TimeInterval = 5

    func placeholder(in context: Context) -> LyricDriveEntry {
        LyricDriveEntry(date: Date(), snapshot: .preview, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricDriveEntry) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.load() ?? (context.isPreview ? .preview : nil)
        completion(LyricDriveEntry(date: now, snapshot: snapshot, isStale: snapshot.map { Self.isStale($0, at: now) } ?? false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricDriveEntry>) -> Void) {
        let timeline = makeTimeline(now: Date(), snapshot: WidgetSnapshotStore.load())
        #if DEBUG
        log(timeline, family: context.family)
        #endif
        completion(timeline)
    }

    private func makeTimeline(now: Date, snapshot: WidgetSnapshot?) -> Timeline<LyricDriveEntry> {
        guard let snapshot else {
            return Timeline(entries: [LyricDriveEntry(date: now, snapshot: nil, isStale: false)], policy: .never)
        }
        guard snapshot.status == .track, !Self.isStale(snapshot, at: now) else {
            // Nothing to schedule; LyricDrive reloads the widgets itself when this changes.
            return Timeline(entries: [LyricDriveEntry(date: now, snapshot: snapshot, isStale: Self.isStale(snapshot, at: now))], policy: .never)
        }

        // `nil` while playing a song of unknown duration: lines are still scheduled, up to the
        // horizon, but there's no estimated end to mark the song stale at.
        let staleDate = Self.staleDate(for: snapshot)
        let horizonEnd = now.addingTimeInterval(Self.horizon)
        let scheduleEnd = min(staleDate ?? horizonEnd, horizonEnd)
        let schedule = schedulesLyricLines
            ? snapshot.lyricSchedule(from: now, until: scheduleEnd, limit: Self.maxLineEntries)
            : (steps: [WidgetSnapshot.LyricStep(date: now, lineIndex: nil)], isComplete: true)

        var entries = schedule.steps.map {
            LyricDriveEntry(date: $0.date, snapshot: snapshot, isStale: false, lineIndex: $0.lineIndex)
        }
        let lastLine = entries.last?.lineIndex
        let reachedHorizon = schedulesLyricLines && !snapshot.isPaused && scheduleEnd < (staleDate ?? .distantFuture)
        if !schedule.isComplete {
            // Too many lines: the reload after the last one continues from the same anchor.
        } else if reachedHorizon {
            // A very long song, or one of unknown duration: hold the last line until the horizon,
            // then continue from the same anchor.
            if scheduleEnd > entries[entries.count - 1].date {
                entries.append(LyricDriveEntry(date: scheduleEnd, snapshot: snapshot, isStale: false, lineIndex: lastLine))
            }
        } else if let staleDate {
            entries.append(LyricDriveEntry(date: staleDate, snapshot: snapshot, isStale: true, lineIndex: lastLine))
        }
        // After the last entry WidgetKit asks again, picking up any snapshot written since (e.g. one
        // whose reload request iOS deferred). Never a per-line or per-second reload.
        return Timeline(entries: entries, policy: entries.count > 1 ? .atEnd : .never)
    }

    private static func staleDate(for snapshot: WidgetSnapshot) -> Date? {
        if snapshot.isPaused {
            return snapshot.writtenAt.addingTimeInterval(pausedStaleAfter)
        }
        return snapshot.estimatedEndDate?.addingTimeInterval(endGrace)
    }

    private static func isStale(_ snapshot: WidgetSnapshot, at date: Date) -> Bool {
        guard snapshot.status == .track, let staleDate = staleDate(for: snapshot) else { return false }
        return date >= staleDate
    }

    #if DEBUG
    private func log(_ timeline: Timeline<LyricDriveEntry>, family: WidgetFamily) {
        let entries = timeline.entries
        let policy = switch timeline.policy {
        case .atEnd: "atEnd"
        case .never: "never"
        default: "after"
        }
        var lines: [String]
        if let snapshot = entries.first?.snapshot {
            let now = entries[0].date
            lines = [
                "timeline \(kind) \(family) provider=\(snapshot.provider) status=\(snapshot.status.rawValue) song=\(snapshot.track?.id ?? "-") \"\(snapshot.track?.title ?? "-")\"",
                "  anchor positionMs=\(snapshot.positionMs) at \(WidgetDebugLog.timestamp(snapshot.positionDate)) (written \(WidgetDebugLog.timestamp(snapshot.writtenAt))) estimatedNowMs=\(snapshot.estimatedPositionMs(at: now)) durationMs=\(snapshot.durationMs) paused=\(snapshot.isPaused) live=\(snapshot.isLive) lyrics=\(snapshot.lyricsStatus.rawValue)",
                "  currentLine=\(entries[0].lineIndex.map(String.init) ?? "-") of \(snapshot.lines.count) entries=\(entries.count) first=\(WidgetDebugLog.timestamp(now)) last=\(WidgetDebugLog.timestamp(entries[entries.count - 1].date)) policy=\(policy)",
            ]
            for entry in entries.prefix(6) {
                let text = entry.lineIndex.flatMap { snapshot.lines.indices.contains($0) ? snapshot.lines[$0].text : nil } ?? ""
                lines.append("    \(WidgetDebugLog.timestamp(entry.date)) line=\(entry.lineIndex.map(String.init) ?? "-") stale=\(entry.isStale) \"\(text.prefix(28))\"")
            }
        } else {
            lines = ["timeline \(kind) \(family) no snapshot entries=\(entries.count) policy=\(policy)"]
        }
        let logger = Logger(subsystem: "com.andresbotia.LyricDrive", category: "WidgetTimeline")
        for line in lines { logger.debug("\(line, privacy: .public)") }
        WidgetDebugLog.append(lines)
    }
    #endif
}

// MARK: - Widgets

struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricDriveWidgetKind.lyrics, provider: LyricDriveTimelineProvider(kind: LyricDriveWidgetKind.lyrics, schedulesLyricLines: true)) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyrics")
        .description("The current synced lyric, with the lines around it.")
        // Small is the lyrics-only layout made for CarPlay (and StandBy). On the Home Screen the
        // small spot belongs to Lyric Glance, so small Lyrics isn't offered there.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .disfavoredLocations([.homeScreen], for: [.systemSmall])
        .contentMarginsDisabled()
    }
}

struct CompactLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricDriveWidgetKind.compactLyrics, provider: LyricDriveTimelineProvider(kind: LyricDriveWidgetKind.compactLyrics, schedulesLyricLines: true)) { entry in
            CompactLyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyric Glance")
        .description("Just the current synced lyric.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct PlaybackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricDriveWidgetKind.playback, provider: LyricDriveTimelineProvider(kind: LyricDriveWidgetKind.playback, schedulesLyricLines: false)) { entry in
            PlaybackWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The current song, with previous, play/pause, and next.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Style

private enum WidgetStyle {
    static let night = Color(red: 0.024, green: 0.027, blue: 0.039)
    static let aurora = Color(red: 0.215, green: 0.825, blue: 0.948)
    static let textPrimary = Color(red: 0.949, green: 0.953, blue: 0.965)
    static let textSecondary = textPrimary.opacity(0.66)
    static let textTertiary = textPrimary.opacity(0.42)

    static func tint(_ snapshot: WidgetSnapshot?) -> Color? {
        guard let tint = snapshot?.tint, tint.count == 3 else { return nil }
        return Color(red: tint[0], green: tint[1], blue: tint[2])
    }
}

/// Dark LyricDrive surface with a soft glow from the artwork's average color.
private struct WidgetBackground: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        ZStack {
            WidgetStyle.night
            if let tint = WidgetStyle.tint(snapshot) {
                LinearGradient(
                    colors: [tint.opacity(0.55), tint.opacity(0.18), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
    }
}

private extension View {
    func lyricDriveBackground(_ snapshot: WidgetSnapshot?) -> some View {
        containerBackground(for: .widget) { WidgetBackground(snapshot: snapshot) }
    }
}

private struct ArtworkThumbnail: View {
    let snapshot: WidgetSnapshot?
    let size: CGFloat

    var body: some View {
        let radius = size * 0.2
        Group {
            if let image = artwork {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.36)).foregroundStyle(.white.opacity(0.35)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .accessibilityHidden(true)
    }

    /// Only ever the snapshot's own track's file (see `WidgetSnapshotStore.writeArtwork`).
    private var artwork: UIImage? {
        guard let snapshot, snapshot.track != nil, let name = snapshot.artworkFileName,
              let url = WidgetSnapshotStore.artworkURL(named: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - Shared state copy

/// What a widget shows instead of lyrics or controls.
private struct WidgetMessage {
    let symbol: String
    let title: String
    let detail: String?

    /// `nil` when there's a current, fresh song to show.
    static func forEntry(_ entry: LyricDriveEntry) -> WidgetMessage? {
        guard let snapshot = entry.snapshot else {
            return WidgetMessage(symbol: "music.note", title: "Open LyricDrive to get started", detail: nil)
        }
        let name = snapshot.providerName
        switch snapshot.status {
        case .track:
            return entry.isStale ? WidgetMessage(symbol: "arrow.clockwise", title: "Open LyricDrive to refresh", detail: nil) : nil
        case .noTrack:
            return WidgetMessage(symbol: "music.note", title: "No song playing", detail: "Play something in \(name)")
        case .connecting:
            return WidgetMessage(symbol: "ellipsis", title: "Connecting to \(name)…", detail: nil)
        case .needsSetup:
            return WidgetMessage(symbol: "link", title: "Open LyricDrive to connect", detail: nil)
        case .disconnected:
            return WidgetMessage(symbol: "arrow.clockwise", title: "\(name) isn't connected", detail: "Open LyricDrive to reconnect")
        case .accessDenied:
            return WidgetMessage(symbol: "lock.fill", title: "Apple Music access is off", detail: "Turn it on in Settings")
        }
    }

    /// Lyric-specific status for a current song, or `nil` when synced lyrics are showing.
    static func forLyrics(_ snapshot: WidgetSnapshot) -> String? {
        switch snapshot.lyricsStatus {
        case .loading: "Finding synced lyrics…"
        case .unavailable: "Synced lyrics unavailable"
        case .synced: nil
        }
    }
}

private struct MessageView: View {
    let message: WidgetMessage
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Image(systemName: message.symbol)
                .font(.system(size: compact ? 15 : 18, weight: .semibold))
                .foregroundStyle(WidgetStyle.aurora)
            Text(message.title)
                .font((compact ? Font.subheadline : .headline).weight(.semibold))
                .foregroundStyle(WidgetStyle.textPrimary)
                .lineLimit(3)
            if let detail = message.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(WidgetStyle.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - Lyrics widget

struct LyricsWidgetView: View {
    let entry: LyricDriveEntry
    @Environment(\.widgetFamily) private var family
    /// `false` where the system removes widget backgrounds — CarPlay and StandBy. WidgetKit has
    /// no public way to tell those two apart at render time (`WidgetLocation` is only used for
    /// `disfavoredLocations`), so both get the glanceable layout.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.widgetContentMargins) private var contentMargins

    private var isLarge: Bool { family == .systemLarge }

    /// Lyrics only, using the whole widget: the small size, and anywhere without a background.
    private var isFocused: Bool { family == .systemSmall || !showsBackground }

    var body: some View {
        if isFocused {
            FocusedLyricsView(content: focusedContent)
                .padding(contentMargins)
                // Plain, high-contrast surface where a background is shown; no artwork tint.
                .containerBackground(for: .widget) { WidgetStyle.night }
        } else {
            content
                .padding(isLarge ? 20 : 16)
                .lyricDriveBackground(entry.snapshot)
        }
    }

    private var focusedContent: FocusedLyricsView.Content {
        guard let snapshot = entry.snapshot else { return .message("Open LyricDrive to get started") }
        switch snapshot.status {
        case .track:
            if entry.isStale { return .message("Open LyricDrive to refresh") }
            if let status = WidgetMessage.forLyrics(snapshot) { return .message(status) }
            return .lyrics(entry.lyricWindow)
        case .noTrack: return .message("No song playing")
        case .connecting: return .message("Connecting to \(snapshot.providerName)…")
        case .needsSetup: return .message("Open LyricDrive to connect")
        case .disconnected: return .message("Open LyricDrive to reconnect \(snapshot.providerName)")
        case .accessDenied: return .message("Apple Music access is off")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let message = WidgetMessage.forEntry(entry) {
            VStack(alignment: .leading, spacing: 0) {
                if entry.isStale, let snapshot = entry.snapshot { header(snapshot) }
                MessageView(message: message)
            }
        } else if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                header(snapshot)
                Spacer(minLength: isLarge ? 12 : 6)
                if let status = WidgetMessage.forLyrics(snapshot) {
                    Text(status)
                        .font(.headline)
                        .foregroundStyle(WidgetStyle.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    lyrics(entry.lyricWindow)
                }
            }
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(snapshot: snapshot, size: isLarge ? 40 : 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.track?.title ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetStyle.textSecondary)
                Text(snapshot.track?.artist ?? "")
                    .font(.caption2)
                    .foregroundStyle(WidgetStyle.textTertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if snapshot.isPaused, !entry.isStale {
                Image(systemName: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(WidgetStyle.textTertiary)
                    .accessibilityLabel("Paused")
            }
        }
    }

    private func lyrics(_ window: WidgetSnapshot.LyricWindow) -> some View {
        VStack(alignment: .leading, spacing: isLarge ? 10 : 5) {
            if isLarge, let previous = window.previous {
                Text(previous)
                    .font(.subheadline)
                    .foregroundStyle(WidgetStyle.textTertiary)
                    .lineLimit(2)
            }
            Text(window.current ?? "♪")
                .font(.system(isLarge ? .title : .title3, design: .rounded, weight: .bold))
                .foregroundStyle(WidgetStyle.textPrimary)
                .lineLimit(isLarge ? 4 : 2)
                .minimumScaleFactor(0.75)
                .shadow(color: WidgetStyle.aurora.opacity(0.25), radius: 10)
            if let next = window.next {
                Text(next)
                    .font(isLarge ? .headline : .subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(WidgetStyle.textSecondary)
                    .lineLimit(isLarge ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - Compact lyrics widget

struct CompactLyricsWidgetView: View {
    let entry: LyricDriveEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular {
            accessory
                .containerBackground(for: .widget) { Color.clear }
        } else {
            small
                .padding(14)
                .lyricDriveBackground(entry.snapshot)
        }
    }

    @ViewBuilder
    private var small: some View {
        if let message = WidgetMessage.forEntry(entry) {
            MessageView(message: message, compact: true)
        } else if let snapshot = entry.snapshot, let status = WidgetMessage.forLyrics(snapshot) {
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WidgetStyle.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            let window = entry.lyricWindow
            VStack(alignment: .leading, spacing: 6) {
                Text(window.current ?? "♪")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(WidgetStyle.textPrimary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                if let next = window.next {
                    Text(next)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(WidgetStyle.textTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// Lock Screen: system-tinted, no background, just the line.
    @ViewBuilder
    private var accessory: some View {
        let text: String = if let message = WidgetMessage.forEntry(entry) {
            message.title
        } else if let snapshot = entry.snapshot, let status = WidgetMessage.forLyrics(snapshot) {
            status
        } else {
            entry.lyricWindow.current ?? "♪"
        }
        Text(text)
            .font(.headline)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetAccentable()
    }
}

// MARK: - Playback widget

struct PlaybackWidgetView: View {
    let entry: LyricDriveEntry
    @Environment(\.widgetFamily) private var family

    private var isMedium: Bool { family == .systemMedium }

    var body: some View {
        content
            .padding(isMedium ? 16 : 14)
            .lyricDriveBackground(entry.snapshot)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot, snapshot.status == .track, let track = snapshot.track {
            if isMedium {
                HStack(spacing: 14) {
                    ArtworkThumbnail(snapshot: snapshot, size: 108)
                    VStack(alignment: .leading, spacing: 0) {
                        metadata(track, titleLines: 2)
                        Spacer(minLength: 8)
                        controls(snapshot)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ArtworkThumbnail(snapshot: snapshot, size: 44)
                    Spacer(minLength: 6)
                    metadata(track, titleLines: 1)
                    Spacer(minLength: 8)
                    controls(snapshot)
                }
            }
        } else if let message = WidgetMessage.forEntry(entry) {
            MessageView(message: message, compact: !isMedium)
        }
    }

    private func metadata(_ track: WidgetSnapshot.Track, titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .font(.headline)
                .foregroundStyle(WidgetStyle.textPrimary)
                .lineLimit(titleLines)
            Text(track.artist)
                .font(.subheadline)
                .foregroundStyle(WidgetStyle.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Real interactive buttons (App Intents), only when LyricDrive can reach the service.
    /// Otherwise the widget says so; tapping it opens LyricDrive.
    @ViewBuilder
    private func controls(_ snapshot: WidgetSnapshot) -> some View {
        if entry.isStale {
            Text("Open LyricDrive to refresh")
                .font(.caption)
                .foregroundStyle(WidgetStyle.textTertiary)
                .lineLimit(2)
        } else if snapshot.controlsAvailable {
            HStack(spacing: 0) {
                Button(intent: PreviousTrackIntent()) { controlLabel("backward.fill", prominent: false) }
                    .accessibilityLabel("Previous")
                Spacer(minLength: 0)
                Button(intent: TogglePlaybackIntent()) {
                    controlLabel(snapshot.isPaused ? "play.fill" : "pause.fill", prominent: true)
                }
                .accessibilityLabel(snapshot.isPaused ? "Play" : "Pause")
                Spacer(minLength: 0)
                Button(intent: NextTrackIntent()) { controlLabel("forward.fill", prominent: false) }
                    .accessibilityLabel("Next")
            }
            .buttonStyle(.plain)
        } else {
            Text("Open LyricDrive to control \(snapshot.providerName)")
                .font(.caption)
                .foregroundStyle(WidgetStyle.textTertiary)
                .lineLimit(2)
        }
    }

    private func controlLabel(_ symbol: String, prominent: Bool) -> some View {
        let side: CGFloat = prominent ? (isMedium ? 44 : 38) : (isMedium ? 36 : 30)
        return Image(systemName: symbol)
            .font(.system(size: prominent ? side * 0.4 : side * 0.42, weight: .semibold))
            .foregroundStyle(prominent ? WidgetStyle.night : WidgetStyle.textPrimary)
            .frame(width: side, height: side)
            .background(Circle().fill(prominent ? WidgetStyle.textPrimary : .white.opacity(0.1)))
            .contentShape(Circle())
    }
}

// MARK: - Preview data

extension WidgetSnapshot {
    /// Widget gallery placeholder. Generic text, no real song.
    static var preview: WidgetSnapshot {
        WidgetSnapshot(
            provider: "spotify",
            providerName: "Spotify",
            status: .track,
            track: Track(id: "preview", title: "Midnight Drive", artist: "LyricDrive"),
            artworkFileName: nil,
            tint: [0.05, 0.45, 0.75],
            isPaused: true,
            lyricsStatus: .synced,
            lines: [
                Line(startMs: 0, text: "Headlights cutting through the rain"),
                Line(startMs: 8_000, text: "Every exit looks the same"),
                Line(startMs: 16_000, text: "Radio low, the city's asleep"),
                Line(startMs: 24_000, text: "Promises I meant to keep"),
                Line(startMs: 32_000, text: "Mile markers counting down"),
            ],
            positionMs: 17_000,
            positionDate: Date(),
            durationMs: 210_000,
            isLive: true,
            controlsAvailable: true,
            writtenAt: Date()
        )
    }
}

// MARK: - Previews

#Preview("Lyrics · small", as: .systemSmall) {
    LyricsWidget()
} timeline: {
    LyricDriveEntry(date: .now, snapshot: .preview, isStale: false)
    LyricDriveEntry(date: .now, snapshot: .previewLongLines, isStale: false)
    LyricDriveEntry(date: .now, snapshot: nil, isStale: false)
}

#Preview("Lyrics · medium", as: .systemMedium) {
    LyricsWidget()
} timeline: {
    LyricDriveEntry(date: .now, snapshot: .preview, isStale: false)
}

#Preview("Lyrics · large", as: .systemLarge) {
    LyricsWidget()
} timeline: {
    LyricDriveEntry(date: .now, snapshot: .preview, isStale: false)
}

#Preview("Lyric Glance · small", as: .systemSmall) {
    CompactLyricsWidget()
} timeline: {
    LyricDriveEntry(date: .now, snapshot: .preview, isStale: false)
}

extension WidgetSnapshot {
    /// Preview only: long wrapping lines, to exercise the focused layout's fallbacks.
    static var previewLongLines: WidgetSnapshot {
        var snapshot = preview
        snapshot.lines = [
            Line(startMs: 0, text: "Headlights cutting through the rain on an empty road"),
            Line(startMs: 4_000, text: "Every exit looks the same when you're this far from home tonight"),
            Line(startMs: 8_000, text: "Radio low, the city's asleep and the stars are burning out one by one"),
            Line(startMs: 12_000, text: "Promises I meant to keep are folded in the glovebox"),
            Line(startMs: 16_000, text: "Mile markers counting down"),
        ]
        snapshot.positionMs = 9_000
        return snapshot
    }
}

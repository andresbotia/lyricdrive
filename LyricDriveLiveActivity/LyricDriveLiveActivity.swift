import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LyricDriveLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LyricDriveLiveActivity()
    }
}

/// The lyric Live Activity. It only renders the window the app sends: no timeline, no position
/// math, no controls, no artwork. The `.small` family is what CarPlay (and Apple Watch) shows,
/// so it gets the full five-line treatment; the Lock Screen and Dynamic Island stay compact.
struct LyricDriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricDriveActivityAttributes.self) { context in
            LyricActivityView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(LyricPalette.background)
                .activitySystemActionForegroundColor(LyricPalette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LyricPalette.text.opacity(0.6))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedIslandView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(LyricPalette.accent)
            } compactTrailing: {
                Image(systemName: context.isStale || context.state.isPaused ? "pause.fill" : "waveform")
                    .foregroundStyle(LyricPalette.accent)
            } minimal: {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(LyricPalette.accent)
            }
            .keylineTint(LyricPalette.accent)
        }
        .supplementalActivityFamilies([.small])
    }
}

enum LyricPalette {
    static let background = Color(red: 0.024, green: 0.027, blue: 0.039)
    static let text = Color(red: 0.949, green: 0.953, blue: 0.965)
    static let accent = Color(red: 0.215, green: 0.825, blue: 0.948)
}

// MARK: - Families

private struct LyricActivityView: View {
    let state: LyricDriveActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            CarPlayLyricsView(state: state, isStale: isStale)
        default:
            LockScreenLyricsView(state: state, isStale: isStale)
        }
    }
}

/// CarPlay Dashboard (and Apple Watch): lyrics fill the space; a message replaces them when
/// there's nothing live to show.
private struct CarPlayLyricsView: View {
    let state: LyricDriveActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let message = ActivityMessage(state: state, isStale: isStale) {
                    MessageView(title: state.title, message: message.text, scale: LyricMetrics(height: proxy.size.height))
                } else {
                    FittingLyricWindow(state: state, metrics: LyricMetrics(height: proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Lock Screen: song title, then previous / current / next when they fit.
private struct LockScreenLyricsView: View {
    let state: LyricDriveActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(state.artist.isEmpty ? state.title : "\(state.title) · \(state.artist)")
                    .lineLimit(1)
                if state.isPaused && !isStale {
                    Image(systemName: "pause.fill")
                        .accessibilityLabel("Paused")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(LyricPalette.text.opacity(0.55))

            if let message = ActivityMessage(state: state, isStale: isStale) {
                Text(message.text)
                    .font(.headline)
                    .foregroundStyle(LyricPalette.text)
                    .lineLimit(2)
            } else {
                FittingLyricWindow(state: state, metrics: .lockScreen, maxPrevious: 1, maxNext: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// Dynamic Island, expanded: the current line and the next one. Never the full window.
private struct ExpandedIslandView: View {
    let state: LyricDriveActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = ActivityMessage(state: state, isStale: isStale) {
                Text(message.text)
                    .font(.headline)
                    .foregroundStyle(LyricPalette.text)
                    .lineLimit(2)
            } else {
                FittingLyricWindow(state: state, metrics: .island, maxPrevious: 0, maxNext: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}

// MARK: - Messages

/// What replaces the lyric window when there's no live line to show.
private struct ActivityMessage {
    let text: String

    init?(state: LyricDriveActivityAttributes.ContentState, isStale: Bool) {
        if isStale {
            // Stale only when the song should have ended (or stayed paused for a long time)
            // without LyricDrive sending anything newer.
            text = "Open LyricDrive to resume lyrics"
            return
        }
        switch state.status {
        case .lyrics: return nil
        case .findingLyrics: text = "Finding synced lyrics…"
        case .noLyrics: text = "No synced lyrics for this song"
        }
    }
}

private struct MessageView: View {
    let title: String
    let message: String
    let scale: LyricMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: scale.outer, weight: .semibold))
                .foregroundStyle(LyricPalette.text.opacity(0.55))
                .lineLimit(1)
            Text(message)
                .font(.system(size: scale.near, weight: .semibold))
                .foregroundStyle(LyricPalette.text)
                .lineLimit(2)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Lyric window

/// Type sizes for one surface. CarPlay's are derived from the space the system gives the
/// activity, within ranges that stay readable at a glance without becoming oversized.
struct LyricMetrics {
    var current: CGFloat
    var near: CGFloat
    var outer: CGFloat
    var spacing: CGFloat

    init(current: CGFloat, near: CGFloat, outer: CGFloat, spacing: CGFloat) {
        self.current = current
        self.near = near
        self.outer = outer
        self.spacing = spacing
    }

    init(height: CGFloat) {
        let current = min(max(height * 0.15, 17), 21)
        self.init(
            current: current,
            near: min(max(current * 0.8, 14), 17),
            outer: min(max(current * 0.66, 12), 14),
            spacing: min(max(height * 0.02, 2), 5)
        )
    }

    static let lockScreen = LyricMetrics(current: 20, near: 15, outer: 13, spacing: 4)
    static let island = LyricMetrics(current: 17, near: 14, outer: 12, spacing: 3)

    /// The "shrink slightly" step, used only after the outer lines are gone.
    var reduced: LyricMetrics {
        LyricMetrics(current: current * 0.9, near: near * 0.9, outer: outer * 0.9, spacing: max(spacing - 1, 1))
    }
}

/// Picks the richest version of the window that fits. In order: everything; then drop the
/// farthest upcoming line, then the farthest previous line, alternating until only one line
/// remains on each side; then slightly smaller type; then fewer lines. The current line is never
/// dropped and may wrap to two lines.
private struct FittingLyricWindow: View {
    let state: LyricDriveActivityAttributes.ContentState
    let metrics: LyricMetrics
    var maxPrevious = 4
    var maxNext = 4

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                LyricStack(previous: candidate.previous, current: state.currentLine, next: candidate.next, metrics: candidate.metrics, isPaused: state.isPaused)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Candidate {
        let previous: [String]
        let next: [String]
        let metrics: LyricMetrics
    }

    private var candidates: [Candidate] {
        var previous = Array(state.previousLines.suffix(maxPrevious))
        var next = Array(state.nextLines.prefix(maxNext))
        var result = [Candidate(previous: previous, next: next, metrics: metrics)]
        while previous.count > 1 || next.count > 1 {
            if next.count > 1 && next.count >= previous.count {
                next.removeLast()
            } else if previous.count > 1 {
                previous.removeFirst()
            } else {
                next.removeLast()
            }
            result.append(Candidate(previous: previous, next: next, metrics: metrics))
        }
        let reduced = metrics.reduced
        result.append(Candidate(previous: previous, next: next, metrics: reduced))
        result.append(Candidate(previous: [], next: next, metrics: reduced))
        result.append(Candidate(previous: [], next: [], metrics: reduced))
        return result
    }
}

private struct LyricStack: View {
    let previous: [String]
    let current: String
    let next: [String]
    let metrics: LyricMetrics
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            ForEach(Array(previous.enumerated()), id: \.offset) { index, line in
                context(line, distance: previous.count - index)
            }
            Text(current)
                .font(.system(size: metrics.current, weight: .bold, design: .rounded))
                .foregroundStyle(LyricPalette.text.opacity(isPaused ? 0.7 : 1))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(next.enumerated()), id: \.offset) { index, line in
                context(line, distance: index + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func context(_ line: String, distance: Int) -> some View {
        Text(line)
            .font(.system(size: distance == 1 ? metrics.near : metrics.outer, weight: .semibold, design: .rounded))
            .foregroundStyle(LyricPalette.text.opacity(distance == 1 ? 0.6 : 0.34))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

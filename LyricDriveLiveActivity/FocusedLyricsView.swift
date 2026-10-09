import SwiftUI

/// The Lyrics widget's glanceable layout: lyrics only, using the whole widget, for places where
/// the widget is read at a distance — CarPlay and StandBy (where the system removes the widget
/// background) and the small size.
///
/// Up to five rows — two lines before, the current line, two after — with emphasis falling off
/// away from the current line. Sizes follow the widget's height, compact enough that five rows
/// usually fit: when long lines wrap and five don't, context gives way in priority order (wrapped
/// context to one line, next +2, previous −2, then the next line) before the current line is ever
/// truncated. No
/// metadata, artwork, or animation, and no reliance on the background for contrast.
struct FocusedLyricsView: View {
    enum Content: Equatable {
        case lyrics(WidgetSnapshot.LyricWindow)
        /// A status in place of lyrics (no song, no synced lyrics, needs the app, …).
        case message(String)
    }

    let content: Content

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(height: proxy.size.height)
            Group {
                switch content {
                case .lyrics(let window):
                    lyrics(window, metrics)
                case .message(let text):
                    Text(text)
                        .font(.system(size: metrics.current, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    // MARK: Layout

    /// Text sizes derived from the available height, within readable bounds. Sized so five rows
    /// usually fit at once: context matters more at a glance than one oversized line.
    private struct Metrics {
        let current: CGFloat
        let near: CGFloat
        let far: CGFloat
        let spacing: CGFloat

        init(height: CGFloat) {
            current = min(max(height * 0.11, 18), 24)
            near = min(max(current * 0.74, 14), 18)
            far = min(max(current * 0.62, 13), 15)
            spacing = max(current * 0.2, 3)
        }
    }

    private enum Role {
        case current, near, far
    }

    private struct Row: Identifiable {
        let id: Int
        let text: String
        let role: Role
        /// `nil` for the current line: an option only fits if the whole current line does.
        let lineLimit: Int?
    }

    /// Candidates from most to least context; the first one that fits the height is shown.
    private func lyrics(_ window: WidgetSnapshot.LyricWindow, _ metrics: Metrics) -> some View {
        let current = window.current ?? "♪"
        func rows(_ spec: [(Int, String?, Role, Int?)]) -> [Row] {
            spec.compactMap { offset, text, role, limit in
                text.map { Row(id: offset, text: $0, role: role, lineLimit: limit) }
            }
        }
        // The current line is never truncated in these; context rows give way instead.
        let candidates: [[Row]] = [
            // All five, nearby lines allowed to wrap once.
            rows([(-2, window.previous2, .far, 1), (-1, window.previous, .near, 2), (0, current, .current, nil),
                  (1, window.next, .near, 2), (2, window.next2, .far, 1)]),
            // All five, context on one line each.
            rows([(-2, window.previous2, .far, 1), (-1, window.previous, .near, 1), (0, current, .current, nil),
                  (1, window.next, .near, 1), (2, window.next2, .far, 1)]),
            // Drop next +2, then previous −2.
            rows([(-2, window.previous2, .far, 1), (-1, window.previous, .near, 1), (0, current, .current, nil),
                  (1, window.next, .near, 1)]),
            rows([(-1, window.previous, .near, 2), (0, current, .current, nil), (1, window.next, .near, 2)]),
            rows([(-1, window.previous, .near, 1), (0, current, .current, nil), (1, window.next, .near, 1)]),
            // Previous and current, then current alone.
            rows([(-1, window.previous, .near, 1), (0, current, .current, nil)]),
            rows([(0, current, .current, nil)]),
        ]

        return ViewThatFits(in: .vertical) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                stack(candidate, metrics)
            }
            // Last resort (a very long current line): shrunk only as much as needed.
            Text(current)
                .font(.system(size: metrics.current, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(5)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.current.map { "Current lyric: \($0)" } ?? "Lyrics are about to start")
    }

    private func stack(_ rows: [Row], _ metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            ForEach(rows) { row in
                Text(row.text)
                    .font(font(for: row.role, metrics))
                    .foregroundStyle(.white.opacity(opacity(for: row.role)))
                    .lineLimit(row.lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func font(for role: Role, _ metrics: Metrics) -> Font {
        switch role {
        case .current: .system(size: metrics.current, weight: .bold, design: .rounded)
        case .near: .system(size: metrics.near, weight: .semibold, design: .rounded)
        case .far: .system(size: metrics.far, weight: .medium, design: .rounded)
        }
    }

    /// High contrast for the current line; context steps down but stays readable.
    private func opacity(for role: Role) -> Double {
        switch role {
        case .current: 1
        case .near: 0.68
        case .far: 0.46
        }
    }
}

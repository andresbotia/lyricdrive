//
//  SyncedLyricsView.swift
//  LyricDrive
//

import SwiftUI

/// Presents synced lyrics with the current line in focus near the upper third. Pure
/// presentation: it reads `LyricsManager.lines` / `currentLineIndex` as given and never computes
/// timing itself.
///
/// Equatable on its inputs so the parent's ~10Hz playback updates only re-render it when the
/// active line actually changes.
struct SyncedLyricsView: View, Equatable {
    let lines: [LyricLine]
    let currentIndex: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var baseFontSize: CGFloat = 30

    /// Where the current line sits, as a fraction of the view height.
    private static let focusAnchor = UnitPoint(x: 0, y: 0.3)

    static func == (lhs: SyncedLyricsView, rhs: SyncedLyricsView) -> Bool {
        lhs.currentIndex == rhs.currentIndex && lhs.lines == rhs.lines
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(lines.indices, id: \.self) { index in
                            lineView(index)
                                .id(index)
                        }
                    }
                    // Let the first and last lines reach the focus position.
                    .padding(.top, proxy.size.height * Self.focusAnchor.y)
                    .padding(.bottom, proxy.size.height * (1 - Self.focusAnchor.y))
                }
                .scrollDisabled(true)
                .onAppear { scroll(scroller, animated: false) }
                .onChange(of: currentIndex) { scroll(scroller, animated: !reduceMotion) }
                .onChange(of: lines) { scroll(scroller, animated: false) }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lyrics")
        .accessibilityValue(currentIndex.map { text(at: $0) } ?? "Waiting for the first line")
    }

    private func scroll(_ scroller: ScrollViewProxy, animated: Bool) {
        let target = currentIndex ?? 0
        guard lines.indices.contains(target) else { return }
        if animated {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                scroller.scrollTo(target, anchor: Self.focusAnchor)
            }
        } else {
            scroller.scrollTo(target, anchor: Self.focusAnchor)
        }
    }

    private func text(at index: Int) -> String {
        let text = lines[index].text
        return text.isEmpty ? "♪" : text
    }

    private func lineView(_ index: Int) -> some View {
        // Before the first line, every line counts as upcoming.
        let distance = index - (currentIndex ?? -1)
        let isCurrent = distance == 0
        let opacity: Double = switch distance {
        case 0: 1
        case ..<0: 0.36
        case 1: 0.66
        case 2: 0.48
        default: 0.32
        }

        return Text(text(at: index))
            .font(.system(size: min(baseFontSize, 46), weight: .bold))
            .tracking(-0.4)
            .lineSpacing(2)
            .foregroundStyle(.white)
            .opacity(opacity)
            .shadow(color: isCurrent ? LDTheme.aurora.opacity(0.45) : .clear, radius: 14)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isCurrent || reduceMotion ? 1 : 0.94, anchor: .leading)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.45), value: isCurrent)
            .animation(.easeInOut(duration: 0.45), value: opacity)
    }
}

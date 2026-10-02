//
//  WidgetGuideView.swift
//  LyricDrive
//

import SwiftUI

/// The three widgets, and how to add them on iPhone and in CarPlay. Opened from the walkthrough
/// and from Settings → Widgets. The previews are lightweight drawings in the widgets' style with demo
/// content; they don't use the widget extension.
struct WidgetGuideView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LyricDrive widgets live on your iPhone's Home Screen and Lock Screen.")
                        .foregroundStyle(LDTheme.textSecondary)
                    Text("The Lyrics widget can also appear in CarPlay, giving you a glanceable view of the current lyrics without opening the full LyricDrive CarPlay app.")
                        .foregroundStyle(LDTheme.textSecondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }

            Section("Widgets") {
                guideRow(.lyrics) { LyricsWidgetPreview() }
                guideRow(.glance) { LyricGlancePreview() }
                guideRow(.nowPlaying) { NowPlayingWidgetPreview() }
            }

            Section {
                step(1, "Touch and hold an empty area of your Home Screen.")
                step(2, "Choose to add a widget.")
                step(3, "Search for LyricDrive.")
                step(4, "Pick a widget and size, then add it.")
            } header: {
                Text("Add to your Home Screen")
            }

            Section {
                step(1, "Touch and hold your Lock Screen, then choose to customize it.")
                step(2, "Select the widget area below the time.")
                step(3, "Choose LyricDrive, then Lyric Glance.")
            } header: {
                Text("Add to your Lock Screen")
            }

            Section {
                step(1, "While parked, open the widget settings for CarPlay — touch and hold the widgets on your CarPlay screen, or look under CarPlay in your iPhone's Settings.")
                step(2, "Find LyricDrive.")
                step(3, "Add the Lyrics widget to a widget stack.")
                step(4, "Move it where you'd like it.")
            } header: {
                Text("Add to CarPlay")
            } footer: {
                Text("In CarPlay, the Lyrics widget shows just the lyrics, large and easy to read. Steps vary by car and iOS version. For artwork, playback controls and the full lyric view, open the LyricDrive app in CarPlay — its Now Playing and Lyrics tabs are always there.\n\nWidgets show the song LyricDrive last followed. Open LyricDrive if a widget asks you to refresh it.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(LDTheme.night)
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(_ kind: WidgetPreviewKind, @ViewBuilder preview: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            preview()
                .frame(maxWidth: kind == .lyrics ? .infinity : 170, alignment: .leading)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                    .font(.headline)
                    .foregroundStyle(LDTheme.textPrimary)
                Text(kind.summary)
                    .font(.subheadline)
                    .foregroundStyle(LDTheme.textSecondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.name) widget. \(kind.summary) Available on the \(kind.placement).")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(LDTheme.aurora)
                .frame(minWidth: 18, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(LDTheme.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}

// MARK: - Widget previews

enum WidgetPreviewKind {
    case lyrics, glance, nowPlaying

    var name: String {
        switch self {
        case .lyrics: "Lyrics"
        case .glance: "Lyric Glance"
        case .nowPlaying: "Now Playing"
        }
    }

    var summary: String {
        switch self {
        case .lyrics: "Follow the current lyric with nearby lines. Optimized for CarPlay."
        case .glance: "A compact lyric view for quick reading."
        case .nowPlaying: "Artwork, song information and playback controls."
        }
    }

    var placement: String {
        switch self {
        case .lyrics: "Home Screen and in CarPlay"
        case .nowPlaying: "Home Screen"
        case .glance: "Home Screen and Lock Screen"
        }
    }
}

/// Dark surface with the soft artwork glow the real widgets use.
private struct WidgetPreviewSurface<Content: View>: View {
    var aspectRatio: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .background(
                ZStack {
                    LDTheme.night
                    LinearGradient(
                        colors: [LDTheme.aurora.opacity(0.35), LDTheme.aurora.opacity(0.1), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .accessibilityHidden(true)
    }
}

/// Lyrics widget (medium): small song row, large current line, next line.
struct LyricsWidgetPreview: View {
    var body: some View {
        WidgetPreviewSurface(aspectRatio: 2.1) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    DemoArtwork(size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(WalkthroughDemo.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(LDTheme.textSecondary)
                        Text(WalkthroughDemo.artist).font(.system(size: 9)).foregroundStyle(LDTheme.textTertiary)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(WalkthroughDemo.lines[1])
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(LDTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(WalkthroughDemo.lines[2])
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LDTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
    }
}

/// Lyric Glance (small): just the current and next line.
struct LyricGlancePreview: View {
    var body: some View {
        WidgetPreviewSurface(aspectRatio: 1) {
            VStack(alignment: .leading, spacing: 4) {
                Text(WalkthroughDemo.lines[1])
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(LDTheme.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text(WalkthroughDemo.lines[2])
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LDTheme.textTertiary)
                    .lineLimit(2)
            }
        }
    }
}

/// Now Playing (small): artwork, song, and the three controls.
struct NowPlayingWidgetPreview: View {
    var body: some View {
        WidgetPreviewSurface(aspectRatio: 1) {
            VStack(alignment: .leading, spacing: 0) {
                DemoArtwork(size: 30)
                Spacer(minLength: 4)
                Text(WalkthroughDemo.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LDTheme.textPrimary)
                Text(WalkthroughDemo.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(LDTheme.textSecondary)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    control("backward.fill")
                    Spacer(minLength: 0)
                    control("pause.fill", prominent: true)
                    Spacer(minLength: 0)
                    control("forward.fill")
                }
            }
            .lineLimit(1)
        }
    }

    private func control(_ symbol: String, prominent: Bool = false) -> some View {
        let side: CGFloat = prominent ? 26 : 21
        return Image(systemName: symbol)
            .font(.system(size: side * 0.42, weight: .semibold))
            .foregroundStyle(prominent ? LDTheme.night : LDTheme.textPrimary)
            .frame(width: side, height: side)
            .background(Circle().fill(prominent ? LDTheme.textPrimary : .white.opacity(0.1)))
    }
}

//
//  WalkthroughView.swift
//  LyricDrive
//

import SwiftUI

/// Four short pages explaining how LyricDrive works: connect a music app, press play, CarPlay,
/// and iPhone widgets. Shown once during onboarding (between Welcome and service selection) and
/// any time from Settings → How LyricDrive Works. Purely educational: it reads no playback state
/// and changes no settings beyond what `onFinish` does.
struct WalkthroughView: View {
    enum Mode {
        /// First run: Skip on every page, "Get Started" on the last.
        case onboarding
        /// Reopened later: no Skip, "Done" on the last.
        case help
    }

    let mode: Mode
    let onFinish: () -> Void

    @State private var page = Page.connect
    @State private var isShowingWidgetGuide = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Page: Int, CaseIterable, Identifiable {
        case connect, play, carPlay, widgets
        var id: Int { rawValue }
    }

    private var isLastPage: Bool { page == Page.allCases.last }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            TabView(selection: $page) {
                ForEach(Page.allCases) { page in
                    pageContent(page)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            bottomBar
        }
        .background(alignment: .top) { glow }
        .background(LDTheme.night.ignoresSafeArea())
        .sheet(isPresented: $isShowingWidgetGuide) {
            NavigationStack {
                WidgetGuideView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isShowingWidgetGuide = false }
                                .fontWeight(.semibold)
                        }
                    }
            }
            .tint(LDTheme.aurora)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            if mode == .onboarding && !isLastPage {
                Button("Skip", action: onFinish)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LDTheme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Skips the introduction and goes to choosing your music app.")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, LDTheme.screenMargin - 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            PageIndicator(count: Page.allCases.count, current: page.rawValue) { index in
                if let target = Page(rawValue: index) { go(to: target) }
            }

            Button(isLastPage ? (mode == .onboarding ? "Get Started" : "Done") : "Continue") {
                if isLastPage {
                    onFinish()
                } else if let next = Page(rawValue: page.rawValue + 1) {
                    go(to: next)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(isLastPage ? "" : "Shows the next page.")
        }
        .padding(.horizontal, LDTheme.screenMargin)
        .padding(.bottom, 16)
        .frame(maxWidth: LDTheme.maxContentWidth)
    }

    private func go(to target: Page) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { page = target }
    }

    private var glow: some View {
        RadialGradient(colors: [LDTheme.aurora.opacity(0.2), .clear], center: .top, startRadius: 0, endRadius: 420)
            .frame(height: 520)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    // MARK: Pages

    @ViewBuilder
    private func pageContent(_ page: Page) -> some View {
        switch page {
        case .connect:
            WalkthroughPage(
                title: "Your music.\nYour lyrics.",
                message: "Connect Spotify or Apple Music. LyricDrive follows what you're already playing — you don't need to start music inside LyricDrive."
            ) {
                VStack(spacing: 12) {
                    ServicePreviewCard(service: .spotify, detail: "Follows the Spotify app")
                    ServicePreviewCard(service: .appleMusic, detail: "Follows the Music app")
                }
            }

        case .play:
            WalkthroughPage(
                title: "Just press play.",
                message: "Start a song in Spotify or Apple Music, then open LyricDrive. When synchronized lyrics are available, they follow the song automatically.",
                note: "Lyrics availability varies by song."
            ) {
                LyricsDemoCard(isAnimated: self.page == .play && !reduceMotion)
            }

        case .carPlay:
            WalkthroughPage(
                title: "Made for CarPlay.",
                message: "Connect your iPhone to CarPlay and open LyricDrive. Use Now Playing for artwork and playback controls, or switch to Lyrics for synchronized lines.",
                note: "Set up LyricDrive before driving and use CarPlay controls only when conditions allow."
            ) {
                CarPlayIllustration()
            }

        case .widgets:
            WalkthroughPage(
                eyebrow: "iPhone widgets",
                title: "Lyrics at a glance.",
                message: "Add LyricDrive widgets to your iPhone Home Screen or Lock Screen for lyrics, song information and quick controls.",
                textFirst: true
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    Button {
                        isShowingWidgetGuide = true
                    } label: {
                        Label("How to add a widget", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityHint("Shows steps for adding a widget to your Home Screen or Lock Screen.")
                    WidgetLineup()
                }
            }
        }
    }
}

// MARK: - Page layout

/// Illustration on top, then the headline and one short paragraph (or the reverse, for a page
/// whose illustration is tall). Scrolls at large text sizes.
private struct WalkthroughPage<Illustration: View>: View {
    var eyebrow: String?
    let title: String
    let message: String
    var note: String?
    var textFirst = false
    @ViewBuilder let illustration: () -> Illustration

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if textFirst {
                    text
                        .padding(.top, 12)
                    illustration()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                } else {
                    illustration()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    text
                        .padding(.top, 32)
                }
            }
            .padding(.horizontal, LDTheme.screenMargin)
            .padding(.bottom, 24)
            .frame(maxWidth: LDTheme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let eyebrow {
                EyebrowText(eyebrow)
            }
            Text(title)
                .font(.title.weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(LDTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(LDTheme.textSecondary)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(LDTheme.textTertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Dots that also work as an adjustable control for VoiceOver ("Page 2 of 4").
private struct PageIndicator: View {
    let count: Int
    let current: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? LDTheme.textPrimary : LDTheme.textPrimary.opacity(0.25))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .frame(minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if current + 1 < count { onSelect(current + 1) }
            case .decrement: if current > 0 { onSelect(current - 1) }
            @unknown default: break
            }
        }
    }
}

// MARK: - Page 1: services

private struct ServicePreviewCard: View {
    let service: MusicService
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            ServiceMark(service: service, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .font(.headline)
                    .foregroundStyle(LDTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(LDTheme.textTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(LDTheme.aurora)
                .accessibilityHidden(true)
        }
        .padding(16)
        .glassCard(fill: .white.opacity(0.05), stroke: .white.opacity(0.08))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(service.displayName). \(detail).")
    }
}

// MARK: - Page 2: lyrics demo

/// Fictional demo content, used by every onboarding illustration. Not a real song.
enum WalkthroughDemo {
    static let title = "Midnight Drive"
    static let artist = "LyricDrive Demo"
    static let lines = [
        "City lights are passing by",
        "We're following every line",
        "The road keeps moving on",
    ]
}

/// Local stand-in artwork: a gradient tile, no real album art.
struct DemoArtwork: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(
                colors: [LDTheme.aurora.opacity(0.9), Color(red: 0.12, green: 0.18, blue: 0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct LyricsDemoCard: View {
    let isAnimated: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.4)) { context in
            let current = isAnimated
                ? Int(context.date.timeIntervalSinceReferenceDate / 2.4) % WalkthroughDemo.lines.count
                : 1
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    DemoArtwork(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WalkthroughDemo.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LDTheme.textPrimary)
                        Text(WalkthroughDemo.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(LDTheme.textTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(WalkthroughDemo.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: index == current ? 24 : 18, weight: index == current ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(index == current ? LDTheme.textPrimary : LDTheme.textPrimary.opacity(0.32))
                            .shadow(color: index == current ? LDTheme.aurora.opacity(0.45) : .clear, radius: 12)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .animation(isAnimated ? .smooth(duration: 0.5) : nil, value: current)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(fill: .white.opacity(0.05), stroke: .white.opacity(0.08))
        }
        // A picture of the experience, so it's never enlarged past what fits the card.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: the current lyric is highlighted, with the previous and next lines dimmed around it.")
    }
}

// MARK: - Page 3: CarPlay illustration

/// A generic drawing of LyricDrive's two CarPlay tabs in LyricDrive's own style — an
/// illustration, not a screenshot of the CarPlay system interface.
private struct CarPlayIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                tab("Now Playing", symbol: "play.circle", selected: true)
                tab("Lyrics", symbol: "quote.bubble", selected: false)
            }

            HStack(alignment: .center, spacing: 16) {
                DemoArtwork(size: 84)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WalkthroughDemo.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(LDTheme.textPrimary)
                        Text(WalkthroughDemo.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(LDTheme.textSecondary)
                    }
                    .lineLimit(1)
                    HStack(spacing: 18) {
                        control("backward.fill")
                        control("pause.fill", prominent: true)
                        control("forward.fill")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 6) {
                Text("Lyrics tab")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LDTheme.textTertiary)
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LDTheme.aurora)
                    Text(WalkthroughDemo.lines[1])
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LDTheme.textPrimary)
                }
                Text(WalkthroughDemo.lines[2])
                    .font(.system(size: 14))
                    .foregroundStyle(LDTheme.textSecondary)
                    .padding(.leading, 19)
            }
            .lineLimit(1)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.05, green: 0.055, blue: 0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration of LyricDrive in CarPlay: a Now Playing tab with artwork, song title and previous, play-pause and next buttons, and a Lyrics tab with synchronized lines.")
    }

    private func tab(_ title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? LDTheme.night : LDTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? LDTheme.textPrimary : .white.opacity(0.08)))
    }

    private func control(_ symbol: String, prominent: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: prominent ? 15 : 13, weight: .semibold))
            .foregroundStyle(prominent ? LDTheme.night : LDTheme.textPrimary)
            .frame(width: prominent ? 34 : 28, height: prominent ? 34 : 28)
            .background(Circle().fill(prominent ? LDTheme.textPrimary : .white.opacity(0.1)))
    }
}

// MARK: - Page 4: widgets

/// The three widgets side by side, each with its name and what it's for.
private struct WidgetLineup: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            widgetItem(.lyrics) { LyricsWidgetPreview() }
            HStack(alignment: .top, spacing: 14) {
                widgetItem(.glance) { LyricGlancePreview() }
                widgetItem(.nowPlaying) { NowPlayingWidgetPreview() }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func widgetItem(_ kind: WidgetPreviewKind, @ViewBuilder preview: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            preview()
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LDTheme.textPrimary)
                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(LDTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.name) widget. \(kind.summary)")
    }
}

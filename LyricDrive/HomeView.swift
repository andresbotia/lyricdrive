//
//  HomeView.swift
//  LyricDrive
//

import SwiftUI

/// The single home once a service is authorized. It changes with playback (Listening ↔ Now
/// Playing); connection problems appear as a panel over the last-known state, never a dead end.
struct HomeView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingStore
    @EnvironmentObject private var lyricsManager: LyricsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: MusicSessionState
    let onShowSettings: () -> Void
    let onUserAction: () -> Void

    @State private var isReconnectPanelDismissed = false

    /// The provider manager reported that the user has to act (e.g. Spotify's automatic
    /// reconnect ended, or Apple Music access isn't granted).
    private var needsUserAction: Bool { session.phase == .needsUserAction }

    private var showsReconnectPanel: Bool { needsUserAction && !isReconnectPanelDismissed }
    private var hasTrack: Bool { nowPlaying.track != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, LDTheme.screenMargin - 4)

                ZStack {
                    if hasTrack {
                        NowPlayingView(session: session)
                            .transition(.opacity)
                    } else {
                        ListeningView(service: session.service)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: hasTrack)
            }
            .frame(maxWidth: LDTheme.maxContentWidth)
            .opacity(showsReconnectPanel ? 0.35 : 1)
            .allowsHitTesting(!showsReconnectPanel)
            .accessibilityHidden(showsReconnectPanel)

            if showsReconnectPanel {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .accessibilityHidden(true)
                ReconnectPanel(
                    session: session,
                    onAction: onUserAction,
                    onDismiss: { isReconnectPanelDismissed = true }
                )
                .frame(maxWidth: LDTheme.maxContentWidth)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AmbientBackground(artwork: hasTrack ? nowPlaying.artwork : nil)
        }
        .animation(.smooth(duration: 0.4), value: showsReconnectPanel)
        .onChange(of: needsUserAction) { _, needsAction in
            if !needsAction { isReconnectPanelDismissed = false }
        }
        .sensoryFeedback(trigger: nowPlaying.track?.id) { old, new in
            old != nil && new != nil ? .impact(weight: .light) : nil
        }
    }

    private var header: some View {
        HStack {
            ConnectionStatusPill(session: session, onAttentionTap: onUserAction)
            Spacer()
            Button(action: onShowSettings) {
                CircleIconLabel(systemName: "ellipsis")
            }
            .accessibilityLabel("Settings")
            .accessibilityHint("Music service, help, and app information")
        }
    }
}

// MARK: - 03 Listening (connected, nothing playing)

private struct ListeningView: View {
    let service: MusicService
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                listeningMark
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Ready when you are")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(LDTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Start playing something in \(service.displayName) and LyricDrive will follow along.")
                        .font(.callout)
                        .foregroundStyle(LDTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 36)

                if let appURL = service.appURL {
                    Button {
                        openURL(appURL)
                    } label: {
                        HStack(spacing: 10) {
                            ServiceMark(service: service)
                            Text("Open \(service.displayName)")
                        }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .padding(.top, 24)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, LDTheme.screenMargin)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background {
            RadialGradient(colors: [LDTheme.aurora.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 280)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    /// Static "listening" mark — concentric rings around the waveform motif. Deliberately not a
    /// looping animation.
    private var listeningMark: some View {
        ZStack {
            ForEach(0..<3) { ring in
                Circle()
                    .strokeBorder(LDTheme.aurora.opacity(0.3 - Double(ring) * 0.09), lineWidth: 1)
                    .frame(width: 124 + CGFloat(ring) * 48, height: 124 + CGFloat(ring) * 48)
            }
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.165, green: 0.204, blue: 0.267), Color(red: 0.047, green: 0.059, blue: 0.082)],
                    center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 60
                ))
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                .frame(width: 88, height: 88)
                .shadow(color: LDTheme.aurora.opacity(0.45), radius: 25)
            WaveformMotif(heights: [12, 22, 16])
        }
        .frame(width: 220, height: 220)
    }
}

/// The LyricDrive waveform bars, used as the brand motif in empty states.
struct WaveformMotif: View {
    let heights: [CGFloat]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(index == heights.count / 2 ? Color.white : LDTheme.aurora)
                    .frame(width: 4, height: height)
            }
        }
    }
}

// MARK: - 04 / 05 Now Playing

private enum LyricsPresentation: Equatable {
    case synced
    case loading
    case unavailable(UnavailableReason)

    enum UnavailableReason: Equatable { case plainOnly, notFound, failed }

    init(_ state: LyricsState, hasLines: Bool) {
        switch state {
        case .synced: self = hasLines ? .synced : .unavailable(.notFound)
        case .idle, .loading: self = .loading
        case .plainOnly: self = .unavailable(.plainOnly)
        case .notFound: self = .unavailable(.notFound)
        case .error: self = .unavailable(.failed)
        }
    }

    /// Synced and loading share the compact layout so a typical lookup doesn't jump.
    var usesCompactLayout: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

private struct NowPlayingView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingStore
    @EnvironmentObject private var lyricsManager: LyricsManager

    let session: MusicSessionState

    @State private var isShowingPlainLyrics = false

    private var presentation: LyricsPresentation {
        LyricsPresentation(lyricsManager.state, hasLines: !lyricsManager.lines.isEmpty)
    }

    private var trackTitle: String {
        let title = nowPlaying.track?.title ?? ""
        return title.isEmpty ? "Unknown Song" : title
    }

    private var trackSubtitle: String {
        [nowPlaying.track?.artist ?? "", nowPlaying.track?.album ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        let presentation = presentation
        VStack(spacing: 0) {
            Group {
                if presentation.usesCompactLayout {
                    compactLayout(presentation)
                        .transition(.opacity)
                } else {
                    ambientLayout(presentation)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.4), value: presentation.usesCompactLayout)

            PlaybackFooter(
                positionMs: nowPlaying.playbackPositionMs,
                durationMs: nowPlaying.track?.durationMs ?? 0,
                isPaused: nowPlaying.isPaused,
                controlsEnabled: session.phase == .connected,
                showsSyncedTag: presentation == .synced,
                onPrevious: nowPlaying.previousTrack,
                onTogglePlay: nowPlaying.togglePlayPause,
                onNext: nowPlaying.nextTrack
            )
            .padding(.horizontal, LDTheme.screenMargin)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $isShowingPlainLyrics) {
            PlainLyricsSheet(
                title: trackTitle,
                subtitle: nowPlaying.track?.artist ?? "",
                lyrics: lyricsManager.plainLyrics ?? ""
            )
        }
        .onChange(of: nowPlaying.track?.id) { isShowingPlainLyrics = false }
    }

    // MARK: Synced / loading

    private func compactLayout(_ presentation: LyricsPresentation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ArtworkView(image: nowPlaying.artwork, size: 68, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trackTitle)
                        .font(.headline)
                        .foregroundStyle(LDTheme.textPrimary)
                    Text(trackSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, LDTheme.screenMargin)
            .padding(.top, 14)

            if presentation == .synced {
                SyncedLyricsView(lines: lyricsManager.lines, currentIndex: lyricsManager.currentLineIndex)
                    .equatable()
                    .padding(.horizontal, LDTheme.screenMargin)
                    .transition(.opacity)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(LDTheme.textSecondary)
                    Text("Finding lyrics…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LDTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, LDTheme.screenMargin)
                .transition(.opacity)
            }
        }
    }

    // MARK: No synced lyrics

    private func ambientLayout(_ presentation: LyricsPresentation) -> some View {
        GeometryReader { proxy in
            let artSize = min(236, proxy.size.width - LDTheme.screenMargin * 2, max(140, proxy.size.height * 0.36))
            ScrollView {
                VStack(spacing: 0) {
                    ArtworkView(image: nowPlaying.artwork, size: artSize, cornerRadius: 20)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                        .padding(.top, 20)

                    VStack(spacing: 4) {
                        Text(trackTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(LDTheme.textPrimary)
                        Text(trackSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.66))
                    }
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .padding(.top, 22)

                    NoLyricsVisualizerView(
                        playbackPositionMs: nowPlaying.playbackPositionMs,
                        isPaused: nowPlaying.isPaused,
                        trackURI: nowPlaying.track?.id ?? "",
                        artwork: nowPlaying.artwork,
                        message: ""
                    )
                    .frame(maxWidth: 300)
                    .padding(.top, 18)
                    .accessibilityHidden(true)

                    if case .unavailable(let reason) = presentation {
                        LyricsUnavailableCard(reason: reason) {
                            isShowingPlainLyrics = true
                        }
                        .padding(.top, 18)
                    }
                }
                .padding(.horizontal, LDTheme.screenMargin)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.35), value: image.map(ObjectIdentifier.init))
        .accessibilityHidden(true)
    }
}

/// Calm, non-error explanation shown in place of synced lyrics.
private struct LyricsUnavailableCard: View {
    let reason: LyricsPresentation.UnavailableReason
    let onShowPlainLyrics: () -> Void

    private var title: String {
        switch reason {
        case .plainOnly, .notFound: "Synced lyrics aren't available for this track."
        case .failed: "Lyrics couldn't be loaded right now."
        }
    }

    private var detail: String {
        switch reason {
        case .plainOnly: "Plain lyrics are available to read."
        case .notFound: "LyricDrive keeps following along and shows synced lyrics on tracks that have them."
        case .failed: "LyricDrive will look again when the next track starts."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LDTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(LDTheme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            if reason == .plainOnly {
                Button("Show Plain Lyrics", action: onShowPlainLyrics)
                    .buttonStyle(GlassButtonStyle(fillsWidth: true))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Playback footer

private struct PlaybackFooter: View {
    let positionMs: Int
    let durationMs: Int
    let isPaused: Bool
    let controlsEnabled: Bool
    let showsSyncedTag: Bool
    let onPrevious: () -> Void
    let onTogglePlay: () -> Void
    let onNext: () -> Void

    private var progress: CGFloat {
        durationMs > 0 ? min(max(CGFloat(positionMs) / CGFloat(durationMs), 0), 1) : 0
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * progress)
                        }
                }
                .frame(height: 4)

                HStack {
                    Text(Self.format(ms: positionMs))
                    Spacer()
                    if showsSyncedTag {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(LDTheme.aurora)
                                .frame(width: 5, height: 5)
                            Text("SYNCED")
                                .font(.caption2.weight(.semibold))
                                .tracking(1.2)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Synced lyrics")
                    }
                    Spacer()
                    Text(Self.format(ms: durationMs))
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Self.format(ms: positionMs)) of \(Self.format(ms: durationMs))\(showsSyncedTag ? ", synced lyrics" : "")")

            HStack(spacing: 44) {
                Button(action: onPrevious) {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Previous track")

                Button(action: onTogglePlay) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .foregroundStyle(LDTheme.night)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(LDTheme.primaryFill))
                        .contentShape(Circle())
                }
                .accessibilityLabel(isPaused ? "Play" : "Pause")

                Button(action: onNext) {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Next track")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(!controlsEnabled)
            .opacity(controlsEnabled ? 1 : 0.4)
        }
    }

    private static func format(ms: Int) -> String {
        let totalSeconds = max(ms, 0) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Plain lyrics

private struct PlainLyricsSheet: View {
    let title: String
    let subtitle: String
    let lyrics: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(LDTheme.textSecondary)
                    Text(lyrics)
                        .font(.title3)
                        .lineSpacing(6)
                        .foregroundStyle(LDTheme.textPrimary.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(.top, 18)
                }
                .foregroundStyle(LDTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LDTheme.screenMargin)
            }
            .background(LDTheme.sheet)
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 06 Reconnect

/// Shown only once the provider reports the user has to act — for Spotify, never while a silent
/// reconnect, a bounded retry, or the SDK wake is still in progress. Copy and action come from
/// the provider's session state.
private struct ReconnectPanel: View {
    let session: MusicSessionState
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)

            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(.white.opacity(0.06))
                    .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                    .frame(width: 64, height: 64)
                    .overlay(ServiceMark(service: session.service, size: 36))
                Image(systemName: session.attentionSymbol)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(LDTheme.sheet)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LDTheme.attention))
                    .overlay(Circle().strokeBorder(LDTheme.sheet, lineWidth: 3))
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
            .padding(.top, 24)

            Text(session.attentionTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(LDTheme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 18)

            Text(session.attentionMessage)
                .font(.subheadline)
                .foregroundStyle(LDTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            #if DEBUG
            ConnectionDetailsDisclosure(details: session.debugDetails)
                .padding(.top, 12)
            #endif

            Button(session.attentionButtonTitle, action: onAction)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 22)

            Button("Not Now", action: onDismiss)
                .font(.headline)
                .foregroundStyle(LDTheme.aurora)
                .frame(minHeight: 44)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(LDTheme.sheet)
                .shadow(color: .black.opacity(0.5), radius: 30, y: -10)
        )
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}

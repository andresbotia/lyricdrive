//
//  ContentView.swift
//  LyricDrive
//
//  Created by Andres on 9/22/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var spotifyManager: SpotifyManager
    @EnvironmentObject private var lyricsManager: LyricsManager

    @State private var isConfirmingDisconnect = false
    @State private var isShowingHelp = false
    @ScaledMetric(relativeTo: .footnote) private var stepBadgeSize: CGFloat = 26

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !spotifyManager.isConnected {
                onboardingView
            } else if spotifyManager.trackURI.isEmpty {
                readyView
            } else {
                connectedView
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Disconnect Spotify?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                spotifyManager.disconnectAndForgetSpotify()
            }
        } message: {
            Text("You'll need to connect Spotify again before LyricDrive can follow playback.")
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpAboutView()
        }
    }

    // MARK: - Onboarding / connection

    /// Everything shown while App Remote isn't connected: first launch, connecting, reconnect,
    /// and connection problems. Returning users (already authorized) skip "How it works".
    private var onboardingView: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Spacer()
                        moreOptionsMenu
                    }
                    brandHeader

                    if !spotifyManager.hasAuthorizedSession {
                        howItWorks
                        safetyNotice
                    }

                    VStack(spacing: 14) {
                        connectionButton
                        connectionIssue
                    }

                    Text("Requires the Spotify app and a Spotify account.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 16) {
            Image(.brandIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            Text("LyricDrive")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 8) {
                Text("Synchronized lyrics for the music you're already playing.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Connect Spotify, start a song, and LyricDrive follows along on your iPhone and CarPlay when synchronized lyrics are available.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .multilineTextAlignment(.center)
        }
    }

    private static let howItWorksSteps: [(title: String, detail: String)] = [
        ("Connect Spotify", "Link LyricDrive to the Spotify app."),
        ("Start your music", "Play a song in Spotify."),
        ("Open LyricDrive in CarPlay", "Use Now Playing for playback controls and Lyrics for synchronized lyrics."),
    ]

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(Self.howItWorksSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .frame(width: stepBadgeSize, height: stepBadgeSize)
                        .background(Circle().fill(Color.brandCyan))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(step.detail)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1): \(step.title). \(step.detail)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
    }

    private var safetyNotice: some View {
        Text("Set up LyricDrive before driving. Use CarPlay controls only when conditions allow, and always keep your attention on the road.")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The single primary action, derived purely from existing `SpotifyManager` state.
    private enum ConnectionAction {
        case connect, reconnect, wake, inProgress

        var title: String {
            switch self {
            case .connect: "Connect Spotify"
            case .reconnect, .wake: "Reconnect Spotify"
            case .inProgress: "Connecting…"
            }
        }
    }

    private var connectionAction: ConnectionAction {
        if spotifyManager.isWakingSpotify || spotifyManager.isConnecting { return .inProgress }
        if spotifyManager.requiresSpotifyWake { return .wake }
        if spotifyManager.hasAuthorizedSession { return .reconnect }
        return .connect
    }

    private var connectionButton: some View {
        let action = connectionAction
        return Button {
            switch action {
            case .connect, .reconnect: spotifyManager.connect()
            case .wake: spotifyManager.bootstrapSpotifyAppRemote()
            case .inProgress: break
            }
        } label: {
            HStack(spacing: 10) {
                if action == .inProgress {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: action == .connect ? "music.note" : "arrow.clockwise")
                        .accessibilityHidden(true)
                }
                Text(action.title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [.brandCyan, .brandBlue], startPoint: .leading, endPoint: .trailing)
                )
            )
            .opacity(action == .inProgress ? 0.6 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(action == .inProgress)
        .accessibilityLabel(action.title)
        .accessibilityHint(action == .inProgress ? "" : "Opens Spotify to connect it to LyricDrive.")
    }

    /// Friendly summary of a connection problem. In Debug builds only, the raw SDK diagnostics are
    /// also available, collapsed, under "Connection Details"; Release builds never show them.
    @ViewBuilder
    private var connectionIssue: some View {
        if connectionAction != .inProgress, let message = connectionIssueMessage {
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                #if DEBUG
                if let details = spotifyManager.errorMessage {
                    DisclosureGroup("Connection Details") {
                        Text(details)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                    .tint(.white.opacity(0.45))
                }
                #endif
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        }
    }

    private var connectionIssueMessage: String? {
        if spotifyManager.requiresSpotifyWake {
            return "Spotify needs to be reopened to reconnect. Tap Reconnect Spotify to continue."
        }
        if spotifyManager.errorMessage != nil {
            return "Couldn't connect to Spotify. Make sure Spotify is installed and you're signed in, then try again."
        }
        if spotifyManager.hasAuthorizedSession {
            return "Spotify may need to be reopened after your phone or car has been inactive."
        }
        return nil
    }

    // MARK: - Connected status

    /// Subtle connected indicator and the shared Help / connection options menu.
    private var connectedStatusBar: some View {
        HStack {
            Label("Spotify Connected", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .labelStyle(StatusLabelStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.08)))

            Spacer()

            moreOptionsMenu
        }
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button {
                isShowingHelp = true
            } label: {
                Label("Help & About", systemImage: "questionmark.circle")
            }
            if spotifyManager.hasAuthorizedSession {
                Button(role: .destructive) {
                    isConfirmingDisconnect = true
                } label: {
                    Label("Disconnect Spotify", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
        .accessibilityHint("Help, app information, and Spotify connection options")
    }

    // MARK: - Connected, nothing playing

    private var readyView: some View {
        VStack(spacing: 0) {
            connectedStatusBar

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(
                        Circle().fill(
                            LinearGradient(colors: [.brandCyan.opacity(0.35), .brandBlue.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    )
                    .shadow(color: .brandCyan.opacity(0.3), radius: 20)
                    .accessibilityHidden(true)

                Text("Ready for Spotify")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                Text("Start playing a song in Spotify and LyricDrive will follow automatically.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding()
    }

    // MARK: - Connected, playing

    private var connectedView: some View {
        VStack(spacing: 24) {
            connectedStatusBar

            artworkView

            VStack(spacing: 4) {
                Text(spotifyManager.albumName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text(spotifyManager.artistName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            lyricsView

            Text(playbackPositionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding()
    }

    private var artworkView: some View {
        Group {
            if let artwork = spotifyManager.albumArtwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var lyricsView: some View {
        switch lyricsManager.state {
        case .synced:
            fiveLineLyricsView
        case .idle:
            visualizerFallback(message: "")
        case .loading:
            visualizerFallback(message: "Loading lyrics…")
        case .notFound:
            visualizerFallback(message: "No lyrics found")
        case .plainOnly:
            visualizerFallback(message: "No synced lyrics available")
        case .error:
            visualizerFallback(message: "Lyrics unavailable")
        }
    }

    private func visualizerFallback(message: String) -> some View {
        NoLyricsVisualizerView(
            playbackPositionMs: spotifyManager.playbackPositionMs,
            isPaused: spotifyManager.isPaused,
            trackURI: spotifyManager.trackURI,
            artwork: spotifyManager.albumArtwork,
            message: message
        )
        .frame(height: 150)
    }

    private var fiveLineLyricsView: some View {
        VStack(spacing: 10) {
            ForEach(lyricsManager.fiveLineWindow) { slot in
                Text(slot.line?.text ?? " ")
                    .font(slot.isCurrent ? .title3.weight(.semibold) : .body)
                    .foregroundStyle(.white.opacity(slot.isCurrent ? 1.0 : 0.35))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150)
    }

    // MARK: - Formatting

    private var playbackPositionText: String {
        "\(formatted(ms: spotifyManager.playbackPositionMs)) / \(formatted(ms: spotifyManager.durationMs))"
    }

    private func formatted(ms: Int) -> String {
        let totalSeconds = ms / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// Icon tinted with the brand accent, text in the label's own style — so "connected" is carried
/// by the checkmark glyph and the words, not by color alone.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(Color.brandCyan)
            configuration.title
        }
    }
}

private extension Color {
    static let brandCyan = Color(red: 0.0, green: 0.86, blue: 1.0)
    static let brandBlue = Color(red: 0.12, green: 0.42, blue: 1.0)
}

private struct HelpAboutView: View {
    @Environment(\.dismiss) private var dismiss

    private static let privacyPolicyURL = URL(string: "https://andresbotia.github.io/lyricdrive/privacy")!
    private static let supportURL = URL(string: "https://andresbotia.github.io/lyricdrive/support")!

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    Text("LyricDrive")
                        .font(.headline)
                    Text("Synchronized lyrics for the music you're already playing.")
                }

                Section("How CarPlay works") {
                    Text("On CarPlay, use Now Playing for music controls and Lyrics for the synchronized lyric view. Once you're on Lyrics, the app updates automatically as songs change.")
                }

                Section("Spotify") {
                    Text("Spotify provides playback. LyricDrive connects to the Spotify app and follows your current track.")
                    Text("If Spotify disconnects after your phone or car has been inactive, return to LyricDrive and tap Reconnect Spotify.")
                }

                Section("Lyrics") {
                    Text("Synchronized lyrics appear on iPhone and CarPlay when available. Some tracks may not have synchronized lyrics.")
                }

                Section("Safety") {
                    Text("Set up LyricDrive before driving. Use CarPlay controls only when conditions allow, and always keep your attention on the road.")
                }

                Section("Links") {
                    Link("Privacy Policy", destination: Self.privacyPolicyURL)
                    Link("Support", destination: Self.supportURL)
                }

                Section("Version") {
                    Text(versionText)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Help & About")
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

#Preview {
    let services = AppServices.shared
    ContentView()
        .environmentObject(services.spotifyManager)
        .environmentObject(services.lyricsManager)
}

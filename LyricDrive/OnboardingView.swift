//
//  OnboardingView.swift
//  LyricDrive
//

import SwiftUI

/// Shown until a music service has been authorized: Welcome (first launch only), the short
/// walkthrough (once), then service selection. Returning users with a saved session never see this.
struct OnboardingView: View {
    let sessionForService: (MusicService) -> MusicSessionState
    let onConnect: (MusicService) -> Void
    let onOpenSettings: () -> Void
    let onShowSettings: () -> Void

    @AppStorage("onboarding.hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage(OnboardingProgress.hasCompletedWalkthroughKey) private var hasCompletedWalkthrough = false
    @AppStorage(OnboardingProgress.whatsNewVersionKey) private var whatsNewVersion = ""
    /// Not persisted: the walkthrough only follows a Welcome tap, so anyone already past Welcome
    /// (including people updating mid-setup) is never routed through it automatically.
    @State private var isShowingWalkthrough = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if hasSeenWelcome {
                ChooseServiceView(
                    sessionForService: sessionForService,
                    onBack: { setWelcomeSeen(false) },
                    onConnect: onConnect,
                    onOpenSettings: onOpenSettings,
                    onShowSettings: onShowSettings
                )
                .transition(stepTransition(edge: .trailing))
            } else if isShowingWalkthrough {
                WalkthroughView(mode: .onboarding, onFinish: finishWalkthrough)
                    .transition(stepTransition(edge: .trailing))
            } else {
                WelcomeView(onGetStarted: {
                    if hasCompletedWalkthrough {
                        setWelcomeSeen(true)
                    } else {
                        withAnimation(stepAnimation) { isShowingWalkthrough = true }
                    }
                })
                .transition(stepTransition(edge: .leading))
            }
        }
    }

    /// Finished or skipped. Also covers this release's What's New, which describes the same things.
    private func finishWalkthrough() {
        hasCompletedWalkthrough = true
        whatsNewVersion = OnboardingProgress.whatsNewVersion
        withAnimation(stepAnimation) {
            isShowingWalkthrough = false
            hasSeenWelcome = true
        }
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)
    }

    private func setWelcomeSeen(_ seen: Bool) {
        withAnimation(stepAnimation) {
            hasSeenWelcome = seen
        }
    }

    private func stepTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

// MARK: - 01 Welcome

private struct WelcomeView: View {
    let onGetStarted: () -> Void

    private static let highlights = [
        "Follows your music automatically",
        "Synced lyrics when they're available",
        "On your iPhone and in CarPlay",
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image(.brandIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: LDTheme.aurora.opacity(0.45), radius: 24)
                        .accessibilityHidden(true)

                    Spacer(minLength: 40)

                    VStack(alignment: .leading, spacing: 16) {
                        EyebrowText("LyricDrive")
                        Text("Every word,\nright on time.")
                            .font(.largeTitle.weight(.bold))
                            .tracking(-0.6)
                            .foregroundStyle(LDTheme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Connect your music service and LyricDrive follows the song you're playing with synchronized lyrics when available.")
                            .font(.body)
                            .foregroundStyle(LDTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.highlights, id: \.self) { highlight in
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(LDTheme.aurora)
                                    .frame(width: 8, height: 8)
                                    .shadow(color: LDTheme.aurora, radius: 5)
                                    .accessibilityHidden(true)
                                Text(highlight)
                                    .font(.subheadline)
                                    .foregroundStyle(LDTheme.textPrimary)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(fill: .white.opacity(0.05), stroke: .white.opacity(0.08))
                    .padding(.top, 28)

                    worksWith
                        .padding(.top, 24)

                    Button("Get Started", action: onGetStarted)
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 16)

                    Text("Set up before you drive. Keep your eyes on the road.")
                        .font(.caption)
                        .foregroundStyle(LDTheme.textPrimary.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 20)
                .frame(maxWidth: LDTheme.maxContentWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(alignment: .top) { welcomeGlow }
    }

    private var worksWith: some View {
        HStack(spacing: 12) {
            Text("Works with")
                .foregroundStyle(LDTheme.textTertiary)
            HStack(spacing: 6) {
                ServiceMark(service: .spotify)
                Text("Spotify")
            }
            HStack(spacing: 6) {
                ServiceMark(service: .appleMusic)
                Text("Apple Music")
            }
        }
        .font(.footnote)
        .foregroundStyle(LDTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Works with Spotify and Apple Music.")
    }

    private var welcomeGlow: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [LDTheme.aurora.opacity(0.32), .clear], center: .center, startRadius: 0, endRadius: 210))
                .frame(width: 420, height: 420)
                .offset(x: -130, y: -150)
            Circle()
                .fill(RadialGradient(colors: [LDTheme.attention.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 190))
                .frame(width: 380, height: 380)
                .offset(x: 150, y: -40)
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - 02 Choose service

private struct ChooseServiceView: View {
    let sessionForService: (MusicService) -> MusicSessionState
    let onBack: () -> Void
    let onConnect: (MusicService) -> Void
    let onOpenSettings: () -> Void
    let onShowSettings: () -> Void

    /// The highlighted card. Only becomes the active service once connecting succeeds.
    @AppStorage("musicService.selected") private var selectedServiceID = MusicService.spotify.rawValue

    private var selectedService: MusicService {
        MusicService(rawValue: selectedServiceID) ?? .spotify
    }

    private var session: MusicSessionState { sessionForService(selectedService) }

    private var isConnecting: Bool { session.phase == .connecting }

    /// Apple Music access was denied or is restricted: iOS won't prompt again, so the only way
    /// forward is the Settings app.
    private var needsSystemSettings: Bool {
        session.appleMusicAuthorization == .denied || session.appleMusicAuthorization == .restricted
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(action: onBack) {
                            CircleIconLabel(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                        Spacer()
                        Button(action: onShowSettings) {
                            CircleIconLabel(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, -4)

                    Text("Where do you\nlisten?")
                        .font(.largeTitle.weight(.bold))
                        .tracking(-0.5)
                        .foregroundStyle(LDTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 20)

                    Text("Pick the app you play music in.")
                        .font(.callout)
                        .foregroundStyle(LDTheme.textSecondary)
                        .padding(.top, 10)

                    VStack(spacing: 12) {
                        ForEach(MusicService.allCases) { service in
                            MusicServiceCard(service: service, isSelected: service == selectedService) {
                                selectedServiceID = service.rawValue
                            }
                        }
                    }
                    .padding(.top, 28)

                    EyebrowText("What LyricDrive can see")
                        .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 12) {
                        permissionRow("checkmark", "The song that's playing right now", emphasized: true)
                        permissionRow("checkmark", "Where you are in the song, to time the lyrics", emphasized: true)
                        permissionRow("minus", "Never changes your library or playlists", emphasized: false)
                    }
                    .padding(.top, 12)

                    Spacer(minLength: 28)

                    connectionIssue

                    Button {
                        if needsSystemSettings {
                            onOpenSettings()
                        } else {
                            onConnect(selectedService)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isConnecting {
                                ProgressView().tint(LDTheme.night)
                                Text("Connecting…")
                            } else if needsSystemSettings {
                                Text("Open Settings")
                            } else {
                                Text("Continue with \(selectedService.displayName)")
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isConnecting)
                    .accessibilityHint(selectedService == .spotify ? "Opens Spotify to connect it to LyricDrive." : "Asks for access to Apple Music.")

                    if !needsSystemSettings {
                        Text(selectedService.connectNote)
                            .font(.footnote)
                            .foregroundStyle(LDTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, LDTheme.screenMargin)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: LDTheme.maxContentWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func permissionRow(_ symbol: String, _ text: String, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(emphasized ? LDTheme.aurora : LDTheme.textTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(emphasized ? LDTheme.textPrimary : LDTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var connectionIssueMessage: String? {
        switch selectedService {
        case .spotify:
            guard session.phase == .notConnected, session.lastAttemptFailed else { return nil }
            return "Couldn't connect to Spotify. Make sure Spotify is installed and you're signed in, then try again."
        case .appleMusic:
            return needsSystemSettings ? session.attentionMessage : nil
        }
    }

    /// Friendly summary after a failed first connection or denied access. DEBUG builds can also
    /// expand the raw SDK diagnostics; Release builds never show them.
    @ViewBuilder
    private var connectionIssue: some View {
        if let message = connectionIssueMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(LDTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if DEBUG
                ConnectionDetailsDisclosure(details: session.debugDetails)
                #endif
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 16)
            .padding(.bottom, 16)
        }
    }
}

#if DEBUG
/// DEBUG-only raw connection diagnostics, collapsed by default.
struct ConnectionDetailsDisclosure: View {
    let details: String?

    var body: some View {
        if let details {
            DisclosureGroup("Connection Details") {
                Text(details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(LDTheme.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(.caption)
            .tint(LDTheme.textTertiary)
        }
    }
}
#endif

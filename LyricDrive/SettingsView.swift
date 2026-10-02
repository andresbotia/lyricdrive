//
//  SettingsView.swift
//  LyricDrive
//

import SwiftUI

/// Settings · Help · About, presented as a sheet from the ••• button.
struct SettingsView: View {
    @EnvironmentObject private var spotifyManager: SpotifyManager
    @EnvironmentObject private var appleMusicManager: AppleMusicManager
    @EnvironmentObject private var nowPlaying: NowPlayingStore
    @Environment(\.dismiss) private var dismiss

    /// The active provider's reconnect / access action (same as the home panel's).
    let onUserAction: () -> Void
    let onOpenSettings: () -> Void

    @State private var isConfirmingDisconnect = false
    @State private var isConfirmingStopAppleMusic = false
    @State private var pendingSwitch: MusicService?
    @State private var appleMusicSwitchIssue: String?

    private static let privacyPolicyURL = URL(string: "https://andresbotia.github.io/lyricdrive/privacy")!
    private static let supportURL = URL(string: "https://andresbotia.github.io/lyricdrive/support")!

    private var session: MusicSessionState {
        switch nowPlaying.activeService {
        case .spotify: MusicSessionState(spotify: spotifyManager)
        case .appleMusic: MusicSessionState(appleMusic: appleMusicManager)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "LyricDrive \(version) (\(build))"
    }

    var body: some View {
        let session = session
        NavigationStack {
            List {
                musicServiceSection(session)

                Section("Help") {
                    // Help only: reopening the walkthrough never resets onboarding progress.
                    NavigationLink("How LyricDrive Works") { HowItWorksView() }
                    NavigationLink("Widgets") { WidgetGuideView() }
                    NavigationLink("Driving Safely") { DrivingSafelyView() }
                    externalLink("Contact Support", url: Self.supportURL)
                    externalLink("Privacy Policy", url: Self.privacyPolicyURL)
                }

                #if DEBUG
                if let details = session.debugDetails {
                    Section("Diagnostics (Debug only)") {
                        Text(details)
                            .font(.caption2.monospaced())
                            .foregroundStyle(LDTheme.textTertiary)
                            .textSelection(.enabled)
                    }
                }
                #endif

                Section {
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Synced lyrics aren't available for every song. Set up LyricDrive before driving and keep your attention on the road.")
                        Text(versionText)
                    }
                    .font(.footnote)
                    .foregroundStyle(LDTheme.textPrimary.opacity(0.42))
                }
            }
            .scrollContentBackground(.hidden)
            .background(LDTheme.night)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Disconnect Spotify?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    spotifyManager.disconnectAndForgetSpotify()
                    dismiss()
                }
            } message: {
                Text("You'll need to connect Spotify again before LyricDrive can follow playback.")
            }
            .confirmationDialog("Stop Using Apple Music?", isPresented: $isConfirmingStopAppleMusic, titleVisibility: .visible) {
                Button("Stop Using Apple Music", role: .destructive) {
                    nowPlaying.stopUsingAppleMusic()
                    dismiss()
                }
            } message: {
                Text(spotifyManager.hasAuthorizedSession
                     ? "LyricDrive will stop following the Music app and reconnect to Spotify."
                     : "LyricDrive will stop following the Music app and return to service selection.")
            }
            .confirmationDialog(
                pendingSwitch.map { "Switch to \($0.displayName)?" } ?? "",
                isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
                titleVisibility: .visible,
                presenting: pendingSwitch
            ) { service in
                Button("Switch to \(service.displayName)") { confirmSwitch(to: service) }
            } message: { service in
                Text(switchMessage(for: service))
            }
        }
        .tint(LDTheme.aurora)
        .preferredColorScheme(.dark)
    }

    // MARK: Music service

    private func musicServiceSection(_ session: MusicSessionState) -> some View {
        Section {
            ForEach(MusicService.allCases) { service in
                serviceRow(service, isActive: service == nowPlaying.activeService, session: session)
            }

            switch nowPlaying.activeService {
            case .spotify:
                if session.hasAuthorizedSession {
                    if session.phase == .needsUserAction || session.phase == .disconnected {
                        Button("Reconnect Spotify") {
                            dismiss()
                            onUserAction()
                        }
                    }
                    Button("Disconnect Spotify", role: .destructive) {
                        isConfirmingDisconnect = true
                    }
                }
            case .appleMusic:
                if session.phase == .needsUserAction {
                    Text(session.attentionMessage)
                        .font(.footnote)
                        .foregroundStyle(LDTheme.textSecondary)
                    Button(session.attentionButtonTitle) {
                        if session.userAction == .openSettings {
                            onOpenSettings()
                        } else {
                            onUserAction()
                        }
                    }
                } else if appleMusicManager.canPlayCatalogContent == false {
                    Text("This Apple Music account can't stream the Apple Music catalog. Songs in your library still work.")
                        .font(.footnote)
                        .foregroundStyle(LDTheme.textSecondary)
                }
                Button("Stop Using Apple Music") {
                    isConfirmingStopAppleMusic = true
                }
            }

            if let message = appleMusicSwitchIssue {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LDTheme.textSecondary)
                Button("Open Settings", action: onOpenSettings)
            }
        } header: {
            Text("Music Service")
        } footer: {
            if nowPlaying.activeService == .appleMusic {
                Text("LyricDrive can't remove its own Apple Music access. To change it, open the Settings app and go to LyricDrive.")
            }
        }
    }

    private func serviceRow(_ service: MusicService, isActive: Bool, session: MusicSessionState) -> some View {
        Button {
            if !isActive { pendingSwitch = service }
        } label: {
            HStack(spacing: 12) {
                ServiceMark(service: service, size: 26)
                Text(service.displayName)
                    .foregroundStyle(LDTheme.textPrimary)
                Spacer()
                if isActive {
                    Text(statusText(session))
                        .font(.subheadline)
                        .foregroundStyle(session.phase == .connected ? LDTheme.aurora : LDTheme.textTertiary)
                } else {
                    Text("Switch")
                        .font(.subheadline)
                        .foregroundStyle(LDTheme.aurora)
                }
            }
        }
        .disabled(isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isActive ? "\(service.displayName), active, \(statusText(session))" : "Switch to \(service.displayName)")
        .accessibilityAddTraits(isActive ? [] : .isButton)
    }

    private func statusText(_ session: MusicSessionState) -> String {
        switch session.phase {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .notConnected: return "Not set up"
        case .disconnected, .needsUserAction:
            switch session.appleMusicAuthorization {
            case nil: return "Not connected"
            case .restricted: return "Restricted"
            case .notDetermined: return "Access needed"
            case .authorized, .denied: return "Access off"
            }
        }
    }

    private func confirmSwitch(to service: MusicService) {
        switch service {
        case .spotify:
            dismiss()
            nowPlaying.activateSpotify()
        case .appleMusic:
            Task {
                let status = await nowPlaying.activateAppleMusic()
                switch status {
                case .authorized:
                    appleMusicSwitchIssue = nil
                    dismiss()
                case .denied:
                    appleMusicSwitchIssue = "Apple Music access is turned off for LyricDrive. You can turn it on in Settings."
                case .restricted:
                    appleMusicSwitchIssue = "Apple Music access is restricted on this device, for example by Screen Time."
                case .notDetermined:
                    appleMusicSwitchIssue = nil
                }
            }
        }
    }

    private func switchMessage(for service: MusicService) -> String {
        switch service {
        case .spotify:
            spotifyManager.hasAuthorizedSession
                ? "LyricDrive will stop following Apple Music and reconnect to Spotify."
                : "LyricDrive will stop following Apple Music. Spotify will open briefly to confirm."
        case .appleMusic:
            spotifyManager.hasAuthorizedSession
                ? "LyricDrive will follow the Music app instead of Spotify. Spotify stays signed in, so you can switch back anytime."
                : "LyricDrive will follow what's playing in the Music app."
        }
    }

    private func externalLink(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title)
                    .foregroundStyle(LDTheme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LDTheme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Help pages

/// The onboarding walkthrough in help mode; "Done" on the last page returns to Settings.
private struct HowItWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WalkthroughView(mode: .help) { dismiss() }
            .navigationTitle("How LyricDrive Works")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DrivingSafelyView: View {
    var body: some View {
        List {
            Section {
                Text("Set up LyricDrive before driving.")
                Text("Use CarPlay controls only when conditions allow.")
                Text("Always keep your attention on the road.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(LDTheme.night)
        .navigationTitle("Driving Safely")
        .navigationBarTitleDisplayMode(.inline)
    }
}

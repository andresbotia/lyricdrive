//
//  ContentView.swift
//  LyricDrive
//
//  Created by Andres on 9/22/26.
//

import SwiftUI

/// Routes between onboarding (no service set up yet) and the single adaptive home.
/// All connection behavior stays in the provider managers; this only reads their state and
/// forwards user actions to the same entry points the previous UI used.
struct ContentView: View {
    @EnvironmentObject private var spotifyManager: SpotifyManager
    @EnvironmentObject private var appleMusicManager: AppleMusicManager
    @EnvironmentObject private var nowPlaying: NowPlayingStore
    @EnvironmentObject private var lyricsManager: LyricsManager
    @Environment(\.openURL) private var openURL

    @State private var isShowingSettings = false
    @State private var isShowingWhatsNew = false
    @AppStorage(OnboardingProgress.hasCompletedWalkthroughKey) private var hasCompletedWalkthrough = false
    @AppStorage(OnboardingProgress.whatsNewVersionKey) private var whatsNewVersion = ""

    /// Apple Music only becomes active after access was granted once, so it always gets the home
    /// (which explains how to restore access if it's later revoked). Spotify keeps its original rule.
    private var showsHome: Bool {
        switch nowPlaying.activeService {
        case .spotify: spotifyManager.isConnected || spotifyManager.hasAuthorizedSession
        case .appleMusic: true
        }
    }

    private var activeSession: MusicSessionState {
        session(for: nowPlaying.activeService)
    }

    private func session(for service: MusicService) -> MusicSessionState {
        switch service {
        case .spotify: MusicSessionState(spotify: spotifyManager)
        case .appleMusic: MusicSessionState(appleMusic: appleMusicManager)
        }
    }

    var body: some View {
        ZStack {
            LDTheme.night.ignoresSafeArea()

            if showsHome {
                HomeView(
                    session: activeSession,
                    onShowSettings: { isShowingSettings = true },
                    onUserAction: performUserAction
                )
                .transition(.opacity)
            } else {
                OnboardingView(
                    sessionForService: session(for:),
                    onConnect: connect,
                    onOpenSettings: openSystemSettings,
                    onShowSettings: { isShowingSettings = true }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showsHome)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(onUserAction: performUserAction, onOpenSettings: openSystemSettings)
                .environmentObject(spotifyManager)
                .environmentObject(appleMusicManager)
                .environmentObject(nowPlaying)
        }
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewView()
        }
        .task(id: showsHome) { showWhatsNewIfNeeded() }
    }

    /// Once, on the home screen, for people updating from a version without the walkthrough.
    /// Marked as seen when shown, so it never comes back — whichever button is used.
    private func showWhatsNewIfNeeded() {
        guard showsHome, !hasCompletedWalkthrough, !isShowingSettings,
              whatsNewVersion != OnboardingProgress.whatsNewVersion else { return }
        whatsNewVersion = OnboardingProgress.whatsNewVersion
        isShowingWhatsNew = true
    }

    private func connect(_ service: MusicService) {
        switch service {
        case .spotify:
            nowPlaying.activateSpotify()
        case .appleMusic:
            Task { await nowPlaying.activateAppleMusic() }
        }
    }

    /// The action behind the active provider's reconnect panel and attention pill.
    private func performUserAction() {
        switch activeSession.userAction {
        case .reconnect:
            // Same mapping as before the redesign: the SDK wake app-switch when Spotify's local
            // transport is asleep, otherwise a normal (silently renewing) connect.
            if spotifyManager.requiresSpotifyWake {
                spotifyManager.bootstrapSpotifyAppRemote()
            } else {
                spotifyManager.connect()
            }
        case .requestAccess:
            Task { await nowPlaying.activateAppleMusic() }
        case .openSettings:
            openSystemSettings()
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

#Preview {
    let services = AppServices.shared
    ContentView()
        .environmentObject(services.spotifyManager)
        .environmentObject(services.appleMusicManager)
        .environmentObject(services.nowPlaying)
        .environmentObject(services.lyricsManager)
}

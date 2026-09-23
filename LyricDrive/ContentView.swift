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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if spotifyManager.isConnected {
                connectedView
            } else if spotifyManager.requiresSpotifyWake {
                wakeSpotifyView
            } else {
                disconnectedView
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .imageScale(.large)
                .foregroundStyle(.white)

            Text("LyricDrive")
                .font(.title)
                .foregroundStyle(.white)

            Button("Connect Spotify") {
                spotifyManager.connect()
            }
            .buttonStyle(.borderedProminent)

            errorText
        }
        .padding()
    }

    /// Shown instead of the Connect button when Spotify is already authorized but its local App
    /// Remote transport is asleep — this is an app-switch prompt, not a re-authorization prompt.
    private var wakeSpotifyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .imageScale(.large)
                .foregroundStyle(.white)

            Text("LyricDrive")
                .font(.title)
                .foregroundStyle(.white)

            if spotifyManager.isWakingSpotify {
                ProgressView()
                    .tint(.white)
                Text("Reconnecting to Spotify…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Button("Reconnect Spotify") {
                    spotifyManager.bootstrapSpotifyAppRemote()
                }
                .buttonStyle(.borderedProminent)

                Text(spotifyManager.errorMessage ?? "Spotify needs to be reconnected. Tap above to continue.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(spacing: 24) {
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

            // Tenths of a second are shown temporarily to verify the local playback clock;
            // drop this precision once lyric sync is finalized.
            Text(playbackPositionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))

            errorText
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

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage = spotifyManager.errorMessage {
            Text(errorMessage)
                .font(.caption2)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Formatting

    private var playbackPositionText: String {
        "\(formattedWithTenths(ms: spotifyManager.playbackPositionMs)) / \(formatted(ms: spotifyManager.durationMs))"
    }

    private func formatted(ms: Int) -> String {
        let totalSeconds = ms / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func formattedWithTenths(ms: Int) -> String {
        let totalTenths = ms / 100
        let minutes = totalTenths / 600
        let seconds = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

#Preview {
    let spotifyManager = SpotifyManager()
    ContentView()
        .environmentObject(spotifyManager)
        .environmentObject(LyricsManager(spotifyManager: spotifyManager))
}

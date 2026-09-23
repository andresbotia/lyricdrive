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
        case .idle:
            Color.clear.frame(height: 150)
        case .loading:
            Text("Loading lyrics…")
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 150)
        case .notFound:
            Text("No lyrics found")
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 150)
        case .error(let message):
            Text("Lyrics unavailable: \(message)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .frame(height: 150)
                .padding(.horizontal)
        case .plainOnly:
            Text(lyricsManager.plainLyrics ?? "")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .frame(height: 150)
                .padding(.horizontal)
        case .synced:
            fiveLineLyricsView
        }
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

//
//  CarPlayDemo.swift
//  LyricDrive
//

#if DEBUG && targetEnvironment(simulator)
import UIKit

/// DEBUG + Simulator only: fake playback for exercising the real CarPlay (and iPhone) UI without
/// the Spotify app. Enabled by the `--carplay-demo` launch argument. Compiled out of every
/// device and Release build.
///
/// It doesn't have its own UI: `SpotifyManager` publishes these tracks through its normal
/// properties and `LyricsService` returns their lyrics, so the existing presentation code runs
/// unchanged.
enum CarPlayDemo {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--carplay-demo")
    }

    struct Track {
        let uri: String
        let name: String
        let artist: String
        let album: String
        let durationMs: Int
        /// `(seconds, text)` pairs; `nil` means "no synced lyrics" for this track.
        let lyrics: [(Double, String)]?
        let colors: (UIColor, UIColor)
    }

    static let tracks: [Track] = [
        Track(
            uri: "lyricdrive-demo:track:1",
            name: "Midnight Drive",
            artist: "LyricDrive Demo",
            album: "Simulator Sessions",
            durationMs: 210_000,
            // Steady ~8s lines starting almost immediately.
            lyrics: [
                "Headlights cutting through the rain",
                "Every exit looks the same",
                "Radio low, the city's asleep",
                "Promises I meant to keep",
                "Mile markers counting down",
                "Neon fading out of town",
                "Hands on the wheel, eyes on the road",
                "Carrying a lighter load",
                "Midnight drive, midnight drive",
                "Only time I feel alive",
                "Windows down and the stars in view",
                "Every song reminds me of you",
                "Gas station glow at a quarter to two",
                "Coffee's cold but the night is new",
                "Turn signal ticking like a heart",
                "Every ending's a place to start",
                "Midnight drive, midnight drive",
                "Following the white line home",
                "Midnight drive, midnight drive",
                "Never really feel alone",
                "Dashboard light on a sleepy face",
                "Leaving nothing, leaving no trace",
                "Sunrise waiting past the hill",
                "Midnight drive, I'm driving still",
            ].enumerated().map { (2 + Double($0.offset) * 8, $0.element) },
            colors: (UIColor(red: 0.05, green: 0.55, blue: 0.95, alpha: 1), UIColor(red: 0.02, green: 0.05, blue: 0.2, alpha: 1))
        ),
        Track(
            uri: "lyricdrive-demo:track:2",
            name: "Signal Lost",
            artist: "LyricDrive Demo",
            album: "Simulator Sessions",
            durationMs: 185_000,
            // Long intro (exercises "before the first lyric"), uneven fast lines, and an
            // instrumental break (empty line → "♪").
            lyrics: [
                (12.0, "Static on the line"),
                (14.5, "Can you hear me now"),
                (17.0, "Tunnel swallowing the sound"),
                (21.5, "Bars going down, down, down"),
                (24.0, "Signal lost"),
                (26.0, "Signal lost"),
                (29.5, "Talking to the dark again"),
                (33.0, "Echo of a friend"),
                (38.0, ""),
                (58.0, "Back above the ground"),
                (61.0, "Voices coming through"),
                (63.5, "Every word I missed"),
                (66.0, "Found its way to you"),
                (70.0, "Signal found"),
                (72.0, "Signal found"),
                (76.0, "Loud and clear tonight"),
                (80.0, "Every light is green"),
                (84.5, "Everything's alright"),
                (90.0, ""),
                (110.0, "Static on the line"),
                (113.0, "But I know you're there"),
                (117.0, "Signal lost, signal found"),
                (121.0, "Anywhere"),
            ],
            colors: (UIColor(red: 0.85, green: 0.25, blue: 0.55, alpha: 1), UIColor(red: 0.15, green: 0.02, blue: 0.12, alpha: 1))
        ),
        Track(
            uri: "lyricdrive-demo:track:3",
            name: "Open Road (Instrumental)",
            artist: "LyricDrive Demo",
            album: "Simulator Sessions",
            durationMs: 160_000,
            lyrics: nil,
            colors: (UIColor(red: 0.2, green: 0.8, blue: 0.5, alpha: 1), UIColor(red: 0.02, green: 0.12, blue: 0.08, alpha: 1))
        ),
    ]

    /// The demo lyrics for a track, as LRC text run through the real `LRCParser`.
    static func lyricsResult(trackName: String, artistName: String) -> LyricsFetchResult? {
        guard let track = tracks.first(where: { $0.name == trackName && $0.artist == artistName }) else { return nil }
        guard let lyrics = track.lyrics else { return .notFound }

        let lrc = lyrics.map { seconds, text in
            let totalCentiseconds = Int((seconds * 100).rounded())
            return String(
                format: "[%02d:%02d.%02d] %@",
                totalCentiseconds / 6000, (totalCentiseconds / 100) % 60, totalCentiseconds % 100, text
            )
        }.joined(separator: "\n")
        return .synced(LRCParser.parse(lrc))
    }

    /// Locally generated artwork: a per-track gradient with a music note.
    static func artwork(for track: Track) -> UIImage {
        let size = CGSize(width: 300, height: 300)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [track.colors.0.cgColor, track.colors.1.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: 120, weight: .semibold)
            if let note = UIImage(systemName: "music.note", withConfiguration: configuration)?
                .withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal) {
                note.draw(at: CGPoint(x: (size.width - note.size.width) / 2, y: (size.height - note.size.height) / 2))
            }
        }
    }
}
#endif

//
//  NoLyricsVisualizerView.swift
//  LyricDrive
//

import CoreImage
import SwiftUI
import UIKit

/// A procedural equalizer-style visualizer shown in place of the lyric window when no synced
/// lyrics are available. Deliberately decoupled from `LyricsManager`/`SpotifyManager` — it takes
/// only plain values, so it can be reused (e.g. by a future CarPlay scene) without pulling in
/// either dependency.
///
/// There is no real audio spectrum data available from Spotify App Remote, so bar heights are a
/// deterministic function of `playbackPositionMs`, the bar's index, and a hash of `trackURI`.
/// Because it's a pure function of those inputs rather than accumulated/random state, playback
/// pausing automatically freezes the pattern (since `playbackPositionMs` itself stops advancing),
/// and a track change instantly reseeds the whole pattern with no explicit reset step needed.
struct NoLyricsVisualizerView: View {
    let playbackPositionMs: Int
    let isPaused: Bool
    let trackURI: String
    let artwork: UIImage?
    let message: String

    private let barCount = 20

    @State private var accentColor: Color = .white

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { _ in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barGradient)
                            .frame(height: height)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.18), value: barHeights)
            }
            .frame(height: 110)

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: artwork.map(ObjectIdentifier.init)) {
            accentColor = Self.resolveAccentColor(from: artwork) ?? .white
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(colors: [accentColor.opacity(0.9), .white], startPoint: .bottom, endPoint: .top)
    }

    /// Heights for all bars at the current playback position — a pure function of `trackURI`,
    /// bar index, and `playbackPositionMs`, so it naturally freezes when playback is paused
    /// (because `playbackPositionMs` stops advancing) and reseeds instantly on a track change.
    private var barHeights: [CGFloat] {
        let seed = Self.seed(for: trackURI)
        return (0..<barCount).map { index in
            Self.barHeight(seed: seed, index: index, playbackPositionMs: playbackPositionMs, isPaused: isPaused)
        }
    }

    private static func barHeight(seed: UInt64, index: Int, playbackPositionMs: Int, isPaused: Bool) -> CGFloat {
        let minHeight: CGFloat = 8
        let maxHeight: CGFloat = 100

        // A stable 0...1 offset per bar, derived from the track seed so every bar in a given
        // track has its own fixed frequency/phase rather than all bars moving in lockstep.
        let barOffset = Double((seed &+ UInt64(index) &* 2_654_435_761) % 1_000) / 1_000.0
        let frequency = 1.1 + barOffset * 1.6
        let phase = barOffset * 2 * .pi

        let t = Double(playbackPositionMs) / 1000.0
        let primary = sin(t * frequency * 2 * .pi + phase)
        let harmonic = sin(t * frequency * 3.3 * 2 * .pi + phase * 1.7) * 0.35
        let normalized = min(max(((primary + harmonic) + 1.35) / 2.7, 0), 1)

        // While paused, don't just freeze in place (which could land on any height, including a
        // tall one) — visually settle to a short, gently-varied resting baseline.
        let amplitude = isPaused ? 0.25 : 1.0
        let baseline = isPaused ? 0.18 : 0.0
        let effective = min(baseline + normalized * amplitude, 1.0)

        return minHeight + CGFloat(effective) * (maxHeight - minHeight)
    }

    /// A small deterministic string hash (FNV-1a). Deliberately not Swift's built-in
    /// `hashValue`/`Hasher`, which mix in a random per-process seed and so wouldn't give a
    /// stable pattern for the same track from one launch to the next.
    private static func seed(for trackURI: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in trackURI.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash == 0 ? 1 : hash
    }

    /// Cheap average-color extraction via Core Image's `CIAreaAverage`, used as a subtle accent
    /// for the bars. Returns `nil` (falling back to plain white) if there's no artwork yet or the
    /// filter pipeline fails for any reason.
    private static func resolveAccentColor(from image: UIImage?) -> Color? {
        guard let image, let ciImage = CIImage(image: image) else { return nil }

        let extentVector = CIVector(
            x: ciImage.extent.origin.x,
            y: ciImage.extent.origin.y,
            z: ciImage.extent.size.width,
            w: ciImage.extent.size.height
        )
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: extentVector,
        ]), let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return Color(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        NoLyricsVisualizerView(
            playbackPositionMs: 12_345,
            isPaused: false,
            trackURI: "spotify:track:preview",
            artwork: nil,
            message: "No synced lyrics available"
        )
        .padding()
    }
}

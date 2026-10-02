//
//  LyricDriveTheme.swift
//  LyricDrive
//

import CoreImage
import SwiftUI
import UIKit

/// Design tokens for the iPhone UI (dark-first). CarPlay does not use these.
enum LDTheme {
    // MARK: Color

    /// App background.
    static let night = Color(red: 0.024, green: 0.027, blue: 0.039)
    /// Grouped-list rows and sheets.
    static let surface = Color(red: 0.071, green: 0.078, blue: 0.098)
    static let sheet = Color(red: 0.082, green: 0.090, blue: 0.114)
    /// Glass fill/stroke on top of `night` or artwork.
    static let glass = Color.white.opacity(0.06)
    static let glassStroke = Color.white.opacity(0.09)
    /// The primary (white) control fill.
    static let primaryFill = Color(red: 0.957, green: 0.961, blue: 0.969)

    /// Marks live state: the current lyric's glow, connection, progress.
    static let aurora = Color(red: 0.215, green: 0.825, blue: 0.948)
    /// Marks states that need the user's attention (reconnect, access) and the onboarding glow.
    static let attention = Color(red: 0.768, green: 0.676, blue: 1.0)

    static let textPrimary = Color(red: 0.949, green: 0.953, blue: 0.965)
    static let textSecondary = textPrimary.opacity(0.66)
    static let textTertiary = textPrimary.opacity(0.5)

    // MARK: Layout (4pt grid)

    static let screenMargin: CGFloat = 24
    static let cardRadius: CGFloat = 22
    static let rowRadius: CGFloat = 18
    static let sheetRadius: CGFloat = 32
    static let maxContentWidth: CGFloat = 520
}

// MARK: - Buttons

/// The one white, fully round primary action per screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(LDTheme.night)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 20)
            .background(Capsule().fill(LDTheme.primaryFill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.55)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Secondary glass capsule.
struct GlassButtonStyle: ButtonStyle {
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LDTheme.textPrimary)
            .padding(.horizontal, 22)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 46)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .contentShape(Capsule())
    }
}

/// Round icon button used for the ••• menu and transport controls.
struct CircleIconLabel: View {
    let systemName: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LDTheme.textPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(.black.opacity(0.25)))
            .overlay(Circle().strokeBorder(.white.opacity(0.1)))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

// MARK: - Surfaces

extension View {
    /// Translucent rounded card on top of the dark background or artwork tint.
    func glassCard(radius: CGFloat = LDTheme.cardRadius, fill: Color = LDTheme.glass, stroke: Color = LDTheme.glassStroke) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke))
    }
}

/// Small tracked-caps section label.
struct EyebrowText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(LDTheme.textTertiary)
    }
}

// MARK: - Service mark

/// Neutral service mark: an SF Symbol on a glass tile, always shown alongside (or labelled by) the
/// service's name. Deliberately not an imitation of either brand's logo; swap in the official
/// Spotify logo / Apple Music badge here, following each brand's guidelines, once supplied.
struct ServiceMark: View {
    let service: MusicService
    var size: CGFloat = 16

    private var symbol: String {
        switch service {
        case .spotify: "waveform"
        case .appleMusic: "music.note"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(.white.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.14))
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(LDTheme.textPrimary)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Connection status

/// Top-left status pill. A live dot means connected; words only appear when something needs
/// attention, and every state also carries text for VoiceOver (never color alone).
struct ConnectionStatusPill: View {
    let session: MusicSessionState
    var onAttentionTap: () -> Void = {}

    private enum Display { case live, working, attention }

    private var display: Display {
        switch session.phase {
        case .connected: .live
        case .connecting, .reconnecting: .working
        case .disconnected, .needsUserAction, .notConnected: .attention
        }
    }

    var body: some View {
        let display = display
        Button(action: onAttentionTap) {
            HStack(spacing: 8) {
                ServiceMark(service: session.service, size: 16)
                    .opacity(display == .attention ? 0.55 : 1)
                switch display {
                case .live:
                    Text(session.service.displayName)
                    Circle()
                        .fill(LDTheme.aurora)
                        .frame(width: 6, height: 6)
                        .shadow(color: LDTheme.aurora, radius: 4)
                case .working:
                    Text(session.service.displayName)
                    Text(session.phase == .connecting ? "· Connecting" : "· Reconnecting")
                        .foregroundStyle(LDTheme.textTertiary)
                    ProgressView()
                        .controlSize(.mini)
                        .tint(LDTheme.textSecondary)
                case .attention:
                    Text(session.attentionPillText)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(LDTheme.textPrimary)
            .lineLimit(1)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(display == .attention ? LDTheme.attention.opacity(0.14) : .black.opacity(0.25)))
            .overlay(Capsule().strokeBorder(display == .attention ? LDTheme.attention.opacity(0.4) : .white.opacity(0.1)))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(display != .attention)
        .animation(.easeInOut(duration: 0.25), value: display)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: display))
        .accessibilityAddTraits(display == .attention ? .isButton : [])
    }

    private func accessibilityText(for display: Display) -> String {
        let name = session.service.displayName
        switch display {
        case .live: return "\(name) connected"
        case .working: return session.phase == .connecting ? "Connecting to \(name)" : "Reconnecting to \(name)"
        case .attention: return "\(name) needs attention. \(session.attentionPillText)."
        }
    }
}

// MARK: - Music service card

/// Selectable service card used in onboarding.
struct MusicServiceCard: View {
    let service: MusicService
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ServiceMark(service: service, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.displayName)
                        .font(.headline)
                        .foregroundStyle(LDTheme.textPrimary)
                    Text(service.requirement)
                        .font(.footnote)
                        .foregroundStyle(LDTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(isSelected ? 0 : 0.25), lineWidth: 1.5)
                    if isSelected {
                        Circle().fill(LDTheme.aurora)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LDTheme.night)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(18)
            .glassCard(
                fill: .white.opacity(isSelected ? 0.07 : 0.04),
                stroke: isSelected ? LDTheme.aurora : .white.opacity(0.08)
            )
            .shadow(color: isSelected ? LDTheme.aurora.opacity(0.18) : .clear, radius: 18)
            .contentShape(RoundedRectangle(cornerRadius: LDTheme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(service.displayName). \(service.requirement)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Ambient background

/// Full-screen background tinted by the current artwork: a pre-blurred, heavily darkened copy of
/// the art, cross-fading between songs. Blurred once per artwork (not per frame), so the 10Hz
/// playback updates elsewhere on screen never re-run the filter.
struct AmbientBackground: View {
    let artwork: UIImage?
    /// Glow used when there is no artwork.
    var fallbackTint: Color = LDTheme.aurora

    @State private var blurred: UIImage?

    var body: some View {
        ZStack {
            LDTheme.night

            if let blurred {
                // Overlay on a flexible clear view so the fill image never sizes its container.
                Color.clear
                    .overlay {
                        Image(uiImage: blurred)
                            .resizable()
                            .scaledToFill()
                            .saturation(1.25)
                            .opacity(0.85)
                    }
                    .clipped()
                    .transition(.opacity)
                    .id(ObjectIdentifier(blurred))
            } else {
                RadialGradient(colors: [fallbackTint.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 520)
                    .transition(.opacity)
            }

            LinearGradient(
                colors: [LDTheme.night.opacity(0.35), LDTheme.night.opacity(0.62), LDTheme.night.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .task(id: artwork.map(ObjectIdentifier.init)) {
            let result = artwork.flatMap { Self.blur($0) }
            withAnimation(.easeInOut(duration: 0.8)) { blurred = result }
        }
        .accessibilityHidden(true)
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func blur(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.width, extent.height) * 0.08)
            .cropped(to: extent)
        guard let cgImage = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

//
//  WhatsNewView.swift
//  LyricDrive
//

import SwiftUI

/// Persisted onboarding/education progress. Separate from connection state: viewing help never
/// changes the selected music service or sends anyone back through onboarding.
enum OnboardingProgress {
    /// Set when the walkthrough is finished or skipped during first-run onboarding.
    static let hasCompletedWalkthroughKey = "onboarding.hasCompletedWalkthrough"
    /// The release whose What's New was last shown (or made unnecessary by the walkthrough).
    static let whatsNewVersionKey = "whatsNew.lastSeenVersion"
    /// The release the current What's New describes.
    static let whatsNewVersion = "1.1"
}

/// One-time sheet for people updating from an earlier version, who never saw the walkthrough.
/// "Explore LyricDrive" opens the walkthrough in place.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isExploring = false

    private struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private static let items = [
        Item(symbol: "music.note", title: "Apple Music", detail: "Spotify and Apple Music are now supported."),
        Item(symbol: "car.fill", title: "CarPlay", detail: "Improved Now Playing, with lyrics for whichever music app you use."),
        Item(symbol: "square.grid.2x2.fill", title: "Widgets", detail: "Add lyrics and playback widgets to your iPhone."),
    ]

    var body: some View {
        Group {
            if isExploring {
                WalkthroughView(mode: .help) { dismiss() }
            } else {
                summary
            }
        }
        .background(LDTheme.night.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var summary: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EyebrowText("What's new in LyricDrive \(OnboardingProgress.whatsNewVersion)")
                    Text("More ways to\nfollow along.")
                        .font(.largeTitle.weight(.bold))
                        .tracking(-0.5)
                        .foregroundStyle(LDTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Self.items) { item in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: item.symbol)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(LDTheme.aurora)
                                    .frame(width: 32)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.headline)
                                        .foregroundStyle(LDTheme.textPrimary)
                                    Text(item.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(LDTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 32)

                    Spacer(minLength: 32)

                    Button("Explore LyricDrive") {
                        isExploring = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint("Shows how LyricDrive works.")

                    Button("Not Now") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LDTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 16)
                .frame(maxWidth: LDTheme.maxContentWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

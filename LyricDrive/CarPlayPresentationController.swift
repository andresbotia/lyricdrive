//
//  CarPlayPresentationController.swift
//  LyricDrive
//

import CarPlay
import Combine
import UIKit

/// Translates shared `SpotifyManager`/`LyricsManager` state into the CarPlay root template.
///
/// Purely a presentation layer: no authentication, network, Keychain, or playback-clock logic
/// lives here. It observes only *semantic* changes (track, artwork, lyric line, connection,
/// paused state) — never the ~10Hz `playbackPositionMs` — and rebuilds the template only when
/// the derived `Snapshot` actually differs from what's already on screen.
final class CarPlayPresentationController {

    let rootTemplate: CPListTemplate

    private let spotifyManager: SpotifyManager
    private let lyricsManager: LyricsManager
    private var cancellables = Set<AnyCancellable>()
    private var lastSnapshot: Snapshot?
    private lazy var placeholderArtwork = Self.makePlaceholderArtwork()

    private static let disconnectedTitle = "LyricDrive"
    private static let disconnectedMessage = "Open LyricDrive on your iPhone to connect Spotify."

    /// What the lyric area should show. `window` always holds five slots (line -2 … line +2),
    /// with the current line at index 2.
    private enum LyricsPresentation: Equatable {
        case none
        case message(String)
        case window([String])
    }

    /// Everything the template depends on. Artwork is compared by identity — `SpotifyManager`
    /// assigns a new `UIImage` instance exactly when the artwork changes.
    private struct Snapshot: Equatable {
        var isConnected: Bool
        var trackURI: String
        var albumName: String
        var artistName: String
        var isPaused: Bool
        var artworkID: ObjectIdentifier?
        var lyrics: LyricsPresentation
    }

    init(spotifyManager: SpotifyManager, lyricsManager: LyricsManager) {
        self.spotifyManager = spotifyManager
        self.lyricsManager = lyricsManager
        rootTemplate = CPListTemplate(title: Self.disconnectedTitle, sections: [])
        showDisconnected()
    }

    // MARK: - Lifecycle

    func start() {
        let triggers: [AnyPublisher<Void, Never>] = [
            spotifyManager.$isConnected.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$trackURI.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$albumName.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$artistName.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$isPaused.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$albumArtwork.map { $0.map(ObjectIdentifier.init) }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            lyricsManager.$state.map { _ in }.eraseToAnyPublisher(),
            lyricsManager.$lines.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            // Reassigned on every clock tick, but only actually changes when the line does.
            lyricsManager.$currentLineIndex.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(triggers)
            // `@Published` emits during `willSet`; hop to the next main-queue turn so the snapshot
            // reads settled values. A burst of changes (e.g. a track change touching several
            // properties) collapses to one template update via the snapshot comparison.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func stop() {
        cancellables.removeAll()
        lastSnapshot = nil
    }

    // MARK: - State translation

    private func refresh() {
        let snapshot = makeSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        if !snapshot.isConnected {
            showDisconnected()
        } else if #available(iOS 26.4, *) {
            showDetailsHeader(for: snapshot)
        } else {
            showListFallback(for: snapshot)
        }
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            isConnected: spotifyManager.isConnected,
            trackURI: spotifyManager.trackURI,
            albumName: spotifyManager.albumName,
            artistName: spotifyManager.artistName,
            isPaused: spotifyManager.isPaused,
            artworkID: spotifyManager.albumArtwork.map(ObjectIdentifier.init),
            lyrics: makeLyricsPresentation()
        )
    }

    private func makeLyricsPresentation() -> LyricsPresentation {
        guard !spotifyManager.trackURI.isEmpty else { return .none }

        switch lyricsManager.state {
        case .idle:
            return .none
        case .loading:
            return .message("Loading lyrics…")
        case .plainOnly, .notFound:
            return .message("No synced lyrics available")
        case .error:
            return .message("Lyrics unavailable")
        case .synced:
            let lines = lyricsManager.lines
            // Before the first timestamp there's no current line yet: show a note as the
            // "current" slot with the opening lines queued up below it.
            let center = lyricsManager.currentLineIndex ?? -1
            let window = (-2...2).map { offset -> String in
                let index = center + offset
                let text = lines.indices.contains(index)
                    ? lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return offset == 0 && text.isEmpty ? "♪" : text
            }
            return .window(window)
        }
    }

    /// Ordered from most to least preferred, as `bodyVariants` expects: five lines, three lines,
    /// then the current line alone. Plain text only — CarPlay owns typography for this area.
    private func bodyVariants(for lyrics: LyricsPresentation) -> [NSAttributedString] {
        switch lyrics {
        case .none:
            return []
        case .message(let message):
            return [NSAttributedString(string: message)]
        case .window(let window):
            return [
                window.joined(separator: "\n"),
                window[1...3].joined(separator: "\n"),
                window[2],
            ].map { NSAttributedString(string: $0) }
        }
    }

    // MARK: - Template rendering

    private func showDisconnected() {
        if #available(iOS 26.4, *) {
            rootTemplate.listHeader = nil
        }
        rootTemplate.emptyViewTitleVariants = [Self.disconnectedTitle]
        rootTemplate.emptyViewSubtitleVariants = [Self.disconnectedMessage]
        rootTemplate.updateSections([])
    }

    @available(iOS 26.4, *)
    private func showDetailsHeader(for snapshot: Snapshot) {
        // Assigning a fresh header is the documented way to update `listHeader` dynamically.
        // This only happens on semantic changes (a new lyric line every few seconds at most).
        rootTemplate.listHeader = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: spotifyManager.albumArtwork ?? placeholderArtwork),
            title: headerTitle(for: snapshot),
            subtitle: headerSubtitle(for: snapshot),
            bodyVariants: bodyVariants(for: snapshot.lyrics),
            actionButtons: makeActionButtons(isPaused: snapshot.isPaused)
        )
        rootTemplate.emptyViewTitleVariants = []
        rootTemplate.emptyViewSubtitleVariants = []
        if !rootTemplate.sections.isEmpty {
            rootTemplate.updateSections([])
        }
    }

    /// Pre-iOS 26.4: no details header, so the same information is laid out as list rows.
    private func showListFallback(for snapshot: Snapshot) {
        let nowPlaying = CPListItem(
            text: headerTitle(for: snapshot),
            detailText: headerSubtitle(for: snapshot),
            image: spotifyManager.albumArtwork ?? placeholderArtwork
        )

        let lyricItems: [CPListItem]
        switch snapshot.lyrics {
        case .none:
            lyricItems = []
        case .message(let message):
            lyricItems = [CPListItem(text: message, detailText: nil)]
        case .window(let window):
            lyricItems = window.enumerated().map { offset, text in
                let item = CPListItem(text: text, detailText: nil)
                item.isPlaying = offset == 2
                return item
            }
        }

        let controls = makeControlItems(isPaused: snapshot.isPaused)

        rootTemplate.emptyViewTitleVariants = []
        rootTemplate.emptyViewSubtitleVariants = []
        rootTemplate.updateSections(
            [
                CPListSection(items: [nowPlaying]),
                lyricItems.isEmpty ? nil : CPListSection(items: lyricItems),
                CPListSection(items: controls),
            ].compactMap { $0 }
        )
    }

    private func headerTitle(for snapshot: Snapshot) -> String {
        snapshot.albumName.isEmpty ? Self.disconnectedTitle : snapshot.albumName
    }

    private func headerSubtitle(for snapshot: Snapshot) -> String? {
        if !snapshot.artistName.isEmpty { return snapshot.artistName }
        return snapshot.trackURI.isEmpty ? "Start playback in Spotify." : nil
    }

    // MARK: - Controls

    private enum Control {
        case previous, playPause, next
    }

    /// Previous / Play-Pause / Next, trimmed to what the header can display — Play/Pause is kept
    /// first, then Next, then Previous.
    @available(iOS 26.4, *)
    private func makeActionButtons(isPaused: Bool) -> [CPButton] {
        let controls: [Control]
        switch CPListTemplateDetailsHeader.maximumActionButtonCount {
        case 3...: controls = [.previous, .playPause, .next]
        case 2: controls = [.playPause, .next]
        case 1: controls = [.playPause]
        default: controls = []
        }

        return controls.map { control in
            CPButton(image: symbolImage(for: control, isPaused: isPaused)) { [weak self] _ in
                self?.perform(control)
            }
        }
    }

    private func makeControlItems(isPaused: Bool) -> [CPListItem] {
        [Control.previous, .playPause, .next].map { control in
            let item = CPListItem(
                text: title(for: control, isPaused: isPaused),
                detailText: nil,
                image: symbolImage(for: control, isPaused: isPaused)
            )
            item.handler = { [weak self] _, completion in
                self?.perform(control)
                completion()
            }
            return item
        }
    }

    private func perform(_ control: Control) {
        switch control {
        case .previous: spotifyManager.previousTrack()
        case .playPause: spotifyManager.togglePlayPause()
        case .next: spotifyManager.nextTrack()
        }
    }

    private func title(for control: Control, isPaused: Bool) -> String {
        switch control {
        case .previous: "Previous"
        case .playPause: isPaused ? "Play" : "Pause"
        case .next: "Next"
        }
    }

    private func symbolImage(for control: Control, isPaused: Bool) -> UIImage {
        let name = switch control {
        case .previous: "backward.fill"
        case .playPause: isPaused ? "play.fill" : "pause.fill"
        case .next: "forward.fill"
        }
        return UIImage(systemName: name) ?? UIImage()
    }

    // MARK: - Artwork placeholder

    /// Local-only stand-in shown until `SpotifyManager.albumArtwork` arrives.
    private static func makePlaceholderArtwork() -> UIImage {
        let size = CGSize(width: 300, height: 300)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let configuration = UIImage.SymbolConfiguration(pointSize: 110, weight: .regular)
            guard let note = UIImage(systemName: "music.note", withConfiguration: configuration)?
                .withTintColor(UIColor(white: 0.55, alpha: 1), renderingMode: .alwaysOriginal) else { return }
            note.draw(at: CGPoint(x: (size.width - note.size.width) / 2, y: (size.height - note.size.height) / 2))
        }
    }
}

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
/// paused state) — never the ~10Hz `playbackPositionMs` — and touches the template only when the
/// derived header state or lyric rows actually differ from what's already on screen.
///
/// Layout (iOS 26.4+): the system details header carries artwork, song, artist and transport
/// controls; the lyrics are real list rows beneath it. CarPlay owns all positioning.
final class CarPlayPresentationController {

    let rootTemplate: CPListTemplate

    private let spotifyManager: SpotifyManager
    private let lyricsManager: LyricsManager
    private var cancellables = Set<AnyCancellable>()
    private var lastHeader: HeaderState?
    private var lastLyricRows: [LyricRow]?
    /// The list items currently on screen for the lyric section, kept so a line change can update
    /// them in place (no list reload) when the row count is unchanged.
    private var lyricItems: [CPListItem] = []
    private lazy var placeholderArtwork = Self.makePlaceholderArtwork()

    private static let disconnectedTitle = "Spotify Not Connected"
    private static let disconnectedMessage = "Open LyricDrive on your iPhone to connect Spotify."

    /// Lyric lines shown on each side of the current line.
    private static let contextLineCount = 2

    /// One display-only row in the lyric section.
    private struct LyricRow: Equatable {
        enum Role: Equatable {
            /// The active line: now-playing indicator, full-strength text.
            case current
            /// Lines around the active one (or upcoming lines before the first timestamp):
            /// rendered disabled, which CarPlay draws dimmed.
            case context
            /// A status message (loading / no synced lyrics / error): plain, full-strength text.
            case message
        }

        var text: String
        var role: Role
    }

    /// Everything the details header depends on. Artwork is compared by identity —
    /// `SpotifyManager` assigns a new `UIImage` instance exactly when the artwork changes.
    private struct HeaderState: Equatable {
        var isConnected: Bool
        var trackURI: String
        var trackName: String
        var artistName: String
        var isPaused: Bool
        var artworkID: ObjectIdentifier?
    }

    init(spotifyManager: SpotifyManager, lyricsManager: LyricsManager) {
        self.spotifyManager = spotifyManager
        self.lyricsManager = lyricsManager
        // No navigation title: the screen is about the song, not the app name.
        rootTemplate = CPListTemplate(title: nil, sections: [])
        showDisconnected()
    }

    // MARK: - Lifecycle

    func start() {
        let triggers: [AnyPublisher<Void, Never>] = [
            spotifyManager.$isConnected.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$trackURI.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$trackName.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$artistName.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$isPaused.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$albumArtwork.map { $0.map(ObjectIdentifier.init) }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            lyricsManager.$state.map { _ in }.eraseToAnyPublisher(),
            lyricsManager.$lines.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            // Reassigned on every clock tick, but only actually changes when the line does.
            lyricsManager.$currentLineIndex.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(triggers)
            // `@Published` emits during `willSet`; hop to the next main-queue turn so the state
            // reads settled values. A burst of changes (e.g. a track change touching several
            // properties) collapses to at most one header and one lyric update via comparison.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func stop() {
        cancellables.removeAll()
        lastHeader = nil
        lastLyricRows = nil
        lyricItems = []
    }

    // MARK: - State translation

    private func refresh() {
        let header = makeHeaderState()
        let lyricRows = makeLyricRows()
        let headerChanged = header != lastHeader
        let lyricsChanged = lyricRows != lastLyricRows
        guard headerChanged || lyricsChanged else { return }
        lastHeader = header
        lastLyricRows = lyricRows

        if !header.isConnected {
            showDisconnected()
        } else if #available(iOS 26.4, *) {
            if headerChanged {
                showDetailsHeader(for: header)
            }
            if lyricsChanged {
                showLyricSection(lyricRows)
            }
        } else {
            showListFallback(header: header, lyricRows: lyricRows)
        }
    }

    private func makeHeaderState() -> HeaderState {
        HeaderState(
            isConnected: spotifyManager.isConnected,
            trackURI: spotifyManager.trackURI,
            trackName: spotifyManager.trackName,
            artistName: spotifyManager.artistName,
            isPaused: spotifyManager.isPaused,
            artworkID: spotifyManager.albumArtwork.map(ObjectIdentifier.init)
        )
    }

    private func makeLyricRows() -> [LyricRow] {
        guard spotifyManager.isConnected, !spotifyManager.trackURI.isEmpty else { return [] }

        switch lyricsManager.state {
        case .idle:
            return []
        case .loading:
            return [LyricRow(text: "Loading lyrics…", role: .message)]
        case .plainOnly, .notFound:
            return [LyricRow(text: "No synced lyrics available", role: .message)]
        case .error:
            return [LyricRow(text: "Lyrics unavailable", role: .message)]
        case .synced:
            let lines = lyricsManager.lines
            guard !lines.isEmpty else { return [] }
            let context = Self.contextLineCount

            guard let current = lyricsManager.currentLineIndex else {
                // Before the first timestamp: just the opening lines, none marked current yet.
                return lines.prefix(context + 1).map { LyricRow(text: Self.displayText($0.text), role: .context) }
            }

            // Only lines that exist — no placeholder rows at the start or end of the song.
            let range = max(current - context, 0)...min(current + context, lines.count - 1)
            return range.map { index in
                LyricRow(text: Self.displayText(lines[index].text), role: index == current ? .current : .context)
            }
        }
    }

    /// Empty LRC lines mark instrumental breaks; show them as a note rather than a blank row.
    private static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "♪" : trimmed
    }

    // MARK: - Template rendering

    private func showDisconnected() {
        if #available(iOS 26.4, *) {
            rootTemplate.listHeader = nil
        }
        lyricItems = []
        rootTemplate.emptyViewTitleVariants = [Self.disconnectedTitle]
        rootTemplate.emptyViewSubtitleVariants = [Self.disconnectedMessage]
        rootTemplate.updateSections([])
    }

    @available(iOS 26.4, *)
    private func showDetailsHeader(for header: HeaderState) {
        // Assigning a fresh header is the documented way to update `listHeader` dynamically.
        // Lyrics are deliberately not passed as `bodyVariants`: those are alternatives of which
        // CarPlay displays exactly one, so they live in the list rows below instead.
        rootTemplate.listHeader = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: spotifyManager.albumArtwork ?? placeholderArtwork),
            title: headerTitle(for: header),
            subtitle: headerSubtitle(for: header),
            actionButtons: makeActionButtons(isPaused: header.isPaused)
        )
        rootTemplate.emptyViewTitleVariants = []
        rootTemplate.emptyViewSubtitleVariants = []
    }

    /// Updates the lyric section. When the new rows line up one-to-one with the items already on
    /// screen (the common case: the song advancing a line mid-verse), the existing items are
    /// updated in place; otherwise the section is replaced.
    @available(iOS 26.4, *)
    private func showLyricSection(_ rows: [LyricRow]) {
        if !lyricItems.isEmpty, lyricItems.count == rows.count {
            for (item, row) in zip(lyricItems, rows) {
                configure(item, for: row)
            }
            return
        }

        lyricItems = makeLyricItems(rows)
        rootTemplate.updateSections(lyricItems.isEmpty ? [] : [CPListSection(items: lyricItems)])
    }

    /// Pre-iOS 26.4: no details header, so song info and controls are list rows too, around the
    /// same lyric rows. The whole list is rebuilt on any change.
    private func showListFallback(header: HeaderState, lyricRows: [LyricRow]) {
        let nowPlaying = CPListItem(
            text: headerTitle(for: header),
            detailText: headerSubtitle(for: header),
            image: spotifyManager.albumArtwork ?? placeholderArtwork
        )
        lyricItems = makeLyricItems(lyricRows)
        let controls = makeControlItems(isPaused: header.isPaused)

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

    // MARK: - Lyric rows

    private func makeLyricItems(_ rows: [LyricRow]) -> [CPListItem] {
        rows.map { row in
            let item = CPListItem(text: row.text, detailText: nil)
            item.playingIndicatorLocation = .leading
            // Display only: selecting a lyric does nothing beyond completing the tap.
            item.handler = { _, completion in completion() }
            configure(item, for: row)
            return item
        }
    }

    /// Current line: the system now-playing indicator and normal (enabled) text. Context lines:
    /// disabled, which CarPlay renders dimmed and non-selectable. Messages: plain enabled text.
    private func configure(_ item: CPListItem, for row: LyricRow) {
        if item.text != row.text {
            item.setText(row.text)
        }
        item.isPlaying = row.role == .current
        item.isEnabled = row.role != .context
    }

    private func headerTitle(for header: HeaderState) -> String {
        header.trackName.isEmpty ? "Not Playing" : header.trackName
    }

    private func headerSubtitle(for header: HeaderState) -> String? {
        if !header.artistName.isEmpty { return header.artistName }
        return header.trackURI.isEmpty ? "Start playback in Spotify." : nil
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

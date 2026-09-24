//
//  CarPlayPresentationController.swift
//  LyricDrive
//

import CarPlay
import Combine
import UIKit

/// Translates shared `SpotifyManager`/`LyricsManager` state into CarPlay templates.
///
/// Purely a presentation layer: no authentication, network, Keychain, or playback-clock logic
/// lives here. It observes only *semantic* changes (track, artwork, lyric line, connection,
/// paused state) — never the ~10Hz `playbackPositionMs` — and touches a template only when its
/// derived state actually differs from what's already on screen.
///
/// Structure: a `CPTabBarTemplate` with two tabs, built once per CarPlay connection and never
/// replaced, so whichever tab the driver picked stays selected across song changes:
/// - **Now Playing** — a list template whose details header (iOS 26.4+) carries artwork, song,
///   artist and transport controls; older iOS shows the same as list rows.
/// - **Lyrics** — a list template of up to five display-only lyric rows, or one status row.
/// CarPlay owns all positioning.
final class CarPlayPresentationController {

    let rootTemplate: CPTabBarTemplate

    private let nowPlayingTemplate: CPListTemplate
    private let lyricsTemplate: CPListTemplate

    private let spotifyManager: SpotifyManager
    private let lyricsManager: LyricsManager
    private var cancellables = Set<AnyCancellable>()
    private var lastHeader: HeaderState?
    private var lastLyricRows: [LyricRow]?
    /// The items currently on screen in the Lyrics tab, kept so a line change can update them in
    /// place (no list reload) when the row count is unchanged.
    private var lyricItems: [CPListItem] = []
    private lazy var placeholderArtwork = Self.makePlaceholderArtwork()

    private static let disconnectedTitle = "Spotify Not Connected"
    private static let disconnectedMessage = "Open LyricDrive on your iPhone to connect Spotify."
    private static let connectingTitle = "Connecting to Spotify…"

    /// Lyric lines shown on each side of the current line.
    private static let contextLineCount = 2

    /// One display-only row in the Lyrics tab.
    private struct LyricRow: Equatable {
        enum Role: Equatable {
            /// The active line: marked with the system now-playing indicator.
            case current
            /// Lines around the active one, or upcoming lines before the first timestamp.
            case context
            /// A status message (connecting, no track, loading, no synced lyrics, error).
            case message
        }

        var text: String
        var role: Role
    }

    /// Everything the Now Playing tab depends on. Artwork is compared by identity —
    /// `SpotifyManager` assigns a new `UIImage` instance exactly when the artwork changes.
    private struct HeaderState: Equatable {
        var isConnected: Bool
        var isAutoReconnecting: Bool
        var trackURI: String
        var trackName: String
        var artistName: String
        var isPaused: Bool
        var artworkID: ObjectIdentifier?
    }

    init(spotifyManager: SpotifyManager, lyricsManager: LyricsManager) {
        self.spotifyManager = spotifyManager
        self.lyricsManager = lyricsManager

        // No navigation titles: the tabs name the screens, the content is about the song.
        nowPlayingTemplate = CPListTemplate(title: nil, sections: [])
        nowPlayingTemplate.tabTitle = "Now Playing"
        nowPlayingTemplate.tabImage = UIImage(systemName: "play.circle")

        lyricsTemplate = CPListTemplate(title: nil, sections: [])
        lyricsTemplate.tabTitle = "Lyrics"
        lyricsTemplate.tabImage = UIImage(systemName: "quote.bubble")

        rootTemplate = CPTabBarTemplate(templates: [nowPlayingTemplate, lyricsTemplate])
    }

    // MARK: - Lifecycle

    func start() {
        let triggers: [AnyPublisher<Void, Never>] = [
            spotifyManager.$isConnected.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$isAutoReconnecting.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
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
            // properties) collapses to at most one update per tab via comparison.
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

    /// Updates each tab's *contents* independently. The tab bar itself is never rebuilt or
    /// re-assigned, so the selected tab is left entirely to the driver.
    private func refresh() {
        let header = makeHeaderState()
        if header != lastHeader {
            lastHeader = header
            renderNowPlaying(header)
        }

        let lyricRows = makeLyricRows()
        if lyricRows != lastLyricRows {
            lastLyricRows = lyricRows
            renderLyrics(lyricRows)
        }
    }

    private func makeHeaderState() -> HeaderState {
        HeaderState(
            isConnected: spotifyManager.isConnected,
            isAutoReconnecting: spotifyManager.isAutoReconnecting,
            trackURI: spotifyManager.trackURI,
            trackName: spotifyManager.trackName,
            artistName: spotifyManager.artistName,
            isPaused: spotifyManager.isPaused,
            artworkID: spotifyManager.albumArtwork.map(ObjectIdentifier.init)
        )
    }

    /// Always at least one row, so the Lyrics tab is meaningful in every state.
    private func makeLyricRows() -> [LyricRow] {
        guard spotifyManager.isConnected else {
            let text = spotifyManager.isAutoReconnecting ? Self.connectingTitle : "Spotify not connected"
            return [LyricRow(text: text, role: .message)]
        }
        guard !spotifyManager.trackURI.isEmpty else {
            return [LyricRow(text: "Start playing a song in Spotify", role: .message)]
        }

        switch lyricsManager.state {
        case .idle, .loading:
            return [LyricRow(text: "Loading lyrics…", role: .message)]
        case .plainOnly, .notFound:
            return [LyricRow(text: "No synced lyrics available", role: .message)]
        case .error:
            return [LyricRow(text: "Lyrics unavailable", role: .message)]
        case .synced:
            let lines = lyricsManager.lines
            guard !lines.isEmpty else { return [LyricRow(text: "No synced lyrics available", role: .message)] }
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

    // MARK: - Now Playing tab

    private func renderNowPlaying(_ header: HeaderState) {
        if !header.isConnected {
            if #available(iOS 26.4, *) {
                nowPlayingTemplate.listHeader = nil
            }
            nowPlayingTemplate.emptyViewTitleVariants = [header.isAutoReconnecting ? Self.connectingTitle : Self.disconnectedTitle]
            nowPlayingTemplate.emptyViewSubtitleVariants = header.isAutoReconnecting ? [] : [Self.disconnectedMessage]
            nowPlayingTemplate.updateSections([])
            return
        }

        nowPlayingTemplate.emptyViewTitleVariants = []
        nowPlayingTemplate.emptyViewSubtitleVariants = []

        if #available(iOS 26.4, *) {
            // Assigning a fresh header is the documented way to update `listHeader` dynamically;
            // only this tab's header changes, never the tab bar.
            nowPlayingTemplate.listHeader = CPListTemplateDetailsHeader(
                thumbnail: CPThumbnailImage(image: spotifyManager.albumArtwork ?? placeholderArtwork),
                title: headerTitle(for: header),
                subtitle: headerSubtitle(for: header),
                actionButtons: makeActionButtons(isPaused: header.isPaused)
            )
            if !nowPlayingTemplate.sections.isEmpty {
                nowPlayingTemplate.updateSections([])
            }
        } else {
            // Pre-iOS 26.4: no details header, so song info and controls are list rows.
            let nowPlaying = CPListItem(
                text: headerTitle(for: header),
                detailText: headerSubtitle(for: header),
                image: spotifyManager.albumArtwork ?? placeholderArtwork
            )
            nowPlayingTemplate.updateSections([
                CPListSection(items: [nowPlaying]),
                CPListSection(items: makeControlItems(isPaused: header.isPaused)),
            ])
        }
    }

    private func headerTitle(for header: HeaderState) -> String {
        header.trackName.isEmpty ? "Not Playing" : header.trackName
    }

    private func headerSubtitle(for header: HeaderState) -> String? {
        if !header.artistName.isEmpty { return header.artistName }
        return header.trackURI.isEmpty ? "Start playback in Spotify." : nil
    }

    // MARK: - Lyrics tab

    /// When the new rows line up one-to-one with the items already on screen (the common case:
    /// the song advancing a line mid-verse), the existing items are updated in place; otherwise
    /// only this tab's section is replaced.
    private func renderLyrics(_ rows: [LyricRow]) {
        if !lyricItems.isEmpty, lyricItems.count == rows.count {
            for (item, row) in zip(lyricItems, rows) {
                configure(item, for: row)
            }
            return
        }

        lyricItems = rows.map { row in
            let item = CPListItem(text: row.text, detailText: nil)
            item.playingIndicatorLocation = .leading
            // Display only: selecting a lyric does nothing beyond completing the tap.
            item.handler = { _, completion in completion() }
            configure(item, for: row)
            return item
        }
        lyricsTemplate.updateSections([CPListSection(items: lyricItems)])
    }

    /// The current line gets the system now-playing indicator. All rows stay enabled so
    /// surrounding lines remain fully readable on the car display.
    private func configure(_ item: CPListItem, for row: LyricRow) {
        if item.text != row.text {
            item.setText(row.text)
        }
        item.isPlaying = row.role == .current
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

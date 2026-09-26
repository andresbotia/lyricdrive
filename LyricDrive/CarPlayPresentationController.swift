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
/// Structure: a stable two-tab root. Now Playing displays Spotify metadata and controls
/// directly in a list. Spotify owns audio playback and system Now Playing; this companion
/// does not publish MediaPlayer metadata or register system remote commands.
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
        var detailText: String?
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
        var albumName: String
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
            spotifyManager.$albumName.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
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
            albumName: spotifyManager.albumName,
            isPaused: spotifyManager.isPaused,
            artworkID: spotifyManager.albumArtwork.map(ObjectIdentifier.init)
        )
    }

    /// Always at least one row, so the Lyrics tab is meaningful in every state.
    private func makeLyricRows() -> [LyricRow] {
        guard spotifyManager.isConnected else {
            let text = spotifyManager.isAutoReconnecting ? Self.connectingTitle : "Spotify not connected"
            return [Self.lyricRow(text, role: .message)]
        }
        guard !spotifyManager.trackURI.isEmpty else {
            return [Self.lyricRow("Start playing a song in Spotify", role: .message)]
        }

        switch lyricsManager.state {
        case .idle, .loading:
            return [Self.lyricRow("Loading lyrics…", role: .message)]
        case .plainOnly, .notFound:
            return [Self.lyricRow("No synced lyrics available", role: .message)]
        case .error:
            return [Self.lyricRow("Lyrics unavailable", role: .message)]
        case .synced:
            let lines = lyricsManager.lines
            guard !lines.isEmpty else { return [Self.lyricRow("No synced lyrics available", role: .message)] }
            let context = Self.contextLineCount

            guard let current = lyricsManager.currentLineIndex else {
                // Before the first timestamp: just the opening lines, none marked current yet.
                return lines.prefix(context + 1).map { Self.lyricRow(Self.displayText($0.text), role: .context) }
            }

            // Only lines that exist — no placeholder rows at the start or end of the song.
            let range = max(current - context, 0)...min(current + context, lines.count - 1)
            return range.map { index in
                Self.lyricRow(Self.displayText(lines[index].text), role: index == current ? .current : .context)
            }
        }
    }

    /// Empty LRC lines mark instrumental breaks; show them as a note rather than a blank row.
    private static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "♪" : trimmed
    }

    private static func lyricRow(_ text: String, role: LyricRow.Role) -> LyricRow {
        let (first, second) = splitLyric(text)
        return LyricRow(text: first, detailText: second, role: role)
    }

    /// Preserve every character except the separator whitespace, which is represented by the
    /// line break between the two fields. Favor punctuation near the middle of a long line.
    private static func splitLyric(_ text: String) -> (String, String?) {
        let threshold = 38
        guard text.count > threshold else { return (text, nil) }
        let characters = Array(text)
        let midpoint = characters.count / 2
        let boundaries = characters.indices.filter { index in
            index > 0 && index < characters.count - 1 && characters[index].isWhitespace
        }
        guard !boundaries.isEmpty else { return (text, nil) }
        let preferred = boundaries.filter { index in
            let before = characters[index - 1]
            return before == "," || before == ";" || before == "—" || before == "–" || before == "-"
        }
        let candidates = preferred.filter { abs($0 - midpoint) <= 15 }
        let split = (candidates.isEmpty ? boundaries : candidates).min { abs($0 - midpoint) < abs($1 - midpoint) }!
        let first = String(characters[..<split]).trimmingCharacters(in: .whitespaces)
        let second = String(characters[split...]).trimmingCharacters(in: .whitespaces)
        return second.isEmpty ? (text, nil) : (first, second)
    }

    // MARK: - Now Playing tab

    /// These rows are the destination, not a launcher for CPNowPlayingTemplate. The default
    /// MPNowPlayingInfoCenter belongs to this app, not Spotify; supplying its dictionary does
    /// not make a non-playing companion the system's active Now Playing app.
    private func renderNowPlaying(_ header: HeaderState) {
        guard header.isConnected else {
            nowPlayingTemplate.emptyViewTitleVariants = [header.isAutoReconnecting ? Self.connectingTitle : Self.disconnectedTitle]
            nowPlayingTemplate.emptyViewSubtitleVariants = header.isAutoReconnecting ? [] : [Self.disconnectedMessage]
            nowPlayingTemplate.updateSections([])
            return
        }

        nowPlayingTemplate.emptyViewTitleVariants = []
        nowPlayingTemplate.emptyViewSubtitleVariants = []

        guard !header.trackURI.isEmpty else {
            nowPlayingTemplate.updateSections([CPListSection(items: [
                makeMetadataItem("Not Playing", detailText: "Start playback in Spotify.")
            ])])
            return
        }

        // Give title and artist their own rows. Long values use both text fields rather than
        // competing for the single detail line of a small combined title/artist launcher.
        // Keep the original strings; the host still determines the available display width.
        let (title, titleDetail) = Self.splitLyric(header.trackName.isEmpty ? "Unknown Title" : header.trackName)
        let (artist, artistDetail) = Self.splitLyric(header.artistName.isEmpty ? "Unknown Artist" : header.artistName)
        var metadata = [
            makeMetadataItem(title, detailText: titleDetail, image: spotifyManager.albumArtwork ?? placeholderArtwork),
            makeMetadataItem(artist, detailText: artistDetail),
        ]
        if !header.albumName.isEmpty {
            let (album, albumDetail) = Self.splitLyric(header.albumName)
            metadata.append(makeMetadataItem(album, detailText: albumDetail))
        }
        nowPlayingTemplate.updateSections([
            CPListSection(items: metadata),
            CPListSection(items: makeControlItems(isPaused: header.isPaused)),
        ])
    }

    private func makeMetadataItem(_ text: String, detailText: String?, image: UIImage? = nil) -> CPListItem {
        let item = CPListItem(text: text, detailText: detailText, image: image)
        // Display only. Completing a tap never pushes a template or sends a playback command.
        item.handler = { _, completion in completion() }
        return item
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
            let item = CPListItem(text: row.text, detailText: row.detailText)
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
        if item.detailText != row.detailText {
            item.setDetailText(row.detailText)
        }
        item.isPlaying = row.role == .current
    }

    // MARK: - Controls

    private enum Control {
        case previous, playPause, next
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
        guard spotifyManager.isConnected, !spotifyManager.trackURI.isEmpty else { return }
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

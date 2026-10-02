//
//  CarPlayPresentationController.swift
//  LyricDrive
//

import CarPlay
import Combine
import UIKit

/// Translates the active music service's normalized state (`NowPlayingStore`) and
/// `LyricsManager` into CarPlay templates, for Spotify and Apple Music alike.
///
/// Purely a presentation layer: no authentication, network, Keychain, or playback-clock logic
/// lives here. It observes only *semantic* changes (service, track, artwork, paused state, lyric
/// line, connection/access) — never the ~10Hz `playbackPositionMs` — and touches a template only
/// when its derived state actually differs from what's already on screen.
///
/// Structure: a stable two-tab root that is never rebuilt, so the driver's selected tab survives
/// track changes, metadata enrichment, and service switches.
/// - **Now Playing** — a details header (artwork, title, artist, previous / play-pause / next) on
///   iOS 26.4+, or a short list on older iOS. The music app keeps owning system playback: this
///   companion publishes no MediaPlayer now-playing metadata and registers no remote commands.
/// - **Lyrics** — a list template of up to five display-only lyric rows, or one status row.
///   CarPlay owns all positioning.
@MainActor
final class CarPlayPresentationController {

    let rootTemplate: CPTabBarTemplate

    private let nowPlayingTemplate: CPListTemplate
    private let lyricsTemplate: CPListTemplate
    private let spotifyManager: SpotifyManager
    private let appleMusicManager: AppleMusicManager
    private let nowPlaying: NowPlayingStore
    private let lyricsManager: LyricsManager
    private var cancellables = Set<AnyCancellable>()
    private var lastHeader: HeaderState?
    private var lastLyricRows: [LyricRow]?
    /// The items currently on screen in the Lyrics tab, kept so a line change can update them in
    /// place (no list reload) when the row count is unchanged.
    private var lyricItems: [CPListItem] = []
    private lazy var placeholderArtwork = Self.makePlaceholderArtwork()
    /// Control symbols, rendered once at the size the details header allows.
    private var controlImages: [String: UIImage] = [:]

    /// Lyric lines shown on each side of the current line.
    private static let contextLineCount = 2

    /// Whether the active service can supply a song right now, with the copy to show when it
    /// can't. The only place CarPlay looks at provider-specific connection or access state.
    private enum Availability: Equatable {
        case ready
        /// Connecting / reconnecting / waiting for access: a calm status, no user action asked.
        case working(title: String)
        /// The user has to do something; `message` says what.
        case unavailable(title: String, message: String)
    }

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

    /// Everything the Now Playing tab depends on. Artwork is compared by identity — each
    /// provider assigns a new `UIImage` instance exactly when the artwork changes, and
    /// `NowPlayingStore` clears it on track and service changes.
    private struct HeaderState: Equatable {
        var service: MusicService
        var availability: Availability
        var trackID: String?
        var title: String
        var artist: String
        var isPaused: Bool
        var artworkID: ObjectIdentifier?
    }

    init(spotifyManager: SpotifyManager, appleMusicManager: AppleMusicManager, nowPlaying: NowPlayingStore, lyricsManager: LyricsManager) {
        self.spotifyManager = spotifyManager
        self.appleMusicManager = appleMusicManager
        self.nowPlaying = nowPlaying
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
            // Normalized active-service state. `track` is republished on enrichment too.
            nowPlaying.$activeService.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            nowPlaying.$track.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            nowPlaying.$isPaused.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            nowPlaying.$artwork.map { $0.map(ObjectIdentifier.init) }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            // Inputs to each provider's `MusicSessionState`.
            spotifyManager.$isConnected.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$isConnecting.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$isAutoReconnecting.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$isWakingSpotify.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$requiresSpotifyWake.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.$errorMessage.map { $0 != nil }.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            spotifyManager.hasPendingReconnectPublisher.map { _ in }.eraseToAnyPublisher(),
            appleMusicManager.$authorization.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            appleMusicManager.$isRequestingAuthorization.removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            // Lyrics.
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
        let availability = makeAvailability()

        let header = makeHeaderState(availability)
        if header != lastHeader {
            let previous = lastHeader
            lastHeader = header
            renderNowPlaying(header, previous: previous)
        }

        let lyricRows = makeLyricRows(availability)
        if lyricRows != lastLyricRows {
            lastLyricRows = lyricRows
            renderLyrics(lyricRows)
        }
    }

    /// Derived from the same `MusicSessionState` the iPhone UI uses, so CarPlay asks for action
    /// exactly when the phone would — for Spotify, never while a silent renewal, an automatic
    /// reconnect, or a scheduled retry is still pending.
    private func makeAvailability() -> Availability {
        switch nowPlaying.activeService {
        case .spotify:
            let session = MusicSessionState(spotify: spotifyManager)
            switch session.phase {
            case .connected:
                return .ready
            case .connecting:
                return .working(title: "Connecting to Spotify…")
            case .reconnecting:
                return .working(title: "Reconnecting to Spotify…")
            case .notConnected:
                return .unavailable(title: "Spotify Not Connected", message: "Open LyricDrive on your iPhone to connect Spotify.")
            case .disconnected, .needsUserAction:
                return .unavailable(title: "Spotify Isn't Connected", message: "Start playback in Spotify, then return to LyricDrive.")
            }

        case .appleMusic:
            let session = MusicSessionState(appleMusic: appleMusicManager)
            if session.phase == .connected { return .ready }
            if session.phase == .connecting { return .working(title: "Waiting for Apple Music Access…") }
            switch session.appleMusicAuthorization {
            case .restricted:
                return .unavailable(title: "Apple Music Access Is Restricted", message: "Access is restricted on this iPhone.")
            case .denied:
                return .unavailable(title: "Apple Music Access Is Off", message: "Turn it on in Settings on your iPhone.")
            case .notDetermined, .authorized, nil:
                return .unavailable(title: "Apple Music Access Needed", message: "Open LyricDrive on your iPhone to allow access.")
            }
        }
    }

    private func makeHeaderState(_ availability: Availability) -> HeaderState {
        // Track fields only matter when the service is ready; otherwise they could be the last
        // song from before a disconnect.
        let track = availability == .ready ? nowPlaying.track : nil
        return HeaderState(
            service: nowPlaying.activeService,
            availability: availability,
            trackID: track?.id,
            title: track.map { $0.title.isEmpty ? "Unknown Title" : $0.title } ?? "",
            artist: track.map { $0.artist.isEmpty ? "Unknown Artist" : $0.artist } ?? "",
            isPaused: nowPlaying.isPaused,
            artworkID: track == nil ? nil : nowPlaying.artwork.map(ObjectIdentifier.init)
        )
    }

    /// Always at least one row, so the Lyrics tab is meaningful in every state.
    private func makeLyricRows(_ availability: Availability) -> [LyricRow] {
        switch availability {
        case .ready: break
        case .working(let title), .unavailable(let title, _):
            return [Self.lyricRow(title, role: .message)]
        }
        guard nowPlaying.track != nil else {
            return [Self.lyricRow("Start playing a song in \(nowPlaying.activeService.displayName)", role: .message)]
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

    /// LyricDrive owns this presentation; the music app keeps owning system playback.
    private func renderNowPlaying(_ header: HeaderState, previous: HeaderState?) {
        let status: (title: String, message: String?, spinner: Bool)? = switch header.availability {
        case .working(let title):
            (title, nil, true)
        case .unavailable(let title, let message):
            (title, message, false)
        case .ready where header.trackID == nil:
            ("No Song Playing", "Start playing something in \(header.service.displayName).", false)
        case .ready:
            nil
        }

        // Status states use the template's own empty view: no header, no rows, no controls.
        if let status {
            if #available(iOS 26.4, *) { nowPlayingTemplate.listHeader = nil }
            nowPlayingTemplate.emptyViewTitleVariants = [status.title]
            nowPlayingTemplate.emptyViewSubtitleVariants = status.message.map { [$0] } ?? []
            nowPlayingTemplate.showsSpinnerWhileEmpty = status.spinner
            if nowPlayingTemplate.sectionCount != 0 { nowPlayingTemplate.updateSections([]) }
            return
        }

        nowPlayingTemplate.emptyViewTitleVariants = []
        nowPlayingTemplate.emptyViewSubtitleVariants = []
        nowPlayingTemplate.showsSpinnerWhileEmpty = false

        if #available(iOS 26.4, *) {
            renderDetailsHeader(header, previous: previous)
            return
        }

        // Older iOS: one row for the song (artwork, title, artist) and one row per control, so
        // all three controls sit directly below it without scrolling on typical displays.
        let song = makeMetadataItem(header.title, detailText: header.artist, image: currentArtwork)
        nowPlayingTemplate.updateSections([
            CPListSection(items: [song]),
            CPListSection(items: makeControlItems(isPaused: header.isPaused)),
        ])
    }

    /// The current track's artwork, or the local placeholder. Never another song's or service's:
    /// `NowPlayingStore` clears artwork on every track and service change.
    private var currentArtwork: UIImage {
        nowPlaying.artwork ?? placeholderArtwork
    }

    /// Artwork, title, artist, and the three controls — nothing else, so the controls are always
    /// visible. Updates the existing header in place, touching only what changed.
    @available(iOS 26.4, *)
    private func renderDetailsHeader(_ header: HeaderState, previous: HeaderState?) {
        guard let details = nowPlayingTemplate.listHeader else {
            let details = CPListTemplateDetailsHeader(
                thumbnail: CPThumbnailImage(image: currentArtwork),
                title: header.title,
                subtitle: header.artist,
                actionButtons: makeHeaderButtons(isPaused: header.isPaused)
            )
            // Background tinted from the artwork, generated by CarPlay for light and dark mode.
            details.wantsAdaptiveBackgroundStyle = true
            nowPlayingTemplate.listHeader = details
            if nowPlayingTemplate.sectionCount != 0 { nowPlayingTemplate.updateSections([]) }
            return
        }

        if details.title != header.title { details.title = header.title }
        if details.subtitle != header.artist { details.subtitle = header.artist }
        if previous?.artworkID != header.artworkID || previous?.trackID != header.trackID {
            details.thumbnail = CPThumbnailImage(image: currentArtwork)
        }
        if previous?.isPaused != header.isPaused || previous?.availability != header.availability {
            details.actionButtons = makeHeaderButtons(isPaused: header.isPaused)
        }
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

    @available(iOS 26.4, *)
    private func makeHeaderButtons(isPaused: Bool) -> [CPButton] {
        [Control.previous, .playPause, .next].map { control in
            CPButton(image: headerImage(for: control, isPaused: isPaused)) { [weak self] _ in
                self?.perform(control)
            }
        }
    }

    private func makeControlItems(isPaused: Bool) -> [CPListItem] {
        [Control.previous, .playPause, .next].map { control in
            let item = CPListItem(
                text: title(for: control, isPaused: isPaused),
                detailText: nil,
                image: UIImage(systemName: symbolName(for: control, isPaused: isPaused))
            )
            item.handler = { [weak self] _, completion in
                self?.perform(control)
                completion()
            }
            return item
        }
    }

    /// Routed through `NowPlayingStore`, which sends each command to the active service only
    /// (Spotify App Remote or the system music player). Ignored while there's no current song.
    private func perform(_ control: Control) {
        guard lastHeader?.availability == .ready, lastHeader?.trackID != nil else { return }
        switch control {
        case .previous: nowPlaying.previousTrack()
        case .playPause: nowPlaying.togglePlayPause()
        case .next: nowPlaying.nextTrack()
        }
    }

    private func title(for control: Control, isPaused: Bool) -> String {
        switch control {
        case .previous: "Previous"
        case .playPause: isPaused ? "Play" : "Pause"
        case .next: "Next"
        }
    }

    private func symbolName(for control: Control, isPaused: Bool) -> String {
        switch control {
        case .previous: "backward.fill"
        case .playPause: isPaused ? "play.fill" : "pause.fill"
        case .next: "forward.fill"
        }
    }

    /// Symbols sized to fill the details header's button area instead of the default small
    /// symbol size. Rendered once per symbol.
    @available(iOS 26.4, *)
    private func headerImage(for control: Control, isPaused: Bool) -> UIImage {
        let name = symbolName(for: control, isPaused: isPaused)
        if let cached = controlImages[name] { return cached }

        let maximum = CPListTemplateDetailsHeader.maximumActionButtonSize
        let side = min(maximum.width, maximum.height)
        let pointSize = side > 0 ? side * 0.5 : 28
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = UIImage(systemName: name, withConfiguration: configuration) ?? UIImage()
        controlImages[name] = image
        return image
    }

    // MARK: - Artwork placeholder

    /// Local-only stand-in shown until the current song's artwork arrives, or when it has none.
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

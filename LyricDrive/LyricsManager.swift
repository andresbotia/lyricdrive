//
//  LyricsManager.swift
//  LyricDrive
//

import Combine
import Foundation

enum LyricsState {
    case idle
    case loading
    case synced
    case plainOnly
    case notFound
    case error(String)
}

/// One slot in the five-line lyric window. `id` is stable per on-screen position: the absolute
/// index into `LyricsManager.lines` when a line occupies that slot, or a unique negative
/// sentinel when the slot is empty (song hasn't started / near the end of the lyric list).
struct LyricWindowSlot: Identifiable {
    let id: Int
    let line: LyricLine?
    let isCurrent: Bool
}

/// Owns synced-lyric state for the currently playing track: fetches lyrics once per track
/// change (keyed by the normalized track `id`) and derives the active line from
/// `NowPlayingStore.playbackPositionMs` on every tick, purely locally — no network request
/// happens on playback ticks. Works the same for every music service.
final class LyricsManager: ObservableObject {

    @Published private(set) var state: LyricsState = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainLyrics: String?
    @Published private(set) var currentLineIndex: Int?

    /// The current five-line window (current line centered), ready for direct UI consumption —
    /// and reusable as-is by a future CarPlay scene.
    var fiveLineWindow: [LyricWindowSlot] {
        (-2...2).map { offset in
            if let currentLineIndex, lines.indices.contains(currentLineIndex + offset) {
                let idx = currentLineIndex + offset
                return LyricWindowSlot(id: idx, line: lines[idx], isCurrent: offset == 0)
            }
            return LyricWindowSlot(id: -100 + offset, line: nil, isCurrent: false)
        }
    }

    private let lyricsService: LyricsService
    private var cancellables = Set<AnyCancellable>()
    private var currentTrackURI: String?
    private var fetchTask: Task<Void, Never>?

    init(nowPlaying: NowPlayingStore, lyricsService: LyricsService = LyricsService()) {
        self.lyricsService = lyricsService

        nowPlaying.$track
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self, weak nowPlaying] track in
                guard let self, let nowPlaying else { return }
                self.handleTrackChange(track: track, nowPlaying: nowPlaying)
            }
            .store(in: &cancellables)

        nowPlaying.$playbackPositionMs
            .sink { [weak self] positionMs in
                self?.updateCurrentLine(for: positionMs)
            }
            .store(in: &cancellables)
    }

    private func handleTrackChange(track: NowPlayingTrack?, nowPlaying: NowPlayingStore) {
        let trackURI = track?.id ?? ""
        guard trackURI != currentTrackURI else { return }
        currentTrackURI = trackURI

        // Any in-flight lookup belonged to whatever track we were just on — abandon it.
        fetchTask?.cancel()
        lines = []
        plainLyrics = nil
        currentLineIndex = nil

        guard let track, !trackURI.isEmpty else {
            state = .idle
            return
        }

        let trackName = track.title
        let artistName = track.artist
        let albumName = track.album
        let durationMs = track.durationMs

        state = .loading

        fetchTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyricsService.fetchLyrics(
                trackName: trackName,
                artistName: artistName,
                albumName: albumName,
                durationMs: durationMs
            )

            // The track may have changed again while this request was in flight — a lyrics
            // response finishing late must never overwrite a newer song's lyrics.
            guard !Task.isCancelled, self.currentTrackURI == trackURI else { return }

            switch result {
            case .synced(let parsedLines):
                self.lines = parsedLines
                self.state = .synced
                self.updateCurrentLine(for: nowPlaying.playbackPositionMs)
            case .plainOnly(let text):
                self.plainLyrics = text
                self.state = .plainOnly
            case .notFound:
                self.state = .notFound
            case .failure(let message):
                self.state = .error(message)
            }
        }
    }

    private func updateCurrentLine(for positionMs: Int) {
        guard !lines.isEmpty else {
            currentLineIndex = nil
            return
        }
        // Lines are sorted ascending; the active line is the last one whose start is <= position.
        currentLineIndex = lines.lastIndex { $0.startTimeMs <= positionMs }
    }
}

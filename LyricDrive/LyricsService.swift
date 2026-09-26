//
//  LyricsService.swift
//  LyricDrive
//

import Foundation

/// The distinct outcomes a lyrics lookup can produce, so callers can render each state
/// differently instead of collapsing everything into "got text" / "got nothing".
enum LyricsFetchResult {
    case synced([LyricLine])
    case plainOnly(String)
    case notFound
    case failure(String)
}

/// Parses LRC-formatted synced lyrics such as:
/// ```
/// [01:24.32] some lyric text
/// [01:27.10][01:40.00] a repeated line
/// [ar: some metadata tag that isn't a timestamp]
/// ```
enum LRCParser {

    static func parse(_ raw: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("[") else { continue }

            var remaining = Substring(trimmed)
            var timestampsMs: [Int] = []

            while remaining.hasPrefix("["), let closeIndex = remaining.firstIndex(of: "]") {
                let tag = remaining[remaining.index(after: remaining.startIndex)..<closeIndex]
                if let ms = parseTimestamp(String(tag)) {
                    timestampsMs.append(ms)
                }
                remaining = remaining[remaining.index(after: closeIndex)...]
            }

            // No valid timestamp tags: either a malformed line or an LRC metadata header
            // (e.g. `[ar:Some Artist]`). Tolerate it by skipping.
            guard !timestampsMs.isEmpty else { continue }

            let text = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            for ms in timestampsMs {
                lines.append(LyricLine(startTimeMs: ms, text: text))
            }
        }

        return lines.sorted { $0.startTimeMs < $1.startTimeMs }
    }

    /// Parses a single `mm:ss.xx` (or `mm:ss.xxx` / `mm:ss`) timestamp tag into milliseconds.
    private static func parseTimestamp(_ tag: String) -> Int? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]) else { return nil }

        let secondParts = parts[1].split(separator: ".")
        guard let seconds = Int(secondParts[0]) else { return nil }

        var milliseconds = 0
        if secondParts.count > 1 {
            var fraction = String(secondParts[1])
            switch fraction.count {
            case 1: fraction += "00"
            case 2: fraction += "0"
            case 3: break
            default: fraction = String(fraction.prefix(3))
            }
            milliseconds = Int(fraction) ?? 0
        }

        return minutes * 60_000 + seconds * 1_000 + milliseconds
    }
}

/// Fetches lyrics from LRCLIB (https://lrclib.net), falling back to plain lyrics from lyrics.ovh
/// (https://lyrics.ovh) — no API keys, no backend.
final class LyricsService {

    private static let getEndpoint = URL(string: "https://lrclib.net/api/get")!
    private static let searchEndpoint = URL(string: "https://lrclib.net/api/search")!

    /// lyrics.ovh can be slow; keep each fallback attempt bounded.
    private static let lyricsOvhTimeout: TimeInterval = 8

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Looks up lyrics for the given Spotify track metadata, strictly sequentially:
    ///
    /// 1. LRCLIB (primary, up to four requests — see `fetchFromLRCLIB`): synced lyrics, or a
    ///    confident plain-only match.
    /// 2. Only if LRCLIB produced nothing usable: lyrics.ovh plain lyrics (up to
    ///    `LyricsOvh.maximumAttempts` requests).
    /// 3. Not found — or LRCLIB's failure, if LRCLIB errored and lyrics.ovh found nothing either.
    ///
    /// Stops early if the calling task is cancelled (track changed); `LyricsManager` additionally
    /// discards any result whose track is no longer current.
    func fetchLyrics(trackName: String, artistName: String, albumName: String, durationMs: Int) async -> LyricsFetchResult {
        guard !trackName.isEmpty, !artistName.isEmpty else { return .notFound }

        #if DEBUG && targetEnvironment(simulator)
        if CarPlayDemo.isEnabled, let demoResult = CarPlayDemo.lyricsResult(trackName: trackName, artistName: artistName) {
            // Brief pause so the "Loading lyrics…" state is visible, then no network at all.
            try? await Task.sleep(for: .milliseconds(600))
            return demoResult
        }
        #endif

        let query = LyricsQuery(
            trackName: trackName,
            artistName: artistName,
            albumName: albumName.isEmpty ? nil : albumName,
            durationSeconds: durationMs > 0 ? Int((Double(durationMs) / 1000).rounded()) : nil
        )

        let lrclibOutcome = await fetchFromLRCLIB(query)
        switch lrclibOutcome {
        case .synced(let lines):
            Self.log("LRCLIB matched")
            return .synced(lines)
        case .plain(let text):
            Self.log("LRCLIB matched (plain lyrics)")
            return .plainOnly(text)
        case .cancelled:
            return .notFound
        case .notFound, .failure:
            break
        }

        if let text = await fetchFromLyricsOvh(query) {
            Self.log("lyrics.ovh plain fallback matched")
            return .plainOnly(text)
        }

        if case .failure(let message) = lrclibOutcome {
            return .failure(message)
        }
        Self.log("no provider matched")
        return .notFound
    }

    // MARK: - LRCLIB

    private enum LRCLIBOutcome {
        case synced([LyricLine])
        case plain(String)
        case notFound
        case failure(String)
        case cancelled
    }

    /// LRCLIB's bounded pipeline (at most four requests), stopping at the first synced match:
    ///
    /// 1. `/api/get` with title + artist + album + duration — LRCLIB's own exact match.
    /// 2. `/api/get` without the album (skipped when there is none), since album titles often
    ///    differ (deluxe editions, compilations, singles vs. albums).
    /// 3. `/api/search` by normalized title + artist, no duration; results are ranked by
    ///    `LyricsMatcher` and only a confident match is accepted.
    /// 4. `/api/search` with a free-text query of normalized title + primary artist, for
    ///    artist-formatting differences; ranked the same way.
    ///
    /// A plain-only match found along the way is remembered and returned only if no synced
    /// lyrics turn up.
    private func fetchFromLRCLIB(_ query: LyricsQuery) async -> LRCLIBOutcome {
        var plainFallback: String?

        // Stages 1–2: exact lookups. LRCLIB does the matching, so a returned record is trusted.
        var exactStages: [(label: String, albumName: String?)] = [("exact match", query.albumName)]
        if query.albumName != nil {
            exactStages.append(("no-album fallback", nil))
        }
        for stage in exactStages {
            guard !Task.isCancelled else { return .cancelled }
            switch await getRecord(query: query, albumName: stage.albumName) {
            case .failure(let message):
                return plainFallback.map(LRCLIBOutcome.plain) ?? .failure(message)
            case .records(let records):
                guard let record = records.first else { continue }
                if let lines = Self.syncedLines(from: record) {
                    Self.log(stage.label)
                    return .synced(lines)
                }
                plainFallback = plainFallback ?? Self.plainLyrics(from: record)
            }
        }

        // Stages 3–4: loose searches, ranked and validated locally.
        let normalizedTitle = LyricsMatcher.normalizedTitle(query.trackName)
        let searchStages: [(label: String, items: [URLQueryItem])] = [
            ("normalized-title fallback", [
                URLQueryItem(name: "track_name", value: normalizedTitle),
                URLQueryItem(name: "artist_name", value: query.artistName),
            ]),
            ("free-text fallback", [
                URLQueryItem(name: "q", value: "\(normalizedTitle) \(LyricsMatcher.primaryArtist(query.artistName))"),
            ]),
        ]
        for stage in searchStages {
            guard !Task.isCancelled else { return .cancelled }
            switch await search(stage.items) {
            case .failure(let message):
                return plainFallback.map(LRCLIBOutcome.plain) ?? .failure(message)
            case .records(let records):
                guard let best = LyricsMatcher.bestCandidate(records, for: query) else { continue }
                if let lines = Self.syncedLines(from: best) {
                    Self.log(stage.label)
                    return .synced(lines)
                }
                plainFallback = plainFallback ?? Self.plainLyrics(from: best)
            }
        }

        if let plainFallback {
            Self.log("plain-lyrics fallback")
            return .plain(plainFallback)
        }
        Self.log("no confident LRCLIB match")
        return .notFound
    }

    // MARK: - lyrics.ovh

    /// Final plain-lyrics fallback: tries `LyricsOvh.attempts` in order. A 404 or unusable body
    /// moves on to the next attempt; a transport error (offline, timeout) stops the fallback so
    /// a dead network doesn't cost several timeouts.
    private func fetchFromLyricsOvh(_ query: LyricsQuery) async -> String? {
        for attempt in LyricsOvh.attempts(trackName: query.trackName, artistName: query.artistName) {
            guard !Task.isCancelled else { return nil }
            guard let url = LyricsOvh.url(artist: attempt.artist, title: attempt.title) else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = Self.lyricsOvhTimeout
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if let lyrics = LyricsOvh.lyrics(from: data) {
                    return lyrics
                }
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - Requests

    private enum RequestOutcome {
        /// Zero or more records. An empty array means "no match" (e.g. a 404 from `/api/get`).
        case records([LRCLibTrackResponse])
        case failure(String)
    }

    private func getRecord(query: LyricsQuery, albumName: String?) async -> RequestOutcome {
        var items = [
            URLQueryItem(name: "track_name", value: query.trackName),
            URLQueryItem(name: "artist_name", value: query.artistName),
        ]
        if let albumName {
            items.append(URLQueryItem(name: "album_name", value: albumName))
        }
        if let durationSeconds = query.durationSeconds {
            items.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        return await request(Self.getEndpoint, items: items, decoding: LRCLibTrackResponse.self) { [$0] }
    }

    private func search(_ items: [URLQueryItem]) async -> RequestOutcome {
        await request(Self.searchEndpoint, items: items, decoding: [LRCLibTrackResponse].self) { $0 }
    }

    private func request<Response: Decodable>(
        _ endpoint: URL,
        items: [URLQueryItem],
        decoding: Response.Type,
        records: (Response) -> [LRCLibTrackResponse]
    ) async -> RequestOutcome {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return .failure("Invalid lyrics service URL.")
        }
        components.queryItems = items
        guard let url = components.url else {
            return .failure("Could not build lyrics request URL.")
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("No HTTP response from lyrics service.")
            }
            if httpResponse.statusCode == 404 {
                return .records([])
            }
            guard httpResponse.statusCode == 200 else {
                return .failure("Lyrics service returned status \(httpResponse.statusCode).")
            }
            return .records(records(try JSONDecoder().decode(Response.self, from: data)))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Result helpers

    private static func syncedLines(from record: LRCLibTrackResponse) -> [LyricLine]? {
        guard let syncedLyrics = record.syncedLyrics, !syncedLyrics.isEmpty else { return nil }
        let lines = LRCParser.parse(syncedLyrics)
        return lines.isEmpty ? nil : lines
    }

    /// Never invents timestamps: plain lyrics stay plain.
    private static func plainLyrics(from record: LRCLibTrackResponse) -> String? {
        LyricsMatcher.hasPlainLyrics(record) ? record.plainLyrics : nil
    }

    private static func log(_ stage: String) {
        #if DEBUG
        print("LyricsService: \(stage)")
        #endif
    }
}

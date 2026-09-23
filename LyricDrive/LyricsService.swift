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

/// Fetches synchronized lyrics from LRCLIB (https://lrclib.net) — no API key, no backend.
final class LyricsService {

    private static let getEndpoint = URL(string: "https://lrclib.net/api/get")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Looks up lyrics for the given Spotify track metadata. Tries LRCLIB's exact-match
    /// `/api/get` with album name + duration first (LRCLIB's recommended disambiguation), then
    /// falls back to track+artist+duration only, since album titles frequently mismatch between
    /// Spotify and LRCLIB (deluxe editions, compilations, singles vs. albums, etc.).
    func fetchLyrics(trackName: String, artistName: String, albumName: String, durationMs: Int) async -> LyricsFetchResult {
        guard !trackName.isEmpty, !artistName.isEmpty else { return .notFound }

        let durationSeconds = Int((Double(durationMs) / 1000).rounded())

        if let result = await performRequest(
            trackName: trackName,
            artistName: artistName,
            albumName: albumName.isEmpty ? nil : albumName,
            durationSeconds: durationSeconds
        ) {
            return result
        }

        if !albumName.isEmpty,
           let result = await performRequest(
               trackName: trackName,
               artistName: artistName,
               albumName: nil,
               durationSeconds: durationSeconds
           ) {
            return result
        }

        return .notFound
    }

    /// Returns `nil` when LRCLIB had no match (or the match had no usable lyrics at all), so the
    /// caller can decide whether to retry with a looser query. Returns a concrete
    /// `LyricsFetchResult` for anything conclusive (success or a real error).
    private func performRequest(
        trackName: String,
        artistName: String,
        albumName: String?,
        durationSeconds: Int
    ) async -> LyricsFetchResult? {
        guard var components = URLComponents(url: Self.getEndpoint, resolvingAgainstBaseURL: false) else {
            return .failure("Invalid lyrics service URL.")
        }

        var queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName),
        ]
        if let albumName {
            queryItems.append(URLQueryItem(name: "album_name", value: albumName))
        }
        if durationSeconds > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            return .failure("Could not build lyrics request URL.")
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("No HTTP response from lyrics service.")
            }
            if httpResponse.statusCode == 404 {
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                return .failure("Lyrics service returned status \(httpResponse.statusCode).")
            }

            let decoded = try JSONDecoder().decode(LRCLibTrackResponse.self, from: data)

            if let syncedLyrics = decoded.syncedLyrics, !syncedLyrics.isEmpty {
                let parsedLines = LRCParser.parse(syncedLyrics)
                if !parsedLines.isEmpty {
                    return .synced(parsedLines)
                }
            }
            if let plainLyrics = decoded.plainLyrics, !plainLyrics.isEmpty {
                return .plainOnly(plainLyrics)
            }
            // Matched a track but it carries no lyrics at all (e.g. instrumental) — let the
            // caller decide whether a looser query is worth trying.
            return nil
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

//
//  LyricsOvh.swift
//  LyricDrive
//

import Foundation

/// Pure helpers for the lyrics.ovh fallback (https://lyrics.ovh, `GET /v1/{artist}/{title}`):
/// no API key, plain lyrics only. The request itself lives in `LyricsService`.
enum LyricsOvh {

    private static let baseURL = URL(string: "https://api.lyrics.ovh/v1/")!

    /// Upper bound on lookups per track.
    static let maximumAttempts = 3

    private struct Response: Decodable {
        let lyrics: String?
    }

    /// Builds the lookup URL, percent-encoding each segment so titles/artists containing
    /// "/", "?" or "#" (e.g. "AC/DC") stay a single path component.
    static func url(artist: String, title: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let artistSegment = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let titleSegment = title.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "\(artistSegment)/\(titleSegment)", relativeTo: baseURL)?.absoluteURL
    }

    /// Bounded, de-duplicated (artist, title) pairs to try, in order: the original Spotify
    /// metadata, then the conservatively normalized title, then the primary artist alone when
    /// the artist string lists several.
    static func attempts(trackName: String, artistName: String) -> [(artist: String, title: String)] {
        let normalizedTitle = LyricsMatcher.normalizedTitle(trackName)
        let primaryArtist = LyricsMatcher.primaryArtist(artistName)
        let candidates = [
            (artist: artistName, title: trackName),
            (artist: artistName, title: normalizedTitle),
            (artist: primaryArtist, title: normalizedTitle),
        ]

        var seen = Set<String>()
        return candidates
            .filter { !$0.artist.isEmpty && !$0.title.isEmpty }
            .filter { seen.insert("\($0.artist)\u{1F}\($0.title)").inserted }
            .prefix(maximumAttempts)
            .map { $0 }
    }

    /// Decodes a lyrics.ovh response body into usable plain lyrics, or `nil` if it's invalid,
    /// an error payload, or empty. Normalizes line endings and drops the
    /// "Paroles de la chanson … par …" banner line lyrics.ovh sometimes prepends.
    static func lyrics(from data: Data) -> String? {
        guard let raw = (try? JSONDecoder().decode(Response.self, from: data))?.lyrics else { return nil }

        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("Paroles de la chanson") {
            lines.removeFirst()
        }

        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

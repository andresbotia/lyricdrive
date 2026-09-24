//
//  LyricsMatcher.swift
//  LyricDrive
//

import Foundation

/// The Spotify-side metadata a lyrics lookup is trying to match.
struct LyricsQuery {
    let trackName: String
    let artistName: String
    let albumName: String?
    /// `nil` when Spotify didn't report a usable duration.
    let durationSeconds: Int?
}

/// Pure, network-free helpers for matching Spotify metadata against LRCLIB records.
///
/// Deliberately conservative: normalization only strips well-known *trailing* metadata noise
/// (remaster/deluxe/live/feat. tags), and a candidate must match the normalized title and share
/// at least one artist before it's even ranked. Correctness beats hit rate — a wrong song's
/// lyrics are worse than none.
enum LyricsMatcher {

    /// Candidates whose duration differs from Spotify's by more than this are rejected outright:
    /// a different edit/version would put synced lyrics out of time.
    static let durationToleranceSeconds = 5.0

    // MARK: - Title normalization

    /// Metadata that may follow a title in parentheses/brackets or after " - ".
    private static let noiseSuffix = [
        #"(?:\d{4}\s+)?(?:digital(?:ly)?\s+)?remaster(?:ed)?(?:\s+\d{4})?(?:\s+version)?"#,
        #"deluxe(?:\s+edition|\s+version)?"#,
        #"radio\s+edit"#,
        #"single\s+version"#,
        #"live(?:\s+(?:at|from|in)\s+.+|\s+version)?"#,
        #"acoustic(?:\s+version)?"#,
        #"(?:feat\.?|ft\.?|featuring)\s+.+"#,
    ].joined(separator: "|")

    private static let bracketedNoise = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*(?:\#(noiseSuffix))\s*[\)\]]\s*$"#,
        options: [.caseInsensitive]
    )

    private static let dashedNoise = try! NSRegularExpression(
        pattern: #"\s+[-–—]\s+(?:\#(noiseSuffix))\s*$"#,
        options: [.caseInsensitive]
    )

    /// Strips trailing Spotify metadata noise such as "(Remastered 2011)", "- Radio Edit",
    /// "(feat. X)". Only trailing tags are removed, repeatedly (e.g. "(feat. X) - Remastered"),
    /// and the original is returned if stripping would leave nothing.
    static func normalizedTitle(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let range = NSRange(result.startIndex..., in: result)
            var stripped = bracketedNoise.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            stripped = dashedNoise.stringByReplacingMatches(
                in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: ""
            )
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripped != result, !stripped.isEmpty else { break }
            result = stripped
        }
        return result.isEmpty ? title : result
    }

    // MARK: - Comparison keys

    /// Case-, diacritic- and punctuation-insensitive comparison key: "Don’t Stop — Me!" and
    /// "dont stop me" compare equal; "&" is treated as "and".
    static func matchKey(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        let words = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: " ")
    }

    private static let artistSeparator = try! NSRegularExpression(
        pattern: #"\s*(?:,|;|/|&|\bfeat\.?|\bft\.?|\bfeaturing\b)\s*"#,
        options: [.caseInsensitive]
    )

    /// The individual artists in an artist string ("A, B & C feat. D" → A, B, C, D), trimmed,
    /// in their original order and casing.
    static func artists(in artistName: String) -> [String] {
        let range = NSRange(artistName.startIndex..., in: artistName)
        let marked = artistSeparator.stringByReplacingMatches(in: artistName, range: range, withTemplate: "\u{1F}")
        return marked
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The first listed artist, for a looser secondary search.
    static func primaryArtist(_ artistName: String) -> String {
        artists(in: artistName).first ?? artistName
    }

    /// Comparison keys for the whole artist string plus each individual artist, so
    /// "A & B" matches "A, B", "A", or "B feat. A".
    static func artistKeys(_ artistName: String) -> Set<String> {
        var keys = Set(artists(in: artistName).map { matchKey($0) })
        keys.insert(matchKey(artistName))
        keys.remove("")
        return keys
    }

    // MARK: - Duration

    /// Whether a candidate's duration is compatible with the target. Unknown durations on either
    /// side are not grounds for rejection.
    static func isDurationAcceptable(candidateSeconds: Double?, targetSeconds: Int?) -> Bool {
        guard let candidateSeconds, let targetSeconds, targetSeconds > 0 else { return true }
        return abs(candidateSeconds - Double(targetSeconds)) <= durationToleranceSeconds
    }

    // MARK: - Candidate scoring

    static func hasSyncedLyrics(_ record: LRCLibTrackResponse) -> Bool {
        !(record.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    static func hasPlainLyrics(_ record: LRCLibTrackResponse) -> Bool {
        !(record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Scores a loose-search candidate, or returns `nil` if it's not plausibly the same song.
    ///
    /// Hard requirements: some lyrics, the same normalized title, at least one shared artist, and
    /// (when both are known) a duration within tolerance. Among survivors, synced lyrics dominate
    /// the ranking; then duration closeness, exact title/artist, and album agreement.
    static func score(_ candidate: LRCLibTrackResponse, for query: LyricsQuery) -> Int? {
        let hasSynced = hasSyncedLyrics(candidate)
        guard hasSynced || hasPlainLyrics(candidate) else { return nil }

        let titleKey = matchKey(normalizedTitle(query.trackName))
        guard !titleKey.isEmpty, matchKey(normalizedTitle(candidate.trackName)) == titleKey else { return nil }

        guard !artistKeys(query.artistName).isDisjoint(with: artistKeys(candidate.artistName)) else { return nil }

        guard isDurationAcceptable(candidateSeconds: candidate.duration, targetSeconds: query.durationSeconds) else {
            return nil
        }

        var score = hasSynced ? 100 : 0
        if let target = query.durationSeconds, target > 0, let duration = candidate.duration {
            // +20 for an exact duration, falling linearly to 0 at the tolerance limit.
            let difference = abs(duration - Double(target))
            score += Int((20 * (1 - difference / durationToleranceSeconds)).rounded())
        }
        if matchKey(candidate.trackName) == matchKey(query.trackName) {
            score += 10
        }
        if matchKey(candidate.artistName) == matchKey(query.artistName) {
            score += 10
        }
        if let album = query.albumName, !album.isEmpty, let candidateAlbum = candidate.albumName,
           matchKey(normalizedTitle(candidateAlbum)) == matchKey(normalizedTitle(album)) {
            score += 10
        }
        return score
    }

    /// The highest-scoring plausible candidate (ties keep LRCLIB's order), or `nil` if none is a
    /// confident match.
    static func bestCandidate(_ candidates: [LRCLibTrackResponse], for query: LyricsQuery) -> LRCLibTrackResponse? {
        var best: (record: LRCLibTrackResponse, score: Int)?
        for candidate in candidates {
            guard let score = score(candidate, for: query), score > best?.score ?? .min else { continue }
            best = (candidate, score)
        }
        return best?.record
    }
}

import ActivityKit

/// The Live Activity's data. Attributes are empty: everything can change during the activity's
/// lifetime (track, provider, lyrics), so it all lives in `ContentState`.
///
/// `ContentState` is the complete, render-ready lyric window — the extension computes nothing.
/// It's small and `Codable` on purpose, so the same payload could later arrive through an
/// ActivityKit push instead of a local update.
nonisolated struct LyricDriveActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            /// A synced-lyric window is available.
            case lyrics
            /// The track changed and its lyrics are still being looked up.
            case findingLyrics
            /// The current track has no synced lyrics.
            case noLyrics
        }

        /// `MusicService.rawValue` of the service the content came from.
        var provider: String
        var trackID: String
        var title: String
        var artist: String
        var status: Status
        /// Up to four context lines around `currentLine`, split between before and after: two
        /// each mid-song, more upcoming at the start of a song, more previous near the end.
        /// Oldest first.
        var previousLines: [String]
        /// The active line, or "♪" for an instrumental break or before the first timed line.
        /// Empty unless `status == .lyrics`.
        var currentLine: String
        /// Next first.
        var nextLines: [String]
        /// Index of `currentLine` in the song's lyrics; `nil` before the first timed line.
        var lineIndex: Int?
        var lineCount: Int
        var isPaused: Bool

        init(
            provider: String, trackID: String, title: String, artist: String, status: Status,
            previousLines: [String], currentLine: String, nextLines: [String],
            lineIndex: Int?, lineCount: Int, isPaused: Bool
        ) {
            self.provider = provider
            self.trackID = trackID
            self.title = title
            self.artist = artist
            self.status = status
            self.previousLines = previousLines
            self.currentLine = currentLine
            self.nextLines = nextLines
            self.lineIndex = lineIndex
            self.lineCount = lineCount
            self.isPaused = isPaused
        }

        /// Lenient, so an activity written by an earlier version (different fields) still
        /// decodes — as a neutral "finding lyrics" state — until the app replaces its content.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
            trackID = try container.decodeIfPresent(String.self, forKey: .trackID) ?? ""
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
            status = (try? container.decodeIfPresent(Status.self, forKey: .status)) ?? .findingLyrics
            previousLines = try container.decodeIfPresent([String].self, forKey: .previousLines) ?? []
            currentLine = try container.decodeIfPresent(String.self, forKey: .currentLine) ?? ""
            nextLines = try container.decodeIfPresent([String].self, forKey: .nextLines) ?? []
            lineIndex = try container.decodeIfPresent(Int.self, forKey: .lineIndex)
            lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? 0
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        }
    }
}

import ActivityKit

nonisolated struct LyricDriveActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var trackIdentifier: String
        var songTitle: String
        var currentLyric: String
        var nextLyric: String
        var hasLyrics: Bool
        var isPaused: Bool
    }
}

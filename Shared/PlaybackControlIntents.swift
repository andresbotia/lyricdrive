import AppIntents

/// Transport commands the playback widget can send.
nonisolated enum WidgetPlaybackCommand: Sendable {
    case previous, playPause, next
}

/// Where widget playback intents are handled. Only the app sets `handler`; in the widget
/// extension it stays `nil` and commands are ignored, because only the app holds the Spotify App
/// Remote connection and follows the Music app.
///
/// The intents adopt `AudioPlaybackIntent`, which has the system perform them in the app's
/// process (launching it in the background if needed) rather than in the widget extension.
@MainActor
enum WidgetPlaybackRouter {
    static var handler: ((WidgetPlaybackCommand) async -> Void)?

    static func perform(_ command: WidgetPlaybackCommand) async {
        await handler?(command)
    }
}

nonisolated struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Goes back in the music service LyricDrive is following.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetPlaybackRouter.perform(.previous)
        return .result()
    }
}

nonisolated struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the music service LyricDrive is following.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetPlaybackRouter.perform(.playPause)
        return .result()
    }
}

nonisolated struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips ahead in the music service LyricDrive is following.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetPlaybackRouter.perform(.next)
        return .result()
    }
}

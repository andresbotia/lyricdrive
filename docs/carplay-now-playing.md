# CarPlay Now Playing investigation

September 26, 2026. Inspected Xcode 27.0 (27A266a), iPhoneOS27.0 SDK.

## Supported structure

Apple's [tab initializer documentation](https://developer.apple.com/documentation/carplay/cptabbartemplate/init(templates:)) restricts audio tab roots to List and Grid. Each tab has its own navigation hierarchy; `CPInterfaceController.pushTemplate` pushes onto the selected tab. System Now Playing can be pushed above a tab root, but cannot be placed in the audio tab array.

Inspected `CPTabBarTemplate.h`, `CPNowPlayingTemplate.h`, and `CPInterfaceController.h` under the SDK's `System/Library/Frameworks/CarPlay.framework/Headers`. The tab delegate exposes `tabBarTemplate:didSelectTemplate:` (Swift `tabBarTemplate(_:didSelect:)`); `selectedTemplate` identifies the selected tab, and `topTemplate` identifies the visible navigation template. These could support automatic presentation and duplicate prevention for an app that actually owns playback. The headers accept generic `CPTemplate` types; the entitlement-specific tab restrictions are explained in Apple's documentation.

## Metadata and playback ownership

The previous code assigned `MPNowPlayingInfoCenter.default().nowPlayingInfo` a fresh dictionary when metadata, pause state, artwork, or the playback anchor changed. It contained:

| Field | Previous value/type |
| --- | --- |
| Title | Track name, Swift String bridged to NSString |
| Artist / album | String, omitted when empty |
| Duration | Double seconds, omitted when zero |
| Elapsed time | Double seconds |
| Playback rate | Double, 0 paused / 1 playing |
| Artwork | MPMediaItemArtwork, omitted until Spotify's image arrived |
| Default playback rate / media type | Not supplied |

These value types are valid. Normal playback defaults to rate 1; adding optional keys does not solve ownership. Publication was already semantic/anchor driven, not at the 10 Hz clock rate. The code cleared its dictionary when disconnected or without a track, and rebuilt it rather than retaining previous-track fields. Its fallback only handled a failed template push, not a successfully presented screen with blank metadata.

Inspected `MPNowPlayingInfoCenter.h`, `MPRemoteCommandCenter.h`, and `MPNowPlayingSession.h` under `MediaPlayer.framework/Headers`. The default info center describes the **current application**, not another app's playback. The playbackState header explicitly says that property applies on macOS; iOS derives playback from the audio session. MPNowPlayingSession requires local AVPlayer instances and selects a session within the app; it does not attach to Spotify's player.

Apple's [WWDC19 playback ownership explanation](https://developer.apple.com/videos/play/wwdc2019/501/?time=1255) requires remote-command support and initiating playback with a non-mixable audio session on iOS. LyricDrive registers commands but does not play audio or activate such a session. Spotify's App Remote calls control Spotify's player; they do not establish a LyricDrive audio session. Activating a non-mixable session to take ownership would interrupt other audio rather than preserve this companion architecture.

There is no documented supported route in these APIs for LyricDrive to reliably own system Now Playing metadata while Spotify remains the playback app. Apple's [CPNowPlayingTemplate documentation](https://developer.apple.com/documentation/carplay/cpnowplayingtemplate) obtains metadata from MediaPlayer rather than template title/artwork setters.

The structural failure is assuming that dictionary assignment makes LyricDrive the active Now Playing provider. That explains why correctly typed local metadata does not establish a populated system screen. We have no real-car process logs or active-owner trace here, so the precise runtime dictionary contents and ownership arbitration at the reported failure are **not measured**. Do not describe this as a confirmed runtime trace or a verified real-car fix.

## Final implementation

Use the requested LyricDrive-owned fallback consistently across supported iOS versions. Both tab roots remain CPListTemplate. Now Playing is the initial first tab and directly displays metadata and controls; selecting it later shows the same list without tapping a launcher or pushing a screen. There is no extra Back step or duplicate-template risk. Track and pause changes update contents without changing tabs.

Title, artist, and nonempty album get separate display-only rows. Long values reuse the existing whitespace/punctuation split across text and detailText, preserving the strings rather than shortening them. Artwork appears on the title row, with a local placeholder until Spotify supplies the current track image. SpotifyManager already clears artwork on track changes and guards image callbacks by track URI. Disconnect removes metadata and controls; reconnect restores current state. Host width may still truncate unusually long fields; inspect this in the car.

Previous, Play/Pause, and Next are separate native list controls. Each tap calls one existing SpotifyManager method once and completes the selection. Play/Pause reads Spotify's current paused state in SpotifyManager. Commands are ignored if disconnected or without a track. No MediaPlayer metadata publication or MPRemoteCommandCenter registration remains in LyricDrive; Spotify keeps its own system controls. CPNowPlayingTemplate and CPListTemplateDetailsHeader are no longer used as LyricDrive destinations.

Lyrics state translation, five-row context window, long-line splitting, current indicator, loading/no-lyrics/error presentation, and rendering match HEAD exactly. The persistent tab array is unchanged. Authentication, reconnect behavior, providers, phone UI, signing, and capabilities were not edited.

## Validation

- Requested generic iOS build: passed.
- Generic iOS Simulator Debug build: passed.
- Generic iOS Release build: passed.
- `git diff --check`: passed.
- Source comparison: lyric translation/splitting/rendering match HEAD exactly; no navigation pushes, tab replacement/selection, details header, MediaPlayer writes/registrations, or playback-clock subscriptions remain in the presenter.

Build logs: `/tmp/lyricdrive-carplay-generic.log`, `/tmp/lyricdrive-carplay-simulator.log`, `/tmp/lyricdrive-carplay-release.log`. Warnings concern AppIntents metadata extraction (no AppIntents.framework dependency) and Spotify SDK umbrella headers missing connectivity headers; all three builds succeed.

Still required in another TestFlight/car test: initial display and switching tabs; long title/artist readability; artwork replacement and rapid track changes; each transport control and pause label; disconnect/reconnect states; staying on Lyrics during track changes; Spotify retaining system playback controls. No real-car success is claimed.

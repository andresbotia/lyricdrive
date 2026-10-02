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

## Apple Music and CPNowPlayingTemplate

October 2, 2026. Re-inspected `CPNowPlayingTemplate.h` (iPhoneOS27.0 SDK). `sharedTemplate` is "the shared now playing template for your app"; it exposes buttons, Up Next, album/artist button, and (iOS 27) `allowsMiniPlayer`, but no title, artist, artwork, or playback-state setters. Its content comes from the app's own now-playing state.

Apple Music playback in LyricDrive goes through `MPMusicPlayerController.systemMusicPlayer`, whose playback belongs to the Music app, not LyricDrive. Nothing in the headers documents that LyricDrive's shared template reflects another app's session, and making it do so would mean publishing LyricDrive-owned `MPNowPlayingInfoCenter` metadata, which is the impersonation this design avoids. CarPlay's own Now Playing button already opens Music's real Now Playing screen. So LyricDrive does not use `CPNowPlayingTemplate` for either service.

## Current implementation

Both tab roots remain `CPListTemplate` in a `CPTabBarTemplate` that is created once per connection and never rebuilt, so the selected tab survives track changes, metadata enrichment, and service switches.

**Data source.** CarPlay reads the normalized active-service state from `NowPlayingStore` (track, artwork, paused state, active service) and lyrics from `LyricsManager`, the same objects the iPhone UI uses. Provider-specific connection/access state is converted in one place (`makeAvailability()`), derived from the shared `MusicSessionState`; for Spotify that keeps "reconnecting" up while a renewal, automatic reconnect, or scheduled retry is pending. Controls go through `NowPlayingStore`, which routes them to the active service only.

**Now Playing (iOS 26.4+).** `CPListTemplateDetailsHeader`: artwork thumbnail (local placeholder until the song's artwork arrives), title, artist, and Previous / Play-Pause / Next buttons, with no list rows and no album, so the controls are always visible. Control symbols are rendered at the header's `maximumActionButtonSize`, and `wantsAdaptiveBackgroundStyle` tints the header from the artwork. The header is updated in place, touching only the fields that changed. If a car reports `maximumActionButtonCount` below three, play/pause and next are kept first.

*Artwork* is center-cropped to a square (aspect fill, never stretched) and rendered at the car's `displayScale`, at `CPThumbnailImage.maximumImageSize(forAspectRatio: 1)` on iOS 27 (300 pt on 26.x), never above the source resolution. Both providers now supply 600 × 600 source artwork (previously 300 × 300).

*Text.* Nothing is shortened by LyricDrive. The header's `title`/`subtitle` are single-line and truncated by CarPlay, which is what produced "Mus…" / "Empire…". When the title is over 22 characters or the artist over 28, the complete string(s) are also passed as `bodyVariants` — the header's only multiline, wrapping field — most complete first (`title⏎artist`, then `title`), and CarPlay picks the variant that fits. The thresholds are `comfortableTitleLength` / `comfortableArtistLength` in `CarPlayPresentationController`; whether this reads well, and the header's exact geometry, has not been verified on a real car display.

**Now Playing (older iOS).** One section: a row with artwork, title, and artist (no album), followed directly by the three control rows.

**Status states.** Connecting/reconnecting, needs action, Apple Music access off/restricted/needed, and no song use the template's empty view (with a spinner for in-progress states). No controls are shown.

**Lyrics.** Unchanged presentation: up to five rows, current line marked with the playing indicator, long lines split across text/detail, ♪ for instrumental breaks, loading/no-synced/error rows. Status rows follow the same availability.

**Updates.** Only semantic publishers are observed (never the playback clock), changes are coalesced to the next main-queue turn, and each tab is touched only if its derived state changed.

No `MPNowPlayingInfoCenter` writes, `MPRemoteCommandCenter` registrations, audio session, or background modes. No real-car result is claimed.

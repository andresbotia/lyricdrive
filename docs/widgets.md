# Widgets

October 2, 2026. Xcode 27.0 (27A266a), iPhoneOS27.0 SDK. Deployment target iOS 18.6.

## Targets and data flow

The widgets live in the existing `LyricDriveLiveActivity` widget extension, next to the Live Activity (`LyricDriveLiveActivityBundle`). No new target.

The extension runs in its own process, so it can't read the app's managers or `UserDefaults.standard`. The app and extension share the App Group `group.com.andresbotia.LyricDrive` (entitlement on both). `WidgetSnapshotPublisher` (app) writes one small `WidgetSnapshot` (Shared/WidgetSnapshot.swift) to the group's defaults, plus the current artwork as a per-track JPEG in the group container. Each artwork file is named after its track ID, and other artwork files are removed, so a widget can never pair one song's artwork with another song's snapshot.

Sources are the same as the iPhone UI and CarPlay: `NowPlayingStore` (active service, track, artwork, paused), `LyricsManager` (state, lines), `MusicSessionState` (connection/access). A provider switch clears the track and artwork in `NowPlayingStore`, so the next snapshot can't mix providers.

## Widgets

| Widget | Families | Content |
| --- | --- | --- |
| Lyrics | medium, large | Current line dominant; next line (and previous on large); title/artist small at top |
| Lyric Glance | small, Lock Screen rectangular | Current line, next line faint (small only); no metadata |
| Now Playing | small, medium | Artwork, title, artist, Previous / Play-Pause / Next |

## Updates

Writes (and `WidgetCenter` reloads) only happen on semantic changes: track, artwork, play/pause, lyrics state/lines, provider, connection/access, or a playback anchor shift over 1.5 s (a seek). They never happen on clock ticks or lyric line changes. A playing snapshot carries the synced lines and a playback anchor. Lyric widgets get one timeline entry per remaining line, dated in wall-clock time as `positionDate + (line.startMs − positionMs)` and carrying that line's index, up to the estimated song end (max 150 entries / 30 min; songs of unknown duration are scheduled to the 30-minute horizon). The timeline policy is `.atEnd`: after the song's estimated end the widget shows "Open LyricDrive to refresh" and WidgetKit asks for a new timeline, which picks up any newer snapshot. Paused snapshots go stale after 3 hours. Debug builds log every timeline build and snapshot write to a small App Group log that the app prints when it becomes active.

Limits:
- Line entries are **estimates**. While LyricDrive is suspended it can't see pauses, seeks, or skips made in the music app, so the widget keeps advancing on the old timing until the estimated end of the song.
- WidgetKit shows entries close to, but not exactly at, their dates.
- In the background (e.g. CarPlay drives), app-requested reloads count against WidgetKit's daily budget. Writes are coalesced (2.5 s in the background vs 0.4 s in the foreground) to roughly one reload per track. Once the budget runs out, iOS ignores reloads until it refills.

## Controls

Real interactive buttons (`Button(intent:)`) with `AudioPlaybackIntent`s (Shared/PlaybackControlIntents.swift). These are performed in the app process, which the system launches in the background if needed, and routed through `NowPlayingStore` to the active service.
- **Apple Music:** shown whenever access is granted and a song is current. The app resyncs with the Music app before and after the command.
- **Spotify:** shown only while App Remote is connected (LyricDrive in the foreground, or CarPlay connected). Otherwise the widget says "Open LyricDrive to control Spotify": App Remote can't be reached from a suspended app, and no wake or background workaround is attempted.

## Empty states

Never opened → "Open LyricDrive to get started"; no session → "Open LyricDrive to connect"; Spotify disconnected without a song → "Spotify isn't connected"; Apple Music denied/restricted → "Apple Music access is off"; connecting → "Connecting to …"; nothing playing → "No song playing"; lyrics loading/missing → "Finding synced lyrics…" / "Synced lyrics unavailable"; stale → "Open LyricDrive to refresh".

The Live Activity is unchanged and separate.

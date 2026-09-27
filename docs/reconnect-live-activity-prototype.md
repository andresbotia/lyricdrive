# Reconnect diagnostics and Live Activity prototype

This milestone is implemented but has not been validated on a physical iPhone and vehicle. Neither reconnect reliability nor actual CarPlay Dashboard lyric presentation is confirmed.

## Existing reconnect flow, before these changes

1. `LyricDriveApp.init` obtains `AppServices.shared`: SpotifyManager is constructed first, then LyricsManager. SpotifyManager restores the saved session from Keychain, assigns it to the session manager and App Remote, and immediately connects if valid or silently requests renewal if expired. Successful renewal persists the session and connects App Remote.
2. Phone scene activation calls `appDidBecomeActive` → `reconnectIfAuthorized`. Phone inactivity disconnects App Remote unless `isCarPlayConnected` is already true. Phone inactivity and CarPlay connection callbacks have no ordering guarantee.
3. CarPlay `didConnect` sets `isCarPlayConnected = true`, calls `reconnectForCarPlay`, constructs the existing presentation controller and installs its root template. The reconnect call requires a token and skips an already connected or active reconnect sequence. An existing launch/phone connection attempt is adopted.
4. CarPlay scene activation calls the same reconnect method. It joins an active sequence; after a sequence has finished it could previously start another sequence on every activation, without a per-connection activation budget.
5. Failures classified as sleeping transport retry immediately-first, then 1.5, 3 and 6 seconds after the preceding failure (nominally 0, 1.5, 4.5, 10.5 seconds if failures return immediately). Standalone phone/manual attempts get one 0.75-second retry. SDK callback duration is additional; there was no overall deadline.
6. The old classifier accepted the SDK's generic connection-attempt failure, any Spotify transport-domain error, or an underlying POSIX connection refusal. Thus unrelated failures could be misclassified. On exhaustion it cancelled automatic retries and set `requiresSpotifyWake = true`. Starting a new sequence did not clear an earlier wake requirement. The standalone delayed retry used an uncancellable dispatch callback.
7. Success cancelled automatic retries, cleared wake/connecting flags, subscribed to player state, fetched current state and restarted the interpolated clock. Spotify playing in its own CarPlay app was never inspected and does not establish that LyricDrive's local App Remote endpoint is available.
8. The manual wake action uses the existing SDK `initiateSession(... .clientOnly)` app switch, then connects after the redirect. Automatic paths never initiate this switch.

The leading hypothesis remains that Spotify playback is active while its separate local App Remote transport is unavailable. Manual app switching has previously been observed to bring that transport up. Lifecycle ordering, premature/stale wake state, and overly broad classification also need to be distinguished using device logs; extending delays alone would not establish a fix.

## Changes and diagnostics

`SpotifyManager.swift` and `CarPlaySceneDelegate.swift` contain the reconnect changes. `LyricDriveApp.swift` was inspected and left unchanged.

DEBUG Logger subsystem: `com.andresbotia.LyricDrive`; category: `SpotifyReconnect`. Events include ISO timestamps, trigger (`sessionRestore`, `carPlayDidConnect`, `carPlaySceneDidBecomeActive`, `phoneSceneDidBecomeActive`, `manualReconnect`), attempt number, session presence, renewal attempted/succeeded, SDK connection state, automatic sequence state and wake state before/after transitions. Nested NSError domains/codes/descriptions/failure reasons are recorded up to six levels. Player subscription and initial metadata-refresh success/failure are recorded. Arbitrary SDK userInfo and access/refresh tokens are not dumped. These new diagnostics are compiled out of Release and add no Release UI.

Retries now require an underlying `NSPOSIXErrorDomain` `ECONNREFUSED`, including through Spotify's wrappers. Generic wrapper errors alone, unknown/nil errors, auth and renewal failures stop. The existing four-attempt timing is preserved; an 18-second deadline includes callback and renewal time. A CarPlay connection allows one additional fresh sequence on a subsequent scene activation, with no repeated activation loop. Automatic and standalone retries are cancellable; foreground phone callbacks do not overlap a pending sequence. Late renewal can save the renewed session but cannot reconnect after the sequence's deadline or lifecycle cancellation.

Wake state is cleared when a sequence/attempt starts and immediately on success. It is set on exhausted known transport retries, or at the deadline only if a known transport failure was observed and renewal is not pending. The existing explicit manual SDK-wake failure also restores the wake fallback. It is not set during pending retries or for generic/fatal connection failures. Success cancels retries and deadline, subscribes to player state and fetches metadata. No automatic Spotify launch was added.

## Live Activity implementation

- `Shared/LyricDriveActivityAttributes.swift`: shared, nonisolated ActivityKit attributes, compiled into app and extension. Static attributes are empty. Content contains track identifier, song title, current/next lyric, synced-lyrics availability and paused state; no tokens, artwork or position ticks.
- `LyricDrive/LiveActivityManager.swift`: app-owned coordinator retained by `AppServices`. One internal switch: `InternalFeatures.carPlayLiveActivityEnabled = true`.
- `LyricDriveLiveActivity/LyricDriveLiveActivity.swift`: WidgetBundle and ActivityConfiguration, Lock Screen and Dynamic Island presentation plus `.supplementalActivityFamilies([.small])`. Small presentation shows a title and current line, with paused context; next line is reserved for the larger iPhone presentation. All surfaces are read-only.
- `LyricDriveLiveActivity/Info.plist`: WidgetKit extension declaration.
- `LyricDrive/Info.plist`: `NSSupportsLiveActivities = YES`.
- `LyricDrive.xcodeproj/project.pbxproj`: extension target, build configurations, shared source membership, app dependency and embed phase. The extension inherits the existing project team and uses automatic signing. No new entitlements, App Groups, push, frequent-update or background capabilities were added. The extension version matches the app's existing local version 9. Pre-existing edits to the app version, entitlements and support files were preserved.

A useful connected track starts an activity when system authorization and execution policy permit it. A failed request is suppressed until the next phone foreground event rather than retried on every lyric. Local background starts may be refused; this prototype does not add push infrastructure to bypass that limitation. System/user dismissal also defers restarting until a later foreground opportunity.

The coordinator watches semantic publishers, defers reads past Combine willSet and serializes/coalesces work. It does not subscribe to the 10 Hz playback clock. Payload equality prevents redundant updates. Track changes, lyric-index changes, availability changes, pause/resume and reconnect/foreground refresh can update content. Text lengths are bounded. Loading shows “Finding synced lyrics…”; unsynced/plain/not-found/error results show “No synced lyrics available”; gaps in synced lyrics show a music note.

Disconnects retain the activity for up to 30 seconds while reconnecting; forgotten authorization or an empty/unusable track ends it immediately. A 30-second stale date makes the widget replace lyrics with “Open LyricDrive to refresh” if the app cannot supply fresh content. App suspension can postpone the actual end operation; stale presentation prevents indefinitely visible old lyrics. Paused playback retains the available track, but unchanged content may become stale. This is deliberately conservative for the prototype.

Apple documents automatic supported Live Activity presentation in CarPlay Dashboard on iOS 26 and later, controlled by the system and user settings. No custom Dashboard view or forced placement is used: https://developer.apple.com/videos/play/wwdc2025/216/

## Validation

All builds used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `LyricDrive.xcodeproj`, and `build`:

| Scheme | Configuration | Destination | Result |
| --- | --- | --- | --- |
| LyricDrive | Debug | generic/platform=iOS | Passed, signed, extension embedded |
| LyricDrive | Debug | generic/platform=iOS Simulator | Passed |
| LyricDrive | Release | generic/platform=iOS | Passed, signed, extension embedded |
| LyricDriveLiveActivity | Debug | generic/platform=iOS | Passed, signed |

Build logs: `/tmp/lyricdrive-{device,simulator,release,widget}-build.log`. No new Swift compiler warnings remain. Xcode emits its informational App Intents metadata warning because the app has no AppIntents dependency.

Seven isolated Swift assertions executed the production error-classification functions extracted from SpotifyManager, without creating an SDK session: direct/nested refusal accepted; generic connection error, generic stream error, login error, other POSIX error and excessively deep error chains rejected. These are not a substitute for reconnect lifecycle or ActivityKit runtime testing.

`git diff --check` passed. No commit or push was performed.

## Physical-device follow-up

1. Capture DEBUG SpotifyReconnect logs while entering the car with Spotify already playing. Compare didConnect, phone scene and CarPlay activation triggers, exact error chain, renewal events, four attempts, deadline and wake transitions.
2. After exhaustion, activate LyricDrive in CarPlay once: confirm one fresh sequence. Repeated activation must not create further sequences for that connection. Confirm success clears wake, cancels retries and reports subscription/metadata results.
3. Exercise an expired session, fatal/auth failure, CarPlay disconnect during a retry and manual wake during reconnect. Confirm no unsolicited Spotify app switch, late retry or lost saved authorization.
4. Start connected playback with LyricDrive foregrounded and Live Activities allowed. Check Lock Screen, Dynamic Island and iOS 26+ CarPlay Dashboard. Confirm current-line changes, track changes, no-lyrics and paused states. Check system placement and settings; no Dashboard display is claimed from build success.
5. Lock/background the phone, interrupt Spotify and verify that stale lyrics disappear within the stale interval. Reconnect and check fresh content. Forget authorization and verify activity dismissal. Confirm the internal flag disables creation and clears previous prototype activities.

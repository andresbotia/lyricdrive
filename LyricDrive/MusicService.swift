//
//  MusicService.swift
//  LyricDrive
//

import Foundation

/// The music apps LyricDrive can follow. The iPhone UI is written against this rather than
/// against a specific SDK, so each provider supplies its own state, actions, and copy.
enum MusicService: String, CaseIterable, Identifiable {
    case spotify
    case appleMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        }
    }

    /// What the user needs before choosing this service, shown on its card.
    var requirement: String {
        switch self {
        case .spotify: "Needs the Spotify app and a Spotify account"
        case .appleMusic: "Follows the Music app · needs access to Apple Music"
        }
    }

    /// What happens when the user continues with this service, shown under the button.
    var connectNote: String {
        switch self {
        case .spotify: "Spotify will open briefly to confirm."
        case .appleMusic: "You'll be asked to allow access to Apple Music."
        }
    }

    /// URL that opens the service's own app, if there's a supported way to open it directly.
    var appURL: URL? {
        switch self {
        case .spotify: URL(string: "spotify:")
        case .appleMusic: nil
        }
    }
}

/// The connection lifecycle the iPhone UI presents, independent of any provider SDK.
enum MusicConnectionPhase: Equatable {
    /// No authorized session yet — onboarding territory.
    case notConnected
    /// First-time connection in progress.
    case connecting
    /// A saved session is reconnecting (silent reconnect, bounded retries, or an SDK wake).
    case reconnecting
    /// Authorized, but nothing is in progress or pending and no failure was reported (e.g. a
    /// clean disconnect). The UI offers reconnect from the status pill only, not the panel.
    case disconnected
    /// The provider needs the user to act: Spotify's automatic reconnect ended (it needs waking,
    /// or a failure occurred), or Apple Music access isn't granted.
    case needsUserAction
    case connected
}

/// What the "needs attention" surfaces (reconnect panel, status pill) do when tapped.
enum MusicUserAction: Equatable {
    /// Spotify: wake / reconnect App Remote.
    case reconnect
    /// Apple Music: access was reset and can be requested again.
    case requestAccess
    /// Apple Music: access was denied or is restricted; only the Settings app can change it.
    case openSettings
}

/// A read-only snapshot of the active provider's session, derived on demand. Owns no state and
/// performs no actions — the provider managers remain the source of truth.
struct MusicSessionState {
    let service: MusicService
    let phase: MusicConnectionPhase
    let hasAuthorizedSession: Bool

    /// `true` when reconnecting needs Spotify's app-switch wake rather than a plain connect.
    let requiresAppWake: Bool

    /// `true` when the most recent connection attempt reported a failure.
    let lastAttemptFailed: Bool

    /// Apple Music only.
    let appleMusicAuthorization: AppleMusicManager.Authorization?

    #if DEBUG
    /// Raw SDK diagnostics. DEBUG builds only; never shown in Release.
    let debugDetails: String?
    #endif

    init(spotify: SpotifyManager) {
        service = .spotify
        hasAuthorizedSession = spotify.hasAuthorizedSession
        requiresAppWake = spotify.requiresSpotifyWake
        lastAttemptFailed = spotify.errorMessage != nil
        appleMusicAuthorization = nil
        #if DEBUG
        debugDetails = spotify.errorMessage
        #endif

        // Order matters: an in-progress attempt always wins over a stale failure flag, so the
        // reconnect action only appears once SpotifyManager's own retries have finished.
        if spotify.isConnected {
            phase = .connected
        } else if spotify.isWakingSpotify || spotify.isConnecting || spotify.isAutoReconnecting || spotify.hasPendingReconnect {
            phase = spotify.hasAuthorizedSession ? .reconnecting : .connecting
        } else if !spotify.hasAuthorizedSession {
            phase = .notConnected
        } else if spotify.requiresSpotifyWake || spotify.errorMessage != nil {
            phase = .needsUserAction
        } else {
            phase = .disconnected
        }
    }

    init(appleMusic: AppleMusicManager) {
        let authorization = appleMusic.authorization
        service = .appleMusic
        hasAuthorizedSession = authorization == .authorized
        requiresAppWake = false
        lastAttemptFailed = authorization == .denied || authorization == .restricted
        appleMusicAuthorization = authorization
        #if DEBUG
        debugDetails = nil
        #endif

        // No reconnect concept: the system player is always reachable once access is granted.
        if appleMusic.isRequestingAuthorization {
            phase = .connecting
        } else if authorization == .authorized {
            phase = .connected
        } else {
            phase = .needsUserAction
        }
    }

    // MARK: Needs-attention copy

    var userAction: MusicUserAction {
        switch appleMusicAuthorization {
        case nil: .reconnect
        case .notDetermined: .requestAccess
        case .authorized, .denied, .restricted: .openSettings
        }
    }

    var attentionTitle: String {
        switch appleMusicAuthorization {
        case nil: "Reconnect \(service.displayName)"
        case .restricted: "Apple Music Access Is Restricted"
        default: "Allow Apple Music Access"
        }
    }

    var attentionMessage: String {
        let name = service.displayName
        switch appleMusicAuthorization {
        case nil:
            if requiresAppWake || !lastAttemptFailed {
                return "\(name) needs to be reopened to restore the connection. It opens for a moment, then brings you back here."
            }
            return "LyricDrive couldn't reach \(name). Make sure \(name) is installed and you're signed in, then try again."
        case .notDetermined:
            return "LyricDrive needs access to Apple Music to see what's playing in the Music app."
        case .restricted:
            return "Access to Apple Music is restricted on this device, for example by Screen Time. It can be changed in Settings."
        case .authorized, .denied:
            return "LyricDrive needs access to Apple Music to see what's playing. You can turn it on in Settings under LyricDrive."
        }
    }

    var attentionButtonTitle: String {
        switch userAction {
        case .reconnect: "Reconnect \(service.displayName)"
        case .requestAccess: "Continue"
        case .openSettings: "Open Settings"
        }
    }

    /// Short text for the status pill once the panel has been dismissed.
    var attentionPillText: String {
        switch userAction {
        case .reconnect: "Tap to reconnect"
        case .requestAccess, .openSettings: "Allow access"
        }
    }

    var attentionSymbol: String {
        switch userAction {
        case .reconnect: "arrow.clockwise"
        case .requestAccess, .openSettings: "lock.fill"
        }
    }
}

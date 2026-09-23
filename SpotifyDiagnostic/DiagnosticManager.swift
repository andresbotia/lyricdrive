//
//  DiagnosticManager.swift
//  SpotifyDiagnostic
//
//  Minimal, isolated reproduction of Spotify's official App Remote flow.
//  No Keychain. No lyrics. No artwork. No interpolation. No visualizer. No custom retry logic.
//

import Combine
import Foundation
import SpotifyiOS
import UIKit

@MainActor
final class DiagnosticManager: NSObject, ObservableObject {

    // Same Client ID and redirect URI pattern as LyricDrive.
    static let clientID = "1294b9c52c284018bed1a49c50d84998"
    static let redirectURL = URL(string: "lyricdrive-login://callback")!

    @Published private(set) var log: [String] = []

    private lazy var configuration: SPTConfiguration = {
        let configuration = SPTConfiguration(clientID: Self.clientID, redirectURL: Self.redirectURL)
        configuration.playURI = ""
        return configuration
    }()

    private lazy var sessionManager: SPTSessionManager = {
        SPTSessionManager(configuration: configuration, delegate: self)
    }()

    private lazy var appRemote: SPTAppRemote = {
        let appRemote = SPTAppRemote(configuration: configuration, logLevel: .debug)
        appRemote.delegate = self
        return appRemote
    }()

    private func append(_ line: String) {
        let entry = "[\(Self.timestamp())] \(line)"
        print("DIAG: \(entry)")
        log.append(entry)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    /// Full nested NSError chain, following `NSUnderlyingErrorKey` all the way down.
    private func fullChain(_ error: NSError) -> String {
        var parts: [String] = []
        var current: NSError? = error
        var depth = 0
        while let e = current, depth < 6 {
            parts.append("domain=\(e.domain) code=\(e.code) desc=\(e.localizedDescription)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " -> ")
    }

    // MARK: - Test 1: official SPTSessionManager (.clientOnly) + SPTAppRemote flow

    func startSessionManagerFlow() {
        append("=== Test 1: SPTSessionManager + SPTAppRemote ===")
        let installed = sessionManager.isSpotifyAppInstalled
        append("Spotify app installed: \(installed)")
        append("Calling sessionManager.initiateSession(with: [.appRemoteControl], options: .clientOnly)")
        sessionManager.initiateSession(with: [.appRemoteControl], options: .clientOnly)
    }

    // MARK: - Test 2: appRemote.authorizeAndPlayURI("") direct path

    func startAuthorizeAndPlayURIFlow() {
        append("=== Test 2: appRemote.authorizeAndPlayURI(\"\") ===")
        append("Calling appRemote.authorizeAndPlayURI(\"\") directly")
        let result = appRemote.authorizeAndPlayURI("")
        append("authorizeAndPlayURI(\"\") returned: \(result)")
    }

    func handleOpenURL(_ url: URL) {
        append("Received redirect URL with scheme: \(url.scheme ?? "?")")
        let handled = sessionManager.application(UIApplication.shared, open: url, options: [:])
        append("sessionManager.application(_:open:options:) returned: \(handled)")
    }

    func clearLog() {
        log.removeAll()
    }
}

// MARK: - SPTSessionManagerDelegate

extension DiagnosticManager: SPTSessionManagerDelegate {

    func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        append("sessionManager(_:didInitiate:) — session obtained. isExpired=\(session.isExpired)")
        appRemote.connectionParameters.accessToken = session.accessToken
        append("Calling appRemote.connect()")
        appRemote.connect()
    }

    func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        append("sessionManager(_:didRenew:) — session renewed")
        appRemote.connectionParameters.accessToken = session.accessToken
        appRemote.connect()
    }

    func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        append("sessionManager(_:didFailWith:) — \(fullChain(error as NSError))")
    }
}

// MARK: - SPTAppRemoteDelegate

extension DiagnosticManager: SPTAppRemoteDelegate {

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        append("RESULT: App Remote CONNECTED successfully")
        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            if let error {
                self?.append("subscribe(toPlayerState:) error: \(self?.fullChain(error as NSError) ?? "")")
            } else {
                self?.append("subscribe(toPlayerState:) succeeded")
            }
        })
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        if let error {
            append("RESULT: App Remote FAILED to connect — \(fullChain(error as NSError))")
        } else {
            append("RESULT: App Remote FAILED to connect — (no error object provided)")
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        if let error {
            append("App Remote disconnected with error: \(fullChain(error as NSError))")
        } else {
            append("App Remote disconnected cleanly")
        }
    }
}

// MARK: - SPTAppRemotePlayerStateDelegate

extension DiagnosticManager: SPTAppRemotePlayerStateDelegate {

    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        append("playerStateDidChange — track=\"\(playerState.track.name)\" paused=\(playerState.isPaused)")
    }
}

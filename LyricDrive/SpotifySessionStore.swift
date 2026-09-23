//
//  SpotifySessionStore.swift
//  LyricDrive
//

import Foundation
import Security
import SpotifyiOS

enum SpotifySessionStoreError: Error {
    case archivingFailed(Error)
    case unarchivingFailed(Error)
    case keychainWrite(OSStatus)
    case keychainRead(OSStatus)
}

/// Persists the Spotify `SPTSession` (access token, refresh token, expiration, scope) securely
/// in the iOS Keychain — never in `UserDefaults` — so the user doesn't have to re-authorize
/// every time the app is rebuilt, killed, or updated.
final class SpotifySessionStore {

    /// Stable identifiers for the single Keychain item LyricDrive stores. Kept distinct from the
    /// app's bundle ID string so they read unambiguously in Keychain inspection tools.
    private let service = "com.andresbotia.LyricDrive.spotify"
    private let account = "spotifySession"

    /// Archives `session` via `NSSecureCoding` (which `SPTSession` conforms to) and writes it to
    /// the Keychain, replacing whatever was stored previously.
    func save(session: SPTSession) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: session, requiringSecureCoding: true)
            try write(data)
        } catch {
            print("SpotifySessionStore: failed to save Spotify session — \(error)")
        }
    }

    /// Reads and unarchives the stored session, or `nil` if none exists or it couldn't be decoded.
    func loadSession() -> SPTSession? {
        do {
            guard let data = try read() else { return nil }
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: SPTSession.self, from: data)
        } catch {
            print("SpotifySessionStore: failed to load Spotify session — \(error)")
            return nil
        }
    }

    /// Removes the stored session entirely (used for logout / reset).
    func deleteSession() {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            print("SpotifySessionStore: failed to delete Spotify session (status \(status))")
            return
        }
    }

    // MARK: - Keychain plumbing

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func write(_ data: Data) throws {
        // Saving a new session always replaces any previous one.
        SecItemDelete(query() as CFDictionary)

        var attributes = query()
        attributes[kSecValueData as String] = data
        // Available once the device has been unlocked at least once since boot (so a background
        // reconnect after a restart still works), but never included in iCloud/other-device
        // backups — this token shouldn't leave the device it was issued on.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SpotifySessionStoreError.keychainWrite(status)
        }
    }

    private func read() throws -> Data? {
        var lookupQuery = query()
        lookupQuery[kSecReturnData as String] = true
        lookupQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(lookupQuery as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SpotifySessionStoreError.keychainRead(status)
        }
        return result as? Data
    }
}

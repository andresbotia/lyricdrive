//
//  LyricLine.swift
//  LyricDrive
//

import Foundation

/// A single timed lyric line, in milliseconds from the start of the track.
struct LyricLine: Equatable {
    let startTimeMs: Int
    let text: String
}

/// Decodes LRCLIB's `/api/get` response.
/// See https://lrclib.net/docs for the full field list; only what we use is modeled here.
struct LRCLibTrackResponse: Decodable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

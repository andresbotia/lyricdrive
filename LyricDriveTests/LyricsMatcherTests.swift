//
//  LyricsMatcherTests.swift
//  LyricDriveTests
//

import XCTest
@testable import LyricDrive

@MainActor
final class LyricsMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func record(
        _ trackName: String,
        artist: String,
        album: String? = nil,
        duration: Double? = 200,
        synced: String? = "[00:01.00] line",
        plain: String? = "line"
    ) -> LRCLibTrackResponse {
        LRCLibTrackResponse(
            id: 1,
            trackName: trackName,
            artistName: artist,
            albumName: album,
            duration: duration,
            instrumental: false,
            plainLyrics: plain,
            syncedLyrics: synced
        )
    }

    private func query(
        _ trackName: String,
        artist: String,
        album: String? = nil,
        duration: Int? = 200
    ) -> LyricsQuery {
        LyricsQuery(trackName: trackName, artistName: artist, albumName: album, durationSeconds: duration)
    }

    // MARK: - Title normalization

    func testRemasteredTitle() {
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Don't Stop Me Now - Remastered 2011"), "Don't Stop Me Now")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Heroes - 2017 Remaster"), "Heroes")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Yesterday (Remastered 2009)"), "Yesterday")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Go Your Own Way - 2004 Remastered Version"), "Go Your Own Way")
    }

    func testDeluxeLiveAcousticAndEditTitles() {
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song (Deluxe Edition)"), "Song")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song - Deluxe"), "Song")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song - Radio Edit"), "Song")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song (Single Version)"), "Song")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song - Live at Wembley"), "Song")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song (Live)"), "Song")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song - Acoustic"), "Song")
    }

    func testFeaturedArtistTitle() {
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Stay (feat. Mikky Ekko)"), "Stay")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Stay (ft. Mikky Ekko)"), "Stay")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Stay - feat. Mikky Ekko"), "Stay")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Stay [feat. A & B] - Remastered"), "Stay")
    }

    func testNormalizationIsConservative() {
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Live Forever"), "Live Forever")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Live and Let Die"), "Live and Let Die")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Hey Jude"), "Hey Jude")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Anti-Hero"), "Anti-Hero")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("(Don't Fear) The Reaper"), "(Don't Fear) The Reaper")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("Song (Interlude)"), "Song (Interlude)")
        XCTAssertEqual(LyricsMatcher.normalizedTitle("(Live)"), "(Live)")
    }

    // MARK: - Keys and artists

    func testMatchKeyIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(LyricsMatcher.matchKey("Don’t Stop — Me!"), LyricsMatcher.matchKey("dont stop me"))
        XCTAssertEqual(LyricsMatcher.matchKey("Beyoncé"), LyricsMatcher.matchKey("Beyonce"))
        XCTAssertEqual(LyricsMatcher.matchKey("Rock & Roll"), LyricsMatcher.matchKey("Rock and Roll"))
    }

    func testArtistSplittingAndPrimaryArtist() {
        XCTAssertEqual(LyricsMatcher.artists(in: "A, B & C feat. D"), ["A", "B", "C", "D"])
        XCTAssertEqual(LyricsMatcher.primaryArtist("Calvin Harris, Dua Lipa"), "Calvin Harris")
        XCTAssertEqual(LyricsMatcher.primaryArtist("Adele"), "Adele")
        XCTAssertEqual(LyricsMatcher.artists(in: "Daft Punk"), ["Daft Punk"])
    }

    // MARK: - Duration

    func testDurationTolerance() {
        XCTAssertTrue(LyricsMatcher.isDurationAcceptable(candidateSeconds: 203, targetSeconds: 200))
        XCTAssertTrue(LyricsMatcher.isDurationAcceptable(candidateSeconds: 196, targetSeconds: 200))
        XCTAssertTrue(LyricsMatcher.isDurationAcceptable(candidateSeconds: 205, targetSeconds: 200))
        XCTAssertFalse(LyricsMatcher.isDurationAcceptable(candidateSeconds: 206, targetSeconds: 200))
        XCTAssertFalse(LyricsMatcher.isDurationAcceptable(candidateSeconds: 240, targetSeconds: 200))
        XCTAssertTrue(LyricsMatcher.isDurationAcceptable(candidateSeconds: nil, targetSeconds: 200))
        XCTAssertTrue(LyricsMatcher.isDurationAcceptable(candidateSeconds: 240, targetSeconds: nil))
    }

    func testCloserDurationRanksHigher() {
        let q = query("Song", artist: "Artist")
        let far = record("Song", artist: "Artist", duration: 204)
        let near = record("Song", artist: "Artist", duration: 201)
        XCTAssertGreaterThan(LyricsMatcher.score(near, for: q)!, LyricsMatcher.score(far, for: q)!)
    }

    // MARK: - Candidate selection

    func testRemasteredSpotifyTitleMatchesPlainLRCLibTitle() {
        let q = query("Don't Stop Me Now - Remastered 2011", artist: "Queen", duration: 209)
        let candidate = record("Don't Stop Me Now", artist: "Queen", duration: 210)
        XCTAssertNotNil(LyricsMatcher.bestCandidate([candidate], for: q))
    }

    func testDeluxeAlbumMismatchStillMatches() {
        let q = query("Song", artist: "Artist", album: "Album (Deluxe Edition)")
        let candidate = record("Song", artist: "Artist", album: "Greatest Hits")
        XCTAssertNotNil(LyricsMatcher.bestCandidate([candidate], for: q))
    }

    func testAlbumAgreementBreaksTies() {
        let q = query("Song", artist: "Artist", album: "Album (Deluxe Edition)")
        let otherAlbum = record("Song", artist: "Artist", album: "Greatest Hits")
        let sameAlbum = record("Song", artist: "Artist", album: "Album")
        XCTAssertEqual(LyricsMatcher.bestCandidate([otherAlbum, sameAlbum], for: q)?.albumName, "Album")
    }

    func testFeaturedArtistInTitleMatchesMultiArtistCandidate() {
        let q = query("Stay (feat. Mikky Ekko)", artist: "Rihanna")
        let candidate = record("Stay", artist: "Rihanna feat. Mikky Ekko")
        XCTAssertNotNil(LyricsMatcher.bestCandidate([candidate], for: q))
    }

    func testDurationOffByThreeSecondsMatches() {
        let q = query("Song", artist: "Artist", duration: 200)
        XCTAssertNotNil(LyricsMatcher.bestCandidate([record("Song", artist: "Artist", duration: 197)], for: q))
        XCTAssertNotNil(LyricsMatcher.bestCandidate([record("Song", artist: "Artist", duration: 204)], for: q))
    }

    func testPrefersTheOnlySyncedCandidate() {
        let q = query("Song", artist: "Artist")
        let plainExact = record("Song", artist: "Artist", duration: 200, synced: nil)
        let synced = record("Song", artist: "Artist", duration: 203)
        let best = LyricsMatcher.bestCandidate([plainExact, synced], for: q)
        XCTAssertNotNil(best?.syncedLyrics)
    }

    func testPlainOnlyCandidateIsStillSelected() {
        let q = query("Song", artist: "Artist")
        let plainOnly = record("Song", artist: "Artist", synced: nil, plain: "Some words")
        let best = LyricsMatcher.bestCandidate([plainOnly], for: q)
        XCTAssertNotNil(best)
        XCTAssertNil(best?.syncedLyrics)
    }

    func testCandidateWithoutLyricsIsRejected() {
        let q = query("Song", artist: "Artist")
        XCTAssertNil(LyricsMatcher.bestCandidate([record("Song", artist: "Artist", synced: nil, plain: nil)], for: q))
    }

    func testWrongSongIsRejectedEvenWithSyncedLyrics() {
        let q = query("Yesterday", artist: "The Beatles")
        let wrongTitle = record("Yesterday Once More", artist: "Carpenters")
        let wrongArtist = record("Yesterday", artist: "Leona Lewis")
        XCTAssertNil(LyricsMatcher.bestCandidate([wrongTitle, wrongArtist], for: q))
    }

    func testDifferentEditOutsideToleranceIsRejected() {
        let q = query("Song", artist: "Artist", duration: 200)
        XCTAssertNil(LyricsMatcher.bestCandidate([record("Song", artist: "Artist", duration: 260)], for: q))
    }

    func testUnknownSpotifyDurationRanksInsteadOfRejecting() {
        let q = query("Song", artist: "Artist", duration: nil)
        XCTAssertNotNil(LyricsMatcher.bestCandidate([record("Song", artist: "Artist", duration: 999)], for: q))
    }
}

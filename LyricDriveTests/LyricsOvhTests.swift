//
//  LyricsOvhTests.swift
//  LyricDriveTests
//

import XCTest
@testable import LyricDrive

@MainActor
final class LyricsOvhTests: XCTestCase {

    // MARK: - Decoding

    func testDecodesLyrics() {
        let data = Data(#"{"lyrics":"Is this the real life?\r\nIs this just fantasy?"}"#.utf8)
        XCTAssertEqual(LyricsOvh.lyrics(from: data), "Is this the real life?\nIs this just fantasy?")
    }

    func testRejectsEmptyAndWhitespaceLyrics() {
        XCTAssertNil(LyricsOvh.lyrics(from: Data(#"{"lyrics":""}"#.utf8)))
        XCTAssertNil(LyricsOvh.lyrics(from: Data(#"{"lyrics":"  \n\r\n "}"#.utf8)))
    }

    func testRejectsErrorPayloadAndInvalidJSON() {
        XCTAssertNil(LyricsOvh.lyrics(from: Data(#"{"error":"No lyrics found"}"#.utf8)))
        XCTAssertNil(LyricsOvh.lyrics(from: Data("<html>Bad Gateway</html>".utf8)))
    }

    func testStripsFrenchBannerLine() {
        let data = Data(#"{"lyrics":"Paroles de la chanson Song par Artist\r\nFirst line\nSecond line"}"#.utf8)
        XCTAssertEqual(LyricsOvh.lyrics(from: data), "First line\nSecond line")
    }

    // MARK: - URL

    func testURLEncodesEachSegment() {
        XCTAssertEqual(
            LyricsOvh.url(artist: "AC/DC", title: "Who Made Who?")?.absoluteString,
            "https://api.lyrics.ovh/v1/AC%2FDC/Who%20Made%20Who%3F"
        )
        XCTAssertEqual(
            LyricsOvh.url(artist: "Beyoncé", title: "Halo")?.absoluteString,
            "https://api.lyrics.ovh/v1/Beyonc%C3%A9/Halo"
        )
    }

    // MARK: - Attempts

    func testAttemptsOriginalThenNormalizedThenPrimaryArtist() {
        let attempts = LyricsOvh.attempts(trackName: "Song - Remastered 2011", artistName: "A, B")
        XCTAssertEqual(attempts.map(\.artist), ["A, B", "A, B", "A"])
        XCTAssertEqual(attempts.map(\.title), ["Song - Remastered 2011", "Song", "Song"])
    }

    func testAttemptsAreDeduplicated() {
        let attempts = LyricsOvh.attempts(trackName: "Song", artistName: "Artist")
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.artist, "Artist")
        XCTAssertEqual(attempts.first?.title, "Song")
    }

    func testAttemptsAreBounded() {
        let attempts = LyricsOvh.attempts(trackName: "Song (feat. C)", artistName: "A & B")
        XCTAssertLessThanOrEqual(attempts.count, LyricsOvh.maximumAttempts)
    }
}

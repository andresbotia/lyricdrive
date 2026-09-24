//
//  LyricsServiceFallbackTests.swift
//  LyricDriveTests
//

import XCTest
@testable import LyricDrive

/// Serves canned responses for LRCLIB and lyrics.ovh so the provider pipeline can be tested
/// without the network. Unlisted lyrics.ovh paths return 404; LRCLIB returns "no match" unless
/// `lrclibSyncedLyrics` is set.
nonisolated final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lyricsOvhResponses: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var lrclibSyncedLyrics: String?
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() {
        lyricsOvhResponses = [:]
        lrclibSyncedLyrics = nil
        requestedURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestedURLs.append(url)

        let (status, body): (Int, String)
        switch (url.host ?? "", url.path) {
        case ("lrclib.net", "/api/get"):
            if let synced = Self.lrclibSyncedLyrics {
                let record: [String: Any] = [
                    "id": 1, "trackName": "Song", "artistName": "Artist",
                    "duration": 200, "syncedLyrics": synced,
                ]
                (status, body) = (200, String(data: try! JSONSerialization.data(withJSONObject: record), encoding: .utf8)!)
            } else {
                (status, body) = (404, #"{"code":404}"#)
            }
        case ("lrclib.net", "/api/search"):
            (status, body) = (200, "[]")
        case ("api.lyrics.ovh", let path):
            (status, body) = Self.lyricsOvhResponses[path] ?? (404, #"{"error":"No lyrics found"}"#)
        default:
            (status, body) = (500, "")
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class LyricsServiceFallbackTests: XCTestCase {

    private func makeService() -> LyricsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LyricsService(session: URLSession(configuration: configuration))
    }

    private func lyricsOvhRequests() -> [URL] {
        StubURLProtocol.requestedURLs.filter { $0.host == "api.lyrics.ovh" }
    }

    func testFallsBackToLyricsOvhPlainLyrics() async {
        StubURLProtocol.reset()
        StubURLProtocol.lyricsOvhResponses["/v1/Artist/Song"] = (200, #"{"lyrics":"Line one\nLine two"}"#)

        let result = await makeService().fetchLyrics(trackName: "Song", artistName: "Artist", albumName: "Album", durationMs: 200_000)

        guard case .plainOnly(let text) = result else { return XCTFail("Expected plain lyrics, got \(result)") }
        XCTAssertEqual(text, "Line one\nLine two")
        XCTAssertEqual(lyricsOvhRequests().count, 1)
    }

    func testRetriesLyricsOvhWithNormalizedTitle() async {
        StubURLProtocol.reset()
        StubURLProtocol.lyricsOvhResponses["/v1/Artist/Song"] = (200, #"{"lyrics":"Found it"}"#)

        let result = await makeService().fetchLyrics(
            trackName: "Song - Remastered 2011", artistName: "Artist", albumName: "", durationMs: 200_000
        )

        guard case .plainOnly(let text) = result else { return XCTFail("Expected plain lyrics, got \(result)") }
        XCTAssertEqual(text, "Found it")
        XCTAssertEqual(lyricsOvhRequests().map(\.path), ["/v1/Artist/Song - Remastered 2011", "/v1/Artist/Song"])
    }

    func testLyricsOvh404MeansNotFound() async {
        StubURLProtocol.reset()

        let result = await makeService().fetchLyrics(trackName: "Song", artistName: "Artist", albumName: "", durationMs: 200_000)

        guard case .notFound = result else { return XCTFail("Expected not found, got \(result)") }
        XCTAssertEqual(lyricsOvhRequests().count, 1)
    }

    func testEmptyLyricsOvhResponseIsRejected() async {
        StubURLProtocol.reset()
        StubURLProtocol.lyricsOvhResponses["/v1/Artist/Song"] = (200, #"{"lyrics":"   "}"#)

        let result = await makeService().fetchLyrics(trackName: "Song", artistName: "Artist", albumName: "", durationMs: 200_000)

        guard case .notFound = result else { return XCTFail("Expected not found, got \(result)") }
    }

    func testLyricsOvhIsNotCalledWhenLRCLIBMatches() async {
        StubURLProtocol.reset()
        StubURLProtocol.lrclibSyncedLyrics = "[00:01.00] Synced line"
        StubURLProtocol.lyricsOvhResponses["/v1/Artist/Song"] = (200, #"{"lyrics":"Plain"}"#)

        let result = await makeService().fetchLyrics(trackName: "Song", artistName: "Artist", albumName: "Album", durationMs: 200_000)

        guard case .synced(let lines) = result else { return XCTFail("Expected synced lyrics, got \(result)") }
        XCTAssertEqual(lines.first?.text, "Synced line")
        XCTAssertTrue(lyricsOvhRequests().isEmpty)
    }
}

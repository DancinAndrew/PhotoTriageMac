import XCTest
@testable import PhotoTriageCore

final class SongExtractionTests: XCTestCase {
    private func line(_ text: String, y: Double, confidence: Double = 0.95) -> OCRLine {
        OCRLine(text: text, confidence: confidence, x: 0.2, y: y, width: 0.5, height: 0.02)
    }
    func testMultipleSongsAndControlsPreserveOriginalEvidence() {
        let lines = [line("Shazam", y: 0.95), line("Midnight City", y: 0.7), line("M83", y: 0.66),
                     line("Intro", y: 0.5), line("The xx", y: 0.46), line("Open in Spotify", y: 0.1)]
        let result = SongExtractor.parse(lines, assetID: "image-1")
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates[0].title, "Midnight City")
        XCTAssertEqual(result.candidates[0].artist, "M83")
        XCTAssertEqual(result.candidates[0].evidence[0].originalText, ["Midnight City", "M83"])
        XCTAssertEqual(result.candidates[1].evidence[0].lineIndices, [3, 4])
        XCTAssertTrue(result.candidates.allSatisfy(\.needsReview))
        XCTAssertTrue(result.unresolvedLineIndices.isEmpty)
    }
    func testArbitraryScreenshotTextIsNeverPairedAsMusic() {
        let result = SongExtractor.parse([line("Meeting notes", y: 0.7), line("Private person", y: 0.66)], assetID: "other")
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.unresolvedLineIndices, [0, 1])
    }
    func testExplicitSeparatorRemainsLowConfidenceReviewWithUncertainOrder() {
        let result = SongExtractor.parse([line("Artist — Song", y: 0.7)], assetID: "image")
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].confidence, "low")
        XCTAssertTrue(result.candidates[0].needsReview)
        XCTAssertTrue(result.candidates[0].evidence[0].parser.contains("order-needs-review"))
    }
    func testLowConfidenceAndDistantRowsRemainUnresolved() {
        let lines = [line("Shazam", y: 0.9), line("Unclear title", y: 0.7, confidence: 0.5),
                     line("Unclear artist", y: 0.66, confidence: 0.5), line("Far row", y: 0.2)]
        let result = SongExtractor.parse(lines, assetID: "image")
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.unresolvedLineIndices, [1, 2, 3])
    }
    func testDedupExactTitleAndArtistPreservesSourcesAndVersions() {
        let a = SongExtractor.parse([line("Shazam", y: 0.9), line("Intro", y: 0.7), line("The xx", y: 0.66)], assetID: "a").candidates[0]
        let b = SongExtractor.parse([line("Shazam", y: 0.9), line("  INTRO  ", y: 0.7), line("The XX", y: 0.66)], assetID: "b").candidates[0]
        var remix = a; remix.title = "Intro (Remix)"; remix.id = "intro (remix)\u{1F}the xx"
        var unknown = a; unknown.artist = nil; unknown.id = "intro\u{1F}"
        let songs = SongExtractor.deduplicate([a, b, a, remix, unknown])
        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(songs.first { $0.id == a.id }?.evidence.count, 2)
        XCTAssertEqual(songs.first { $0.id == a.id }?.evidence.map(\.assetID), ["a", "b"])
    }
    func testCSVFormulaAndQuoteSafetyKeepsJSONEvidenceUnchanged() {
        let original = "=SUM(1+1) - Artist"
        let candidate = SongExtractor.parse([line(original, y: 0.7)], assetID: "a").candidates[0]
        let csv = SongExtractor.csv([candidate])
        XCTAssertTrue(csv.contains("\"'=SUM(1+1)\""))
        XCTAssertEqual(candidate.evidence[0].originalText, [original])
        XCTAssertTrue(candidate.spotifySearchURL.hasPrefix("https://open.spotify.com/search/"))
        XCTAssertTrue(candidate.youtubeSearchURL.contains("search_query="))
    }
}

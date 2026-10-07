import AppKit
import XCTest
import PhotoTriageCore
@testable import PhotoTriageApp

final class MusicExtractionTests: XCTestCase {
    func testOCRPreviewNeverDownloadsAndUsesReadableQuality() {
        let options = MusicExtractionJob.previewOptions()
        XCTAssertFalse(options.isNetworkAccessAllowed)
        XCTAssertTrue(options.isSynchronous)
        XCTAssertEqual(options.deliveryMode, .highQualityFormat)
        XCTAssertEqual(options.resizeMode, .exact)
    }
    func testTinyCachedPreviewIsRejectedWithoutUpscaling() {
        XCTAssertFalse(MusicExtractionJob.isReadablePreview(width: 30, height: 64, originalWidth: 1170, originalHeight: 2532))
        XCTAssertTrue(MusicExtractionJob.isReadablePreview(width: 740, height: 1600, originalWidth: 1170, originalHeight: 2532))
        XCTAssertTrue(MusicExtractionJob.isReadablePreview(width: 100, height: 200, originalWidth: 100, originalHeight: 200))
    }
    func testPilotSamplesRepresentativeDistinctPositions() {
        XCTAssertEqual(MusicExtractionJob.sampleIndices([0, 4, 9, 15, 20], limit: 3), [0, 9, 20])
        XCTAssertEqual(MusicExtractionJob.sampleIndices([1, 2], limit: 5), [1, 2])
        XCTAssertEqual(MusicExtractionJob.sampleIndices([], limit: 3), [])
        XCTAssertEqual(MusicExtractionJob.sampleIndices([1, 2, 3], limit: 0), [])
    }
    func testExactHierarchyWinsAndDuplicateNamesStayAmbiguous() {
        let exact = AlbumScope(id: "a", title: "音樂", path: ["選集", "音樂"], visibleAssetCount: 3)
        let other = AlbumScope(id: "b", title: "音樂", path: ["Other", "音樂"], visibleAssetCount: 5)
        XCTAssertEqual(AlbumResolver.musicCandidates([exact, other]), [exact])
        let second = AlbumScope(id: "c", title: "音樂", path: ["Another", "音樂"], visibleAssetCount: 4)
        XCTAssertEqual(AlbumResolver.musicCandidates([other, second]).count, 2)
        XCTAssertEqual(AlbumResolver.musicCandidates([other]), [other])
    }
    func testBlockedReportDoesNotPretendAnAlbumIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = MusicExtractionReport(status: "permission_required", authorization: "notRequested", resolvedAlbum: nil, albumCandidates: [])
        try MusicExtractionJob.save(report, to: root)
        let text = try String(contentsOf: root.appendingPathComponent("songs-review.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("尚未讀取相簿"))
        XCTAssertTrue(text.contains("permission_required"))
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("music-extraction.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testVisionRecognizesSyntheticMusicScreenshotOnDevice() async throws {
        try await MainActor.run {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 1400, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 1400)).fill()
            for (text, y, size) in [("Shazam", 1280.0, 40.0), ("Midnight City", 950.0, 48.0), ("M83", 895.0, 35.0),
                                    ("Intro", 650.0, 48.0), ("The xx", 595.0, 35.0)] {
                (text as NSString).draw(at: NSPoint(x: 180, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            let lines = try MusicExtractionJob.recognize(try XCTUnwrap(bitmap.cgImage))
            XCTAssertTrue(lines.contains { $0.text.lowercased().contains("midnight") })
            XCTAssertTrue(lines.contains { $0.text.lowercased().contains("m83") })
            let parsed = PhotoTriageCore.SongExtractor.parse(lines, assetID: "synthetic-only")
            XCTAssertEqual(parsed.candidates.count, 2)
        }
    }
}

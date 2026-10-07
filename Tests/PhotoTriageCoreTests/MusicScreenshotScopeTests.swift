import XCTest
@testable import PhotoTriageCore

final class MusicScreenshotScopeTests: XCTestCase {
    let album = "music"
    func record(_ id: String, screenshot: Bool = false, video: Bool = false) -> PhotoRecord {
        PhotoRecord(id: id, kind: video ? .video : .image, isScreenshot: screenshot, albumIDs: [album, "other"])
    }
    func testOnlyScreenshotImagesInMusicAreTargetsAndOtherMediaRemain() throws {
        let rows = [record("s1", screenshot: true), record("s2", screenshot: true), record("image"), record("video", screenshot: true, video: true)]
        let scope = try MusicScreenshotScope(albumID: album, albumMembers: rows)
        XCTAssertEqual(scope.targetIDs, ["s1", "s2"])
        XCTAssertEqual(Set(scope.retained.map(\.id)), ["image", "video"])
        XCTAssertTrue(rows.allSatisfy { $0.albumIDs == [album, "other"] })
    }
    func testGlobalScreenshotOutsideMusicCannotEnterScope() {
        let outside = PhotoRecord(id: "outside", isScreenshot: true, albumIDs: ["other"])
        XCTAssertThrowsError(try MusicScreenshotScope(albumID: album, albumMembers: [outside]))
    }
    func testTravelOverlapAndDuplicateIDsAreRejected() {
        let r = record("s", screenshot: true)
        XCTAssertThrowsError(try MusicScreenshotScope(albumID: album, albumMembers: [r], protectedIDs: ["s"]))
        XCTAssertThrowsError(try MusicScreenshotScope(albumID: album, albumMembers: [r, r]))
    }
    func testCurrentScopeMustMatchBackupIncludingMetadataAndRetainedItems() throws {
        let rows = [record("s", screenshot: true), record("video", video: true)]
        let scope = try MusicScreenshotScope(albumID: album, albumMembers: rows)
        XCTAssertNoThrow(try scope.validate(MusicScreenshotScope(albumID: album, albumMembers: rows.reversed())))
        var changed = rows; changed[0].width += 1
        XCTAssertThrowsError(try scope.validate(MusicScreenshotScope(albumID: album, albumMembers: changed)))
        XCTAssertThrowsError(try scope.validate(MusicScreenshotScope(albumID: album, albumMembers: [rows[0]])))
    }
    func testEmptyScopeAndUntaggedImagesNeverBecomeDeleteCandidates() throws {
        XCTAssertTrue(try MusicScreenshotScope(albumID: album, albumMembers: []).targetIDs.isEmpty)
        XCTAssertTrue(try MusicScreenshotScope(albumID: album, albumMembers: [record("imported-image")]).targetIDs.isEmpty)
    }
}

import XCTest
@testable import PhotoTriageCore

final class OrganizerPersistenceTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OrganizerStore-\(UUID())") }
    private func fixture() throws -> (ReviewDocument, LocalAlbumsDocument, ReviewDocument, LocalAlbumsDocument) {
        let review = ReviewDocument()
        var albums = LocalAlbumsDocument()
        _ = try LocalAlbumEngine.create(&albums, title: "Existing", sources: [], id: "local:one")
        var nextReview = review, nextAlbums = albums
        ReviewEngine.apply(to: &nextReview, ids: ["a"], label: "Complete batch") { $0.status = .organized }
        _ = try LocalAlbumEngine.changeMembers(&nextAlbums, id: "local:one", ids: ["a"], adding: true, sources: [])
        nextAlbums.history[nextAlbums.history.count - 1].pairedReviewID = nextReview.history.last!.id
        return (review, albums, nextReview, nextAlbums)
    }
    func testWriteFailureRollsBackExactOriginalBytes() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let reviewURL = folder.appendingPathComponent("review.json"), albumsURL = folder.appendingPathComponent("albums.json")
        let journal = folder.appendingPathComponent("pending.json")
        let (review, albums, nextReview, nextAlbums) = try fixture()
        try ReviewPersistence.save(review, to: reviewURL); try LocalAlbumPersistence.save(albums, to: albumsURL)
        let reviewBytes = try Data(contentsOf: reviewURL), albumBytes = try Data(contentsOf: albumsURL)
        XCTAssertThrowsError(try OrganizerPersistence.commit(review: nextReview, albums: nextAlbums,
            expectedReview: review, expectedAlbums: albums, reviewURL: reviewURL, albumURL: albumsURL, journalURL: journal,
            beforeDocumentWrite: { if $0 == 2 { throw NSError(domain: "simulated-disk-failure", code: 1) } }))
        XCTAssertEqual(try Data(contentsOf: reviewURL), reviewBytes)
        XCTAssertEqual(try Data(contentsOf: albumsURL), albumBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testInterruptedCommitFinishesBothDocumentsAndPreservesUndoLink() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let reviewURL = folder.appendingPathComponent("review.json"), albumsURL = folder.appendingPathComponent("albums.json")
        let journal = folder.appendingPathComponent("pending.json")
        let (review, albums, nextReview, nextAlbums) = try fixture()
        try ReviewPersistence.save(review, to: reviewURL); try LocalAlbumPersistence.save(albums, to: albumsURL)
        let pending = PendingOrganizerWrite(reviewBefore: try Data(contentsOf: reviewURL), albumsBefore: try Data(contentsOf: albumsURL),
            reviewAfter: try OrganizerPersistence.encoded(nextReview), albumsAfter: try OrganizerPersistence.encoded(nextAlbums))
        try OrganizerPersistence.write(OrganizerPersistence.encoded(pending), to: journal)
        try OrganizerPersistence.write(pending.reviewAfter, to: reviewURL)
        try OrganizerPersistence.recover(reviewURL: reviewURL, albumURL: albumsURL, journalURL: journal)
        XCTAssertEqual(try ReviewPersistence.load(from: reviewURL), nextReview)
        XCTAssertEqual(try LocalAlbumPersistence.load(from: albumsURL), nextAlbums)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testInterruptedRollbackRestoresMissingOriginalDocuments() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let reviewURL = folder.appendingPathComponent("review.json"), albumsURL = folder.appendingPathComponent("albums.json")
        let journal = folder.appendingPathComponent("pending.json")
        let (_, _, nextReview, nextAlbums) = try fixture()
        let pending = PendingOrganizerWrite(rollBack: true, reviewBefore: nil, albumsBefore: nil,
            reviewAfter: try OrganizerPersistence.encoded(nextReview), albumsAfter: try OrganizerPersistence.encoded(nextAlbums))
        try OrganizerPersistence.write(OrganizerPersistence.encoded(pending), to: journal)
        try OrganizerPersistence.write(pending.reviewAfter, to: reviewURL)
        try OrganizerPersistence.recover(reviewURL: reviewURL, albumURL: albumsURL, journalURL: journal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: albumsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testUnexpectedNewerDataStopsRecoveryWithoutOverwritingAnyFile() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let reviewURL = folder.appendingPathComponent("review.json"), albumsURL = folder.appendingPathComponent("albums.json")
        let journal = folder.appendingPathComponent("pending.json")
        let (review, albums, nextReview, nextAlbums) = try fixture()
        try ReviewPersistence.save(review, to: reviewURL); try LocalAlbumPersistence.save(albums, to: albumsURL)
        let pending = PendingOrganizerWrite(reviewBefore: try Data(contentsOf: reviewURL), albumsBefore: try Data(contentsOf: albumsURL),
            reviewAfter: try OrganizerPersistence.encoded(nextReview), albumsAfter: try OrganizerPersistence.encoded(nextAlbums))
        try OrganizerPersistence.write(OrganizerPersistence.encoded(pending), to: journal)
        var newer = albums
        _ = try LocalAlbumEngine.rename(&newer, id: "local:one", title: "External change", sources: [])
        try LocalAlbumPersistence.save(newer, to: albumsURL)
        let actual = try Data(contentsOf: albumsURL), reviewBytes = try Data(contentsOf: reviewURL), journalBytes = try Data(contentsOf: journal)
        XCTAssertThrowsError(try OrganizerPersistence.recover(reviewURL: reviewURL, albumURL: albumsURL, journalURL: journal))
        XCTAssertEqual(try Data(contentsOf: albumsURL), actual)
        XCTAssertEqual(try Data(contentsOf: reviewURL), reviewBytes)
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    }
    func testOldHistoryAndRawOrganizedStatusRemainCompatible() throws {
        let old = Data("{\"schemaVersion\":1,\"edits\":{},\"hidden\":[],\"history\":[{\"date\":0,\"label\":\"old action\",\"editsBefore\":{},\"hiddenBefore\":[]}]}".utf8)
        let value = try JSONDecoder().decode(LocalAlbumsDocument.self, from: old)
        XCTAssertNil(value.history[0].pairedReviewID)
        let status = try JSONDecoder().decode(ReviewStatus.self, from: Data("\"organized\"".utf8))
        XCTAssertEqual(status, .organized); XCTAssertEqual(status.label, "已完成審閱")
    }
    func testRecentIDsAreBoundedUniqueAndPersistenceIsPrivate() throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        var value = DestinationPreferences()
        for index in 0..<8 { value.remember("local:\(index)") }
        value.remember("local:6")
        XCTAssertEqual(value.recentAlbumIDs, ["local:6", "local:7", "local:5", "local:4", "local:3"])
        let url = folder.appendingPathComponent("recent.json")
        try OrganizerPersistence.saveDestinations(value, to: url)
        XCTAssertEqual(try OrganizerPersistence.loadDestinations(from: url), value)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

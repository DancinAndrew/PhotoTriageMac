import XCTest
@testable import PhotoTriageCore
@testable import PhotoTriageApp

final class LocalAlbumFlowTests: XCTestCase {
    func testUnifiedSourcesUseReceiptIdentityAndPreserveSameNamesAndUnknownCandidates() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            let trip = TravelTrip(id: "trip", title: "Shared title", place: TravelPlace(countryID: "TWN", country: "台灣"),
                start: Date(), end: Date(), anchorIDs: ["a"], assetIDs: ["a"], unknownCandidateIDs: ["unknown"],
                sampleIDs: [], localSamples: 0, travelSceneSamples: 0, confidence: "low", reasons: [])
            model.albums = [Album(id: "approved", title: "Shared title"), Album(id: "different", title: "Shared title")]
            model.records = [PhotoRecord(id: "a", albumIDs: ["approved"]), PhotoRecord(id: "b", albumIDs: ["different"]),
                             PhotoRecord(id: "unknown")]
            model.document.manualGroups["manual"] = "Shared title"
            var decision = ReviewDecision(); decision.groupOverride = "manual"
            model.document.decisions["missing"] = decision
            let review = model.document
            var report = TravelLibraryReport(authorization: "fixture", status: "fixture")
            report.analysis = TravelAnalysis(trips: [trip], visibleAssetCount: 3, geotaggedCount: 0,
                                             excludedIDs: [:], unclassifiedCount: 1)
            model.travelReport = report
            model.travelReceipts = [TravelAlbumReceipt(tripID: "trip", title: "Shared title", albumID: "approved",
                                                       assetIDs: ["a"], status: "verified")]
            model.refreshOrganizerAlbums()
            XCTAssertEqual(model.organizerAlbums.count, 3)
            let approved = try XCTUnwrap(model.organizerAlbums.first { $0.id == "photos:approved" })
            XCTAssertEqual(approved.origins.map(\.kind), [.photos, .travel])
            XCTAssertEqual(approved.assetIDs, ["a"])
            XCTAssertFalse(model.organizerAlbums.contains { $0.id == "travel:trip" })
            XCTAssertEqual(model.organizerAlbums.first { $0.id == "classification:manual" }?.assetIDs, ["missing"])
            XCTAssertEqual(model.count(.unclassified), 1)
            model.setScope(.unclassified); XCTAssertEqual(model.visible.map(\.id), ["unknown"])
            try model.renameLocalAlbum(id: approved.id, title: "Renamed")
            XCTAssertEqual(model.albums[0].title, "Shared title")
            XCTAssertEqual(model.document, review)
            XCTAssertEqual(model.travelReceipts[0].albumID, "approved")
        }
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("LocalAlbumFlow-\(UUID())") }
    func testSnapshotImportAndLocalMembershipKeepReviewIndependentAndDoNotWriteData() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        var document = ReviewDocument()
        var kept = ReviewDecision(); kept.status = .kept
        var queued = ReviewDecision(); queued.status = .deleteCandidate
        document.decisions = ["kept": kept, "queued": queued]
        let expectedReview = document
        let reviewURL = folder.appendingPathComponent("photos-review.json")
        try ReviewPersistence.save(document, to: reviewURL)
        let before = try Data(contentsOf: reviewURL)
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            let snapshot = LibrarySnapshot(records: [PhotoRecord(id: "imported", albumIDs: ["photos"]),
                PhotoRecord(id: "local"), PhotoRecord(id: "kept"), PhotoRecord(id: "queued"), PhotoRecord(id: "unknown")],
                albums: [Album(id: "photos", title: "Imported album")], assets: [:])
            model.loadPhotosSnapshot(snapshot)
            XCTAssertEqual(model.count(.unreviewed), 3)
            XCTAssertEqual(model.count(.unclassified), 4)
            XCTAssertEqual(model.count(.organized), 0)
            XCTAssertEqual(model.document.decision(for: "imported").status, .unreviewed)
            XCTAssertFalse(model.locallyClassifiedIDs.contains("unknown"))
            model.select("local")
            let albumID = try model.createLocalAlbum(title: "Local album", includeSelection: true)
            XCTAssertEqual(model.count(.unclassified), 3)
            XCTAssertEqual(model.count(.unreviewed), 3)
            XCTAssertEqual(model.count(.organized), 0)
            model.setOrganizerAlbum(albumID); model.selectAll(); model.addToDeleteQueue()
            XCTAssertTrue(model.locallyClassifiedIDs.contains("local"))
            XCTAssertEqual(model.visible.map(\.id), ["local"])
            model.undo(); XCTAssertEqual(model.document, expectedReview)
            XCTAssertEqual(try Data(contentsOf: reviewURL), before)
            let localBytes = try Data(contentsOf: model.localAlbumURL)
            model.loadPhotosSnapshot(snapshot)
            let audit = ReviewStatusAudit.report(model: model)
            XCTAssertEqual(audit["classifiedCount"] as? Int, 2)
            XCTAssertEqual(audit["organizedMarkerCount"] as? Int, 0)
            XCTAssertEqual(try Data(contentsOf: reviewURL), before)
            XCTAssertEqual(try Data(contentsOf: model.localAlbumURL), localBytes)
            XCTAssertEqual(model.document.decision(for: "kept").status, .kept)
            XCTAssertEqual(model.document.decision(for: "queued").status, .deleteCandidate)
        }
    }
    func testCreateRenameMembersDeleteAndUndoPreserveReviewFileAndAllPhotos() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try ReviewPersistence.save(ReviewDocument(), to: folder.appendingPathComponent("demo-review.json"))
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            let before = try Data(contentsOf: model.reviewURL), records = model.records
            model.select(model.visible[0].id)
            let id = try model.createLocalAlbum(title: "Coffee", includeSelection: true)
            model.setOrganizerAlbum(id); XCTAssertEqual(model.visible.count, 1)
            try model.renameLocalAlbum(id: id, title: "Coffee notes"); XCTAssertEqual(model.visible.count, 1)
            model.selectAll(); try model.changeLocalAlbumMembers(id: id, adding: false)
            XCTAssertTrue(model.visible.isEmpty); XCTAssertTrue(model.selected.isEmpty)
            model.undo(); XCTAssertEqual(model.visible.count, 1)
            try model.deleteLocalAlbum(id: id); XCTAssertEqual(model.visible.count, 43)
            model.undo(); XCTAssertTrue(model.organizerAlbums.contains { $0.id == id })
            XCTAssertEqual(model.records, records); XCTAssertEqual(try Data(contentsOf: model.reviewURL), before)
            let reopened = AppModel(reviewRoot: folder)
            XCTAssertEqual(reopened.organizerAlbums.first { $0.id == id }?.title, "Coffee notes")
            XCTAssertEqual(reopened.localAlbums.history, model.localAlbums.history)
        }
    }
    func testLocalClassificationUpdatesUnclassifiedAndUndoAfterRestart() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            let record = model.records.first { $0.albumIDs.isEmpty }!
            let count = model.count(.unclassified)
            model.select(record.id); let id = try model.createLocalAlbum(title: "Unsorted notes", includeSelection: true)
            XCTAssertEqual(model.count(.unclassified), count - 1)
            model.setScope(.unclassified); XCTAssertFalse(model.visible.contains { $0.id == record.id })
            let reopened = AppModel(reviewRoot: folder); reopened.undoLocalAlbum()
            XCTAssertFalse(reopened.organizerAlbums.contains { $0.id == id })
            XCTAssertEqual(reopened.count(.unclassified), count)
        }
    }
    func testInspectorMouseSwitchCloseSelectAllAndClearDoNotRequestScroll() async {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        await MainActor.run {
            let model = AppModel(reviewRoot: folder); let ids = model.visible.map(\.id)
            model.select(ids[2]); XCTAssertTrue(model.inspectorVisible); XCTAssertNil(model.scrollTargetID)
            model.select(ids[3]); XCTAssertNil(model.scrollTargetID)
            model.closeInspector(); XCTAssertFalse(model.inspectorVisible); XCTAssertEqual(model.selected, [ids[3]])
            model.selectAll(); XCTAssertEqual(model.selected.count, 43); XCTAssertNil(model.scrollTargetID)
            model.clearSelection(); XCTAssertFalse(model.inspectorVisible); XCTAssertNil(model.focusedID)
            model.advance(1); XCTAssertEqual(model.scrollTargetID, ids[0])
            XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
    func testCancelledAlbumActionAndDuplicateLeaveFilesUnchanged() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            let id = try model.createLocalAlbum(title: "Trips")
            let before = try Data(contentsOf: model.localAlbumURL)
            model.albumAction = .delete(id); model.albumAction = nil
            XCTAssertEqual(try Data(contentsOf: model.localAlbumURL), before)
            XCTAssertThrowsError(try model.createLocalAlbum(title: " trips "))
            XCTAssertEqual(try Data(contentsOf: model.localAlbumURL), before)
            model.albumAction = .rename(id); XCTAssertTrue(model.hasModal)
            let selected = model.selected; model.selectAll(); XCTAssertEqual(model.selected, selected)
        }
    }
    func testCorruptLocalAlbumsBlockWritesAndKeepSourceCollections() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("demo-local-albums.json")
        let original = Data("broken".utf8); try original.write(to: url)
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            XCTAssertFalse(model.canManageAlbums); XCTAssertFalse(model.organizerAlbums.isEmpty)
            XCTAssertThrowsError(try model.createLocalAlbum(title: "No write"))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
}

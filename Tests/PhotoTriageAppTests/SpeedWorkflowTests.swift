import AppKit
import XCTest
import PhotoTriageCore
@testable import PhotoTriageApp

final class SpeedWorkflowTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("SpeedWorkflow-\(UUID())") }
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testAlbumScreenshotReviewMediaDateIntersectionAndChips() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let date = base
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            var review = ReviewDocument(); var kept = ReviewDecision(); kept.status = .kept
            review.decisions["b"] = kept
            try ReviewPersistence.save(review, to: folder.appendingPathComponent("photos-review.json"))
            let records = [PhotoRecord(id: "a", date: date, isScreenshot: true, albumIDs: ["x"]),
                PhotoRecord(id: "b", date: date, isScreenshot: true, albumIDs: ["x"]),
                PhotoRecord(id: "c", date: date, albumIDs: ["x"]),
                PhotoRecord(id: "d", date: date.addingTimeInterval(2 * 86400), isScreenshot: true, albumIDs: ["x"]),
                PhotoRecord(id: "e", date: date, isScreenshot: true, albumIDs: ["y"]),
                PhotoRecord(id: "v", date: date, kind: .video, albumIDs: ["x"]),
                PhotoRecord(id: "unknown", isScreenshot: true, albumIDs: ["x"])]
            model.loadPhotosSnapshot(LibrarySnapshot(records: records, albums: [Album(id: "x", title: "X"), Album(id: "y", title: "Y")], assets: [:]))
            model.setOrganizerAlbum("photos:x"); model.setScope(.screenshots); model.setScope(.unreviewed)
            model.filter.media = .image; model.rangeStart = date; model.rangeEnd = date; model.setDateRangeEnabled(true)
            XCTAssertEqual(model.visible.map(\.id), ["a"])
            XCTAssertEqual(Set(model.activeFilterChips.map(\.kind)), [.album, .review, .screenshots, .media, .date])
            model.selectAll(); model.setOrganizerAlbum("photos:y")
            XCTAssertEqual(model.visible.map(\.id), ["e"]); XCTAssertTrue(model.selected.isEmpty)
            XCTAssertTrue(model.filter.screenshotsOnly); XCTAssertEqual(model.filter.reviewStatus, .unreviewed)
            XCTAssertTrue(model.useDateRange); XCTAssertEqual(model.filter.media, .image)
            model.setOrganizerAlbum("photos:x"); model.removeFilterChip(.review)
            XCTAssertEqual(Set(model.visible.map(\.id)), ["a", "b"])
            model.removeFilterChip(.screenshots); XCTAssertEqual(Set(model.visible.map(\.id)), ["a", "b", "c"])
            model.removeFilterChip(.date); XCTAssertEqual(model.visible.count, 5)
            model.removeFilterChip(.media); XCTAssertEqual(model.visible.count, 6)
            model.resetFilter(); XCTAssertEqual(model.visible.count, 7); XCTAssertTrue(model.activeFilterChips.isEmpty)
            XCTAssertEqual(model.document, review)
        }
    }
    func testFilterSelectionIntersectionEmptyAndKeyboardNavigationRemainSafe() async {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            model.selectAll(); model.setScope(.screenshots)
            XCTAssertEqual(model.selected, Set(model.visible.map(\.id)))
            XCTAssertEqual(model.selected.count, 5)
            model.filter.media = .video; model.filterChanged()
            XCTAssertTrue(model.visible.isEmpty); XCTAssertTrue(model.selected.isEmpty); XCTAssertFalse(model.canAct)
            model.advance(1); model.selectAll(); model.repeatDestination(completeReview: true)
            XCTAssertNil(model.albumAction); XCTAssertTrue(model.document.decisions.isEmpty)
            model.removeFilterChip(.media); model.advance(1)
            XCTAssertEqual(model.selected.count, 1); XCTAssertEqual(model.scrollTargetID, model.visible.first?.id)
            model.setScope(.unreviewed); XCTAssertTrue(model.filter.screenshotsOnly)
            model.mark(.kept); XCTAssertEqual(model.visible.count, 4)
            XCTAssertEqual(model.selected.count, 1)
        }
    }
    func testUnknownDateSwitchOnlyReplacesDateConditionAndInvalidRangeIsEmpty() async {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            model.setScope(.unreviewed); model.filter.media = .image
            model.setDateRangeEnabled(true); model.setUnknownDateOnly(true)
            XCTAssertFalse(model.useDateRange); XCTAssertTrue(model.filter.unknownDateOnly)
            XCTAssertEqual(model.filter.reviewStatus, .unreviewed); XCTAssertEqual(model.filter.media, .image)
            XCTAssertTrue(model.visible.allSatisfy { $0.date == nil })
            model.setDateRangeEnabled(true); XCTAssertFalse(model.filter.unknownDateOnly)
            model.rangeStart = Date(); model.rangeEnd = .distantPast; model.filterChanged()
            XCTAssertTrue(model.visible.isEmpty)
        }
    }
    func testRecentDestinationsPersistRenameRepeatAndDeletedFallback() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), ids = DemoLibrary.records.map(\.id)
            let first = try model.createLocalAlbum(title: "First"), second = try model.createLocalAlbum(title: "Second")
            model.select(ids[0]); try model.addSelectionToAlbum(id: first)
            model.select(ids[1]); try model.addSelectionToAlbum(id: second)
            XCTAssertEqual(model.destinationPreferences.recentAlbumIDs, [second, first])
            XCTAssertFalse(FileManager.default.fileExists(atPath: model.reviewURL.path))
            try model.renameLocalAlbum(id: second, title: "Renamed")
            let reopened = AppModel(reviewRoot: folder)
            XCTAssertEqual(reopened.preferredDestinationID, second)
            XCTAssertEqual(reopened.repeatDestinationAlbum?.title, "Renamed")
            reopened.select(ids[2]); reopened.repeatDestination()
            XCTAssertTrue(reopened.organizerAlbums.first { $0.id == second }!.assetIDs.contains(ids[2]))
            XCTAssertTrue(reopened.document.decisions.isEmpty)
            try reopened.deleteLocalAlbum(id: second)
            XCTAssertEqual(reopened.repeatDestinationAlbum?.id, first)
            reopened.select(ids[3]); reopened.repeatDestination()
            XCTAssertTrue(reopened.organizerAlbums.first { $0.id == first }!.assetIDs.contains(ids[3]))
            try reopened.deleteLocalAlbum(id: first)
            XCTAssertNil(reopened.repeatDestinationAlbum); XCTAssertEqual(reopened.preferredDestinationID, "new")
            let before = reopened.localAlbums
            reopened.select(ids[4]); reopened.repeatDestination(completeReview: true)
            XCTAssertEqual(reopened.albumAction, .addSelectionAndComplete)
            XCTAssertEqual(reopened.localAlbums, before); XCTAssertTrue(reopened.document.decisions.isEmpty)
        }
    }
    func testAddAndCompleteOneUndoAfterRestartPreservesOtherFlagsAndPhotos() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), ids = Array(DemoLibrary.records.prefix(4).map(\.id))
            model.select(ids[0]); model.toggleTemporary(); model.assignGroup(title: "Existing group")
            model.select(ids[1]); model.mark(.kept)
            model.select(ids[2]); model.addToDeleteQueue()
            let albumID = try model.createLocalAlbum(title: "Batch")
            let review = model.document, albums = model.localAlbums, records = model.records
            model.selected = Set(ids.prefix(3)); model.focusedID = ids[0]
            try model.addSelectionToAlbum(id: albumID, completeReview: true)
            XCTAssertEqual(model.document.decision(for: ids[0]).status, .organized)
            XCTAssertTrue(model.document.decision(for: ids[0]).isTemporary)
            XCTAssertEqual(model.document.decision(for: ids[0]).groupOverride, review.decision(for: ids[0]).groupOverride)
            XCTAssertEqual(model.document.decision(for: ids[1]).status, .kept)
            XCTAssertEqual(model.document.decision(for: ids[2]).status, .deleteCandidate)
            XCTAssertEqual(model.document.decision(for: ids[3]).status, .unreviewed)
            XCTAssertEqual(model.records, records)
            XCTAssertEqual(model.localAlbums.history.last?.pairedReviewID, model.document.history.last?.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: model.organizerJournalURL.path))
            let history = model.document.history.count, albumHistory = model.localAlbums.history.count
            try model.addSelectionToAlbum(id: albumID, completeReview: true)
            XCTAssertEqual(model.document.history.count, history); XCTAssertEqual(model.localAlbums.history.count, albumHistory)
            let reopened = AppModel(reviewRoot: folder); reopened.undo()
            XCTAssertEqual(reopened.document, review); XCTAssertEqual(reopened.localAlbums, albums)
            XCTAssertEqual(reopened.records, records)
        }
    }
    func testAlreadyMemberCompletionHasReviewUndoAndNewAlbumCompletionIsPaired() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), id = model.visible[0].id
            model.select(id); let album = try model.createLocalAlbum(title: "Existing", includeSelection: true)
            let oldAlbums = model.localAlbums
            try model.addSelectionToAlbum(id: album, completeReview: true)
            XCTAssertEqual(model.localAlbums, oldAlbums); XCTAssertEqual(model.document.decision(for: id).status, .organized)
            model.undo(); XCTAssertEqual(model.document.decision(for: id).status, .unreviewed)
            model.select(id); let newID = try model.createLocalAlbum(title: "New complete", includeSelection: true, completeReview: true)
            XCTAssertTrue(model.organizerAlbums.contains { $0.id == newID })
            XCTAssertEqual(model.document.decision(for: id).status, .organized)
            model.undo(); XCTAssertFalse(model.organizerAlbums.contains { $0.id == newID })
            XCTAssertEqual(model.document.decision(for: id).status, .unreviewed)
            XCTAssertTrue(model.organizerAlbums.contains { $0.id == album })
        }
    }
    func testCompletionInUnreviewedAlbumIntersectionAdvancesAndUndoRestoresBoth() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            model.setScope(.screenshots); let ids = Array(model.visible.prefix(2).map(\.id))
            model.selected = Set(ids); let source = try model.createLocalAlbum(title: "Source", includeSelection: true)
            let target = try model.createLocalAlbum(title: "Target")
            model.setOrganizerAlbum(source); model.setScope(.unreviewed); model.selectAll()
            try model.addSelectionToAlbum(id: target, completeReview: true)
            XCTAssertTrue(model.visible.isEmpty); XCTAssertTrue(model.selected.isEmpty)
            XCTAssertTrue(model.filter.screenshotsOnly); XCTAssertEqual(model.selectedOrganizerAlbumID, source)
            model.undo(); XCTAssertEqual(Set(model.visible.map(\.id)), Set(ids))
            XCTAssertTrue(model.organizerAlbums.first { $0.id == target }!.assetIDs.isEmpty)
        }
    }
    func testPairedUndoCannotSkipNewerReviewAndChronologicalUndoWorks() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), ids = Array(model.visible.prefix(2).map(\.id))
            model.select(ids[0]); let album = try model.createLocalAlbum(title: "Compound", includeSelection: true, completeReview: true)
            model.select(ids[1]); model.mark(.kept)
            let before = model.document
            model.undoLocalAlbum(); XCTAssertEqual(model.document, before)
            XCTAssertTrue(model.organizerAlbums.contains { $0.id == album })
            model.undo(); XCTAssertEqual(model.document.decision(for: ids[1]).status, .unreviewed)
            model.undo(); XCTAssertFalse(model.organizerAlbums.contains { $0.id == album })
            XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
    func testCompletedReviewDoesNotPretendToHaveAlbumMembership() async {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        await MainActor.run {
            let model = AppModel(reviewRoot: folder), id = model.records.first { $0.albumIDs.isEmpty }!.id
            model.select(id); model.mark(.organized)
            XCTAssertEqual(model.document.decision(for: id).status.rawValue, "organized")
            XCTAssertEqual(model.classificationLabel(for: id), "尚無分類歸屬")
            model.setScope(.organized); model.setScope(.unclassified)
            XCTAssertEqual(model.visible.map(\.id), [id])
        }
    }
    func testCancelledAndCorruptRecentPreferencesNeverRewriteReviewOrOriginal() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("demo-destinations.json"), original = Data("corrupt".utf8)
        try original.write(to: url)
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            XCTAssertNotNil(model.destinationError); XCTAssertTrue(model.canManageAlbums)
            model.albumAction = .addSelection; model.albumAction = nil
            model.select(model.visible[0].id)
            _ = try model.createLocalAlbum(title: "Still works", includeSelection: true)
            XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
    func testNewerSavedReviewBlocksCompoundWriteWithoutClobberingIt() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), id = model.visible[0].id
            var newer = ReviewDocument()
            ReviewEngine.apply(to: &newer, ids: [id], label: "Newer user action") { $0.status = .kept }
            try ReviewPersistence.save(newer, to: model.reviewURL)
            let bytes = try Data(contentsOf: model.reviewURL), albums = model.localAlbums
            model.select(id)
            XCTAssertThrowsError(try model.createLocalAlbum(title: "Blocked", includeSelection: true, completeReview: true))
            XCTAssertEqual(try Data(contentsOf: model.reviewURL), bytes)
            XCTAssertEqual(model.localAlbums, albums)
            XCTAssertFalse(FileManager.default.fileExists(atPath: model.localAlbumURL.path))
        }
    }
    func testNewerReviewAndAlbumFilesBlockStandaloneChangesWithoutClobbering() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), id = model.visible[0].id
            let albumID = try model.createLocalAlbum(title: "Original")
            var newerAlbums = model.localAlbums
            _ = try LocalAlbumEngine.rename(&newerAlbums, id: albumID, title: "User newer title", sources: [])
            try LocalAlbumPersistence.save(newerAlbums, to: model.localAlbumURL)
            let albumBytes = try Data(contentsOf: model.localAlbumURL)
            model.select(id)
            XCTAssertThrowsError(try model.addSelectionToAlbum(id: albumID))
            XCTAssertThrowsError(try model.renameLocalAlbum(id: albumID, title: "Stale title"))
            XCTAssertEqual(try Data(contentsOf: model.localAlbumURL), albumBytes)
            var newerReview = ReviewDocument()
            ReviewEngine.apply(to: &newerReview, ids: [id], label: "Latest keep") { $0.status = .kept }
            try ReviewPersistence.save(newerReview, to: model.reviewURL)
            let reviewBytes = try Data(contentsOf: model.reviewURL)
            model.addToDeleteQueue()
            XCTAssertEqual(try Data(contentsOf: model.reviewURL), reviewBytes)
            XCTAssertNotNil(model.persistenceError)
        }
    }
    func testRestoreUnreviewedPreservesClassificationPlansAndTemporaryFlags() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), id = model.visible[0].id
            model.select(id); model.assignGroup(title: "Existing classification"); model.toggleTemporary()
            model.stageAlbum(AlbumPlan(id: "new:plan", title: "Existing plan", isNew: true))
            _ = try model.createLocalAlbum(title: "Actual local album", includeSelection: true)
            let before = model.document, albumBytes = try Data(contentsOf: model.localAlbumURL)
            model.resetSelected()
            var expected = before.decision(for: id); expected.status = .unreviewed
            XCTAssertEqual(model.document.decision(for: id), expected)
            XCTAssertEqual(try Data(contentsOf: model.localAlbumURL), albumBytes)
            XCTAssertTrue(model.locallyClassifiedIDs.contains(id))
            model.undo(); XCTAssertEqual(model.document, before)
        }
    }
}

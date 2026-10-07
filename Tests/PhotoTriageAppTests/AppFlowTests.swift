import AppKit
import XCTest
import SwiftUI
import PhotoTriageCore
@testable import PhotoTriageApp

final class AppFlowTests: XCTestCase {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTriageTests-\(UUID().uuidString)") }

    func testDemoMultiSelectionAndShiftRange() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            XCTAssertEqual(model.records.count, 43)
            let ids = model.visible.map(\.id)
            model.select(ids[0]); model.select(ids[2], modifiers: .command)
            XCTAssertEqual(model.selected, [ids[0], ids[2]])
            model.select(ids[5], modifiers: .shift)
            XCTAssertEqual(model.selected, Set([ids[0]] + Array(ids[2...5])))
            model.selectAll(); XCTAssertEqual(model.selected.count, 43)
        }
    }
    func testFilterReviewAdvanceAndPersistedUndoAfterRelaunch() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.setScope(.unreviewed); let first = model.visible[0].id
            model.select(first); model.mark(.kept)
            XCTAssertEqual(model.visible.count, 42)
            XCTAssertEqual(model.selected.count, 1)
            XCTAssertFalse(model.selected.contains(first))
            let reopened = AppModel(reviewRoot: root)
            XCTAssertEqual(reopened.document.decision(for: first).status, .kept)
            reopened.undo()
            XCTAssertEqual(reopened.count(.unreviewed), 43)
            XCTAssertEqual(try ReviewPersistence.load(from: reopened.reviewURL).decisions, [:])
        }
    }
    func testAlbumPlanRepeatQueuePrecedenceAndRemoval() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root); let id = model.visible[0].id
            model.select(id); model.mark(.deleteCandidate)
            let plan = AlbumPlan(id: "new:trip", title: "Trip", isNew: true)
            model.stageAlbum(plan); let historyCount = model.document.history.count
            model.stageAlbum(plan)
            XCTAssertEqual(model.document.history.count, historyCount)
            XCTAssertEqual(model.document.decision(for: id).status, .deleteCandidate)
            XCTAssertEqual(model.planCount, 1)
            model.removeFromQueue(ids: [id]); XCTAssertEqual(model.queueCount, 0)
            XCTAssertEqual(model.planCount, 1)
            model.removeAlbumPlans(ids: [id]); XCTAssertEqual(model.planCount, 0)
        }
    }
    func testDirectQueueBatchRepeatAndPersistedUndoPreserveAlbumsAndDecisions() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: root)
            let ids = Array(model.visible.prefix(3).map(\.id))
            model.select(ids[0]); model.mark(.kept)
            model.toggleTemporary(); model.stageAlbum(AlbumPlan(id: "new:notes", title: "Notes", isNew: true))
            model.select(ids[1]); model.assignGroup(title: "Personal notes")
            model.selected = Set(ids)
            _ = try model.createLocalAlbum(title: "References", includeSelection: true)
            let reviewBefore = model.document, recordsBefore = model.records
            let albumBytes = try Data(contentsOf: model.localAlbumURL)
            model.addToDeleteQueue()
            XCTAssertFalse(model.hasModal)
            XCTAssertTrue(model.notice.contains("照片未刪除"))
            XCTAssertEqual(model.queueCount, ids.count)
            XCTAssertEqual(model.document.history.count, reviewBefore.history.count + 1)
            XCTAssertEqual(model.document.history.last?.changes.count, ids.count)
            for id in ids {
                var expected = reviewBefore.decision(for: id); expected.status = .deleteCandidate
                XCTAssertEqual(model.document.decision(for: id), expected)
            }
            let queuedBytes = try Data(contentsOf: model.reviewURL)
            model.addToDeleteQueue()
            XCTAssertEqual(try Data(contentsOf: model.reviewURL), queuedBytes)
            XCTAssertEqual(try Data(contentsOf: model.localAlbumURL), albumBytes)
            XCTAssertEqual(model.records, recordsBefore)
            let reopened = AppModel(reviewRoot: root)
            XCTAssertEqual(reopened.queueCount, ids.count)
            reopened.undo()
            XCTAssertEqual(reopened.document, reviewBefore)
            XCTAssertEqual(try Data(contentsOf: reopened.localAlbumURL), albumBytes)
        }
    }
    func testDirectQueueGuardsEmptySelectionModalAndLoading() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.addToDeleteQueue(); XCTAssertTrue(model.document.history.isEmpty)
            model.selectAll(); model.showPlanSheet = true
            model.addToDeleteQueue(); XCTAssertTrue(model.document.history.isEmpty)
            model.showPlanSheet = false; model.isLoading = true
            model.addToDeleteQueue(); XCTAssertTrue(model.document.history.isEmpty)
            model.isLoading = false; model.persistenceError = "Blocked"
            model.addToDeleteQueue(); XCTAssertTrue(model.document.history.isEmpty)
        }
    }
    func testDirectQueueAdvancesUnreviewedFilterWithoutOpeningModal() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.setScope(.unreviewed)
            let ids = Array(model.visible.prefix(2).map(\.id))
            model.selected = Set(ids); model.focusedID = ids[0]
            model.addToDeleteQueue()
            XCTAssertFalse(model.hasModal)
            XCTAssertEqual(model.visible.count, 41)
            XCTAssertEqual(model.queueCount, 2)
            XCTAssertEqual(model.selected.count, 1)
            XCTAssertTrue(model.selected.isDisjoint(with: Set(ids)))
            model.undo(); XCTAssertEqual(model.visible.count, 43)
            XCTAssertEqual(model.queueCount, 0)
        }
    }
    func testWrongGroupReassignmentThenRestoreAndUndo() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            let destination = model.groups.first { $0.assetIDs.count == 10 }!
            let source = model.groups.first { $0.id != destination.id && $0.assetIDs.count == 10 }!.assetIDs[0]
            model.select(source); model.assignGroup(title: "Trip", existingID: destination.id)
            let manual = model.groups.first { $0.title == "Trip" }!
            XCTAssertEqual(manual.assetIDs.count, 11)
            XCTAssertTrue(manual.id.hasPrefix("manual:"))
            XCTAssertEqual(Set(model.groups.map(\.id)).count, model.groups.count)
            model.select(source); model.restoreSuggestedGroup()
            XCTAssertNil(model.document.decision(for: source).groupOverride)
            model.undo(); XCTAssertEqual(model.document.decision(for: source).groupOverride, manual.id)
            model.undo(); XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
    func testScreenshotVideoUnknownDateAndExistingAlbumFilters() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.setScope(.screenshots); XCTAssertEqual(model.visible.count, 5)
            model.filter.media = .video; XCTAssertTrue(model.visible.isEmpty)
            model.resetFilter(); model.filter.media = .video; XCTAssertEqual(model.visible.count, 4)
            model.resetFilter(); model.filter.unknownDateOnly = true; XCTAssertEqual(model.visible.count, 2)
            model.setAlbum(DemoLibrary.albums[0]); XCTAssertTrue(model.filter.unknownDateOnly)
            XCTAssertTrue(model.visible.isEmpty, "Switching albums must retain the unknown-date condition")
            model.removeFilterChip(.unknownDate); XCTAssertEqual(model.visible.count, 4)
            model.selectAll(); model.toggleTemporary(); XCTAssertEqual(model.count(.temporary), 4)
            model.toggleTemporary(); XCTAssertEqual(model.count(.temporary), 0)
        }
    }
    func testPermissionDeniedAndEmptyDemoRemainUsable() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let denied = AppModel(reviewRoot: root, startupOverride: "denied")
            XCTAssertFalse(denied.isDemo); XCTAssertEqual(denied.access, .denied)
            XCTAssertTrue(denied.records.isEmpty)
            denied.loadDemo(); XCTAssertEqual(denied.records.count, 43)
            let empty = AppModel(reviewRoot: root, startupOverride: "empty")
            XCTAssertTrue(empty.records.isEmpty)
            empty.advance(1); empty.selectAll(); empty.mark(.kept); empty.undo()
            XCTAssertTrue(empty.document.decisions.isEmpty)
        }
    }
    func testCorruptReviewFileBlocksAllWrites() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("demo-review.json")
        let original = Data("broken review file".utf8); try original.write(to: url)
        try await MainActor.run {
            let model = AppModel(reviewRoot: root)
            XCTAssertFalse(model.canReview)
            model.selectAll(); model.mark(.deleteCandidate); model.undo()
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
    func testDeniedThumbnailModeNeverNeedsACloudDownload() async {
        await MainActor.run {
            let loader = ThumbnailLoader()
            loader.load(nil)
            XCTAssertNil(loader.image)
            XCTAssertEqual(loader.message, "照片目前不可見")
            loader.stop(); loader.load(nil); XCTAssertNil(loader.image)
        }
    }
    func testSelectAllUsesEntireFilteredDatasetWithFeedbackAndNoReviewWrite() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.setScope(.screenshots); model.selectAll()
            XCTAssertEqual(model.selected, Set(model.visible.map(\.id)))
            XCTAssertEqual(model.selected.count, 5)
            XCTAssertTrue(model.notice.contains("5"))
            XCTAssertTrue(model.document.decisions.isEmpty)
            model.resetFilter(); model.selectAll(); XCTAssertEqual(model.selected.count, 43)
            XCTAssertTrue(model.notice.contains("43"))
            model.clearSelection(); XCTAssertTrue(model.selected.isEmpty); XCTAssertNil(model.focusedID)
            XCTAssertTrue(model.document.history.isEmpty)
        }
    }
    func testSelectAllCombinesAlbumAndMediaAndRefreshesAfterFilterChange() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.setAlbum(DemoLibrary.albums[0]); model.selectAll(); XCTAssertEqual(model.selected.count, 4)
            model.filter.media = .video; model.filterChanged(); model.selectAll()
            XCTAssertEqual(model.selected, Set(model.visible.map(\.id)))
            XCTAssertLessThan(model.selected.count, 4)
            model.resetFilter(); model.filter.unknownDateOnly = true; model.filterChanged(); model.selectAll()
            XCTAssertEqual(model.selected.count, 2)
        }
    }
    func testSelectAllDoesNotActBehindModalOrDuringReloadAndHandlesEmptyFilter() async {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await MainActor.run {
            let model = AppModel(reviewRoot: root)
            model.showAlbumSheet = true; model.selectAll(); XCTAssertTrue(model.selected.isEmpty)
            model.showAlbumSheet = false; model.isLoading = true; model.selectAll(); XCTAssertTrue(model.selected.isEmpty)
            model.isLoading = false; model.setScope(.screenshots); model.filter.media = .video; model.filterChanged()
            XCTAssertFalse(model.canSelectVisible); model.selectAll(); XCTAssertTrue(model.selected.isEmpty)
            XCTAssertTrue(model.notice.contains("沒有"))
        }
    }
}

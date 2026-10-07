import AppKit
import XCTest
import PhotoTriageCore
@testable import PhotoTriageApp

final class ResumeComparisonFlowTests: XCTestCase {
    func testRelaunchRestoresAlbumCombinedFiltersSelectionAndActualReviewProgress() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(reviewRoot: root)
            model.setScope(.screenshots); model.selectAll()
            let album = try model.createLocalAlbum(title: "Fictional review", includeSelection: true)
            model.setOrganizerAlbum(album); model.setScope(.unreviewed); model.filter.media = .image
            let first = try XCTUnwrap(model.visible.first); model.select(first.id)
            model.flushWorkspace()
            let reviewBefore = model.document, albumsBefore = model.localAlbums
            let again = AppModel(reviewRoot: root)
            XCTAssertEqual(again.selectedOrganizerAlbumID, album)
            XCTAssertTrue(again.filter.screenshotsOnly); XCTAssertEqual(again.filter.reviewStatus, .unreviewed)
            XCTAssertEqual(again.filter.media, .image); XCTAssertEqual(again.selected, [first.id])
            XCTAssertEqual(again.document, reviewBefore); XCTAssertEqual(again.localAlbums, albumsBefore)
            XCTAssertEqual(again.progressCount, 0)
            again.removeFilterChip(.review); again.filterChanged(); again.mark(.kept); again.flushWorkspace()
            let third = AppModel(reviewRoot: root)
            XCTAssertEqual(third.progressCount, 1); XCTAssertEqual(third.document.decision(for: first.id).status, .kept)
        }
    }
    func testMissingAlbumOnlyClearsItsConditionAndPreservesWorkspaceEvidence() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var state = WorkspaceState(); state.organizerAlbumID = "missing"
            state.filter.screenshotsOnly = true; state.filter.reviewStatus = .unreviewed
            try WorkspacePersistence.save(state, expected: nil, to: root.appendingPathComponent("demo-workspace.json"))
            let model = AppModel(reviewRoot: root)
            XCTAssertNil(model.selectedOrganizerAlbumID); XCTAssertTrue(model.filter.screenshotsOnly)
            XCTAssertEqual(model.filter.reviewStatus, .unreviewed); XCTAssertEqual(model.visible.count, 5)
            XCTAssertTrue(model.notice.contains("不可見"))
            XCTAssertEqual(try WorkspacePersistence.load(from: model.workspaceURL), state)
        }
    }
    func testCorruptWorkspaceAllowsReviewButPreservesCorruptPositionFile() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("demo-workspace.json"), data = Data("unreadable".utf8)
            try data.write(to: url)
            let model = AppModel(reviewRoot: root); XCTAssertNotNil(model.workspaceError)
            model.select(model.visible[0].id); model.mark(.kept); model.flushWorkspace()
            XCTAssertEqual(model.progressCount, 1); XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    func testComparisonCancelRepeatedCommitAndUndoAfterRelaunch() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(reviewRoot: root)
            let ids = Array(model.visible.filter { $0.kind == .image }.prefix(3).map(\.id))
            for (index, id) in ids.enumerated() { model.select(id, modifiers: index == 0 ? [] : .command) }
            let before = model.document
            model.beginComparison(); XCTAssertTrue(model.hasModal); XCTAssertFalse(model.canAct)
            model.comparison = nil; XCTAssertEqual(model.document, before)
            model.beginComparison(); let batch = try XCTUnwrap(model.comparison)
            XCTAssertThrowsError(try model.completeComparison(batch, keepers: [])); XCTAssertEqual(model.document, before)
            XCTAssertTrue(try model.completeComparison(batch, keepers: [ids[0]]))
            XCTAssertEqual(model.document.history.count, 1)
            XCTAssertEqual(model.document.decision(for: ids[0]).status, .kept)
            XCTAssertEqual(model.document.decision(for: ids[1]).status, .deleteCandidate)
            XCTAssertThrowsError(try model.completeComparison(batch, keepers: [ids[0]]))
            let again = AppModel(reviewRoot: root); again.undo(); XCTAssertEqual(again.document, before)
        }
    }
    func testComparisonSelectionLimitsVideoAndMissingMetadataAndUnavailableBatch() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(reviewRoot: root); model.selectAll(); XCTAssertFalse(model.canCompare)
            model.clearSelection(); let video = try XCTUnwrap(model.visible.first { $0.kind == .video })
            model.select(video.id); model.select(model.visible.first { $0.kind == .image }!.id, modifiers: .command)
            XCTAssertFalse(model.canCompare)
            model.resetFilter(); model.setUnknownDateOnly(true); model.selectAll(); XCTAssertTrue(model.canCompare)
            model.beginComparison(); let batch = try XCTUnwrap(model.comparison)
            model.records.removeAll { $0.id == batch.assetIDs[0] }
            XCTAssertThrowsError(try model.completeComparison(batch, keepers: [batch.assetIDs[1]]))
            XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
    func testComparisonPreviewCloudFailureUnavailableAndNoNetworkOptions() async throws {
        await MainActor.run {
            XCTAssertFalse(ComparisonPreviewLoader.options().isNetworkAccessAllowed)
            let loader = ComparisonPreviewLoader()
            loader.load(record: PhotoRecord(id: "demo:cloud"), asset: nil); XCTAssertEqual(loader.state, .cloud)
            loader.load(record: PhotoRecord(id: "demo:failed"), asset: nil); XCTAssertEqual(loader.state, .failed)
            loader.load(record: PhotoRecord(id: "unavailable"), asset: nil); XCTAssertEqual(loader.state, .unavailable)
            loader.stop(); XCTAssertNil(loader.image)
        }
    }
}

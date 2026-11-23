import AppKit
import XCTest
import PhotoTriageCore
@testable import PhotoTriageApp

final class DisplayReviewFlowTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DisplayReview-\(UUID())") }

    func testKTDEachCountAsReviewedAndResetUndoPreserveMembership() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), ids = Array(model.visible.prefix(3).map(\.id))
            for (index, id) in ids.enumerated() {
                model.select(id)
                if index == 0 { model.mark(.kept) }
                else if index == 1 { model.toggleTemporary() }
                else { model.addToDeleteQueue() }
            }
            XCTAssertEqual(model.progressCount, 3); XCTAssertEqual(model.count(.unreviewed), 40)
            XCTAssertEqual(model.document.decision(for: ids[1]).status, .unreviewed)
            XCTAssertTrue(model.document.decision(for: ids[1]).hasBeenReviewed)
            model.reviewFilterOption = .reviewed; XCTAssertEqual(Set(model.visible.map(\.id)), Set(ids))
            model.reviewFilterOption = .unreviewed; XCTAssertTrue(model.visible.allSatisfy { !model.document.decision(for: $0.id).hasBeenReviewed })
            model.resetFilter(); model.selected = Set(ids); model.focusedID = ids[0]
            let album = try model.createLocalAlbum(title: "Keep membership", includeSelection: true)
            let before = model.document, membership = model.localAlbums
            model.resetSelected()
            XCTAssertEqual(model.progressCount, 0); XCTAssertFalse(model.document.decision(for: ids[1]).isTemporary)
            XCTAssertEqual(model.localAlbums, membership)
            model.undo(); XCTAssertEqual(model.document, before)
            XCTAssertEqual(model.organizerAlbums.first { $0.id == album }?.assetIDs, Set(ids))
            let again = AppModel(reviewRoot: folder); XCTAssertEqual(again.progressCount, 3)
            model.workspaceSaveTask?.cancel(); again.workspaceSaveTask?.cancel()
        }
    }

    func testLegacyOAndTDerivedReadDoesNotRewriteDecisionOrHistory() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var doc = ReviewDocument()
        _ = ReviewEngine.apply(to: &doc, ids: [DemoLibrary.records[0].id], label: "Old O") { $0.status = .organized }
        _ = ReviewEngine.apply(to: &doc, ids: [DemoLibrary.records[1].id], label: "Old T") { $0.isTemporary = true }
        let url = folder.appendingPathComponent("demo-review.json")
        try ReviewPersistence.save(doc, to: url); let bytes = try Data(contentsOf: url), expected = doc
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            XCTAssertEqual(model.progressCount, 2); XCTAssertEqual(model.document, expected)
            model.reviewFilterOption = .legacy; XCTAssertEqual(model.visible.map(\.id), [DemoLibrary.records[0].id])
            model.selectAll(); model.mark(.organized); XCTAssertEqual(model.document, expected)
            model.reviewFilterOption = .reviewed; XCTAssertEqual(model.visible.count, 2)
            model.reviewFilterOption = .temporary; XCTAssertEqual(model.visible.map(\.id), [DemoLibrary.records[1].id])
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            model.resetFilter(); model.select(DemoLibrary.records[1].id); model.toggleTemporary()
            XCTAssertEqual(model.progressCount, 1); model.undo(); XCTAssertEqual(model.document, expected)
            model.undo(); XCTAssertEqual(model.document.decision(for: DemoLibrary.records[0].id).status, .organized)
            model.undo(); XCTAssertTrue(model.document.decisions.isEmpty)
            model.workspaceSaveTask?.cancel()
        }
    }

    func testInspectorPreferencePersistsWithoutSelectionAndNeverForcedOpen() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder), ids = model.visible.map(\.id)
            model.select(ids[0]); XCTAssertFalse(model.inspectorVisible); XCTAssertFalse(model.shouldShowInspector)
            model.selectAll(); XCTAssertFalse(model.inspectorVisible)
            model.inspectorVisible = true; XCTAssertTrue(model.shouldShowInspector)
            model.select(ids[0]); model.select(ids[1], modifiers: .command); model.select(ids[1], modifiers: .command)
            XCTAssertEqual(model.focusedID, ids[0]); XCTAssertTrue(model.shouldShowInspector)
            model.clearSelection(); XCTAssertTrue(model.inspectorVisible); XCTAssertFalse(model.shouldShowInspector)
            model.flushWorkspace()
            let again = AppModel(reviewRoot: folder)
            XCTAssertTrue(again.inspectorVisible); XCTAssertFalse(again.shouldShowInspector)
            again.select(ids[0]); XCTAssertTrue(again.shouldShowInspector)
            again.closeInspector(); again.select(ids[1]); again.selectAll(); again.advance(1)
            XCTAssertFalse(again.inspectorVisible); XCTAssertFalse(again.shouldShowInspector)
            again.resetFilter(); XCTAssertFalse(again.inspectorVisible); again.flushWorkspace()
            let third = AppModel(reviewRoot: folder); third.selectAll(); XCTAssertFalse(third.shouldShowInspector)
            XCTAssertEqual(try DisplayPreferencePersistence.load(from: third.displayPreferenceURL)?.inspectorEnabled, false)
            for value in [model, again, third] { value.workspaceSaveTask?.cancel() }
        }
    }

    func testEachThumbnailSizeRestartsAndDoesNotWriteReviewDocuments() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            model.select(model.visible[0].id); model.mark(.kept)
            let bytes = try Data(contentsOf: model.reviewURL), selected = model.selected
            for size in ThumbnailSize.allCases {
                model.setThumbnailSize(size); model.flushWorkspace()
                let again = AppModel(reviewRoot: folder)
                XCTAssertEqual(again.thumbnailSize, size); XCTAssertEqual(model.selected, selected)
                XCTAssertEqual(try Data(contentsOf: model.reviewURL), bytes)
                again.workspaceSaveTask?.cancel()
            }
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: model.displayPreferenceURL.path)[.posixPermissions] as? Int, 0o600)
            model.workspaceSaveTask?.cancel()
        }
    }

    func testOldWorkspaceWithoutNewFilterFieldLoadsAndCustomIntersectionClears() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        var state = WorkspaceState(); state.inspectorVisible = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var filter = try XCTUnwrap(object["filter"] as? [String: Any]); filter.removeValue(forKey: "reviewedOnly"); object["filter"] = filter
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("demo-workspace.json"))
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            XCTAssertNil(model.workspaceError); XCTAssertTrue(model.inspectorVisible)
            model.select(model.visible[0].id); model.mark(.kept); model.toggleTemporary()
            model.filter.reviewStatus = .kept; model.filter.temporaryOnly = true; model.filter.reviewedOnly = true
            model.filter.screenshotsOnly = true; model.filter.media = .video; model.filterChanged()
            XCTAssertEqual(model.reviewFilterOption, .custom); XCTAssertTrue(model.visible.isEmpty)
            XCTAssertEqual(Set(model.activeFilterChips.map(\.kind)).count, model.activeFilterChips.count)
            model.resetFilter(); XCTAssertEqual(model.reviewFilterOption, .all); XCTAssertEqual(model.visible.count, 43)
            XCTAssertTrue(model.inspectorVisible); XCTAssertTrue(model.activeFilterChips.isEmpty)
            model.workspaceSaveTask?.cancel()
        }
    }

    func testReflowWaitsForNewGeometryAndMountsTheSavedAnchor() async {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        await MainActor.run {
            let model = AppModel(reviewRoot: folder), id = model.visible[0].id
            model.currentScrollY = 310
            let old = CGRect(x: 22, y: -85, width: 200, height: 190)
            model.galleryFrames = [id: old]
            model.setThumbnailSize(.small)
            XCTAssertEqual(model.pendingViewportRestore?.anchorID, id)
            XCTAssertEqual(model.viewportAnchorToMount, id)
            XCTAssertFalse(model.viewportAnchorMountCompleted)
            model.recordGalleryFrames([id: old])
            XCTAssertNotNil(model.viewportReflowBaseline)
            model.recordGalleryFrames([id: CGRect(x: 22, y: 0, width: 130, height: 140)])
            XCTAssertNil(model.viewportReflowBaseline)
            XCTAssertNotNil(model.pendingViewportRestore)
            model.completeAnchorMount(id); XCTAssertTrue(model.viewportAnchorMountCompleted)
            model.completeViewportRestore(at: 119); XCTAssertNil(model.pendingViewportRestore)
            XCTAssertEqual(model.currentScrollY, 119)
            model.workspaceSaveTask?.cancel()
        }
    }

    func testCorruptFutureOrConcurrentPreferencesAreNeverOverwritten() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("display-preferences.json")
        var future = DisplayPreferences(); future.schemaVersion = 99
        for bytes in [Data("broken".utf8), try JSONEncoder().encode(future)] {
            try bytes.write(to: url)
            try await MainActor.run {
                let model = AppModel(reviewRoot: folder); XCTAssertNotNil(model.displayPreferenceError)
                model.setThumbnailSize(.large); model.inspectorVisible = true
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                model.workspaceSaveTask?.cancel()
            }
        }
        try FileManager.default.removeItem(at: url)
        try await MainActor.run {
            let model = AppModel(reviewRoot: folder)
            var newer = DisplayPreferences(); newer.thumbnailSize = .small
            try DisplayPreferencePersistence.save(newer, expected: nil, to: url)
            let bytes = try Data(contentsOf: url)
            model.setThumbnailSize(.large); XCTAssertNotNil(model.displayPreferenceError)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            model.workspaceSaveTask?.cancel()
        }
    }
}

import XCTest
@testable import PhotoTriageCore

final class WorkspaceComparisonTests: XCTestCase {
    func testWorkspaceRoundTripKeepsIntersectionPositionAndPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        var state = WorkspaceState()
        state.organizerAlbumID = "fictional-album"; state.filter.screenshotsOnly = true
        state.filter.reviewStatus = .unreviewed; state.filter.media = .image; state.useDateRange = true
        state.selectedIDs = ["a", "b"]; state.focusedID = "b"; state.scrollY = 310
        state.anchorID = "b"; state.anchorOffset = -18; state.reviewedCount = 7
        try WorkspacePersistence.save(state, expected: nil, to: url)
        XCTAssertEqual(try WorkspacePersistence.load(from: url), state)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
    func testCorruptFutureAndStaleWorkspaceNeverOverwriteOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json")
        for data in [Data("broken".utf8), try JSONEncoder().encode({ var s = WorkspaceState(); s.schemaVersion = 9; return s }())] {
            try data.write(to: url)
            XCTAssertThrowsError(try WorkspacePersistence.save(WorkspaceState(), expected: nil, to: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        try FileManager.default.removeItem(at: url)
        let before = WorkspaceState(); try WorkspacePersistence.save(before, expected: nil, to: url)
        var newer = before; newer.scrollY = 42
        try WorkspacePersistence.save(newer, expected: before, to: url)
        XCTAssertThrowsError(try WorkspacePersistence.save(before, expected: before, to: url))
        XCTAssertEqual(try WorkspacePersistence.load(from: url), newer)
    }
    func testInvalidScrollAndIndependentLaunchProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var invalid = WorkspaceState(); invalid.scrollY = -.infinity
        XCTAssertThrowsError(try WorkspacePersistence.save(invalid, expected: nil, to: root.appendingPathComponent("state.json")))
        let url = root.appendingPathComponent("launch.json")
        try WorkspacePersistence.saveLaunch(WorkspaceLaunchState(profile: .photos), expected: nil, to: url)
        XCTAssertEqual(try WorkspacePersistence.loadLaunch(from: url)?.profile, .photos)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("photos-review.json").path))
    }
    func testComparisonRequiresExplicitKeepersAndTwoToSixDistinctItems() {
        for ids in [[], ["a"], Array(repeating: "a", count: 2), (0..<7).map(String.init)] {
            XCTAssertThrowsError(try ComparisonEngine.statuses(assetIDs: ids, keepers: ["a"]))
        }
        XCTAssertThrowsError(try ComparisonEngine.statuses(assetIDs: ["a", "b"], keepers: []))
        XCTAssertThrowsError(try ComparisonEngine.statuses(assetIDs: ["a", "b"], keepers: ["outside"]))
    }
    func testMixedComparisonIsOneIdempotentUndoPreservingMembershipAndFlags() throws {
        var doc = ReviewDocument()
        var a = ReviewDecision(); a.status = .deleteCandidate; a.isTemporary = true; a.groupOverride = "manual:event"
        a.albumPlans = [AlbumPlan(id: "album", title: "Fictional")]
        var b = ReviewDecision(); b.status = .kept
        doc.decisions = ["a": a, "b": b]; doc.manualGroups = ["manual:event": "Event"]
        let before = doc
        let statuses = try ComparisonEngine.statuses(assetIDs: ["a", "b", "c"], keepers: ["a"])
        XCTAssertTrue(ReviewEngine.applyStatuses(to: &doc, statuses: statuses, label: "Compare"))
        XCTAssertEqual(doc.history.count, 1); XCTAssertEqual(doc.decision(for: "a").status, .kept)
        XCTAssertEqual(doc.decision(for: "b").status, .deleteCandidate)
        XCTAssertEqual(doc.decision(for: "a").albumPlans, a.albumPlans)
        XCTAssertEqual(doc.decision(for: "a").groupOverride, a.groupOverride)
        XCTAssertTrue(doc.decision(for: "a").isTemporary)
        XCTAssertFalse(ReviewEngine.applyStatuses(to: &doc, statuses: statuses, label: "Again"))
        _ = ReviewEngine.undo(&doc); XCTAssertEqual(doc, before)
    }
    func testAllKeepersNeverStageDeletionAndAlbumPlansNeverChangeReview() throws {
        XCTAssertTrue(try ComparisonEngine.statuses(assetIDs: ["a", "b"], keepers: ["a", "b"]).values.allSatisfy { $0 == .kept })
        for status in ReviewStatus.allCases {
            var decision = ReviewDecision(); decision.status = status
            ReviewEngine.stageAlbum(AlbumPlan(id: "album", title: "Fictional"), decision: &decision)
            XCTAssertEqual(decision.status, status)
            XCTAssertEqual(decision.hasBeenReviewed, status != .unreviewed)
            XCTAssertEqual(decision.isDeletionCandidate, status == .deleteCandidate)
        }
    }
}

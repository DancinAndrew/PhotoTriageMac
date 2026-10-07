import XCTest
@testable import PhotoTriageCore

final class ReviewTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(secondsFromGMT: 0)!; return result
    }
    func photo(_ id: String, seconds: Double = 0, place: Coordinate? = nil) -> PhotoRecord {
        PhotoRecord(id: id, date: base.addingTimeInterval(seconds), coordinate: place)
    }
    func testEmptyInputHasNoGroupsOrCandidates() {
        XCTAssertTrue(EventGrouping.suggest([], document: ReviewDocument()).isEmpty)
        XCTAssertTrue(EventGrouping.rapidShotIDs([]).isEmpty)
    }
    func testTimeAndLocationSplits() {
        let photos = [photo("a", place: Coordinate(25, 121)), photo("b", seconds: 60, place: Coordinate(25.001, 121)),
                      photo("c", seconds: 120, place: Coordinate(26, 121)), photo("d", seconds: 20_000, place: Coordinate(26, 121))]
        let groups = EventGrouping.suggest(photos, document: ReviewDocument(), calendar: calendar)
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.contains { Set($0.assetIDs) == ["a", "b"] })
    }
    func testDifferentCalendarDaysSplitEvenNearby() {
        let midnight = calendar.startOfDay(for: base)
        let photos = [PhotoRecord(id: "a", date: midnight.addingTimeInterval(-1)), PhotoRecord(id: "b", date: midnight)]
        XCTAssertEqual(EventGrouping.suggest(photos, document: ReviewDocument(), calendar: calendar).count, 2)
    }
    func testMissingMetadataIsExplicitAndNotInherited() {
        let photos = [photo("known", place: Coordinate(25, 121)), photo("unknown", seconds: 30),
                      PhotoRecord(id: "no-date"), PhotoRecord(id: "no-date-known-place", coordinate: Coordinate(25, 121))]
        let groups = EventGrouping.suggest(photos, document: ReviewDocument(), calendar: calendar)
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.contains { $0.title == "拍攝時間未知" && $0.detail.contains("位置未知") })
        XCTAssertTrue(groups.contains { $0.assetIDs == ["unknown"] && $0.detail.contains("位置未知") })
    }
    func testGroupingIsDeterministicAndCoversEachAssetOnce() {
        let photos = (0..<200).map { photo("\($0)", seconds: Double($0 * 1000)) }
        let a = EventGrouping.suggest(photos, document: ReviewDocument(), calendar: calendar)
        let b = EventGrouping.suggest(photos.reversed(), document: ReviewDocument(), calendar: calendar)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.flatMap(\.assetIDs).count, 200)
        XCTAssertEqual(Set(a.flatMap(\.assetIDs)).count, 200)
    }
    func testRapidShotsExcludeScreenshotsVideosAndUnknownDistance() {
        var screenshot = photo("screen", seconds: 2); screenshot.isScreenshot = true
        var video = photo("video", seconds: 4); video.kind = .video
        let photos = [photo("a"), photo("b", seconds: 6), screenshot, video,
                      photo("far", seconds: 8, place: Coordinate(25, 121))]
        XCTAssertEqual(EventGrouping.rapidShotIDs(photos), ["a", "b"])
    }
    func testBurstWithoutDateIsCandidate() {
        var value = PhotoRecord(id: "burst"); value.burstID = "capture"
        XCTAssertEqual(EventGrouping.rapidShotIDs([value]), ["burst"])
    }
    func testBatchReviewAndUndoRestoresMixedPriorState() {
        var document = ReviewDocument()
        ReviewEngine.apply(to: &document, ids: ["a"], label: "temporary") { $0.isTemporary = true }
        let prior = document
        ReviewEngine.apply(to: &document, ids: ["a", "b"], label: "keep") { $0.status = .kept }
        XCTAssertEqual(document.decision(for: "a").status, .kept)
        XCTAssertTrue(document.decision(for: "a").isTemporary)
        XCTAssertEqual(ReviewEngine.undo(&document), "keep")
        XCTAssertEqual(document, prior)
    }
    func testRepeatedOperationAndEmptySelectionAreNoOps() {
        var document = ReviewDocument()
        XCTAssertFalse(ReviewEngine.apply(to: &document, ids: [], label: "empty") { $0.status = .kept })
        ReviewEngine.apply(to: &document, ids: ["a"], label: "keep") { $0.status = .kept }
        XCTAssertFalse(ReviewEngine.apply(to: &document, ids: ["a"], label: "keep") { $0.status = .kept })
        XCTAssertEqual(document.history.count, 1)
    }
    func testAlbumPlanningIsIdempotentAndKeepsDeletionQueue() {
        var decision = ReviewDecision(); decision.status = .deleteCandidate
        let plan = AlbumPlan(id: "album", title: "Trip")
        ReviewEngine.stageAlbum(plan, decision: &decision)
        ReviewEngine.stageAlbum(plan, decision: &decision)
        XCTAssertEqual(decision.albumPlans, [plan])
        XCTAssertEqual(decision.status, .deleteCandidate)
        var clean = ReviewDecision(); ReviewEngine.stageAlbum(plan, decision: &clean)
        XCTAssertEqual(clean.status, .unreviewed)
    }
    func testSuggestedDestinationAdoptsMembersIntoStableManualGroup() {
        let photos = [photo("a"), photo("b", seconds: 60), photo("c", seconds: 20_000)]
        var document = ReviewDocument()
        let destination = EventGrouping.suggest(photos, document: document, calendar: calendar).first { $0.assetIDs.contains("a") }!
        let assignment = ReviewEngine.groupAssignment(selectedIDs: ["c"], destination: destination, newID: "manual:trip")
        XCTAssertEqual(assignment.ids, ["a", "b", "c"])
        ReviewEngine.apply(to: &document, ids: assignment.ids, label: "move", manualGroup: (assignment.id, "Trip")) { $0.groupOverride = assignment.id }
        let groups = EventGrouping.suggest(photos, document: document, calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "manual:trip")
        XCTAssertEqual(groups.first?.title, "Trip")
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        let repeated = ReviewEngine.groupAssignment(selectedIDs: ["a"], destination: groups.first, newID: "manual:unused")
        XCTAssertEqual(repeated.id, "manual:trip")
        ReviewEngine.undo(&document)
        XCTAssertEqual(document, ReviewDocument())
    }
    func testResetDecisionRemovesEntryAndUndoRestoresPlans() {
        var document = ReviewDocument()
        ReviewEngine.apply(to: &document, ids: ["a"], label: "plan") {
            ReviewEngine.stageAlbum(AlbumPlan(id: "x", title: "X"), decision: &$0)
        }
        let prior = document
        ReviewEngine.apply(to: &document, ids: ["a"], label: "reset") { $0 = ReviewDecision() }
        XCTAssertNil(document.decisions["a"])
        ReviewEngine.undo(&document); XCTAssertEqual(document, prior)
    }
    func testFilterCombinesAlbumVideoDateAndReviewState() {
        var document = ReviewDocument()
        ReviewEngine.apply(to: &document, ids: ["a"], label: "keep") { $0.status = .kept }
        var a = photo("a"); a.kind = .video; a.albumIDs = ["album"]
        var filter = PhotoFilter(); filter.scope = .kept; filter.media = .video; filter.albumID = "album"
        filter.startDate = base; filter.endDate = base.addingTimeInterval(1)
        XCTAssertTrue(filter.includes(a, document: document, groupIDs: [:], rapidIDs: []))
        XCTAssertFalse(filter.includes(photo("b"), document: document, groupIDs: [:], rapidIDs: []))
        a.date = filter.endDate
        XCTAssertFalse(filter.includes(a, document: document, groupIDs: [:], rapidIDs: []))
    }
    func testUnclassifiedIsNotSynonymousWithUnreviewed() {
        var document = ReviewDocument()
        ReviewEngine.apply(to: &document, ids: ["a"], label: "keep") { $0.status = .kept }
        var filter = PhotoFilter(); filter.scope = .unclassified
        XCTAssertTrue(filter.includes(photo("a"), document: document, groupIDs: ["a": "suggested:a"], rapidIDs: []))
        var existing = photo("b"); existing.albumIDs = ["album"]
        XCTAssertFalse(filter.includes(existing, document: document, groupIDs: [:], rapidIDs: []))
    }
    func testUnknownDatesNeverSneakIntoDateRange() {
        var filter = PhotoFilter(); filter.startDate = base
        XCTAssertFalse(filter.includes(PhotoRecord(id: "unknown"), document: ReviewDocument(), groupIDs: [:], rapidIDs: []))
        filter.startDate = nil; filter.unknownDateOnly = true
        XCTAssertTrue(filter.includes(PhotoRecord(id: "unknown"), document: ReviewDocument(), groupIDs: [:], rapidIDs: []))
        XCTAssertFalse(filter.includes(photo("known"), document: ReviewDocument(), groupIDs: [:], rapidIDs: []))
    }
    func testPersistenceRoundTripAndUndoAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("review.json")
        var document = ReviewDocument()
        ReviewEngine.apply(to: &document, ids: ["a"], label: "keep") { $0.status = .kept }
        try ReviewPersistence.save(document, to: url)
        var loaded = try ReviewPersistence.load(from: url)
        XCTAssertEqual(loaded, document)
        ReviewEngine.undo(&loaded); XCTAssertEqual(loaded, ReviewDocument())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testCorruptAndFutureFilesAreRejectedWithoutOverwriting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("not json".utf8); try corrupt.write(to: url)
        XCTAssertThrowsError(try ReviewPersistence.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        var future = ReviewDocument(); future.schemaVersion = 99
        try ReviewPersistence.save(future, to: url)
        XCTAssertThrowsError(try ReviewPersistence.load(from: url))
    }
    func testFailedAtomicReplacementLeavesOriginalDirectoryUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("review.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("preserve"); try Data([7]).write(to: marker)
        XCTAssertThrowsError(try ReviewPersistence.save(ReviewDocument(), to: target))
        XCTAssertEqual(try Data(contentsOf: marker), Data([7]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["review.json"])
    }
    func testUnavailableDecisionSurvivesAndExportContainsGroupNames() throws {
        var document = ReviewDocument()
        ReviewEngine.apply(to: &document, ids: ["missing"], label: "group", manualGroup: ("manual:trip", "Trip")) {
            $0.groupOverride = "manual:trip"; $0.status = .deleteCandidate
        }
        let export = ReviewPlanExport(source: "test", document: document, availableIDs: [])
        XCTAssertEqual(export.unavailableAssetIDs, ["missing"])
        XCTAssertEqual(export.manualGroups["manual:trip"], "Trip")
        XCTAssertEqual(export.decisions["missing"]?.status, .deleteCandidate)
        XCTAssertFalse(try JSONEncoder().encode(export).isEmpty)
    }
    func testUndoHistoryIsBoundedAt100Operations() {
        var document = ReviewDocument()
        for index in 0..<120 {
            ReviewEngine.apply(to: &document, ids: ["a"], label: "\(index)") { $0.isTemporary = index % 2 == 0 }
        }
        XCTAssertEqual(document.history.count, 100)
        XCTAssertEqual(document.history.first?.label, "20")
    }
}

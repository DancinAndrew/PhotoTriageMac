import XCTest
@testable import PhotoTriageApp
@testable import PhotoTriageCore

final class TravelAlbumPlanTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let now = Date(timeIntervalSince1970: 1_700_500_000)
    var geography: OfflineGeography {
        let tw = CountryBoundary(id: "TWN", name: "台灣", polygons: [[[[120,22],[123,22],[123,26],[120,26],[120,22]]]], bounds: [120,22,123,26])
        let kr = CountryBoundary(id: "KOR", name: "韓國", polygons: [[[[125,34],[130,34],[130,39],[125,39],[125,34]]]], bounds: [125,34,130,39])
        return OfflineGeography(countries: [tw,kr])
    }
    var report: TravelLibraryReport {
        let home = (0..<16).map { index in
            TravelAsset(record: PhotoRecord(id: "home\(index)", date: base.addingTimeInterval(Double(-(index + 1) * 10 * 86400)), coordinate: Coordinate(25,121)))
        }
        let trip = (0..<3).map { index in
            TravelAsset(record: PhotoRecord(id: "trip\(index)", date: base.addingTimeInterval(Double(index * 86400)), coordinate: Coordinate(37.5,127)),
                        vision: LocalTravelVision(status: "local", scenes: ["outdoor": 0.9]))
        }
        var result = TravelLibraryReport(authorization: "authorized", status: "completed_visible_metadata_and_trip_previews")
        result.generatedAt = now; result.assets = home + trip
        return result
    }
    func plan(_ source: TravelLibraryReport? = nil, current: [PhotoRecord]? = nil, albums: [Album] = [],
              protected: Set<String> = [], receipts: [TravelAlbumReceipt] = [], members: [String: Set<String>] = [:]) throws -> [TravelTrip] {
        let source = source ?? report
        return try TravelAlbumWriter.plan(report: source, geography: geography, current: current ?? source.assets.map(\.record),
                                          albums: albums, protected: protected, receipts: receipts, albumMembers: members, now: now)
    }
    func testOnlyVerifiedTripCreatesAddOnlyPlan() throws {
        let result = try plan()
        XCTAssertEqual(result.count, 1); XCTAssertEqual(Set(result[0].assetIDs), ["trip0","trip1","trip2"])
        XCTAssertEqual(result[0].place.country, "韓國")
        XCTAssertTrue(report.assets.allSatisfy { $0.record.albumIDs.isEmpty })
    }
    func testRepeatedVerifiedWriteIsNoOpAndPreservesOtherMemberships() throws {
        let trip = try XCTUnwrap(plan().first)
        let ids = Set(trip.assetIDs)
        let receipt = TravelAlbumReceipt(tripID: trip.id, title: trip.title, albumID: "album", assetIDs: ids, status: "verified")
        XCTAssertTrue(try plan(albums: [Album(id: "album", title: trip.title)], receipts: [receipt], members: ["album": ids.union(["user-added"])]).isEmpty)
    }
    func testInterruptedCommitAndSameTitleStopForReconciliation() throws {
        let trip = try XCTUnwrap(plan().first)
        let receipt = TravelAlbumReceipt(tripID: trip.id, title: trip.title, albumID: nil, assetIDs: Set(trip.assetIDs), status: "prepared")
        XCTAssertThrowsError(try plan(receipts: [receipt]))
        XCTAssertThrowsError(try plan(albums: [Album(id: "user-album", title: trip.title)]))
        var committed = receipt; committed.status = "verified"; committed.albumID = "album"
        XCTAssertThrowsError(try plan(albums: [Album(id: "album", title: trip.title)], receipts: [committed], members: ["album": ["trip0"]]))
    }
    func testMetadataAndVisibilityChangesBlockCompleteBatch() {
        var changed = report.assets.map(\.record)
        changed[changed.count - 1].coordinate = Coordinate(35,128)
        XCTAssertThrowsError(try plan(current: changed))
        XCTAssertThrowsError(try plan(current: Array(report.assets.map(\.record).dropLast())))
    }
    func testNewReviewProtectionAndCloudGapsKeepTripUnclassified() throws {
        XCTAssertTrue(try plan(protected: ["trip1"]).isEmpty)
        var icloud = report
        for i in icloud.assets.indices { icloud.assets[i].vision = LocalTravelVision(status: "icloud_only_no_download") }
        XCTAssertTrue(try plan(icloud).isEmpty)
    }
    func testDeniedPartialStaleAndDuplicateReportsCannotWrite() {
        var denied = report; denied.status = "permission_required"
        XCTAssertThrowsError(try plan(denied))
        var partial = report; partial.status = "permission_revoked_partial"
        XCTAssertThrowsError(try plan(partial))
        var stale = report; stale.generatedAt = now.addingTimeInterval(-2 * 86400)
        XCTAssertThrowsError(try plan(stale))
        var duplicate = report; duplicate.assets.append(duplicate.assets[0])
        XCTAssertThrowsError(try plan(duplicate))
    }
}

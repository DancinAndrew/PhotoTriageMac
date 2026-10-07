import XCTest
@testable import PhotoTriageCore

final class TravelGroupingTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = Coordinate(25, 121)
    let away = Coordinate(37.5, 127)
    var geography: OfflineGeography {
        func rectangle(_ id: String, _ name: String, _ bounds: [Double]) -> CountryBoundary {
            let a = bounds[0], b = bounds[1], c = bounds[2], d = bounds[3]
            return CountryBoundary(id: id, name: name, polygons: [[[[a,b],[c,b],[c,d],[a,d],[a,b]]]], bounds: bounds)
        }
        return OfflineGeography(countries: [rectangle("TWN", "台灣", [120,22,123,26]),
                                             rectangle("KOR", "韓國", [125,34,130,39])])
    }
    func photo(_ id: String, hours: Double, gps: Coordinate? = nil, visual: Bool = true) -> TravelAsset {
        TravelAsset(record: PhotoRecord(id: id, date: base.addingTimeInterval(hours * 3600), coordinate: gps),
                    vision: visual ? LocalTravelVision(status: "local", scenes: ["outdoor": 0.9]) : nil)
    }
    var usualArea: [TravelAsset] { (0..<16).map { photo("home\($0)", hours: Double(-($0 + 1) * 24 * 10), gps: home) } }
    var trip: [TravelAsset] { [photo("a", hours: 0, gps: away), photo("b", hours: 24, gps: away), photo("c", hours: 48, gps: away)] }
    func analyze(_ extra: [TravelAsset], protected: Set<String> = []) -> TravelAnalysis {
        TravelGrouping.analyze(usualArea + extra, geography: geography, protectedIDs: protected, now: now)
    }
    func testCrossDayTripIsOneSemanticDestination() {
        let result = analyze(trip)
        XCTAssertEqual(result.trips.count, 1)
        XCTAssertEqual(result.trips[0].place.country, "韓國")
        XCTAssertTrue(result.trips[0].canCreateAlbum)
        XCTAssertEqual(Set(result.trips[0].assetIDs), ["a", "b", "c"])
        XCTAssertFalse(result.trips[0].title.contains("座標"))
    }
    func testReturnHomeAndLongGapSplitTrips() {
        let next = [photo("d", hours: 96, gps: away), photo("e", hours: 120, gps: away), photo("f", hours: 144, gps: away)]
        XCTAssertEqual(analyze(trip + [photo("return", hours: 72, gps: home)] + next).trips.count, 2)
        XCTAssertEqual(analyze(trip + [photo("later", hours: 24 * 30, gps: away)]).trips.count, 2)
    }
    func testUnknownGPSRequiresTwoCloseAnchorsAndLocalScene() {
        let anchors = [photo("a", hours: 0, gps: away), photo("b", hours: 8, gps: away), photo("c", hours: 12, gps: away)]
        let unknowns = [photo("supported", hours: 4), photo("unreadable", hours: 5, visual: false),
                        photo("outside", hours: 14), photo("far", hours: 30)]
        let group = analyze(anchors + unknowns).trips[0]
        XCTAssertTrue(group.assetIDs.contains("supported"))
        XCTAssertFalse(group.assetIDs.contains("unreadable"))
        XCTAssertFalse(group.assetIDs.contains("outside"))
        XCTAssertEqual(Set(group.unknownCandidateIDs), ["unreadable", "outside"])
    }
    func testScreenMusicTemporaryDeleteAndDocumentsStayOut() {
        var screen = photo("screen", hours: 4, gps: away); screen.record.isScreenshot = true
        var document = photo("doc", hours: 6, gps: away)
        document.vision = LocalTravelVision(status: "local", scenes: ["document": 0.95, "outdoor": 0.9])
        let result = analyze(trip + [screen, document, photo("music", hours: 5, gps: away)], protected: ["music"])
        XCTAssertEqual(Set(result.trips[0].assetIDs), ["a", "b", "c"])
        XCTAssertEqual(Set(result.excludedIDs.keys), ["music", "screen", "doc"])
    }
    func testMissingHomeVisionOrWeakMetadataNeedsReview() {
        XCTAssertFalse(TravelGrouping.analyze(trip, geography: geography, now: now).trips[0].canCreateAlbum)
        let noVision = trip.map { TravelAsset(record: $0.record) }
        XCTAssertFalse(analyze(noVision).trips[0].canCreateAlbum)
        var invalidAccuracy = trip[0]; invalidAccuracy.locationAccuracy = -1
        XCTAssertFalse(analyze([invalidAccuracy] + Array(trip.dropFirst())).trips[0].canCreateAlbum)
        var icloud = trip
        for i in icloud.indices { icloud[i].vision = LocalTravelVision(status: "icloud_only_no_download", scenes: ["outdoor": 1]) }
        XCTAssertFalse(analyze(icloud).trips[0].canCreateAlbum)
    }
    func testEmptyDuplicateFutureAndUnknownDateAreSafe() {
        XCTAssertTrue(TravelGrouping.analyze([], geography: geography, now: now).trips.isEmpty)
        var future = trip[0]; future.record.id = "future"; future.record.date = now.addingTimeInterval(3 * 86400)
        let missing = TravelAsset(record: PhotoRecord(id: "missing", coordinate: away))
        let result = analyze(trip + [trip[0], future, missing])
        XCTAssertEqual(result.visibleAssetCount, usualArea.count + trip.count + 2)
        XCTAssertEqual(result.trips[0].assetIDs.count, 3)
        XCTAssertEqual(Set(result.excludedIDs.keys), ["future", "missing"])
    }
    func testGeographyExcludesHolesAndInvalidCoordinatesAndRecognizesIslands() {
        let outer = [[0.0,0],[10,0],[10,10],[0,10],[0,0]]
        let hole = [[2.0,2],[4,2],[4,4],[2,4],[2,2]]
        let map = OfflineGeography(countries: [CountryBoundary(id: "X", name: "X", polygons: [[outer,hole]], bounds: [0,0,10,10])])
        XCTAssertEqual(map.resolve(Coordinate(1,1))?.countryID, "X")
        XCTAssertNil(map.resolve(Coordinate(3,3)))
        XCTAssertNil(map.resolve(Coordinate(.nan,1)))
        XCTAssertNil(map.resolve(Coordinate(92,1)))
        XCTAssertEqual(geography.resolve(Coordinate(22.0369,121.5584))?.region, "蘭嶼")
        XCTAssertEqual(geography.resolve(Coordinate(23.6,119.5))?.region, "澎湖")
    }
    func testDeterministicTripIDsAndNoAssetMutation() {
        let source = usualArea + trip
        let a = TravelGrouping.analyze(source, geography: geography, now: now)
        let b = TravelGrouping.analyze(source.reversed(), geography: geography, now: now)
        XCTAssertEqual(a.trips.map(\.id), b.trips.map(\.id))
        XCTAssertEqual(a.trips.map(\.assetIDs), b.trips.map(\.assetIDs))
        XCTAssertTrue(source.allSatisfy { $0.record.albumIDs.isEmpty })
    }
    func testBundledOfflinePlacesDecodeAndIdentifyRealWorldReferenceCoordinates() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let map = try JSONDecoder().decode(OfflineGeography.self, from: Data(contentsOf: project.appendingPathComponent("Resources/Travel/places.json")))
        XCTAssertGreaterThan(map.countries.count, 200); XCTAssertGreaterThan(map.cities.count, 7000)
        XCTAssertEqual(map.resolve(Coordinate(43.7,-79.4))?.country, "加拿大")
        XCTAssertEqual(map.resolve(Coordinate(-38.51,145.15))?.country, "澳洲")
        XCTAssertEqual(map.resolve(Coordinate(35.661,139.697))?.country, "日本")
        XCTAssertEqual(map.resolve(Coordinate(37.5665,126.978))?.country, "韓國")
        XCTAssertEqual(map.resolve(Coordinate(23.6,119.5))?.region, "澎湖")
        XCTAssertEqual(map.resolve(Coordinate(22.0369,121.5584))?.region, "蘭嶼")
    }
}

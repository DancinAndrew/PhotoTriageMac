import Foundation

public struct CountryBoundary: Codable, Sendable {
    public var id: String
    public var name: String
    public var polygons: [[[[Double]]]]
    public var bounds: [Double]
}
public struct GeographyCity: Codable, Sendable {
    public var name: String
    public var originalName: String
    public var countryID: String
    public var coordinate: Coordinate
}
public struct TravelPlace: Codable, Equatable, Sendable {
    public var countryID: String
    public var country: String
    public var city: String?
    public var cityOriginal: String?
    public var region: String?
    public var key: String { countryID + (region.map { ":" + $0 } ?? "") }
}
public struct OfflineGeography: Codable, Sendable {
    public var countries: [CountryBoundary]
    public var cities: [GeographyCity]
    public init(countries: [CountryBoundary], cities: [GeographyCity] = []) {
        self.countries = countries; self.cities = cities
    }
    private func inside(_ point: Coordinate, ring: [[Double]]) -> Bool {
        guard ring.count >= 4 else { return false }
        var result = false, previous = ring.count - 1
        for index in ring.indices {
            let a = ring[index], b = ring[previous]
            guard a.count >= 2, b.count >= 2 else { return false }
            if (a[1] > point.latitude) != (b[1] > point.latitude),
               point.longitude < (b[0] - a[0]) * (point.latitude - a[1]) / (b[1] - a[1]) + a[0] {
                result.toggle()
            }
            previous = index
        }
        return result
    }
    public func resolve(_ point: Coordinate) -> TravelPlace? {
        guard point.latitude.isFinite, point.longitude.isFinite,
              abs(point.latitude) <= 90, abs(point.longitude) <= 180 else { return nil }
        // These island review areas supplement small islands omitted at Natural Earth's map scale.
        let island: String?
        if (21.92...22.14).contains(point.latitude), (121.45...121.66).contains(point.longitude) { island = "蘭嶼" }
        else if (23.05...23.85).contains(point.latitude), (119.25...119.85).contains(point.longitude) { island = "澎湖" }
        else if (22.58...22.75).contains(point.latitude), (121.43...121.54).contains(point.longitude) { island = "綠島" }
        else { island = nil }
        let country = countries.first { country in
            guard country.bounds.count == 4,
                  point.longitude >= country.bounds[0], point.latitude >= country.bounds[1],
                  point.longitude <= country.bounds[2], point.latitude <= country.bounds[3] else { return false }
            return country.polygons.contains { polygon in
                guard let outer = polygon.first, inside(point, ring: outer) else { return false }
                return !polygon.dropFirst().contains { inside(point, ring: $0) }
            }
        }
        guard let id = island != nil ? "TWN" : country?.id,
              let name = island != nil ? "台灣" : country?.name else { return nil }
        let nearest = cities.filter { $0.countryID == id }.min {
            $0.coordinate.distance(to: point) < $1.coordinate.distance(to: point)
        }
        let city = nearest.flatMap { $0.coordinate.distance(to: point) <= 120_000 ? $0 : nil }
        return TravelPlace(countryID: id, country: name, city: city?.name,
                           cityOriginal: city?.originalName, region: island)
    }
}

public struct LocalTravelVision: Codable, Sendable {
    public var status: String
    public var scenes: [String: Double]
    public var text: [String]
    public init(status: String, scenes: [String: Double] = [:], text: [String] = []) {
        self.status = status; self.scenes = scenes; self.text = text
    }
    public var isReadable: Bool { status == "local" }
    public var isDocument: Bool { max(scenes["screenshot"] ?? 0, scenes["document"] ?? 0) >= 0.7 }
    public var isTravelScene: Bool {
        ["outdoor", "land", "beach", "mountain", "waterfall", "ocean", "lake", "building", "architecture", "city", "bridge", "park", "airplane", "boat", "landmark", "monument", "forest"].contains {
            scenes[$0, default: 0] >= 0.55
        }
    }
}
public struct TravelAsset: Codable, Sendable {
    public var record: PhotoRecord
    public var locationAccuracy: Double?
    public var vision: LocalTravelVision?
    public init(record: PhotoRecord, locationAccuracy: Double? = nil, vision: LocalTravelVision? = nil) {
        self.record = record; self.locationAccuracy = locationAccuracy; self.vision = vision
    }
}
public struct TravelTrip: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var place: TravelPlace
    public var start: Date
    public var end: Date
    public var anchorIDs: [String]
    public var assetIDs: [String]
    public var unknownCandidateIDs: [String]
    public var sampleIDs: [String]
    public var localSamples: Int
    public var travelSceneSamples: Int
    public var confidence: String
    public var reasons: [String]
    public var canCreateAlbum: Bool { confidence == "high" }
}
public struct TravelAnalysis: Codable, Sendable {
    public var trips: [TravelTrip]
    public var home: Coordinate?
    public var visibleAssetCount: Int
    public var geotaggedCount: Int
    public var excludedIDs: [String: String]
    public var unclassifiedCount: Int
}

public enum TravelGrouping {
    public static func analyze(_ assets: [TravelAsset], geography: OfflineGeography,
                               protectedIDs: Set<String> = [], now: Date = Date()) -> TravelAnalysis {
        var excluded: [String: String] = [:]
        var seen: Set<String> = []
        let eligible = assets.filter { asset in
            let r = asset.record
            guard seen.insert(r.id).inserted else { return false }
            let reason: String?
            if protectedIDs.contains(r.id) { reason = "已有音樂／暫時／待刪審閱決定，保留原決定" }
            else if r.isScreenshot { reason = "螢幕截圖保留未分類" }
            else if r.date == nil { reason = "時間未知" }
            else if r.date! > now.addingTimeInterval(48 * 3600) { reason = "未來時間需確認" }
            else if asset.vision?.isDocument == true { reason = "文件或介面內容，未當作旅遊照片" }
            else { reason = nil }
            if let reason { excluded[r.id] = reason; return false }
            return true
        }
        let dated = eligible.sorted {
            if $0.record.date == $1.record.date { return $0.record.id < $1.record.id }
            return $0.record.date! < $1.record.date!
        }
        var places: [String: TravelPlace] = [:]
        let located = dated.filter { asset in
            guard let coordinate = asset.record.coordinate else { return false }
            guard (asset.locationAccuracy.map { $0 >= 0 && $0 <= 1_000 } ?? true),
                  let place = geography.resolve(coordinate) else { return false }
            places[asset.record.id] = place
            return true
        }
        // Infer a usual area from repeated dates spread over months, not a holiday's dense burst.
        let calendar = Calendar(identifier: .gregorian)
        var best: (Coordinate, Int)?
        var homeCells: Set<String> = []
        for candidate in located {
            let center = candidate.record.coordinate!
            let cell = "\(Int(floor(center.latitude * 10))):\(Int(floor(center.longitude * 10)))"
            guard homeCells.insert(cell).inserted else { continue }
            let nearby = located.filter { $0.record.coordinate!.distance(to: center) <= 40_000 }
            let dates = nearby.map { $0.record.date! }
            let days = Set(dates.map { calendar.startOfDay(for: $0) })
            guard days.count >= 12, let first = dates.min(), let last = dates.max(),
                  last.timeIntervalSince(first) >= 90 * 86400 else { continue }
            if days.count > (best?.1 ?? 0) { best = (center, days.count) }
        }
        let home = best?.0
        var groups: [[TravelAsset]] = []
        var current: [TravelAsset] = []
        func flush() { if !current.isEmpty { groups.append(current); current = [] } }
        for asset in located {
            let coordinate = asset.record.coordinate!, place = places[asset.record.id]!
            if let home, home.distance(to: coordinate) <= 60_000 { flush(); continue }
            if let previous = current.last {
                let previousPlace = places[previous.record.id]!
                let gap = asset.record.date!.timeIntervalSince(previous.record.date!)
                let duration = asset.record.date!.timeIntervalSince(current[0].record.date!)
                // Country/island identity, time continuity and a known return home define a trip.
                // A single trip can span many days; there is no midnight boundary.
                if place.key != previousPlace.key || gap > 14 * 86400 || duration > 60 * 86400 { flush() }
            }
            current.append(asset)
        }
        flush()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current; formatter.dateFormat = "yyyy.MM.dd"
        var trips: [TravelTrip] = []
        for anchors in groups {
            let first = anchors[0], last = anchors.last!, start = first.record.date!, end = last.record.date!
            let place = places[first.record.id]!
            let cities = anchors.compactMap { places[$0.record.id]?.city }
            var uniqueCities: [String] = []
            for city in cities where !uniqueCities.contains(city) { uniqueCities.append(city) }
            let destination = place.region ?? (place.country + (uniqueCities.isEmpty ? "" : "・" + uniqueCities.prefix(3).joined(separator: "・")))
            let sampleIndices = Set([0, anchors.count / 2, anchors.count - 1]).sorted()
            let samples = sampleIndices.map { anchors[$0] }
            let local = samples.filter { $0.vision?.isReadable == true }
            let scenes = local.filter { $0.vision?.isTravelScene == true }
            var members = Set(anchors.map { $0.record.id })
            var unknown: [String] = []
            for asset in dated where asset.record.coordinate == nil {
                let date = asset.record.date!
                guard date >= start.addingTimeInterval(-3 * 3600), date <= end.addingTimeInterval(3 * 3600) else { continue }
                unknown.append(asset.record.id)
                // Missing GPS is never inherited from a distant day or an unreadable preview.
                let before = anchors.last { $0.record.date! <= date }
                let after = anchors.first { $0.record.date! >= date }
                if let before, let after,
                   date.timeIntervalSince(before.record.date!) <= 6 * 3600,
                   after.record.date!.timeIntervalSince(date) <= 6 * 3600,
                   asset.vision?.isReadable == true, asset.vision?.isTravelScene == true,
                   asset.vision?.isDocument != true { members.insert(asset.record.id) }
            }
            let high = home != nil && anchors.count >= 3 && end.timeIntervalSince(start) >= 3600 && local.count >= 2 && !scenes.isEmpty
            let id = "trip:\(place.key):\(formatter.string(from:start)):\(first.record.id.prefix(8))"
            let title = "旅遊｜\(destination)｜\(formatter.string(from:start))–\(formatter.string(from:end))"
            let reasons = ["\(anchors.count) 個已定位資產；以跨日連續性合併", "\(local.count) 個本機抽樣預覽，\(scenes.count) 個具旅行場景線索",
                           home == nil ? "尚無可靠常住區域，需人工確認" : "位於推定常住區域 60 公里之外",
                           "\(unknown.count) 個缺 GPS 的時間鄰近候選，只在雙側 6 小時定位及本機視覺支持時納入"]
            trips.append(TravelTrip(id: id, title: title, place: place, start: start, end: end,
                                    anchorIDs: anchors.map { $0.record.id }, assetIDs: members.sorted(),
                                    unknownCandidateIDs: unknown.filter { !members.contains($0) },
                                    sampleIDs: samples.map { $0.record.id }, localSamples: local.count,
                                    travelSceneSamples: scenes.count, confidence: high ? "high" : "review_required", reasons: reasons))
        }
        let assigned = Set(trips.filter(\.canCreateAlbum).flatMap(\.assetIDs))
        return TravelAnalysis(trips: trips.sorted { $0.start > $1.start }, home: home,
                              visibleAssetCount: seen.count, geotaggedCount: located.count,
                              excludedIDs: excluded, unclassifiedCount: seen.count - assigned.count)
    }
}

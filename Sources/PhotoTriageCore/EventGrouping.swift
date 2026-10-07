import Foundation

public enum EventGrouping {
    public static func suggest(_ photos: [PhotoRecord], document: ReviewDocument,
                               calendar: Calendar = .current) -> [EventGroup] {
        let sorted = photos.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return ($0.date ?? .distantPast) < ($1.date ?? .distantPast)
        }
        var clusters: [[PhotoRecord]] = []
        var overrides: [String: [PhotoRecord]] = [:]
        for photo in sorted {
            if let group = document.decision(for: photo.id).groupOverride {
                overrides[group, default: []].append(photo)
                continue
            }
            if let last = clusters.last?.last, canJoin(last, photo, calendar: calendar) {
                clusters[clusters.count - 1].append(photo)
            } else { clusters.append([photo]) }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        var result = clusters.map { cluster -> EventGroup in
            let first = cluster[0]
            let title = first.date.map { formatter.string(from: $0) } ?? "拍攝時間未知"
            let place = first.coordinate.map { "附近座標 \($0.label)" } ?? "位置未知"
            return EventGroup(id: "suggested:\(first.id)", title: title, detail: place + " · 自動建議",
                              assetIDs: cluster.map(\.id), start: first.date)
        }
        result += overrides.map { id, records in
            EventGroup(id: id, title: document.manualGroups[id] ?? "自訂事件",
                       detail: "手動分組 · 不變更照片相簿", assetIDs: records.map(\.id), start: records.first?.date)
        }
        return result.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return ($0.start ?? .distantPast) > ($1.start ?? .distantPast)
        }
    }

    private static func canJoin(_ a: PhotoRecord, _ b: PhotoRecord, calendar: Calendar) -> Bool {
        if let first = a.date, let second = b.date {
            guard calendar.isDate(first, inSameDayAs: second), second.timeIntervalSince(first) <= 3 * 3600 else { return false }
        } else if a.date != nil || b.date != nil { return false }
        switch (a.coordinate, b.coordinate) {
        case (.none, .none): return true
        case (.some(let x), .some(let y)): return x.distance(to: y) <= 2_000
        default: return false // Unknown location never silently inherits a known place.
        }
    }

    /// A review hint, not duplicate detection or a deletion recommendation.
    public static func rapidShotIDs(_ photos: [PhotoRecord]) -> Set<String> {
        let images = photos.filter { $0.kind == .image && !$0.isScreenshot }
        var result = Set(images.filter { $0.burstID != nil }.map(\.id))
        let dated = images.filter { $0.date != nil }.sorted { $0.date! < $1.date! }
        guard dated.count > 1 else { return result }
        for index in 1..<dated.count {
            let a = dated[index - 1], b = dated[index]
            guard b.date!.timeIntervalSince(a.date!) <= 10 else { continue }
            let nearby: Bool
            switch (a.coordinate, b.coordinate) {
            case (.none, .none): nearby = true
            case (.some(let x), .some(let y)): nearby = x.distance(to: y) <= 50
            default: nearby = false
            }
            if nearby { result.insert(a.id); result.insert(b.id) }
        }
        return result
    }
}

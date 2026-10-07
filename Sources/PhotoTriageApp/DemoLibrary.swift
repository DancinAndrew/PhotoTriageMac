import Foundation
import PhotoTriageCore

enum DemoLibrary {
    static let albums = [Album(id: "demo:travel", title: "旅行回憶"), Album(id: "demo:family", title: "家人")]
    static var records: [PhotoRecord] {
        let base = ISO8601DateFormatter().date(from: "2026-09-28T02:00:00Z")!
        var result: [PhotoRecord] = []
        let places: [Coordinate?] = [Coordinate(25.033, 121.565), Coordinate(24.147, 120.673),
                                      Coordinate(22.997, 120.213), nil]
        for group in 0..<4 {
            for index in 0..<10 {
                let screenshot = group == 3 && index < 5
                let seconds: Double = index < 3 ? Double(index * 3) : Double(index * 240)
                result.append(PhotoRecord(id: "demo:\(group):\(index)",
                    date: base.addingTimeInterval(Double(group * 86400) + seconds),
                    coordinate: places[group], kind: index == 8 ? .video : .image,
                    isScreenshot: screenshot, isFavorite: index == 2,
                    burstID: index < 3 && !screenshot ? "demo:burst:\(group)" : nil,
                    albumIDs: group == 0 && index < 4 ? ["demo:travel"] : [],
                    duration: index == 8 ? 18 : 0, demoScene: screenshot ? 4 : (group + index % 2) % 4))
            }
        }
        result.append(PhotoRecord(id: "demo:unknown:1", demoScene: 2))
        result.append(PhotoRecord(id: "demo:unknown:2", demoScene: 1))
        result.append(PhotoRecord(id: "demo:cloud", date: base.addingTimeInterval(86400 * 4)))
        return result.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

import Foundation
import PhotoTriageCore

struct TravelAlbumReceipt: Codable, Sendable {
    var tripID: String
    var title: String
    var albumID: String?
    var assetIDs: Set<String>
    var status: String
    var error: String?
    var date = Date()
}

/// Pure validation of proposed travel album references; no Photos write implementation.
enum TravelAlbumWriter {
    /// Validate a complete proposal without accessing or modifying Photos.
    static func plan(report: TravelLibraryReport, geography: OfflineGeography, current: [PhotoRecord],
                     albums: [Album], protected: Set<String>, receipts: [TravelAlbumReceipt],
                     albumMembers: [String: Set<String>], now: Date = Date()) throws -> [TravelTrip] {
        guard report.status == "completed_visible_metadata_and_trip_previews", report.schemaVersion == 1,
              abs(report.generatedAt.timeIntervalSince(now)) <= 24 * 3600,
              Set(report.assets.map { $0.record.id }).count == report.assets.count else {
            throw TravelAnalysisJob.failure("分析尚未完成或已過期；請重新分析後確認。")
        }
        let analysis = TravelGrouping.analyze(report.assets, geography: geography,
                                             protectedIDs: report.protectedIDs.union(protected), now: now)
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let originals = Dictionary(uniqueKeysWithValues: report.assets.map { ($0.record.id, $0.record) })
        var pending: [TravelTrip] = [], titles: Set<String> = []
        for trip in analysis.trips.filter(\.canCreateAlbum) {
            let members = Set(trip.assetIDs)
            guard !members.isEmpty, members.isDisjoint(with: protected) else {
                throw TravelAnalysisJob.failure("行程包含受保護項目，停止寫入。")
            }
            for id in members {
                guard let before = originals[id], let now = currentByID[id], before.date == now.date,
                      before.coordinate == now.coordinate, before.kind == now.kind,
                      before.width == now.width, before.height == now.height,
                      before.isScreenshot == now.isScreenshot, !now.isScreenshot else {
                    throw TravelAnalysisJob.failure("照片時間、位置或可見範圍已變更，停止寫入；請重新分析。")
                }
            }
            if let old = receipts.last(where: { $0.tripID == trip.id }) {
                guard old.status == "verified", old.assetIDs == members, let albumID = old.albumID,
                      let actual = albumMembers[albumID], albums.contains(where: { $0.id == albumID && $0.title == old.title }) else {
                    throw TravelAnalysisJob.failure("此行程有未完成或已變更的收據，需人工核對，避免重複建立。")
                }
                guard members.isSubset(of: actual) else { throw TravelAnalysisJob.failure("既有旅遊相簿成員已改變，請人工核對。") }
                continue
            }
            // A same-title album without our receipt could belong to the user or an interrupted write.
            // Stop for reconciliation instead of adding to an unrelated album or making a duplicate.
            guard !albums.contains(where: { $0.title == trip.title }), !receipts.contains(where: { $0.title == trip.title }),
                  titles.insert(trip.title).inserted else {
                throw TravelAnalysisJob.failure("已存在同名相簿 \(trip.title)，需人工核對後再繼續。")
            }
            pending.append(trip)
        }
        return pending
    }
}

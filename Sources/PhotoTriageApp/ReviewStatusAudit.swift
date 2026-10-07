import Foundation
import PhotoTriageCore

/// Local metadata-only diagnostics using the same imported snapshot and catalog as the UI.
enum ReviewStatusAudit {
    @MainActor
    static func report(model: AppModel) -> [String: Any] {
        func statuses(_ records: [PhotoRecord]) -> [String: Int] {
            Dictionary(grouping: records, by: { model.document.decision(for: $0.id).status.rawValue })
                .mapValues(\.count)
        }
        let classified = model.records.filter { model.locallyClassifiedIDs.contains($0.id) }
        let receipts: [[String: Any]] = model.travelReceipts.map { receipt in
            let actual = model.records.filter { $0.albumIDs.contains(receipt.albumID ?? "") }
            return ["title": receipt.title, "receiptStatus": receipt.status,
                    "expectedCount": receipt.assetIDs.count, "visibleCount": actual.count,
                    "exactMembershipMatches": Set(actual.map(\.id)) == receipt.assetIDs,
                    "reviewStatuses": statuses(actual)]
        }
        let albums: [[String: Any]] = model.organizerAlbums.map { album in
            let actual = model.records.filter { album.assetIDs.contains($0.id) }
            return ["title": album.title, "source": album.sourceLabel, "visibleCount": actual.count,
                    "reviewStatuses": statuses(actual)]
        }
        return ["generatedAt": ISO8601DateFormatter().string(from: Date()),
                "authorization": String(describing: model.access), "libraryRead": true,
                "permissionRequested": false, "photosMutated": false, "imagesRequested": false,
                "visibleCount": model.records.count, "storedDecisionCount": model.document.decisions.count,
                "unavailableDecisionCount": model.unavailableDecisionIDs.count,
                "reviewStatuses": statuses(model.records), "classifiedCount": classified.count,
                "unclassifiedCount": model.count(.unclassified),
                "classifiedReviewStatuses": statuses(classified),
                "organizedMarkerCount": model.count(.organized),
                "travelReceipts": receipts, "organizerAlbums": albums]
    }
}

import Foundation

public struct ComparisonBatch: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let assetIDs: [String]
    public init(assetIDs: [String]) { self.assetIDs = assetIDs }
}

public enum ComparisonEngine {
    public enum Failure: Error, LocalizedError {
        case invalidScope, chooseKeepers, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidScope: return "請選取 2–6 張不同照片再並排比較。"
            case .chooseKeepers: return "請明確選擇至少一張保留；也可以全部保留。"
            case .unavailable: return "比較範圍已改變或部分照片不可見，尚未套用標記。"
            }
        }
    }
    public static func statuses(assetIDs: [String], keepers: Set<String>) throws -> [String: ReviewStatus] {
        let scope = Set(assetIDs)
        guard (2...6).contains(scope.count), scope.count == assetIDs.count, !scope.contains("") else { throw Failure.invalidScope }
        guard !keepers.isEmpty, keepers.isSubset(of: scope) else { throw Failure.chooseKeepers }
        return Dictionary(uniqueKeysWithValues: assetIDs.map { ($0, keepers.contains($0) ? .kept : .deleteCandidate) })
    }
}

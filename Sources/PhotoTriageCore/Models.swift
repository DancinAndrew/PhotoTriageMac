import Foundation

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
    public func distance(to other: Coordinate) -> Double {
        let radians = Double.pi / 180
        let a = sin((other.latitude - latitude) * radians / 2)
        let b = sin((other.longitude - longitude) * radians / 2)
        let haversine = min(1, max(0, a * a + cos(latitude * radians) * cos(other.latitude * radians) * b * b))
        return 6_371_000 * 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
    }
    public var label: String { String(format: "%.3f, %.3f", latitude, longitude) }
}

public enum MediaKind: String, Codable, Sendable { case image, video }

public struct PhotoRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date?
    public var coordinate: Coordinate?
    public var kind: MediaKind
    public var isScreenshot: Bool
    public var isFavorite: Bool
    public var burstID: String?
    public var albumIDs: Set<String>
    public var duration: Double
    public var width: Int
    public var height: Int
    public var demoScene: Int?

    public init(id: String, date: Date? = nil, coordinate: Coordinate? = nil,
                kind: MediaKind = .image, isScreenshot: Bool = false,
                isFavorite: Bool = false, burstID: String? = nil,
                albumIDs: Set<String> = [], duration: Double = 0,
                width: Int = 4032, height: Int = 3024, demoScene: Int? = nil) {
        self.id = id; self.date = date; self.coordinate = coordinate; self.kind = kind
        self.isScreenshot = isScreenshot; self.isFavorite = isFavorite; self.burstID = burstID
        self.albumIDs = albumIDs; self.duration = duration; self.width = width; self.height = height
        self.demoScene = demoScene
    }
}

public struct Album: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed, kept, organized, deleteCandidate
    public var label: String {
        switch self {
        case .unreviewed: return "未審閱"
        case .kept: return "保留"
        case .organized: return "已完成審閱"
        case .deleteCandidate: return "待刪候選"
        }
    }
}

public struct AlbumPlan: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var isNew: Bool
    public init(id: String, title: String, isNew: Bool = false) {
        self.id = id; self.title = title; self.isNew = isNew
    }
}

public struct ReviewDecision: Codable, Equatable, Sendable {
    public var status: ReviewStatus = .unreviewed
    public var isTemporary: Bool = false
    public var groupOverride: String?
    public var albumPlans: [AlbumPlan] = []
    public init() {}
    public var isEmpty: Bool { self == ReviewDecision() }
    public var hasBeenReviewed: Bool { status != .unreviewed }
    public var isDeletionCandidate: Bool { status == .deleteCandidate }
}

public struct ReviewChange: Codable, Equatable, Sendable {
    public var assetID: String
    public var before: ReviewDecision?
    public var after: ReviewDecision?
}

public struct ReviewTransaction: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var label: String
    public var changes: [ReviewChange]
    public var groupsBefore: [String: String]
}

public struct ReviewDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var decisions: [String: ReviewDecision] = [:]
    public var manualGroups: [String: String] = [:]
    public var history: [ReviewTransaction] = []
    public init() {}
    public func decision(for id: String) -> ReviewDecision { decisions[id] ?? ReviewDecision() }
}

public struct EventGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var assetIDs: [String]
    public var start: Date?
}

public enum ReviewScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, unreviewed, unclassified, kept, organized, temporary, deleteQueue, screenshots, rapidShots
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "全部照片"
        case .unreviewed: return "未審閱"
        case .unclassified: return "尚未分類"
        case .kept: return "已保留"
        case .organized: return "已完成審閱"
        case .temporary: return "暫時用途"
        case .deleteQueue: return "待刪候選"
        case .screenshots: return "螢幕截圖"
        case .rapidShots: return "連拍／密集拍攝"
        }
    }
    public var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .unreviewed: return "tray"
        case .unclassified: return "square.stack.3d.up.slash"
        case .kept: return "heart"
        case .organized: return "checkmark.circle"
        case .temporary: return "clock"
        case .deleteQueue: return "trash"
        case .screenshots: return "camera.viewfinder"
        case .rapidShots: return "square.3.layers.3d"
        }
    }
}

public struct PhotoFilter: Codable, Equatable, Sendable {
    public var scope: ReviewScope = .all
    public var reviewStatus: ReviewStatus?
    public var screenshotsOnly = false
    public var unclassifiedOnly = false
    public var temporaryOnly = false
    public var rapidShotsOnly = false
    public var media: MediaKind?
    public var albumID: String?
    public var groupID: String?
    public var startDate: Date?
    public var endDate: Date?
    public var unknownDateOnly = false
    public init() {}

    public func includes(_ photo: PhotoRecord, document: ReviewDocument,
                         groupIDs: [String: String], rapidIDs: Set<String>) -> Bool {
        let decision = document.decision(for: photo.id)
        switch scope {
        case .all: break
        case .unreviewed: guard decision.status == .unreviewed else { return false }
        case .unclassified: guard decision.groupOverride == nil, decision.albumPlans.isEmpty,
                                  photo.albumIDs.isEmpty else { return false }
        case .kept: guard decision.status == .kept else { return false }
        case .organized: guard decision.status == .organized else { return false }
        case .temporary: guard decision.isTemporary else { return false }
        case .deleteQueue: guard decision.status == .deleteCandidate else { return false }
        case .screenshots: guard photo.isScreenshot else { return false }
        case .rapidShots: guard rapidIDs.contains(photo.id) else { return false }
        }
        if let reviewStatus, decision.status != reviewStatus { return false }
        if screenshotsOnly, !photo.isScreenshot { return false }
        if temporaryOnly, !decision.isTemporary { return false }
        if rapidShotsOnly, !rapidIDs.contains(photo.id) { return false }
        if unclassifiedOnly {
            guard decision.groupOverride == nil, decision.albumPlans.isEmpty,
                  photo.albumIDs.isEmpty else { return false }
        }
        if let media, photo.kind != media { return false }
        if let albumID, !photo.albumIDs.contains(albumID) { return false }
        if let groupID, groupIDs[photo.id] != groupID { return false }
        if unknownDateOnly, photo.date != nil { return false }
        if let startDate { guard let date = photo.date, date >= startDate else { return false } }
        if let endDate { guard let date = photo.date, date < endDate else { return false } }
        return true
    }
}

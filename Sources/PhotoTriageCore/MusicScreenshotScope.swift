import Foundation

public struct MusicScreenshotScope: Codable, Sendable {
    public var albumID: String
    public var screenshots: [PhotoRecord]
    public var retained: [PhotoRecord]
    public var targetIDs: Set<String> { Set(screenshots.map(\.id)) }
    public init(albumID: String, albumMembers: [PhotoRecord], protectedIDs: Set<String> = []) throws {
        guard !albumID.isEmpty, Set(albumMembers.map(\.id)).count == albumMembers.count,
              albumMembers.allSatisfy({ $0.albumIDs.contains(albumID) }) else {
            throw NSError(domain: "PhotoTriage.MusicScope", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "音樂相簿範圍資料不一致，停止操作。"])
        }
        self.albumID = albumID
        screenshots = albumMembers.filter { $0.kind == .image && $0.isScreenshot }.sorted { $0.id < $1.id }
        retained = albumMembers.filter { $0.kind != .image || !$0.isScreenshot }.sorted { $0.id < $1.id }
        guard targetIDs.isDisjoint(with: protectedIDs) else {
            throw NSError(domain: "PhotoTriage.MusicScope", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "刪除範圍與已確認旅遊相簿相交，停止操作。"])
        }
    }
    public func validate(_ current: MusicScreenshotScope) throws {
        guard albumID == current.albumID, screenshots == current.screenshots, retained == current.retained else {
            throw NSError(domain: "PhotoTriage.MusicScope", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "音樂相簿成員或中繼資料已改變，需重新備份與核對。"])
        }
    }
}

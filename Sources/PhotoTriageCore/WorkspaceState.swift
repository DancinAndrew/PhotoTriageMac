import Foundation
import Darwin

public enum WorkspaceProfile: String, Codable, Sendable { case demo, photos }

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var filter = PhotoFilter()
    public var organizerAlbumID: String?
    public var travelTripID: String?
    public var useDateRange = false
    public var rangeStart = Date()
    public var rangeEnd = Date()
    public var selectedIDs: Set<String> = []
    public var focusedID: String?
    public var inspectorVisible = false
    public var scrollY: Double = 0
    public var anchorID: String?
    public var anchorOffset: Double = 0
    public var reviewedCount = 0
    public var visibleCount = 0
    public init() {}
}

public struct WorkspaceLaunchState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var profile: WorkspaceProfile = .demo
    public init(profile: WorkspaceProfile = .demo) { self.profile = profile }
}

public enum WorkspacePersistence {
    public enum Failure: Error, LocalizedError {
        case incompatible, changed, invalidPosition
        public var errorDescription: String? {
            switch self {
            case .incompatible: return "工作位置檔版本不相容，原檔已保留。"
            case .changed: return "工作位置已由另一個程序更新，原檔已保留。"
            case .invalidPosition: return "工作位置數值無效，原檔已保留。"
            }
        }
    }
    public static func load(from url: URL) throws -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else { throw Failure.incompatible }
        guard state.scrollY.isFinite, state.scrollY >= 0, state.anchorOffset.isFinite else { throw Failure.invalidPosition }
        return state
    }
    public static func save(_ state: WorkspaceState, expected: WorkspaceState?, to url: URL) throws {
        guard try load(from: url) == expected else { throw Failure.changed }
        guard state.scrollY.isFinite, state.scrollY >= 0, state.anchorOffset.isFinite else { throw Failure.invalidPosition }
        try write(state, to: url)
    }
    public static func loadLaunch(from url: URL) throws -> WorkspaceLaunchState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(WorkspaceLaunchState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else { throw Failure.incompatible }
        return state
    }
    public static func saveLaunch(_ state: WorkspaceLaunchState, expected: WorkspaceLaunchState?, to url: URL) throws {
        guard try loadLaunch(from: url) == expected else { throw Failure.changed }
        try write(state, to: url)
    }
    private static func write<T: Encodable>(_ state: T, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let temporary = folder.appendingPathComponent(".workspace-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(state), attributes: [.posixPermissions: 0o600]) else {
            throw ReviewPersistence.Failure.writeFailed(errno)
        }
        guard temporary.path.withCString({ source in url.path.withCString { rename(source, $0) } }) == 0 else {
            throw ReviewPersistence.Failure.writeFailed(errno)
        }
    }
}

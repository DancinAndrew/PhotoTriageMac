import Foundation

public enum ThumbnailSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    public var label: String { switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大" } }
    public var minimumWidth: Double { switch self { case .small: return 118; case .medium: return 166; case .large: return 236 } }
    public var maximumWidth: Double { switch self { case .small: return 150; case .medium: return 225; case .large: return 310 } }
    public var imageHeight: Double { switch self { case .small: return 88; case .medium: return 136; case .large: return 200 } }
}

public struct DisplayPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var thumbnailSize: ThumbnailSize = .medium
    public var inspectorEnabled = false
    public init() {}
}

public enum DisplayPreferencePersistence {
    public static func load(from url: URL) throws -> DisplayPreferences? {
        guard let data = try OrganizerPersistence.read(url) else { return nil }
        let value = try JSONDecoder().decode(DisplayPreferences.self, from: data)
        guard value.schemaVersion == 1 else { throw OrganizerPersistence.Failure.unsupportedVersion }
        return value
    }
    public static func save(_ value: DisplayPreferences, expected: DisplayPreferences?, to url: URL) throws {
        guard value.schemaVersion == 1 else { throw OrganizerPersistence.Failure.unsupportedVersion }
        guard try load(from: url) == expected else { throw OrganizerPersistence.Failure.changedData }
        try OrganizerPersistence.write(OrganizerPersistence.encoded(value), to: url)
    }
}

import Foundation
import Darwin

public struct DestinationPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var recentAlbumIDs: [String] = []
    public init() {}
    public mutating func remember(_ id: String) {
        recentAlbumIDs.removeAll { $0 == id }
        recentAlbumIDs.insert(id, at: 0)
        recentAlbumIDs = Array(recentAlbumIDs.prefix(5))
    }
}

struct PendingOrganizerWrite: Codable {
    var schemaVersion = 1
    var rollBack = false
    var reviewBefore: Data?
    var albumsBefore: Data?
    var reviewAfter: Data
    var albumsAfter: Data
}

/// A recoverable write for the two local documents. No Photos library APIs or paths are used.
public enum OrganizerPersistence {
    public enum Failure: Error, LocalizedError {
        case changedData, unsupportedVersion
        public var errorDescription: String? {
            switch self {
            case .changedData: return "整理資料已由其他操作變更，這次未套用；請重新讀取後再試。"
            case .unsupportedVersion: return "整理交易／最近相簿版本無法讀取，原檔已保留。"
            }
        }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    static func write(_ data: Data?, to url: URL) throws {
        guard let data else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".organizer-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ReviewPersistence.Failure.writeFailed(errno)
        }
        let result = temporary.path.withCString { source in url.path.withCString { destination in Darwin.rename(source, destination) } }
        guard result == 0 else { throw ReviewPersistence.Failure.writeFailed(errno) }
    }
    public static func loadDestinations(from url: URL) throws -> DestinationPreferences {
        guard let data = try read(url) else { return DestinationPreferences() }
        let value = try JSONDecoder().decode(DestinationPreferences.self, from: data)
        guard value.schemaVersion == 1 else { throw Failure.unsupportedVersion }
        return value
    }
    public static func saveDestinations(_ value: DestinationPreferences, to url: URL) throws {
        guard value.schemaVersion == 1 else { throw Failure.unsupportedVersion }
        try write(encoded(value), to: url)
    }
    public static func recover(reviewURL: URL, albumURL: URL, journalURL: URL) throws {
        guard let data = try read(journalURL) else { return }
        let pending = try JSONDecoder().decode(PendingOrganizerWrite.self, from: data)
        guard pending.schemaVersion == 1 else { throw Failure.unsupportedVersion }
        let review = try read(reviewURL), albums = try read(albumURL)
        guard (review == pending.reviewBefore || review == pending.reviewAfter),
              (albums == pending.albumsBefore || albums == pending.albumsAfter) else { throw Failure.changedData }
        // An interrupted successful operation finishes; an interrupted failure finishes its rollback.
        try write(pending.rollBack ? pending.reviewBefore : pending.reviewAfter, to: reviewURL)
        try write(pending.rollBack ? pending.albumsBefore : pending.albumsAfter, to: albumURL)
        try FileManager.default.removeItem(at: journalURL)
    }
    public static func commit(review: ReviewDocument, albums: LocalAlbumsDocument,
                              expectedReview: ReviewDocument, expectedAlbums: LocalAlbumsDocument,
                              reviewURL: URL, albumURL: URL, journalURL: URL,
                              beforeDocumentWrite: (Int) throws -> Void = { _ in }) throws {
        guard !FileManager.default.fileExists(atPath: journalURL.path),
              try ReviewPersistence.load(from: reviewURL) == expectedReview,
              try LocalAlbumPersistence.load(from: albumURL) == expectedAlbums else { throw Failure.changedData }
        var pending = PendingOrganizerWrite(reviewBefore: try read(reviewURL), albumsBefore: try read(albumURL),
                                            reviewAfter: try encoded(review), albumsAfter: try encoded(albums))
        try write(encoded(pending), to: journalURL)
        do {
            try beforeDocumentWrite(1); try write(pending.reviewAfter, to: reviewURL)
            try beforeDocumentWrite(2); try write(pending.albumsAfter, to: albumURL)
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            let original = error
            pending.rollBack = true
            try write(encoded(pending), to: journalURL)
            try recover(reviewURL: reviewURL, albumURL: albumURL, journalURL: journalURL)
            throw original
        }
    }
}

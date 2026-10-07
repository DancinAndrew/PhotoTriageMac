import Foundation
import Darwin

public struct AlbumOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case photos, classification, travel, plan }
    public var kind: Kind
    public var id: String
    public var title: String
    public init(_ kind: Kind, id: String, title: String) { self.kind = kind; self.id = id; self.title = title }
}

/// A local view of references. Its ID, not its display name, defines its identity.
public struct OrganizerAlbum: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var assetIDs: Set<String>
    public var origins: [AlbumOrigin]
    public var locallyEdited = false
    public var sourceUnavailable = false
    public init(id: String, title: String, assetIDs: Set<String> = [], origins: [AlbumOrigin] = []) {
        self.id = id; self.title = title; self.assetIDs = assetIDs; self.origins = origins
    }
    public var sourceLabel: String {
        if origins.isEmpty { return "本機相簿" }
        if locallyEdited { return "本機調整 · 尚未同步" }
        if origins.contains(where: { $0.kind == .photos }) { return "Apple 照片參照" }
        if origins.contains(where: { $0.kind == .travel }) { return "旅遊建議 · 本機" }
        return "本機分類"
    }
}

public struct LocalAlbumEdit: Codable, Equatable, Sendable {
    public var createdTitle: String?
    public var title: String?
    public var sourceTitle: String
    public var sourceMembers: Set<String>
    public var origins: [AlbumOrigin]
    public var added: Set<String> = []
    public var removed: Set<String> = []
    public init(createdTitle: String? = nil, sourceTitle: String, sourceMembers: Set<String> = [], origins: [AlbumOrigin] = []) {
        self.createdTitle = createdTitle; self.sourceTitle = sourceTitle
        self.sourceMembers = sourceMembers; self.origins = origins
    }
}
public struct LocalAlbumTransaction: Codable, Equatable, Sendable {
    public var date = Date()
    public var label: String
    public var editsBefore: [String: LocalAlbumEdit]
    public var hiddenBefore: Set<String>
    public var pairedReviewID: UUID?
}
public struct LocalAlbumsDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var edits: [String: LocalAlbumEdit] = [:]
    public var hidden: Set<String> = []
    public var history: [LocalAlbumTransaction] = []
    public init() {}
}

public enum LocalAlbumFailure: Error, LocalizedError {
    case invalidTitle, duplicateTitle, missingAlbum, invalidSource, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidTitle: return "請輸入 1–100 字的相簿名稱，不含換行或控制字元。"
        case .duplicateTitle: return "已有同名相簿，請使用另一個名稱；不同來源不會自動合併。"
        case .missingAlbum: return "目前找不到這個相簿，請重新選取。"
        case .invalidSource: return "相簿來源識別碼重複，已停止操作以保護原資料。"
        case .unsupportedVersion: return "本機相簿檔版本無法讀取，原檔已保留。"
        }
    }
}

public enum LocalAlbumEngine {
    public static func catalog(sources: [OrganizerAlbum], document: LocalAlbumsDocument) -> [OrganizerAlbum] {
        var byID: [String: OrganizerAlbum] = [:]
        for source in sources where byID[source.id] == nil { byID[source.id] = source }
        for (id, edit) in document.edits {
            if byID[id] == nil {
                var value = OrganizerAlbum(id: id, title: edit.createdTitle ?? edit.sourceTitle,
                                           assetIDs: edit.createdTitle == nil ? edit.sourceMembers : [], origins: edit.origins)
                value.sourceUnavailable = edit.createdTitle == nil
                byID[id] = value
            }
        }
        return byID.values.compactMap { source in
            guard !document.hidden.contains(source.id) else { return nil }
            var value = source
            if let edit = document.edits[source.id] {
                value.title = edit.title ?? edit.createdTitle ?? source.title
                value.assetIDs.subtract(edit.removed); value.assetIDs.formUnion(edit.added)
                value.locallyEdited = true
            }
            return value
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func checkedTitle(_ title: String, excluding: String? = nil, catalog: [OrganizerAlbum]) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalAlbumFailure.invalidTitle
        }
        guard !catalog.contains(where: { $0.id != excluding && normalized($0.title) == normalized(trimmed) }) else {
            throw LocalAlbumFailure.duplicateTitle
        }
        return trimmed
    }
    private static func edit(for album: OrganizerAlbum, document: LocalAlbumsDocument) -> LocalAlbumEdit {
        document.edits[album.id] ?? LocalAlbumEdit(sourceTitle: album.title, sourceMembers: album.assetIDs, origins: album.origins)
    }
    @discardableResult
    private static func transact(_ document: inout LocalAlbumsDocument, label: String,
                                 change: (inout LocalAlbumsDocument) throws -> Void) rethrows -> Bool {
        var next = document
        try change(&next)
        guard next.edits != document.edits || next.hidden != document.hidden else { return false }
        next.history.append(LocalAlbumTransaction(label: label, editsBefore: document.edits, hiddenBefore: document.hidden))
        if next.history.count > 50 { next.history.removeFirst(next.history.count - 50) }
        document = next
        return true
    }
    @discardableResult
    public static func create(_ document: inout LocalAlbumsDocument, title: String, sources: [OrganizerAlbum],
                              assetIDs: Set<String> = [], id: String = "local:\(UUID().uuidString)") throws -> String {
        let name = try checkedTitle(title, catalog: catalog(sources: sources, document: document))
        guard id.hasPrefix("local:"), document.edits[id] == nil, !sources.contains(where: { $0.id == id }) else {
            throw LocalAlbumFailure.invalidSource
        }
        transact(&document, label: "建立相簿：\(name)") { value in
            var entry = LocalAlbumEdit(createdTitle: name, sourceTitle: name)
            entry.added = assetIDs; value.edits[id] = entry
        }
        return id
    }
    @discardableResult
    public static func rename(_ document: inout LocalAlbumsDocument, id: String, title: String, sources: [OrganizerAlbum]) throws -> Bool {
        let all = catalog(sources: sources, document: document)
        guard let album = all.first(where: { $0.id == id }) else { throw LocalAlbumFailure.missingAlbum }
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != album.title else { return false }
        let name = try checkedTitle(title, excluding: id, catalog: all)
        return transact(&document, label: "重新命名：\(name)") { value in
            var entry = edit(for: album, document: value); entry.title = name; value.edits[id] = entry
        }
    }
    @discardableResult
    public static func delete(_ document: inout LocalAlbumsDocument, id: String, sources: [OrganizerAlbum]) throws -> Bool {
        guard let album = catalog(sources: sources, document: document).first(where: { $0.id == id }) else {
            throw LocalAlbumFailure.missingAlbum
        }
        return transact(&document, label: "移除本機相簿：\(album.title)") { value in
            // Preserve the source links and unavailable members. No assets are ever deleted here.
            value.edits[id] = edit(for: album, document: value); value.hidden.insert(id)
        }
    }
    @discardableResult
    public static func changeMembers(_ document: inout LocalAlbumsDocument, id: String, ids: Set<String>,
                                     adding: Bool, sources: [OrganizerAlbum]) throws -> Bool {
        guard let album = catalog(sources: sources, document: document).first(where: { $0.id == id }) else {
            throw LocalAlbumFailure.missingAlbum
        }
        let changes = adding ? ids.subtracting(album.assetIDs) : ids.intersection(album.assetIDs)
        guard !changes.isEmpty else { return false }
        return transact(&document, label: "\(adding ? "加入" : "移出")相簿：\(album.title) · \(changes.count) 張") { value in
            var entry = edit(for: album, document: value)
            if adding { entry.removed.subtract(changes); entry.added.formUnion(changes) }
            else { entry.added.subtract(changes); entry.removed.formUnion(changes) }
            value.edits[id] = entry
        }
    }
    public static func undo(_ document: inout LocalAlbumsDocument) -> String? {
        guard let entry = document.history.popLast() else { return nil }
        document.edits = entry.editsBefore; document.hidden = entry.hiddenBefore
        return entry.label
    }
}

public enum LocalAlbumPersistence {
    public static func load(from url: URL) throws -> LocalAlbumsDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalAlbumsDocument() }
        let value = try JSONDecoder().decode(LocalAlbumsDocument.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw LocalAlbumFailure.unsupportedVersion }
        return value
    }
    public static func save(_ value: LocalAlbumsDocument, to url: URL) throws {
        guard value.schemaVersion == 1 else { throw LocalAlbumFailure.unsupportedVersion }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = folder.appendingPathComponent(".albums-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(value),
                                             attributes: [.posixPermissions: 0o600]) else { throw ReviewPersistence.Failure.writeFailed(errno) }
        let result = temporary.path.withCString { source in url.path.withCString { destination in Darwin.rename(source, destination) } }
        guard result == 0 else { throw ReviewPersistence.Failure.writeFailed(errno) }
    }
}

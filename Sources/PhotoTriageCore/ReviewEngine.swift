import Foundation
import Darwin

public enum ReviewEngine {
    /// Every operation is one batch transaction. No-op repeats do not fill the undo log.
    @discardableResult
    public static func apply(to document: inout ReviewDocument, ids: Set<String>, label: String,
                             manualGroup: (id: String, title: String)? = nil,
                             transform: (inout ReviewDecision) -> Void) -> Bool {
        guard !ids.isEmpty else { return false }
        var changes: [ReviewChange] = []
        for id in ids.sorted() {
            let before = document.decisions[id]
            var after = before ?? ReviewDecision()
            transform(&after)
            let stored: ReviewDecision? = after.isEmpty ? nil : after
            if before != stored { changes.append(ReviewChange(assetID: id, before: before, after: stored)) }
        }
        guard !changes.isEmpty else { return false }
        let previousGroups = document.manualGroups
        if let manualGroup { document.manualGroups[manualGroup.id] = manualGroup.title }
        for change in changes { document.decisions[change.assetID] = change.after }
        document.history.append(ReviewTransaction(label: label, changes: changes, groupsBefore: previousGroups))
        if document.history.count > 100 { document.history.removeFirst(document.history.count - 100) }
        return true
    }

    @discardableResult
    public static func undo(_ document: inout ReviewDocument) -> String? {
        guard let transaction = document.history.popLast() else { return nil }
        for change in transaction.changes { document.decisions[change.assetID] = change.before }
        document.manualGroups = transaction.groupsBefore
        return transaction.label
    }

    public static func stageAlbum(_ plan: AlbumPlan, decision: inout ReviewDecision) {
        // Queue takes precedence; planning an album must never erase a pending deletion decision.
        if !decision.albumPlans.contains(where: { $0.id == plan.id }) { decision.albumPlans.append(plan) }
        if decision.status != .deleteCandidate { decision.status = .organized }
    }

    /// Adopt every member of a suggested destination into one stable manual group.
    /// Reusing a suggested ID would collide with the suggestion generated for its original members.
    public static func groupAssignment(selectedIDs: Set<String>, destination: EventGroup?,
                                       newID: String = "manual:\(UUID().uuidString)") -> (id: String, ids: Set<String>) {
        let id = destination?.id.hasPrefix("manual:") == true ? destination!.id : newID
        return (id, selectedIDs.union(destination?.assetIDs ?? []))
    }
}

public enum ReviewPersistence {
    public enum Failure: Error, LocalizedError {
        case unsupportedVersion(Int)
        case writeFailed(Int32)
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let value): return "審閱檔版本 \(value) 無法讀取；原檔已保留。"
            case .writeFailed(let code): return "無法儲存審閱檔（系統錯誤 \(code)）；原檔已保留。"
            }
        }
    }
    public static func load(from url: URL) throws -> ReviewDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReviewDocument() }
        let value = try JSONDecoder().decode(ReviewDocument.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw Failure.unsupportedVersion(value.schemaVersion) }
        return value
    }
    public static func save(_ document: ReviewDocument, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = folder.appendingPathComponent(".review-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(document),
                                             attributes: [.posixPermissions: 0o600]) else { throw Failure.writeFailed(errno) }
        let result = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw Failure.writeFailed(errno) }
    }
}

public struct ReviewPlanExport: Encodable, Sendable {
    public let format = "PhotoTriage staged review — NO Photos changes performed"
    public let generatedAt = Date()
    public let source: String
    public let decisions: [String: ReviewDecision]
    public let manualGroups: [String: String]
    public let unavailableAssetIDs: [String]
    public init(source: String, document: ReviewDocument, availableIDs: Set<String>) {
        self.source = source
        self.decisions = document.decisions
        self.manualGroups = document.manualGroups
        self.unavailableAssetIDs = document.decisions.keys.filter { !availableIDs.contains($0) }.sorted()
    }
}

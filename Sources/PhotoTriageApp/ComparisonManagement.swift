import PhotoTriageCore

extension AppModel {
    var comparisonSelection: [PhotoRecord] { visible.filter { selected.contains($0.id) } }
    var canCompare: Bool {
        canReview && !hasModal && (2...6).contains(comparisonSelection.count) && comparisonSelection.allSatisfy { $0.kind == .image }
    }
    func beginComparison() {
        guard canCompare else { notice = "並排挑選需要 2–6 張照片；影片請另外審閱。"; return }
        comparison = ComparisonBatch(assetIDs: comparisonSelection.map(\.id))
    }
    @discardableResult
    func completeComparison(_ batch: ComparisonBatch, keepers: Set<String>) throws -> Bool {
        guard canReview, comparison?.id == batch.id,
              batch.assetIDs.allSatisfy({ id in records.contains { $0.id == id && $0.kind == .image } }) else {
            throw ComparisonEngine.Failure.unavailable
        }
        let oldVisible = visible.map(\.id)
        let statuses = try ComparisonEngine.statuses(assetIDs: batch.assetIDs, keepers: keepers)
        var next = document
        if ReviewEngine.applyStatuses(to: &next, statuses: statuses, label: "並排挑選：保留 \(keepers.count)，其餘待刪候選") {
            guard commit(next, success: "已保留 \(keepers.count) 張、\(batch.assetIDs.count - keepers.count) 張加入待刪候選 · 照片未刪除 · ⌘Z 整批復原") else { return false }
        }
        comparison = nil
        let scope = Set(batch.assetIDs)
        let remaining = visible.filter { !scope.contains($0.id) && !document.decision(for: $0.id).hasBeenReviewed }
        let last = oldVisible.lastIndex { scope.contains($0) } ?? -1
        let following = Set(oldVisible.dropFirst(last + 1))
        let completionNotice = notice
        clearSelection()
        if let record = remaining.first(where: { following.contains($0.id) }) ?? remaining.first {
            select(record.id); scrollTargetID = record.id
        }
        notice = completionNotice
        workspaceChanged()
        return true
    }
}

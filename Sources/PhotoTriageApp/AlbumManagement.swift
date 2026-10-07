import Foundation
import PhotoTriageCore

enum AlbumAction: Identifiable, Equatable {
    case create, rename(String), delete(String), addSelection, addSelectionAndComplete
    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let id): return "rename:\(id)"
        case .delete(let id): return "delete:\(id)"
        case .addSelection: return "addSelection"
        case .addSelectionAndComplete: return "addSelectionAndComplete"
        }
    }
}

extension AppModel {
    var localAlbumURL: URL { dataRoot.appendingPathComponent(isDemo ? "demo-local-albums.json" : "photos-local-albums.json") }
    var organizerJournalURL: URL { dataRoot.appendingPathComponent(isDemo ? "demo-organizer-pending.json" : "photos-organizer-pending.json") }
    var destinationURL: URL { dataRoot.appendingPathComponent(isDemo ? "demo-destinations.json" : "photos-destinations.json") }
    var canManageAlbums: Bool { canReview && localAlbumError == nil }
    var canUndo: Bool { !document.history.isEmpty || !localAlbums.history.isEmpty }
    var currentOrganizerAlbum: OrganizerAlbum? { organizerAlbums.first { $0.id == selectedOrganizerAlbumID } }
    var recentDestinationAlbums: [OrganizerAlbum] {
        destinationPreferences.recentAlbumIDs.compactMap { id in organizerAlbums.first { $0.id == id && !$0.sourceUnavailable } }
    }
    var repeatDestinationAlbum: OrganizerAlbum? { recentDestinationAlbums.first }
    var preferredDestinationID: String { repeatDestinationAlbum?.id ?? currentOrganizerAlbum.flatMap { $0.sourceUnavailable ? nil : $0.id } ?? "new" }
    var actionableAlbumIDs: Set<String> { selected.intersection(Set(visible.map(\.id))) }

    func loadDestinationPreferences() {
        do { destinationPreferences = try OrganizerPersistence.loadDestinations(from: destinationURL); destinationError = nil }
        catch { destinationPreferences = DestinationPreferences(); destinationError = "最近相簿紀錄無法讀取，原檔已保留；仍可手動選擇目的地。" }
    }
    private func rememberDestination(_ id: String) {
        guard destinationError == nil else { return }
        var next = destinationPreferences; next.remember(id)
        guard next != destinationPreferences else { return }
        do {
            guard try OrganizerPersistence.loadDestinations(from: destinationURL) == destinationPreferences else { throw OrganizerPersistence.Failure.changedData }
            try OrganizerPersistence.saveDestinations(next, to: destinationURL); destinationPreferences = next
        }
        catch { destinationError = "相簿操作已保存，但最近目的地未保存：\(error.localizedDescription)" }
    }
    func repeatDestination(completeReview: Bool = false) {
        guard canAct && canManageAlbums else { return }
        guard let album = repeatDestinationAlbum else {
            albumAction = completeReview ? .addSelectionAndComplete : .addSelection
            notice = "最近目的相簿已移除或不可見，請重新選擇。"; return
        }
        do { try addSelectionToAlbum(id: album.id, completeReview: completeReview) }
        catch { notice = error.localizedDescription }
    }

    func loadLocalAlbums() {
        do { localAlbums = try LocalAlbumPersistence.load(from: localAlbumURL); localAlbumError = nil }
        catch { localAlbums = LocalAlbumsDocument(); localAlbumError = "本機相簿檔無法讀取，已停止相簿寫入以保護原檔：\(error.localizedDescription)" }
        if !isDemo {
            let url = dataRoot.appendingPathComponent("travel-album-receipts.json")
            travelReceipts = (try? JSONDecoder().decode([TravelAlbumReceipt].self, from: Data(contentsOf: url))) ?? []
        }
        refreshOrganizerAlbums()
    }
    func refreshOrganizerAlbums() {
        var memberships: [String: Set<String>] = [:]
        for record in records { for id in record.albumIDs { memberships[id, default: []].insert(record.id) } }
        var sources = albums.map { album in
            OrganizerAlbum(id: "photos:\(album.id)", title: album.title, assetIDs: memberships[album.id] ?? [],
                           origins: [AlbumOrigin(.photos, id: album.id, title: album.title)])
        }
        for (id, title) in document.manualGroups {
            let members = Set(document.decisions.filter { $0.value.groupOverride == id }.map(\.key))
            sources.append(OrganizerAlbum(id: "classification:\(id)", title: title, assetIDs: members,
                                          origins: [AlbumOrigin(.classification, id: id, title: title)]))
        }
        for trip in travelReport?.analysis?.trips ?? [] {
            let origin = AlbumOrigin(.travel, id: trip.id, title: trip.title)
            if let receipt = travelReceipts.first(where: { $0.tripID == trip.id && $0.status == "verified" }),
               let albumID = receipt.albumID, let index = sources.firstIndex(where: { $0.id == "photos:\(albumID)" }) {
                // The receipt explicitly identifies these two sources as the same collection.
                sources[index].origins.append(origin)
            } else {
                sources.append(OrganizerAlbum(id: "travel:\(trip.id)", title: trip.title,
                                              assetIDs: Set(trip.assetIDs), origins: [origin]))
            }
        }
        var plans: [String: OrganizerAlbum] = [:]
        for (assetID, decision) in document.decisions {
            for plan in decision.albumPlans {
                let id = "plan:\(plan.id)"
                if plans[id] == nil { plans[id] = OrganizerAlbum(id: id, title: plan.title,
                    origins: [AlbumOrigin(.plan, id: plan.id, title: plan.title)]) }
                plans[id]?.assetIDs.insert(assetID)
            }
        }
        sources.append(contentsOf: plans.values)
        albumSources = sources
        organizerAlbums = LocalAlbumEngine.catalog(sources: sources, document: localAlbums)
        locallyClassifiedIDs = organizerAlbums.filter { album in
            album.locallyEdited || album.origins.contains { $0.kind != .travel }
        }.reduce(into: Set<String>()) { $0.formUnion($1.assetIDs) }
        invalidateAlbumFilter()
    }
    func visibleAlbumCount(_ album: OrganizerAlbum) -> Int { records.reduce(0) { $0 + (album.assetIDs.contains($1.id) ? 1 : 0) } }
    func setOrganizerAlbum(_ id: String) {
        guard organizerAlbums.contains(where: { $0.id == id }) else { return }
        clearAlbumFilter(); selectedOrganizerAlbumID = id; invalidateAlbumFilter()
    }
    private func commitLocalAlbums(_ next: LocalAlbumsDocument, success: String) throws {
        guard try LocalAlbumPersistence.load(from: localAlbumURL) == localAlbums else { throw OrganizerPersistence.Failure.changedData }
        try LocalAlbumPersistence.save(next, to: localAlbumURL)
        localAlbums = next
        if let id = selectedOrganizerAlbumID, next.hidden.contains(id) { clearAlbumFilter() }
        refreshOrganizerAlbums(); notice = success + " · 本機保存，未同步 Apple 照片 · ⌘Z 可復原"
    }
    @discardableResult
    func createLocalAlbum(title: String, includeSelection: Bool = false, completeReview: Bool = false) throws -> String {
        guard canManageAlbums else { throw LocalAlbumFailure.missingAlbum }
        var next = localAlbums
        let ids = includeSelection ? actionableAlbumIDs : []
        let id = try LocalAlbumEngine.create(&next, title: title, sources: albumSources, assetIDs: ids)
        try commitAlbumBatch(next, ids: ids, completeReview: completeReview, success: "已建立相簿：\(title)")
        if !ids.isEmpty { rememberDestination(id) }
        return id
    }
    func renameLocalAlbum(id: String, title: String) throws {
        guard canManageAlbums else { throw LocalAlbumFailure.missingAlbum }
        var next = localAlbums
        if try LocalAlbumEngine.rename(&next, id: id, title: title, sources: albumSources) {
            try commitLocalAlbums(next, success: "已重新命名相簿")
        }
    }
    func deleteLocalAlbum(id: String) throws {
        guard canManageAlbums else { throw LocalAlbumFailure.missingAlbum }
        var next = localAlbums
        if try LocalAlbumEngine.delete(&next, id: id, sources: albumSources) {
            try commitLocalAlbums(next, success: "已移除本機相簿，所有照片保留")
        }
    }
    func changeLocalAlbumMembers(id: String, adding: Bool) throws {
        if adding { try addSelectionToAlbum(id: id); return }
        guard canManageAlbums else { throw LocalAlbumFailure.missingAlbum }
        var next = localAlbums
        let ids = actionableAlbumIDs
        if try LocalAlbumEngine.changeMembers(&next, id: id, ids: ids, adding: adding, sources: albumSources) {
            try commitLocalAlbums(next, success: adding ? "已加入相簿" : "已移出相簿，照片仍在全部照片")
        } else { notice = "相簿成員沒有變更。" }
    }
    func addSelectionToAlbum(id: String, completeReview: Bool = false) throws {
        guard canManageAlbums, !actionableAlbumIDs.isEmpty else { throw LocalAlbumFailure.missingAlbum }
        guard let album = organizerAlbums.first(where: { $0.id == id && !$0.sourceUnavailable }) else { throw LocalAlbumFailure.missingAlbum }
        let ids = actionableAlbumIDs
        var next = localAlbums
        _ = try LocalAlbumEngine.changeMembers(&next, id: id, ids: ids, adding: true, sources: albumSources)
        try commitAlbumBatch(next, ids: ids, completeReview: completeReview, success: "已加入「\(album.title)」")
        rememberDestination(id)
    }
    private func commitAlbumBatch(_ albums: LocalAlbumsDocument, ids: Set<String>, completeReview: Bool, success: String) throws {
        var review = document, next = albums
        let oldVisible = visible.map(\.id)
        let oldIndex = focusedID.flatMap { oldVisible.firstIndex(of: $0) } ?? 0
        if completeReview {
            _ = ReviewEngine.apply(to: &review, ids: ids, label: "加入相簿並完成這批") {
                // Existing keep/delete judgments remain intact. Only this batch's unreviewed items change.
                if $0.status == .unreviewed { $0.status = .organized }
            }
        }
        let albumsChanged = next != localAlbums, reviewChanged = review != document
        if albumsChanged && reviewChanged {
            next.history[next.history.count - 1].pairedReviewID = review.history.last!.id
            next.history[next.history.count - 1].date = review.history.last!.date
            try commitPairedDocuments(review: review, albums: next)
        } else if albumsChanged {
            guard try LocalAlbumPersistence.load(from: localAlbumURL) == localAlbums else { throw OrganizerPersistence.Failure.changedData }
            try LocalAlbumPersistence.save(next, to: localAlbumURL); localAlbums = next
        } else if reviewChanged {
            guard try ReviewPersistence.load(from: reviewURL) == document else { throw OrganizerPersistence.Failure.changedData }
            try ReviewPersistence.save(review, to: reviewURL); document = review
        }
        else { notice = "這批已有相同相簿歸屬與審閱狀態，沒有重複寫入。"; return }
        rebuild()
        notice = success + (completeReview ? " · 已完成這批審閱，保留既有保留／待刪標記" : " · 審閱狀態未變更") + " · 本機保存，未同步 Apple 照片 · ⌘Z 可復原"
        if selected.isEmpty, !visible.isEmpty { select(visible[min(oldIndex, visible.count - 1)].id) }
    }
    private func commitPairedDocuments(review: ReviewDocument, albums: LocalAlbumsDocument) throws {
        do {
            try OrganizerPersistence.commit(review: review, albums: albums, expectedReview: document, expectedAlbums: localAlbums,
                reviewURL: reviewURL, albumURL: localAlbumURL, journalURL: organizerJournalURL)
        } catch {
            if FileManager.default.fileExists(atPath: organizerJournalURL.path) {
                persistenceError = "整批存檔尚需恢復，已停止寫入；重新開啟時會安全核對原檔。"
            }
            throw error
        }
        document = review; localAlbums = albums
    }
    func undoLocalAlbum() {
        guard canManageAlbums else { return }
        var next = localAlbums
        if let paired = next.history.last?.pairedReviewID {
            guard document.history.last?.id == paired else {
                notice = "這批包含審閱變更，請先用 ⌘Z 復原較新的審閱操作。"; return
            }
            var review = document
            guard let label = LocalAlbumEngine.undo(&next), ReviewEngine.undo(&review) != nil else { return }
            do {
                try commitPairedDocuments(review: review, albums: next)
                rebuild(); notice = "已整批復原：\(label) · 相簿歸屬與審閱狀態一起復原"
            } catch { notice = "整批復原未套用：\(error.localizedDescription)" }
            return
        }
        guard let label = LocalAlbumEngine.undo(&next) else { return }
        do { try commitLocalAlbums(next, success: "已復原：\(label)") }
        catch { localAlbumError = "復原未套用：\(error.localizedDescription)" }
    }
    func closeInspector() { inspectorVisible = false }
}

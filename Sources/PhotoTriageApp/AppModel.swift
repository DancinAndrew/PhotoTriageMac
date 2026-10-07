import AppKit
import Combine
import Photos
import PhotoTriageCore

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [PhotoRecord] = []
    @Published var albums: [Album] = []
    @Published var document = ReviewDocument()
    @Published var groups: [EventGroup] = []
    @Published var filter = PhotoFilter()
    @Published var selected: Set<String> = []
    @Published var focusedID: String?
    @Published var isDemo = true
    @Published var access = LibraryAccess.current()
    @Published var isLoading = false
    @Published var notice = "先用範例熟悉流程，再連線到「照片」。"
    @Published var persistenceError: String?
    @Published var showAlbumSheet = false
    @Published var showGroupSheet = false
    @Published var showPlanSheet = false
    @Published var showMusicSheet = false
    @Published var musicReport: MusicExtractionReport?
    @Published var musicProgress: String?
    @Published var musicOutputPath: String?
    @Published var showTravelSheet = false
    @Published var albumAction: AlbumAction?
    @Published var localAlbums = LocalAlbumsDocument()
    @Published var organizerAlbums: [OrganizerAlbum] = []
    @Published var localAlbumError: String?
    @Published var destinationPreferences = DestinationPreferences()
    @Published var destinationError: String?
    @Published var selectedOrganizerAlbumID: String?
    @Published var inspectorVisible = false
    @Published var scrollTargetID: String?
    var albumSources: [OrganizerAlbum] = []
    var locallyClassifiedIDs: Set<String> = []
    var travelReceipts: [TravelAlbumReceipt] = []
    @Published var travelReport: TravelLibraryReport?
    @Published var travelProgress: String?
    @Published var travelError: String?
    @Published var travelTripID: String?
    @Published var useDateRange = false
    @Published var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @Published var rangeEnd = Date()
    private(set) var assets: [String: PHAsset] = [:]
    private var rapidIDs: Set<String> = []
    private var groupIDs: [String: String] = [:]
    private var cachedVisible: [PhotoRecord] = []
    private var previousFilter: PhotoFilter?
    private var selectionAnchor: String?
    private var scopeCounts: [ReviewScope: Int] = [:]
    private let reviewRootOverride: URL?

    var dataRoot: URL {
        if let reviewRootOverride { return reviewRootOverride }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--review-root"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoTriageMac", isDirectory: true)
    }
    var reviewURL: URL { dataRoot.appendingPathComponent(isDemo ? "demo-review.json" : "photos-review.json") }
    var canReview: Bool { !isLoading && persistenceError == nil }
    var canAct: Bool { canReview && !actionableAlbumIDs.isEmpty && !hasModal }
    var canSelectVisible: Bool { !isLoading && !hasModal && !visible.isEmpty }
    var hasModal: Bool { albumAction != nil || showAlbumSheet || showGroupSheet || showPlanSheet || showMusicSheet || showTravelSheet }
    var selectedRecords: [PhotoRecord] { records.filter { selected.contains($0.id) } }
    var visible: [PhotoRecord] {
        if previousFilter != effectiveFilter {
            let trip = travelReport?.analysis?.trips.first { $0.id == travelTripID }
            let members = trip.map { Set($0.assetIDs + $0.unknownCandidateIDs) }
            let localMembers = selectedOrganizerAlbumID.flatMap { id in organizerAlbums.first { $0.id == id }?.assetIDs }
            var value = effectiveFilter
            if value.scope == .unclassified { value.scope = .all }
            value.unclassifiedOnly = false
            cachedVisible = records.filter {
                (members?.contains($0.id) ?? true) && (localMembers?.contains($0.id) ?? true) &&
                (!(effectiveFilter.scope == .unclassified || effectiveFilter.unclassifiedOnly) || !locallyClassifiedIDs.contains($0.id)) &&
                value.includes($0, document: document, groupIDs: groupIDs, rapidIDs: rapidIDs)
            }
            previousFilter = effectiveFilter
        }
        return cachedVisible
    }
    private var effectiveFilter: PhotoFilter {
        var value = filter
        if useDateRange {
            value.unknownDateOnly = false
            value.startDate = Calendar.current.startOfDay(for: rangeStart)
            value.endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: rangeEnd))
        }
        return value
    }
    var unavailableDecisionIDs: [String] {
        let available = Set(records.map(\.id))
        return document.decisions.keys.filter { !available.contains($0) }
    }
    var queueCount: Int { document.decisions.values.filter { $0.status == .deleteCandidate }.count }
    var planCount: Int { document.decisions.values.reduce(0) { $0 + $1.albumPlans.count } }
    var progressCount: Int { records.filter { document.decision(for: $0.id).status != .unreviewed }.count }
    var focusedRecord: PhotoRecord? { records.first { $0.id == focusedID } }

    init(reviewRoot: URL? = nil, startupOverride: String? = nil) {
        reviewRootOverride = reviewRoot
        loadDemo()
        let args = CommandLine.arguments
        if args.contains("--simulate-denied") || startupOverride == "denied" {
            isDemo = false; records = []; albums = []; assets = [:]; access = .denied
            loadDocument(); rebuild(); notice = "測試情境：照片權限遭拒絕。可切回範例操作。"
        } else if args.contains("--empty-demo") || startupOverride == "empty" {
            records = []; rebuild(); notice = "測試情境：空照片庫。"
        }
    }

    func loadDemo() {
        guard !isLoading else { return }
        isDemo = true
        travelReport = nil; travelReceipts = []
        records = DemoLibrary.records; albums = DemoLibrary.albums; assets = [:]
        loadDocument(); resetFilter(); rebuild()
        notice = "範例資料 · 插圖與資料皆為虛構，審閱檔與真實照片分開。"
    }
    private func loadDocument() {
        do {
            try OrganizerPersistence.recover(reviewURL: reviewURL, albumURL: localAlbumURL, journalURL: organizerJournalURL)
            document = try ReviewPersistence.load(from: reviewURL); persistenceError = nil
        }
        catch {
            document = ReviewDocument()
            persistenceError = "審閱檔讀取失敗，已停止寫入以保護原檔：\(error.localizedDescription)"
        }
        loadLocalAlbums()
        loadDestinationPreferences()
    }
    func connect() {
        guard !isLoading else { return }
        Task {
            isLoading = true
            if LibraryAccess.current() == .notRequested {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            access = .current()
            isDemo = false
            selected = []; focusedID = nil; assets = [:]; records = []; albums = []
            loadDocument(); resetFilter(); rebuild()
            guard access.canRead else {
                isLoading = false
                notice = "未能讀取照片。請在系統設定 → 隱私權與安全性 → 照片，檢查本程式權限。"
                return
            }
            notice = "讀取照片中繼資料與既有相簿；不下載原始檔。"
            let snapshot = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: PhotoLibraryReader.fetch())
                }
            }
            // Permission may have been revoked while the metadata read was running.
            access = .current()
            if access.canRead {
                loadPhotosSnapshot(snapshot)
                notice = "已讀取 \(records.count) 張照片。分類儲存在本機，尚未同步 Apple 照片。"
            } else {
                notice = "照片權限已變更，請重新連線。"
            }
            isLoading = false
        }
    }
    /// Import a metadata snapshot without changing any saved review decisions or Photos assets.
    func loadPhotosSnapshot(_ snapshot: LibrarySnapshot) {
        isDemo = false
        records = snapshot.records; albums = snapshot.albums; assets = snapshot.assets
        loadDocument(); loadTravelReport(); resetFilter(); rebuild()
    }
    func resetFilter() {
        filter = PhotoFilter(); useDateRange = false; selected = []; focusedID = nil; travelTripID = nil
        selectedOrganizerAlbumID = nil; inspectorVisible = false; scrollTargetID = nil
        previousFilter = nil; selectionAnchor = nil
    }
    func setScope(_ scope: ReviewScope) {
        filter.scope = .all
        switch scope {
        case .all: clearAlbumFilter()
        case .screenshots: filter.screenshotsOnly.toggle()
        case .unclassified: filter.unclassifiedOnly.toggle()
        case .temporary: filter.temporaryOnly.toggle()
        case .rapidShots: filter.rapidShotsOnly.toggle()
        case .unreviewed: filter.reviewStatus = .unreviewed
        case .kept: filter.reviewStatus = .kept
        case .organized: filter.reviewStatus = .organized
        case .deleteQueue: filter.reviewStatus = .deleteCandidate
        }
        filterChanged()
    }
    func setGroup(_ group: EventGroup) {
        clearAlbumFilter(); filter.groupID = group.id; filterChanged()
    }
    func setAlbum(_ album: Album) {
        clearAlbumFilter(); filter.albumID = album.id; filterChanged()
    }
    func setTravelTrip(_ trip: TravelTrip) {
        resetFilter(); travelTripID = trip.id; previousFilter = nil
    }
    var travelOutput: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--travel-report-root"), args.indices.contains(i + 1) {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return dataRoot.appendingPathComponent("travel-latest", isDirectory: true)
    }
    func loadTravelReport() {
        guard !isDemo else { return }
        let url = travelOutput.appendingPathComponent("travel-analysis.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { travelReport = try JSONDecoder().decode(TravelLibraryReport.self, from: Data(contentsOf: url)); travelError = nil }
        catch { travelError = "旅遊分析檔無法讀取：\(error.localizedDescription)" }
        previousFilter = nil
        refreshOrganizerAlbums()
    }
    func analyzeTravel() {
        guard !isDemo, access.canRead, travelProgress == nil else { return }
        travelError = nil; travelProgress = "掃描所有可見照片的時間、GPS 與相簿…"
        let output = travelOutput
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) { try TravelAnalysisJob.run(output: output) }.value
                travelReport = report; previousFilter = nil
                notice = "旅遊分析完成：\(report.analysis?.trips.filter(\.canCreateAlbum).count ?? 0) 個可建立相簿的行程，其餘保留人工確認。"
            } catch { travelError = error.localizedDescription }
            travelProgress = nil
        }
    }
    func filterChanged() {
        previousFilter = nil
        scrollTargetID = nil
        let ids = Set(visible.map(\.id))
        selected.formIntersection(ids)
        if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
    }
    func rebuild() {
        groups = EventGrouping.suggest(records, document: document)
        groupIDs = Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.assetIDs.map { ($0, group.id) } })
        rapidIDs = EventGrouping.rapidShotIDs(records)
        scopeCounts = Dictionary(uniqueKeysWithValues: ReviewScope.allCases.map { scope in
            var value = PhotoFilter(); value.scope = scope
            return (scope, records.filter { value.includes($0, document: document, groupIDs: groupIDs, rapidIDs: rapidIDs) }.count)
        })
        previousFilter = nil
        refreshOrganizerAlbums()
        filterChanged()
    }
    func count(_ scope: ReviewScope) -> Int {
        if scope == .unclassified { return records.filter { !locallyClassifiedIDs.contains($0.id) }.count }
        return scopeCounts[scope] ?? 0
    }
    func invalidateAlbumFilter() { previousFilter = nil; filterChanged() }
    func group(for record: PhotoRecord) -> EventGroup? { groups.first { $0.id == groupIDs[record.id] } }

    func select(_ id: String, modifiers: NSEvent.ModifierFlags = []) {
        let ids = visible.map(\.id)
        guard ids.contains(id) else { return }
        if modifiers.contains(.shift), let selectionAnchor,
           let a = ids.firstIndex(of: selectionAnchor), let b = ids.firstIndex(of: id) {
            selected.formUnion(ids[min(a, b)...max(a, b)])
        } else if modifiers.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            selectionAnchor = id
        } else { selected = [id]; selectionAnchor = id }
        focusedID = id
        inspectorVisible = true
    }
    func selectAll() {
        guard !isLoading, !hasModal else { return }
        let items = visible
        selected = Set(items.map(\.id))
        focusedID = items.first?.id
        inspectorVisible = !items.isEmpty
        selectionAnchor = items.first?.id
        notice = items.isEmpty ? "目前篩選沒有可選取的項目。" : "已全選目前篩選的 \(selected.count) 個項目。"
    }
    func clearSelection() {
        selected = []; focusedID = nil; selectionAnchor = nil
        inspectorVisible = false; scrollTargetID = nil
        notice = "已清除選取。"
    }
    func advance(_ offset: Int) {
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        let index = focusedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = max(0, min(ids.count - 1, index + offset))
        select(ids[next])
        scrollTargetID = ids[next]
    }

    private func commit(_ next: ReviewDocument, success: String) {
        do {
            guard try ReviewPersistence.load(from: reviewURL) == document else { throw OrganizerPersistence.Failure.changedData }
            try ReviewPersistence.save(next, to: reviewURL)
            document = next; notice = success
            rebuild()
        } catch { persistenceError = "儲存失敗，這次操作未套用：\(error.localizedDescription)" }
    }
    func apply(_ label: String, ids: Set<String>? = nil,
               manualGroup: (id: String, title: String)? = nil,
               transform: (inout ReviewDecision) -> Void) {
        guard canReview else { return }
        let target = (ids ?? actionableAlbumIDs).intersection(Set(records.map(\.id)))
        guard !target.isEmpty else { return }
        let oldVisible = visible.map(\.id)
        let oldIndex = focusedID.flatMap { oldVisible.firstIndex(of: $0) } ?? 0
        var next = document
        guard ReviewEngine.apply(to: &next, ids: target, label: label, manualGroup: manualGroup, transform: transform) else {
            notice = "標記已相同，沒有重複寫入。"; return
        }
        commit(next, success: "\(label) · \(target.count) 個項目 · ⌘Z 可復原")
        if selected.isEmpty, !visible.isEmpty { select(visible[min(oldIndex, visible.count - 1)].id) }
    }
    func mark(_ status: ReviewStatus) { apply(status.label) { $0.status = status } }
    func addToDeleteQueue() {
        guard canAct else { return }
        apply("加入待刪候選（照片未刪除）") { $0.status = .deleteCandidate }
    }
    func toggleTemporary() {
        let allTemporary = selectedRecords.allSatisfy { document.decision(for: $0.id).isTemporary }
        apply(allTemporary ? "移除暫時用途" : "標記暫時用途") { $0.isTemporary = !allTemporary }
    }
    func resetSelected() { apply("恢復未審閱，保留分類歸屬") { $0.status = .unreviewed } }
    func stageAlbum(_ plan: AlbumPlan) {
        apply("加入相簿計畫：\(plan.title)") { ReviewEngine.stageAlbum(plan, decision: &$0) }
    }
    func assignGroup(title: String, existingID: String? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selected.isEmpty else { return }
        let destination = groups.first { $0.id == existingID }
        let assignment = ReviewEngine.groupAssignment(selectedIDs: selected, destination: destination)
        apply("移至事件：\(trimmed)", ids: assignment.ids, manualGroup: (assignment.id, trimmed)) {
            $0.groupOverride = assignment.id
        }
    }
    func restoreSuggestedGroup() { apply("恢復事件建議") { $0.groupOverride = nil } }
    func removeAlbumPlans(ids: Set<String>) { apply("移除相簿計畫", ids: ids) { $0.albumPlans = [] } }
    func removeFromQueue(ids: Set<String>) { apply("移出待刪候選", ids: ids) { $0.status = .unreviewed } }
    func undo() {
        guard canReview else { return }
        if let latest = localAlbums.history.last,
           latest.date >= (document.history.last?.date ?? .distantPast) {
            undoLocalAlbum(); return
        }
        var next = document
        guard let label = ReviewEngine.undo(&next) else { return }
        commit(next, success: "已復原：\(label)")
    }
    func exportPlan() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isDemo ? "demo-review-plan.json" : "photos-review-plan.json"
        panel.title = "匯出本機審閱計畫（不包含照片）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = ReviewPlanExport(source: isDemo ? "fictional demo" : "PhotoKit visible assets",
                                         document: document, availableIDs: Set(records.map(\.id)))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            notice = "已匯出計畫；未修改照片或相簿。"
        } catch { notice = "匯出失敗：\(error.localizedDescription)" }
    }
    func extractMusic(albumID: String?) {
        guard !isDemo, access.canRead, musicProgress == nil else { return }
        let folder = dataRoot.appendingPathComponent("music-extraction/run-\(UUID().uuidString)", isDirectory: true)
        musicProgress = "讀取限定相簿…"; musicReport = nil
        Task {
            let report = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = MusicExtractionJob.run(albumID: albumID, output: folder) { processed, total in
                        DispatchQueue.main.async { self.musicProgress = "本機 OCR：\(processed) / \(total)" }
                    }
                    continuation.resume(returning: result)
                }
            }
            do {
                try MusicExtractionJob.save(report, to: folder)
                musicReport = report; musicOutputPath = folder.path
                notice = report.status == "completed_visible_album" ? "音樂 OCR 完成 · \(report.songs.count) 首待確認候選 · 照片未變更" : "音樂 OCR 未完成：\(report.status)"
            } catch { notice = "音樂結果儲存失敗：\(error.localizedDescription)" }
            musicProgress = nil
        }
    }
}

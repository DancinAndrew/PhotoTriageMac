import AppKit
import PhotoTriageCore

extension AppModel {
    var workspaceURL: URL { dataRoot.appendingPathComponent(isDemo ? "demo-workspace.json" : "photos-workspace.json") }
    var launchStateURL: URL { dataRoot.appendingPathComponent("workspace-launch.json") }

    func beginWorkspaceTransition() {
        flushWorkspace()
        workspaceSaveTask?.cancel(); workspaceSaveTask = nil
        workspaceReady = false; pendingViewportRestore = nil; galleryFrames = [:]; currentScrollY = 0
        viewportAnchorToMount = nil; viewportAnchorMountCompleted = false
    }
    func workspaceChanged() {
        guard workspaceReady, workspaceError == nil, pendingViewportRestore == nil else { return }
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            self?.flushWorkspace()
        }
    }
    func workspaceSnapshot() -> WorkspaceState {
        var state = WorkspaceState()
        state.filter = filter; state.organizerAlbumID = selectedOrganizerAlbumID; state.travelTripID = travelTripID
        state.useDateRange = useDateRange; state.rangeStart = rangeStart; state.rangeEnd = rangeEnd
        state.selectedIDs = selected; state.focusedID = focusedID; state.inspectorVisible = inspectorVisible
        state.scrollY = max(0, currentScrollY)
        let anchor = galleryFrames.filter { $0.value.maxY > 0 }.min {
            if abs($0.value.minY - $1.value.minY) < 1 { return $0.value.minX < $1.value.minX }
            return $0.value.minY < $1.value.minY
        }
        state.anchorID = anchor?.key; state.anchorOffset = Double(anchor?.value.minY ?? 0)
        state.reviewedCount = progressCount; state.visibleCount = visible.count
        return state
    }
    func flushWorkspace() {
        guard workspaceReady, workspaceError == nil, pendingViewportRestore == nil else { return }
        let state = workspaceSnapshot()
        guard state != lastWorkspaceState else { return }
        do {
            try WorkspacePersistence.save(state, expected: lastWorkspaceState, to: workspaceURL)
            lastWorkspaceState = state
        } catch { workspaceError = "工作位置未能保存：\(error.localizedDescription)；審閱資料仍獨立保存。" }
    }
    func rememberLaunchProfile() {
        guard launchStateError == nil else { return }
        let next = WorkspaceLaunchState(profile: isDemo ? .demo : .photos)
        guard next != launchState else { return }
        do { try WorkspacePersistence.saveLaunch(next, expected: launchState, to: launchStateURL); launchState = next }
        catch { launchStateError = error.localizedDescription; workspaceError = "無法保存啟動位置：\(error.localizedDescription)" }
    }
    func restoreWorkspace(validateVisibility: Bool = true) {
        workspaceReady = false; workspaceError = nil
        do {
            lastWorkspaceState = try WorkspacePersistence.load(from: workspaceURL)
            guard let state = lastWorkspaceState else { workspaceReady = validateVisibility; return }
            filter = state.filter; useDateRange = state.useDateRange; rangeStart = state.rangeStart; rangeEnd = state.rangeEnd
            selectedOrganizerAlbumID = state.organizerAlbumID; travelTripID = state.travelTripID
            if validateVisibility {
                var unavailable = false
                if let id = selectedOrganizerAlbumID, !organizerAlbums.contains(where: { $0.id == id && !$0.sourceUnavailable }) {
                    selectedOrganizerAlbumID = nil; unavailable = true
                }
                if let id = filter.albumID, !albums.contains(where: { $0.id == id }) { filter.albumID = nil; unavailable = true }
                if let id = filter.groupID, !groups.contains(where: { $0.id == id }) { filter.groupID = nil; unavailable = true }
                if let id = travelTripID, travelReport?.analysis?.trips.contains(where: { $0.id == id }) != true { travelTripID = nil; unavailable = true }
                filterChanged()
                let ids = Set(visible.map(\.id))
                selected = state.selectedIDs.intersection(ids)
                focusedID = state.focusedID.flatMap { ids.contains($0) ? $0 : nil }
                inspectorVisible = state.inspectorVisible && focusedID != nil
                var position = state
                if let anchor = position.anchorID, !ids.contains(anchor) { position.anchorID = nil }
                pendingViewportRestore = position.scrollY > 0 || position.anchorID != nil ? position : nil
                currentScrollY = position.scrollY
                if unavailable { notice = "上次部分相簿／事件已不可見，已清除該條件；其他篩選及審閱紀錄保留。" }
                else { notice = "已恢復上次相簿與篩選；整理進度以目前保存的審閱決定為準。" }
            }
            workspaceReady = validateVisibility
        } catch { workspaceError = "工作位置無法讀取，已保留原檔：\(error.localizedDescription)" }
    }
    func recordGalleryFrames(_ frames: [String: CGRect]) {
        galleryFrames = frames
        viewportRestoreHandler?()
        workspaceChanged()
    }
    func completeViewportRestore(at y: Double) {
        currentScrollY = max(0, y); pendingViewportRestore = nil; viewportAnchorToMount = nil; workspaceChanged()
    }
    func completeAnchorMount(_ id: String) {
        guard viewportAnchorToMount == id, pendingViewportRestore?.anchorID == id else { return }
        viewportAnchorMountCompleted = true
        viewportRestoreHandler?()
    }
}

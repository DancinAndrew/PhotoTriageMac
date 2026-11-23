import Foundation
import PhotoTriageCore

extension AppModel {
    var displayPreferenceURL: URL { dataRoot.appendingPathComponent("display-preferences.json") }
    var shouldShowInspector: Bool {
        inspectorVisible && !selected.isEmpty && focusedID.map { selected.contains($0) && focusedRecord != nil } == true
    }
    func loadDisplayPreferences() {
        do {
            lastDisplayPreferences = try DisplayPreferencePersistence.load(from: displayPreferenceURL)
            if let value = lastDisplayPreferences { thumbnailSize = value.thumbnailSize; inspectorVisible = value.inspectorEnabled }
        } catch { displayPreferenceError = "顯示偏好無法讀取，原檔已保留；本次仍可調整顯示。" }
    }
    func saveDisplayPreferences() {
        guard displayPreferencesReady, displayPreferenceError == nil else { return }
        var next = DisplayPreferences(); next.thumbnailSize = thumbnailSize; next.inspectorEnabled = inspectorVisible
        guard next != lastDisplayPreferences else { return }
        do {
            try DisplayPreferencePersistence.save(next, expected: lastDisplayPreferences, to: displayPreferenceURL)
            lastDisplayPreferences = next
        } catch { displayPreferenceError = "顯示偏好未能保存：\(error.localizedDescription)" }
    }
    func setThumbnailSize(_ size: ThumbnailSize) {
        guard size != thumbnailSize else { return }
        prepareGalleryReflow(); thumbnailSize = size; saveDisplayPreferences(); workspaceChanged()
    }
    /// Preserve the visible asset and its offset when a deliberate size/panel change reflows rows.
    func prepareGalleryReflow() {
        guard workspaceReady, pendingViewportRestore == nil, currentScrollY > 0, !galleryFrames.isEmpty else { return }
        let position = workspaceSnapshot()
        viewportReflowBaseline = galleryFrames
        pendingViewportRestore = position
        viewportAnchorToMount = position.anchorID; viewportAnchorMountCompleted = false
    }
}

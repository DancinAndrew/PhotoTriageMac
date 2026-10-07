import AppKit
import SwiftUI

/// Observes only this gallery's native scroll view. No global window or input access.
struct GalleryScrollPersistence: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view else { return }
            coordinator?.attach(view.enclosingScrollView)
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator {
        weak var model: AppModel?
        weak var scroll: NSScrollView?
        var observation: NSObjectProtocol?
        init(model: AppModel) { self.model = model }
        func attach(_ value: NSScrollView?) {
            guard let value else { return }
            if scroll !== value {
                detach(); scroll = value
                value.contentView.postsBoundsChangedNotifications = true
                observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: value.contentView, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.changed() }
                    }
                model?.viewportRestoreHandler = { [weak self] in self?.restore() }
            }
            restore()
        }
        func restore() {
            guard let model, let scroll, let state = model.pendingViewportRestore,
                  let document = scroll.documentView, document.bounds.height > 0, scroll.contentView.bounds.height > 0 else { return }
            var y = state.scrollY
            if let id = state.anchorID {
                if model.viewportAnchorToMount != nil && !model.viewportAnchorMountCompleted { return }
                guard let frame = model.galleryFrames[id] else {
                    if !model.galleryFrames.isEmpty && model.viewportAnchorToMount == nil { model.viewportAnchorToMount = id }
                    return
                }
                y = Double(scroll.contentView.bounds.origin.y + frame.minY) - state.anchorOffset
            }
            y = max(0, min(y, Double(max(0, document.bounds.height - scroll.contentView.bounds.height))))
            // Clear before scrolling: the native bounds notification can arrive synchronously.
            model.completeViewportRestore(at: y)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        func changed() {
            guard let model, let scroll else { return }
            if model.pendingViewportRestore != nil { restore(); return }
            model.currentScrollY = Double(max(0, scroll.contentView.bounds.origin.y))
            model.workspaceChanged()
        }
        func detach() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil; scroll = nil
        }
    }
}

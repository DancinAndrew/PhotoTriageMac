import AppKit
import SwiftUI
import PhotoTriageCore

/// Commands observe current selection, modal state and history instead of launch-time values.
@MainActor struct OrganizerCommands: Commands {
    @ObservedObject var model: AppModel
    @StateObject private var editing = OrganizerEditingContext()
    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("新增本機相簿…") { model.albumAction = .create }.keyboardShortcut("n")
                    .disabled(!model.canManageAlbums || model.hasModal)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(editing.isEditingText ? "復原文字編輯" : "復原整理操作") { editing.undo(model: model) }.keyboardShortcut("z")
                    .disabled(editing.isEditingText ? !editing.canUndo : !model.canUndo || !model.canReview || model.hasModal)
                Button("重做文字編輯") { editing.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editing.isEditingText || !editing.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("剪下") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
                Button("複製") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
                Button("貼上") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
                Divider()
                Button("全選目前篩選") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                        editor.selectAll(nil)
                    } else { model.selectAll() }
                }.keyboardShortcut("a")
                    .disabled(!model.canSelectVisible && !model.hasModal)
            }
            CommandMenu("審閱") {
                Button("並排挑選（2–6 張）") { model.beginComparison() }.keyboardShortcut("c", modifiers: [])
                    .disabled(!model.canCompare)
                Button("保留") { model.mark(.kept) }.keyboardShortcut("k", modifiers: []).disabled(!model.canAct)
                Button("完成審閱（本機）") { model.mark(.organized) }.keyboardShortcut("o", modifiers: []).disabled(!model.canAct)
                Button("暫時用途") { model.toggleTemporary() }.keyboardShortcut("t", modifiers: []).disabled(!model.canAct)
                Button("加入相簿…") { model.albumAction = .addSelection }.keyboardShortcut("a", modifiers: []).disabled(!model.canAct || !model.canManageAlbums)
                Button("沿用最近目的相簿") { model.repeatDestination() }.keyboardShortcut("a", modifiers: [.shift])
                    .disabled(!model.canAct || !model.canManageAlbums || model.repeatDestinationAlbum == nil)
                Button("加入相簿並完成這批") { model.repeatDestination(completeReview: true) }.keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.canAct || !model.canManageAlbums)
                Button("照片資訊") { model.inspectorVisible.toggle() }.keyboardShortcut("i", modifiers: []).disabled(model.focusedID == nil || model.hasModal)
                Button("加入待刪候選") { model.addToDeleteQueue() }.keyboardShortcut("d", modifiers: []).disabled(!model.canAct)
                Button("恢復未審閱") { model.resetSelected() }.keyboardShortcut("u", modifiers: []).disabled(!model.canAct)
                Divider()
                Button("下一張") { model.advance(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(model.hasModal)
                Button("上一張") { model.advance(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(model.hasModal)
            }
    }
}

/// Keep native text editing separate from the persisted photo review history.
@MainActor final class OrganizerEditingContext: ObservableObject {
    @Published private(set) var isEditingText = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private let editorProvider: () -> NSTextView?
    private var observers: [NSObjectProtocol] = []

    init(editorProvider: (() -> NSTextView?)? = nil) {
        self.editorProvider = editorProvider ?? { NSApp.keyWindow?.firstResponder as? NSTextView }
        let names: [Notification.Name] = [NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            NSText.didChangeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // TextField registers its undo after the text-change notification.
                DispatchQueue.main.async { self?.refresh() }
            })
        }
        refresh()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    private var editor: NSTextView? { editorProvider().flatMap { $0.isEditable ? $0 : nil } }
    func refresh() {
        let current = editor
        isEditingText = current != nil
        canUndo = current?.undoManager?.canUndo == true
        canRedo = current?.undoManager?.canRedo == true
    }
    func undo(model: AppModel) {
        if let current = editor {
            if current.undoManager?.canUndo == true { current.undoManager?.undo() }
        } else if model.canReview && model.canUndo && !model.hasModal { model.undo() }
        refresh()
    }
    func redo() {
        if let current = editor, current.undoManager?.canRedo == true { current.undoManager?.redo() }
        refresh()
    }
}

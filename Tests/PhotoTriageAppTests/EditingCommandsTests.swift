import XCTest
import AppKit
@testable import PhotoTriageApp

final class EditingCommandsTests: XCTestCase {
    @MainActor private final class EditingView: NSTextView {
        let editingUndo = UndoManager()
        override var undoManager: UndoManager? { editingUndo }
    }
    @MainActor func testNativeTextUndoRedoPreservesPhotoReviewTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editing-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(reviewRoot: root)
        model.selected = [try XCTUnwrap(model.visible.first?.id)]
        model.mark(.kept)
        let saved = model.document
        model.albumAction = .create
        let view = EditingView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.isEditable = true; view.allowsUndo = true
        view.editingUndo.beginUndoGrouping()
        view.insertText("native edit", replacementRange: NSRange(location: 0, length: 0))
        view.editingUndo.endUndoGrouping()
        let context = OrganizerEditingContext(editorProvider: { view })
        XCTAssertTrue(context.isEditingText)
        XCTAssertTrue(context.canUndo)
        context.undo(model: model)
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(model.document, saved)
        XCTAssertTrue(context.canRedo)
        context.redo()
        XCTAssertEqual(view.string, "native edit")
        XCTAssertEqual(model.document, saved)
    }
    @MainActor func testPhotoUndoBlockedInModalAndAvailableOutsideEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editing-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(reviewRoot: root)
        let id = try XCTUnwrap(model.visible.first?.id)
        model.selected = [id]; model.mark(.kept)
        let saved = model.document
        let context = OrganizerEditingContext(editorProvider: { nil })
        model.albumAction = .create
        context.undo(model: model)
        XCTAssertEqual(model.document, saved)
        model.albumAction = nil
        context.undo(model: model)
        XCTAssertEqual(model.document.history.count, 0)
        XCTAssertEqual(model.document.decision(for: id).status, .unreviewed)
    }
}

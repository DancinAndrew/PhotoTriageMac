import AppKit
import SwiftUI
import XCTest
import PhotoTriageCore
@testable import PhotoTriageApp

final class StableGalleryTests: XCTestCase {
    func testNativeCardFramesAndScrollStayStableAcrossSelectionInspectorAndSelectAll() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryGeometry-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(reviewRoot: root)
            var frames: [String: CGRect] = [:]
            let content = OrganizerView().environmentObject(model)
                .environment(\.galleryFrameReporter) { frames = $0 }
                .preferredColorScheme(.light)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1320, height: 850),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 1320, height: 850)
            host.autoresizingMask = [.width, .height]; window.contentView = host
            func settle() {
                for _ in 0..<6 {
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
                }
            }
            func compare(_ before: [String: CGRect], file: StaticString = #filePath, line: UInt = #line) {
                let common = Set(before.keys).intersection(frames.keys)
                XCTAssertGreaterThanOrEqual(common.count, 4, file: file, line: line)
                for id in common {
                    XCTAssertEqual(frames[id]!.minX, before[id]!.minX, accuracy: 0.5, file: file, line: line)
                    XCTAssertEqual(frames[id]!.minY, before[id]!.minY, accuracy: 0.5, file: file, line: line)
                    XCTAssertEqual(frames[id]!.width, before[id]!.width, accuracy: 0.5, file: file, line: line)
                }
            }
            settle()
            XCTAssertGreaterThanOrEqual(frames.count, 8)
            let firstRow = frames.values.filter { abs($0.minY - (frames.values.map(\.minY).min() ?? 0)) < 1 }
            XCTAssertGreaterThanOrEqual(firstRow.count, 4, "Grid must fill its actual available width, not collapse into two centered columns")
            let initial = frames, ids = model.visible.map(\.id)
            model.select(ids[0]); settle(); compare(initial)
            model.select(ids[3]); settle(); compare(initial)
            model.closeInspector(); settle(); compare(initial)
            model.inspectorVisible = true; model.select(ids[5], modifiers: .command); settle(); compare(initial)
            model.selectAll(); settle(); compare(initial)
            model.clearSelection(); settle(); compare(initial)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.bounds.width > 400 })
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.reflectScrolledClipView(scroll.contentView); settle()
            let offset = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(offset, 200)
            let scrolled = frames
            model.select(ids[7]); settle(); compare(scrolled)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 0.5)
            model.selectAll(); settle(); XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 0.5)
            model.closeInspector(); model.clearSelection(); settle()
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 0.5)
            window.setContentSize(NSSize(width: 1760, height: 950)); settle()
            let resized = frames
            model.select(ids[8]); settle(); compare(resized)
            model.setScope(.screenshots); settle()
            XCTAssertEqual(model.visible.count, 5)
            let filtered = frames
            model.selectAll(); settle(); compare(filtered)
            model.filter.media = .video; model.filterChanged(); settle()
            XCTAssertTrue(model.visible.isEmpty); XCTAssertTrue(frames.isEmpty)
            XCTAssertTrue(model.document.decisions.isEmpty)
        }
    }
}

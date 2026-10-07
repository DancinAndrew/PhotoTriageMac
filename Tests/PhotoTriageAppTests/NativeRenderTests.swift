import AppKit
import SwiftUI
import XCTest
@testable import PhotoTriageApp

final class NativeRenderTests: XCTestCase {
    /// Exercise native SwiftUI layout offscreen; never activates an app or changes browser focus.
    func testNativeViewsRenderOffscreen() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoTriageRender-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(reviewRoot: root)
            let output = ProcessInfo.processInfo.environment["PHOTOTRIAGE_RENDER_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            try render(OrganizerView().environmentObject(model), width: 1320, height: 850,
                       output: output?.appendingPathComponent("demo-workspace.png"))
            model.select(model.visible[0].id)
            try render(OrganizerView().environmentObject(model), width: 1320, height: 850,
                       output: output?.appendingPathComponent("demo-workspace-selected.png"))
            model.addToDeleteQueue()
            XCTAssertFalse(model.hasModal)
            XCTAssertEqual(model.queueCount, 1)
            try render(OrganizerView().environmentObject(model), width: 1320, height: 850,
                       output: output?.appendingPathComponent("demo-workspace-queued.png"))
            try render(TravelReviewSheet().environmentObject(model), width: 872, height: 680,
                       output: output?.appendingPathComponent("travel-empty-confirmation.png"))
            let denied = AppModel(reviewRoot: root, startupOverride: "denied")
            try render(OrganizerView().environmentObject(denied), width: 1320, height: 850,
                       output: output?.appendingPathComponent("permission-denied.png"))
        }
    }

    func testCombinedFiltersRecentDestinationAndCompleteBatchRenderOffscreen() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeedRender-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(reviewRoot: root)
            let output = ProcessInfo.processInfo.environment["PHOTOTRIAGE_RENDER_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            model.setScope(.screenshots); model.selectAll()
            let album = try model.createLocalAlbum(title: "工作：截圖批次分類", includeSelection: true)
            model.setOrganizerAlbum(album); model.setScope(.unreviewed); model.filter.media = .image
            let dates = model.visible.compactMap(\.date)
            model.rangeStart = try XCTUnwrap(dates.min()); model.rangeEnd = try XCTUnwrap(dates.max()); model.setDateRangeEnabled(true)
            model.selectAll()
            XCTAssertFalse(model.visible.isEmpty); XCTAssertEqual(model.activeFilterChips.count, 5)
            try render(OrganizerView().environmentObject(model), width: 1320, height: 850,
                       output: output?.appendingPathComponent("combined-filters-recent.png"))
            try render(OrganizerView().environmentObject(model), width: 1060, height: 760,
                       output: output?.appendingPathComponent("combined-filters-minimum.png"))
            try render(LocalAlbumSheet(action: .addSelection).environmentObject(model), width: 590, height: 390,
                       output: output?.appendingPathComponent("album-choice-and-complete.png"))
            let ids = Set(model.selected)
            model.repeatDestination(completeReview: true)
            XCTAssertTrue(model.visible.isEmpty)
            XCTAssertTrue(ids.allSatisfy { model.document.decision(for: $0).status == .organized })
            model.removeFilterChip(.review); model.select(ids.sorted()[0])
            try render(OrganizerView().environmentObject(model), width: 1320, height: 850,
                       output: output?.appendingPathComponent("completed-review-membership.png"))
            model.undo()
            XCTAssertTrue(ids.allSatisfy { model.document.decision(for: $0).status == .unreviewed })
        }
    }

    @MainActor
    private func render<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, output: URL?) throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: width, height: height)
            .background(Color.white).foregroundStyle(Theme.ink).preferredColorScheme(.light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("Offscreen native rendering is unavailable in this execution environment")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 500)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 300)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        if let output { try png.write(to: output) }
        window.close()
    }
}

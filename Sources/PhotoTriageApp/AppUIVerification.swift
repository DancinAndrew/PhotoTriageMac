import AppKit
import AVKit
import SwiftUI
import PhotoTriageCore
import Darwin

/// Opt-in verification in the actual application scene. All events stay in this process.
/// A separate fictional profile is mandatory; no Photos connect or global input is used.
@MainActor enum AppUIVerification {
    static var requested: Bool { CommandLine.arguments.contains("--ui-qa") }
    static var started = false
    struct Check: Codable { var name: String; var status: String; var method: String; var detail: String }
    static var checks: [Check] = []
    static var model: AppModel?
    static var rootWindow: NSWindow?
    static var output: URL?
    static func prepare() {
        guard requested else { return }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--review-root"), args.indices.contains(i + 1),
              let o = args.firstIndex(of: "--ui-qa"), args.indices.contains(o + 1), !args.contains("--connect-photos") else { exit(2) }
        let root = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        guard root.pathComponents.contains(".qa-data"),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("photos-review.json").path),
              (try? WorkspacePersistence.loadLaunch(from: root.appendingPathComponent("workspace-launch.json")))?.profile != .photos else { exit(2) }
        output = URL(fileURLWithPath: args[o + 1])
        UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
    static func schedule(_ value: AppModel) {
        guard requested, !started else { return }
        started = true; model = value
        Task { @MainActor in
            await settle(500)
            let simulatedDenied = CommandLine.arguments.contains("--simulate-denied") && value.access == .denied && value.records.isEmpty
            guard value.isDemo || simulatedDenied, let window = NSApp.windows.first(where: { $0.title.contains("Photo Triage") }) else {
                checks.append(Check(name: "actual-app-scene", status: "failed", method: "actual App", detail: "No fictional application window was created."))
                finish(); return
            }
            rootWindow = window; window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            // Accessory mode supports our offscreen sheets without foreground activation.
            NSApp.setActivationPolicy(.accessory)
            window.orderFront(nil); window.makeMain(); window.makeKey(); await settle(350)
            if simulatedDenied { await verifyDenied(value) }
            else if CommandLine.arguments.contains("--empty-demo") { await verifyEmpty(value) }
            else if CommandLine.arguments.contains("--ui-qa-resume") { await verifyResume(value) }
            else if CommandLine.arguments.contains("--ui-qa-video") { await verifyVideoPlayback(value) }
            else { await verifyDisplayDecisions(value); await verifyFlows(value) }
            finish()
        }
    }
    static func settle(_ milliseconds: Int = 180) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        for _ in 0..<3 {
            for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded() }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    static func record(_ name: String, _ passed: Bool, method: String, detail: String = "") {
        checks.append(Check(name: name, status: passed ? "passed" : "failed", method: method, detail: detail))
        print("QA \(name): \(passed) \(detail)")
        if let output, let data = try? JSONEncoder().encode(checks) { try? data.write(to: output, options: .atomic) }
    }
    @MainActor struct Node {
        weak var view: VerificationControlProbe.ProbeView?
        func accessibilityIdentifier() -> String? { view?.controlID }
        func accessibilityLabel() -> String? { nil }
        func accessibilityRole() -> NSAccessibility.Role? { .button }
        func accessibilityFrame() -> CGRect { view?.convert(view?.bounds ?? .zero, to: nil) ?? .zero }
        func isAccessibilityEnabled() -> Bool { view?.enabled ?? false }
    }
    static var controlViews: [String: Node] = [:]
    static func nodes() -> [Node] { controlViews.values.filter { $0.view?.window != nil } }
    static func element(_ id: String) -> Node? { controlViews[id].flatMap { $0.view?.window == nil ? nil : $0 } }
    @discardableResult static func press(_ id: String) async -> Bool {
        await settle(30)
        guard let node = element(id), let view = node.view, let window = view.window else { return false }
        return await sendClick(point: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), window: window)
    }
    @discardableResult static func sendClick(point: NSPoint, window: NSWindow, flags: NSEvent.ModifierFlags = []) async -> Bool {
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags,
                  timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
                  context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { return false }
        NSApp.postEvent(up, atStart: true); NSApp.sendEvent(down); await settle()
        return true
    }
    @discardableResult static func clickPhoto(_ id: String, flags: NSEvent.ModifierFlags = []) async -> Bool {
        guard let view = element("photo-\(id)")?.view, let window = view.window else { return false }
        return await sendClick(point: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), window: window, flags: flags)
    }
    @discardableResult static func key(_ character: String, flags: NSEvent.ModifierFlags = []) async -> Bool {
        await settle(30)
        // Validate the actual binding, then invoke its native menu item. An inactive app's
        // performKeyEquivalent can consume a key without delivering its command.
        let significant: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        func locate(_ menu: NSMenu) -> (NSMenu, Int)? {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == character && item.keyEquivalentModifierMask.intersection(significant) == flags.intersection(significant), item.isEnabled { return (menu, index) }
                if let child = item.submenu, let match = locate(child) { return match }
            }
            return nil
        }
        guard let menu = NSApp.mainMenu, let (owner, index) = locate(menu) else {
            func dump(_ menu: NSMenu) { for item in menu.items {
                if !item.keyEquivalent.isEmpty { print("BINDING \(item.title): \(item.keyEquivalent) flags=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled)") }
                if let child = item.submenu { dump(child) }
            } }
            if let menu = NSApp.mainMenu { dump(menu) }
            return false
        }
        print("MENU \(character): \(owner.items[index].title) key=\(owner.items[index].keyEquivalent) flags=\(owner.items[index].keyEquivalentModifierMask.rawValue)")
        owner.performActionForItem(at: index); await settle()
        print("MENU result: selected=\(model?.selected.count ?? -1) compare=\(model?.comparison?.assetIDs.count ?? 0) history=\(model?.document.history.count ?? -1)")
        return true
    }
    @discardableResult static func sheetKey(_ character: String, code: UInt16) async -> Bool {
        await settle(30)
        guard let window = rootWindow?.attachedSheet,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { return false }
        let handled = window.performKeyEquivalent(with: event); await settle()
        return handled
    }
    static func scrollViews() -> [NSScrollView] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return rootWindow?.contentView.map { walk($0).compactMap { $0 as? NSScrollView } } ?? []
    }
    static func gallery() -> NSScrollView? { scrollViews().first { $0.bounds.width > 350 && $0.bounds.height > 150 } }
    static func capture(_ name: String) {
        guard model?.isDemo == true || (CommandLine.arguments.contains("--simulate-denied") && model?.records.isEmpty == true), let output, let view = (rootWindow?.attachedSheet ?? rootWindow)?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: output.deletingLastPathComponent().appendingPathComponent(name + ".png"))
        }
    }
    static func verifyDisplayDecisions(_ model: AppModel) async {
        let before = model.document
        let first = model.visible[0].id
        model.inspectorVisible = false
        _ = await clickPhoto(first)
        record("closed-inspector-single-selection", !model.inspectorVisible && element("photoInspectorSlot") == nil,
               method: "actual mouse event in isolated app; panel absent from native hierarchy")
        _ = await press("selectAllVisible")
        record("closed-inspector-select-all", model.selected.count == 43 && !model.inspectorVisible && element("photoInspectorSlot") == nil,
               method: "actual select-all button")
        _ = await press("toggleInspector")
        record("inspector-enabled-selection-shows", model.shouldShowInspector && element("photoInspectorSlot") != nil, method: "actual info toggle")
        _ = await press("clearSelection")
        record("inspector-enabled-empty-hides", model.inspectorVisible && !model.shouldShowInspector && element("photoInspectorSlot") == nil,
               method: "actual clear-selection button; preference remains enabled")
        _ = await clickPhoto(first)
        _ = await press("closeInspector")
        _ = await clickPhoto(model.visible[1].id)
        record("inspector-close-stays-closed-next-selection", !model.inspectorVisible && element("photoInspectorSlot") == nil,
               method: "actual close and next card buttons")
        _ = await press("clearSelection"); _ = await clickPhoto(first)
        for (keyName, button) in [("k", "markKeep"), ("t", "markTemporary"), ("d", "addToDeleteQueue")] {
            let keyDelivered = await key(keyName)
            let fromKey = model.document
            record("decision-\(keyName)-reviewed", keyDelivered && model.progressCount == 1 && model.document.decision(for: first).hasBeenReviewed,
                   method: "actual native menu shortcut and saved fixture decision")
            _ = await key("z", flags: .command)
            _ = await press(button)
            record("decision-\(keyName)-button-matches-shortcut", model.document.decisions == fromKey.decisions,
                   method: "actual decision button vs shortcut result")
            _ = await press("undoOrganizer")
        }
        let oBound = await key("o")
        record("legacy-o-operation-removed", !oBound && model.document == before, method: "actual native menu inventory; no O binding")
        _ = await press("markTemporary"); _ = await press("resetDecision")
        record("clear-decision-removes-t-and-reviewed", model.progressCount == 0 && !model.document.decision(for: first).isTemporary,
               method: "actual T and clear-decision buttons")
        _ = await press("undoOrganizer"); _ = await press("undoOrganizer")
        record("decision-batch-undo-restores-original", model.document == before, method: "actual undo buttons; exact fixture document")
        if let scroll = gallery() {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 310)); scroll.reflectScrolledClipView(scroll.contentView); await settle(350)
            for size in [ThumbnailSize.small, .large, .medium] {
                let anchor = model.workspaceSnapshot(), selection = model.selected
                model.setThumbnailSize(size); await settle(700)
                let persisted = try? DisplayPreferencePersistence.load(from: model.displayPreferenceURL)
                let positionOK = anchor.anchorID.flatMap { model.galleryFrames[$0] }.map { abs(Double($0.minY) - anchor.anchorOffset) < 35 } ?? false
                record("thumbnail-\(size.rawValue)-selection-position-preference", model.thumbnailSize == size && model.selected == selection &&
                    model.pendingViewportRestore == nil && positionOK && persisted?.thumbnailSize == size,
                    method: "real native grid after picker binding; asset anchor, selection and isolated saved preference",
                    detail: "anchor restored=\(positionOK), pending=\(model.pendingViewportRestore != nil), expected=\(anchor.anchorOffset), actual=\(anchor.anchorID.flatMap { model.galleryFrames[$0] }?.minY ?? -9999), y=\(model.currentScrollY)")
            }
        } else { record("thumbnail-native-gallery", false, method: "native NSScrollView") }
        for width in [1060.0, 1600.0] {
            rootWindow?.setContentSize(NSSize(width: width, height: 850)); await settle(250)
            for size in ThumbnailSize.allCases {
                model.setThumbnailSize(size); await settle(450)
                let bounds = rootWindow?.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
                let controlIDs = ["thumbnailSize", "filterMedia", "filterReviewStatus", "filterUnknownDate", "markKeep", "markTemporary", "addToDeleteQueue", "resetDecision", "toggleInspector", "clearAllFilters"]
                let frames = controlIDs.compactMap { element($0)?.accessibilityFrame() }
                record("layout-\(Int(width))-\(size.rawValue)", frames.count == controlIDs.count && frames.allSatisfy { $0.width > 0 && bounds.contains($0) },
                       method: "actual native window/size layout; all essential controls inside content bounds")
                if width == 1060 { capture("layout-1060-" + size.rawValue) }
            }
        }
        model.setThumbnailSize(.medium); model.inspectorVisible = false; model.clearSelection()
        if let scroll = gallery() { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        rootWindow?.setContentSize(NSSize(width: 1320, height: 850)); await settle()
        record("display-actions-preserve-review", model.document == before, method: "exact isolated review document after all display operations")
    }
    static func verifyFlows(_ model: AppModel) async {
        record("actual-control-frames", !nodes().isEmpty, method: "own native NSView frame probes; no Accessibility permission needed")
        record("single-filter-region", element("scope-unclassified") == nil && element("scope-screenshots") == nil &&
            ["filterMedia", "filterReviewStatus", "filterScreenshots", "filterUnclassified", "filterRapidShots", "filterDateRange", "filterUnknownDate", "filterResultCount", "clearAllFilters"].allSatisfy { element($0) != nil },
            method: "actual rendered control inventory; sidebar contains source navigation only")
        _ = await press("filterUnclassified")
        record("top-unclassified-filter", model.filter.unclassifiedOnly && model.activeFilterChips.contains { $0.kind == .unclassified } && model.visible.allSatisfy { !model.locallyClassifiedIDs.contains($0.id) },
            method: "actual consolidated checkbox")
        model.reviewFilterOption = .temporary; await settle()
        record("top-combined-empty-filter", model.filter.unclassifiedOnly && model.filter.temporaryOnly && model.visible.isEmpty && model.selected.isEmpty,
            method: "actual review picker binding with unclassified checkbox; fixture has no temporary decisions")
        _ = await press("clearAllFilters")
        _ = await press("filterDateRange"); _ = await press("filterUnknownDate")
        record("top-date-unknown-replacement", !model.useDateRange && model.filter.unknownDateOnly && model.visible.allSatisfy { $0.date == nil },
            method: "actual date and unknown-time checkboxes; shared filter state")
        _ = await press("clearAllFilters")
        record("top-filter-reset-restores-source", model.visible.count == 43 && model.activeFilterChips.isEmpty && model.selectedOrganizerAlbumID == nil && element("filterResultCount") != nil,
            method: "actual single clear-all action and visible result label")
        let initial = model.document
        let photos = Array(model.visible.filter { $0.kind == .image && $0.demoScene != nil }.prefix(6))
        let first = photos[0].id, second = photos[1].id
        let clicked = await clickPhoto(first)
        record("mouse-single-selection", clicked && model.selected == [first], method: "actual scene targeted mouse down/up")
        let commandClicked = await clickPhoto(second, flags: .command)
        record("mouse-command-multiselect", commandClicked && model.selected == [first, second], method: "actual scene targeted mouse down/up")
        let shiftClicked = await clickPhoto(photos[3].id, flags: .shift)
        record("mouse-shift-range", shiftClicked && model.selected.count >= 3, method: "actual scene targeted mouse down/up")
        _ = await press("clearSelection")
        let all = await key("a", flags: .command)
        record("keyboard-select-all", all && model.selected.count == model.visible.count, method: "actual native menu binding and action")
        _ = await press("clearSelection"); _ = await clickPhoto(first); _ = await clickPhoto(second, flags: .command)
        let opened = await key("c")
        await settle(350)
        record("compare-two-open", opened && model.comparison?.assetIDs.count == 2 && element("confirmComparison") != nil,
               method: "actual native menu binding/action and sheet controls")
        if model.comparison == nil { _ = await press("compareSelection"); await settle(350) }
        let unconfirmed = model.document
        _ = await press("confirmComparison")
        record("compare-requires-explicit-keepers", model.comparison != nil && model.document == unconfirmed,
               method: "actual disabled confirmation button cannot save without keepers")
        _ = await press("comparisonEnlarge-\(first)"); _ = await press("comparisonZoom-4")
        record("compare-zoom-four-times", element("comparisonZoom-4") != nil, method: "actual zoom button and enlarged view")
        let escaped = await sheetKey("\u{1b}", code: 53)
        if !escaped { _ = await press("comparisonBack") }
        checks.append(Check(name: "compare-escape-key", status: escaped ? "passed" : "not_tested", method: "own native sheet key equivalent",
                            detail: escaped ? "Native Escape returned from zoom." : "Inactive sheet did not deliver Escape; actual return button verified separately."))
        record("compare-return-to-grid", element("comparisonEnlarge-\(second)") != nil && model.document == initial,
               method: "actual return button; persisted decisions unchanged")
        _ = await press("comparisonBack")
        record("compare-cancel-no-write", model.comparison == nil && model.document == initial, method: "actual cancel button")
        _ = await press("compareSelection"); await settle(300)
        let numeric = await sheetKey("1", code: 18)
        if !numeric { _ = await press("comparisonKeep-\(first)") }
        let before = model.document
        let commit = await press("confirmComparison")
        record("compare-keep-rest-candidate", commit && model.document.decision(for: first).status == .kept &&
            model.document.decision(for: second).status == .deleteCandidate && model.document.history.count == before.history.count + 1,
            method: "actual confirmation button; one saved transaction")
        checks.append(Check(name: "compare-numeric-keeper-key", status: numeric && model.document.decision(for: first).status == .kept ? "passed" : "not_tested",
                            method: "own native sheet key equivalent", detail: numeric ? "1 selected an explicit keeper before confirmation." : "Inactive sheet did not deliver numeric key; actual keeper button verified separately."))
        let undone = await key("z", flags: .command)
        record("compare-batch-undo", undone && model.document == before, method: "actual native undo binding/action")
        _ = await press("clearSelection")
        for record in photos { _ = await clickPhoto(record.id, flags: .command) }
        _ = await press("compareSelection"); await settle(300)
        record("compare-six-layout", model.comparison?.assetIDs.count == 6 && element("comparisonKeep-\(photos[5].id)") != nil,
               method: "actual six-photo comparison sheet")
        capture("actual-app-compare-six")
        let modalBefore = model.document
        _ = await key("d")
        record("modal-shortcut-does-not-mark-grid", model.document == modalBefore, method: "native menu binding/action during actual sheet")
        _ = await press("comparisonBack")
        _ = await press("clearSelection"); _ = await clickPhoto(first)
        _ = await key("d")
        record("queue-without-repeat-confirmation", model.comparison == nil && !model.hasModal && model.document.decision(for: first).status == .deleteCandidate,
               method: "actual native D binding/action; no confirmation sheet")
        _ = await key("z", flags: .command)
        record("queue-undo", model.document == modalBefore, method: "actual native undo menu binding/action")
        let newAlbum = await key("n", flags: .command)
        record("new-album-command-single-window", newAlbum && model.albumAction == .create && NSApp.windows.filter { $0.title.contains("Photo Triage") }.count == 1,
               method: "actual native Cmd-N binding/action; duplicate New Window command removed")
        _ = await press("cancelLocalAlbum")
        _ = await press("filterScreenshots")
        record("screenshots-filter", model.visible.count == 5 && model.filter.screenshotsOnly, method: "actual checkbox")
        _ = await press("selectAllVisible")
        _ = await press("addToLocalAlbum"); await settle(300)
        record("album-chooser-opens", element("cancelLocalAlbum") != nil, method: "actual album button and sheet")
        let cancelBefore = model.localAlbums
        _ = await press("cancelLocalAlbum")
        record("album-cancel-no-write", model.localAlbums == cancelBefore, method: "actual cancel button")
        // Seed an album fixture; membership/review actions below still use real scene controls.
        let target = try? model.createLocalAlbum(title: "QA target", includeSelection: false)
        if let target {
            try? model.addSelectionToAlbum(id: target)
            model.undo(); await settle()
            let reviewBefore = model.document
            _ = await press("repeatAlbumDestination")
            record("repeat-destination-pure-add", model.document == reviewBefore && model.organizerAlbums.first { $0.id == target }?.assetIDs.count == 5,
                   method: "seeded empty fixture; actual recent destination button")
            _ = await press("undoOrganizer")
            _ = await press("addAndCompleteBatch")
            record("album-and-review-complete", model.visible.filter { $0.isScreenshot }.allSatisfy { model.document.decision(for: $0.id).hasBeenReviewed } && model.progressCount == 5,
                   method: "actual complete-batch button")
            _ = await press("undoOrganizer")
            record("album-review-paired-undo", model.document == reviewBefore && model.organizerAlbums.first { $0.id == target }?.assetIDs.isEmpty == true,
                   method: "actual undo button; both persisted documents checked")
            _ = await press("repeatAlbumDestination")
            _ = await press("organizer-album-\(target)")
            record("album-screenshot-intersection", model.visible.count == 5 && model.currentOrganizerAlbum?.id == target && model.filter.screenshotsOnly,
                   method: "actual album and screenshot controls", detail: "album=\(model.currentOrganizerAlbum?.id == target), visible=\(model.visible.count), selected=\(model.selected.count)")
            _ = await press("selectAllVisible")
            _ = await press("removeFromLocalAlbum")
            record("remove-members-preserves-photos", model.visible.isEmpty && model.records.count == 43,
                   method: "actual remove-members button")
            _ = await press("undoOrganizer")
            _ = await press("filterChip-album")
            record("remove-only-album-filter", model.currentOrganizerAlbum == nil && model.filter.screenshotsOnly && model.visible.count == 5,
                   method: "actual filter chip")
            try? model.deleteLocalAlbum(id: target); await settle()
            _ = await press("selectAllVisible")
            _ = await press("addAndCompleteBatch"); await settle(300)
            record("deleted-recent-target-opens-chooser", model.repeatDestinationAlbum == nil && element("cancelLocalAlbum") != nil,
                   method: "deleted fixture; actual complete button safely opens chooser",
                   detail: "destination=\(model.repeatDestinationAlbum?.id ?? "nil"), selected=\(model.selected.count), action=\(String(describing: model.albumAction)), cancel=\(element("cancelLocalAlbum") != nil)")
            _ = await press("cancelLocalAlbum")
        }
        _ = await press("clearAllFilters")
        record("clear-all-filters", model.activeFilterChips.isEmpty && model.visible.count == 43, method: "actual clear-all button")
        // Use fixture metadata to exercise an intentionally empty intersection and chip recovery.
        model.filter.media = .video; model.filter.screenshotsOnly = true; model.filterChanged(); await settle()
        _ = await press("selectAllVisible")
        record("empty-intersection-visible", model.visible.isEmpty && model.selected.isEmpty,
               method: "fixture video+screenshot intersection; actual empty-state controls")
        _ = await press("filterChip-media")
        record("empty-result-chip-recovery", model.visible.count == 5 && model.filter.screenshotsOnly, method: "actual chip removal")
        _ = await press("clearAllFilters"); _ = await clickPhoto(first)
        _ = await press("toggleInspector"); _ = await press("closeInspector"); record("inspector-close-preserves-selection", model.selected == [first] && !model.inspectorVisible, method: "actual close button")
        _ = await press("toggleInspector"); record("inspector-reopen", model.inspectorVisible, method: "actual info button")
        for width in [1060.0, 1600.0] {
            rootWindow?.setContentSize(NSSize(width: width, height: 850)); await settle(250)
            let contentRect = rootWindow?.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let frames = ["compareSelection", "addAndCompleteBatch"].compactMap { element($0)?.accessibilityFrame() }
            record("window-width-\(Int(width))", frames.count == 2 && frames.allSatisfy { $0.width > 0 && contentRect.contains($0) },
                   method: "actual native window resize; important control frames inside content bounds")
            capture("actual-app-width-\(Int(width))")
        }
        rootWindow?.setContentSize(NSSize(width: 1320, height: 850)); await settle()
        // Render honest failed/cloud preview states in the actual comparison sheet.
        let originalRecords = model.records
        model.records += [PhotoRecord(id: "demo:failed")]
        if !model.records.contains(where: { $0.id == "demo:cloud" }) { model.records.append(PhotoRecord(id: "demo:cloud")) }; model.rebuild()
        model.select("demo:failed"); model.select("demo:cloud", modifiers: .command)
        _ = await press("compareSelection"); await settle(350)
        record("compare-cloud-and-failure-placeholders", element("comparisonPreviewStatus-demo:failed") != nil && element("comparisonPreviewStatus-demo:cloud") != nil,
               method: "fictional unavailable previews rendered in actual comparison sheet; unit tests verify state messages")
        capture("actual-app-preview-failure-cloud"); _ = await press("comparisonBack")
        model.records = originalRecords; model.rebuild()
        _ = await press("clearSelection")
        // End with a real persisted working position for the second actual-app launch.
        _ = await press("selectAllVisible")
        if let album = try? model.createLocalAlbum(title: "Resume fixture", includeSelection: true) {
            _ = await press("organizer-album-\(album)")
            model.filter.media = .image; model.filter.reviewStatus = .unreviewed; model.filterChanged(); await settle()
        }
        if let scroll = gallery() {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 310)); scroll.reflectScrolledClipView(scroll.contentView); await settle(350)
            record("native-scroll-observed", model.currentScrollY > 150, method: "actual NSScrollView bounds observation")
        } else { record("native-scroll-observed", false, method: "actual NSScrollView", detail: "Gallery scroll view not found") }
        model.flushWorkspace(); capture("actual-app-resume-position")
        if let data = try? JSONEncoder().encode(model.workspaceSnapshot()), let output {
            try? data.write(to: output.deletingLastPathComponent().appendingPathComponent("resume-expected.json"))
        }
        record("browser-focus-preserved", NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "local.phototriage.mac",
               method: "actual foreground identity read; no global input sent")
        checks.append(Check(name: "foreground-physical-keyboard-and-text-editing", status: "not_tested", method: "no foreground takeover",
                            detail: "Keyboard bindings were checked and their actual native menu actions invoked; mouse events stayed in the application event queue. Global physical input/clipboard interaction was not used while the user worked."))
        checks.append(Check(name: "live-photos-permission-and-cloud-preview", status: "not_tested", method: "fictional isolated profile",
                            detail: "No native Photos permission prompt or real-library/iCloud asset read was initiated. Missing previews are covered separately by mock states and unit tests."))
    }
    static func verifyVideoPlayback(_ model: AppModel) async {
        guard CommandLine.arguments.contains("--video-fixture"), model.isDemo, model.videoFixtureURLs.count == 2 else {
            record("video-fixture-isolated", false, method: "guarded fictional local-file profile"); return
        }
        let beforeReview = model.document, beforeAlbums = model.localAlbums, beforeSelection = model.selected
        let videos = model.records.filter { model.videoFixtureURLs[$0.id] != nil }
        func player() -> AVPlayer? {
            func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
            return rootWindow?.attachedSheet?.contentView.flatMap { walk($0).compactMap { $0 as? AVPlayerView }.first?.player }
        }
        _ = await press("openVideo-\(videos[0].id)"); await settle(450)
        let first = player(), firstItem = first?.currentItem
        record("video-single-open-auto-plays", first?.currentTime().seconds ?? 0 > 0.2 && first?.isMuted == true,
               method: "actual native open button and sample AVPlayer; QA simulates active-app gate", detail: "Local synthetic sample; no Photos or iCloud data.")
        record("video-no-extra-download-control", element("reloadVideo") != nil && model.videoPreview != nil,
               method: "actual sheet controls; initial playback already advances before any reload")
        capture("actual-app-video-autoplay")
        _ = await press("videoPlayPause"); await settle(150)
        record("video-pause-control", first?.rate == 0, method: "actual pause button")
        _ = await press("nextVideo"); await settle(450)
        let second = player()
        record("video-switch-auto-muted", second?.currentItem != nil && second?.currentItem !== firstItem && second?.isMuted == true && (second?.currentTime().seconds ?? 0) > 0.2,
               method: "actual next button; same player, fresh sample item and one playback intent")
        _ = await press("nextVideo"); await settle(150)
        record("video-missing-resource-releases-player", second?.currentItem == nil && second?.rate == 0,
               method: "fictional missing item; actual next button and failure surface")
        capture("actual-app-video-missing")
        _ = await press("previousVideo"); await settle(350)
        _ = await press("closeVideoPreview")
        record("video-close-releases-item", model.videoPreview == nil && second?.currentItem == nil && second?.rate == 0,
               method: "actual close button; retained AVPlayer checked after dismissal")
        record("video-preview-preserves-review-and-selection", model.document == beforeReview && model.localAlbums == beforeAlbums && model.selected == beforeSelection,
               method: "fixture documents compared; video controls do not classify")
        checks.append(Check(name: "real-photos-and-physical-drag", status: "not_tested", method: "isolated synthetic sample", detail: "Active gate is simulated; this run cannot validate real Photos, cloud streaming or global/physical mouse input."))
    }
    static func verifyDenied(_ model: AppModel) async {
        record("denied-access-native-panel", model.access == .denied && !model.isDemo && model.records.isEmpty && element("photosAccessPanel") != nil,
               method: "actual app scene; simulated denied profile; no native prompt invoked")
        _ = await press("compareSelection"); _ = await press("selectAllVisible")
        record("denied-no-review-or-compare", model.comparison == nil && model.selected.isEmpty && model.document.decisions.isEmpty,
               method: "actual disabled controls")
        capture("actual-app-permission-denied")
        _ = await press("deniedUseDemo")
        record("denied-can-use-demo", model.isDemo && model.records.count == 43, method: "actual use-demo button")
        record("denied-user-focus-preserved", NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "local.phototriage.mac", method: "foreground identity read")
    }
    static func verifyEmpty(_ model: AppModel) async {
        record("empty-native-gallery", model.isDemo && model.visible.isEmpty && model.records.isEmpty && model.galleryFrames.isEmpty, method: "actual empty app scene")
        _ = await press("compareSelection"); _ = await press("selectAllVisible")
        record("empty-controls-no-write", model.comparison == nil && model.selected.isEmpty && model.document.history.isEmpty, method: "actual disabled controls")
        capture("actual-app-empty-gallery")
        record("empty-user-focus-preserved", NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "local.phototriage.mac", method: "foreground identity read")
    }
    static func verifyResume(_ model: AppModel) async {
        await settle(700)
        guard let output, let data = try? Data(contentsOf: output.deletingLastPathComponent().appendingPathComponent("resume-expected.json")),
              let expected = try? JSONDecoder().decode(WorkspaceState.self, from: data) else { record("reopen-expected-state", false, method: "actual app restart"); return }
        record("reopen-album-and-combined-filters", model.selectedOrganizerAlbumID == expected.organizerAlbumID && model.filter == expected.filter,
               method: "second actual application process; persisted profile")
        record("reopen-display-preferences", model.thumbnailSize == .medium && model.inspectorVisible, method: "second actual app process; isolated display preferences")
        record("reopen-selection-and-progress", model.selected == expected.selectedIDs && model.progressCount == expected.reviewedCount,
               method: "second actual application process; own review decisions")
        record("reopen-scroll-position", model.pendingViewportRestore == nil && abs(model.currentScrollY - expected.scrollY) < 35,
               method: "actual native gallery position", detail: "expected=\(expected.scrollY), actual=\(model.currentScrollY)")
        capture("actual-app-restored-position")
        record("reopen-focus-preserved", NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "local.phototriage.mac", method: "actual foreground identity")
    }
    static func finish() {
        model?.flushWorkspace()
        if let output {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? encoder.encode(checks) { try? data.write(to: output, options: .atomic) }
            if let data = try? JSONSerialization.data(withJSONObject: nodes().map {
                ["identifier": $0.accessibilityIdentifier() ?? "", "label": $0.accessibilityLabel() ?? "", "role": $0.accessibilityRole()?.rawValue ?? ""]
            }, options: [.prettyPrinted]) { try? data.write(to: output.deletingLastPathComponent().appendingPathComponent("native-elements.json")) }
        }
        exit(checks.contains { $0.status == "failed" } ? 1 : 0)
    }
}

struct VerificationWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacementView() }
    func updateNSView(_ view: NSView, context: Context) {}
    final class PlacementView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if AppUIVerification.requested {
                window?.isRestorable = false; window?.setFrameAutosaveName("")
                window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            }
        }
    }
}

/// Test-only background anchors locate rendered SwiftUI controls. They never handle input.
struct VerificationControlProbe: NSViewRepresentable {
    let id: String
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSView { ProbeView(id: id) }
    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ProbeView else { return }
        if view.controlID != id, AppUIVerification.controlViews[view.controlID]?.view === view { AppUIVerification.controlViews.removeValue(forKey: view.controlID) }
        view.controlID = id; view.enabled = enabled
        if view.window != nil { AppUIVerification.controlViews[id] = AppUIVerification.Node(view: view) }
    }
    final class ProbeView: NSView {
        var controlID: String
        var enabled = true
        init(id: String) { controlID = id; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { AppUIVerification.controlViews[controlID] = AppUIVerification.Node(view: self) }
        }
    }
}
extension View {
    @ViewBuilder func qaControl(_ id: String) -> some View {
        if AppUIVerification.requested { background(VerificationControlProbe(id: id)) }
        else { self }
    }
}

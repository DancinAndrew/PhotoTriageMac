import SwiftUI
import Darwin

@main
struct PhotoTriageApp: App {
    @StateObject private var model = AppModel()
    init() {
        let args = CommandLine.arguments
        // This organizer stages decisions locally and does not implement Photos mutations.
        if args.contains("--delete-music-screenshots") || args.contains("--apply-travel-albums") {
            fputs("此整理版只管理本機分類；實際 Apple 照片寫入需另行審閱與授權。\n", stderr)
            exit(2)
        }
        if let index = args.firstIndex(of: "--review-status-report"), args.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: args[index + 1])
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited); application.finishLaunching()
            Task { @MainActor in
                do {
                    let access = LibraryAccess.current()
                    guard access.canRead else {
                        let value: [String: Any] = ["authorization": String(describing: access),
                            "libraryRead": false, "permissionRequested": false, "photosMutated": false]
                        try MusicExtractionJob.write(JSONSerialization.data(withJSONObject: value), to: output)
                        exit(3)
                    }
                    let snapshot = await Task.detached { PhotoLibraryReader.fetch() }.value
                    guard LibraryAccess.current().canRead else { exit(3) }
                    let model = AppModel()
                    model.access = access; model.loadPhotosSnapshot(snapshot)
                    guard model.persistenceError == nil, model.localAlbumError == nil else { exit(4) }
                    let data = try JSONSerialization.data(withJSONObject: ReviewStatusAudit.report(model: model),
                                                         options: [.prettyPrinted, .sortedKeys])
                    try MusicExtractionJob.write(data, to: output)
                    exit(0)
                } catch { exit(1) }
            }
            application.run(); exit(1)
        }
        if let index = args.firstIndex(of: "--analyze-travel"), args.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited); application.finishLaunching()
            Task.detached {
                do {
                    let report = try TravelAnalysisJob.run(output: output, allLocalPreviews: args.contains("--all-local-previews"))
                    exit(report.status == "completed_visible_metadata_and_trip_previews" ? 0 : 3)
                } catch { exit(1) }
            }
            application.run(); exit(1)
        }
        if let index = args.firstIndex(of: "--permission-report"), args.indices.contains(index + 1) {
            struct Report: Encodable {
                let authorization: String
                let canRead: Bool
                let permissionRequested = false
                let libraryRead = false
            }
            let access = LibraryAccess.current()
            let output = URL(fileURLWithPath: args[index + 1])
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let report = Report(authorization: String(describing: access), canRead: access.canRead)
                try JSONEncoder().encode(report).write(to: output, options: .atomic)
                exit(0)
            } catch { exit(1) }
        }
        if let mode = ["--inspect-library", "--extract-music"].first(where: { args.contains($0) }),
           let index = args.firstIndex(of: mode), args.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            let albumID = args.firstIndex(of: "--album-id").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            let edge = args.firstIndex(of: "--ocr-long-edge").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 1600
            let sampleLimit = args.firstIndex(of: "--limit").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            Task.detached {
                do {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    if mode == "--inspect-library" {
                        struct InventoryReport: Encodable {
                            var authorization: String
                            var libraryRead: Bool
                            var albums: [AlbumScope]
                            var musicCandidates: [AlbumScope]
                        }
                        let access = LibraryAccess.current()
                        let albums = access.canRead ? AlbumResolver.inventory() : []
                        let value = InventoryReport(authorization: String(describing: access), libraryRead: access.canRead,
                                                    albums: albums, musicCandidates: AlbumResolver.musicCandidates(albums))
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try MusicExtractionJob.write(encoder.encode(value), to: output.appendingPathComponent("album-inventory.json"))
                        exit(access.canRead ? 0 : 3)
                    }
                    let report = MusicExtractionJob.run(albumID: albumID, output: output, previewLongEdge: edge, sampleLimit: sampleLimit) { processed, total in
                        let data = try? JSONSerialization.data(withJSONObject: ["processed": processed, "total": total])
                        if let data { try? MusicExtractionJob.write(data, to: output.appendingPathComponent("progress.json")) }
                    }
                    try MusicExtractionJob.save(report, to: output)
                    exit(["completed_visible_album", "completed_preview_sample"].contains(report.status) ? 0 : 3)
                } catch { exit(1) }
            }
            application.run()
            exit(1)
        }
    }
    var body: some Scene {
        WindowGroup("相片整理 · Photo Triage") {
            OrganizerView().environmentObject(model)
                .frame(minWidth: 1060, minHeight: 700).preferredColorScheme(.light)
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("復原整理操作") { model.undo() }.keyboardShortcut("z")
                    .disabled(!model.canUndo || !model.canReview || model.hasModal)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("剪下") { NSApp.sendAction(Selector(("cut:")), to: nil, from: nil) }.keyboardShortcut("x")
                Button("複製") { NSApp.sendAction(Selector(("copy:")), to: nil, from: nil) }.keyboardShortcut("c")
                Button("貼上") { NSApp.sendAction(Selector(("paste:")), to: nil, from: nil) }.keyboardShortcut("v")
                Divider()
                Button("全選目前篩選") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                        editor.selectAll(nil)
                    } else { model.selectAll() }
                }.keyboardShortcut("a")
                    .disabled(!model.canSelectVisible && !model.hasModal)
            }
            CommandMenu("審閱") {
                Button("保留") { model.mark(.kept) }.keyboardShortcut("k", modifiers: []).disabled(!model.canAct)
                Button("完成審閱（本機）") { model.mark(.organized) }.keyboardShortcut("o", modifiers: []).disabled(!model.canAct)
                Button("暫時用途") { model.toggleTemporary() }.keyboardShortcut("t", modifiers: []).disabled(!model.canAct)
                Button("加入相簿…") { model.albumAction = .addSelection }.keyboardShortcut("a", modifiers: []).disabled(!model.canAct || !model.canManageAlbums)
                Button("沿用最近目的相簿") { model.repeatDestination() }.keyboardShortcut("a", modifiers: [.shift])
                    .disabled(!model.canAct || !model.canManageAlbums || model.repeatDestinationAlbum == nil)
                Button("加入相簿並完成這批") { model.repeatDestination(completeReview: true) }.keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.canAct || !model.canManageAlbums)
                Button("新增相簿…") { model.albumAction = .create }.keyboardShortcut("n").disabled(!model.canManageAlbums || model.hasModal)
                Button("照片資訊") { model.inspectorVisible.toggle() }.keyboardShortcut("i", modifiers: []).disabled(model.focusedID == nil || model.hasModal)
                Button("加入待刪候選") { model.addToDeleteQueue() }.keyboardShortcut("d", modifiers: []).disabled(!model.canAct)
                Button("恢復未審閱") { model.resetSelected() }.keyboardShortcut("u", modifiers: []).disabled(!model.canAct)
                Divider()
                Button("下一張") { model.advance(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(model.hasModal)
                Button("上一張") { model.advance(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(model.hasModal)
            }
        }
    }
}

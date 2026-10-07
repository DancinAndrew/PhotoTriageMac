import SwiftUI
import Darwin

@main
struct PhotoTriageApp: App {
    @StateObject private var model = AppModel()
    init() {
        AppUIVerification.prepare()
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
        .commands { OrganizerCommands(model: model) }
    }
}

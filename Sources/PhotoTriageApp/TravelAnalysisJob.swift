import AppKit
import Photos
import Vision
import PhotoTriageCore

struct TravelLibraryReport: Codable, Sendable {
    var schemaVersion = 1
    var generatedAt = Date()
    var authorization: String
    var status: String
    var assets: [TravelAsset] = []
    var albums: [AlbumScope] = []
    var protectedIDs: Set<String> = []
    var analysis: TravelAnalysis?
    var visionRequested = 0
    var visionProcessed = 0
    var previewStatuses: [String: Int] = [:]
    var policy = "All visible PhotoKit metadata; offline geography; on-device Vision on local 640px previews; network disabled; no originals exported; no deletion. GPS-free or weak evidence stays for manual review."
}

enum TravelAnalysisJob {
    static var reviewRoot: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--review-root"), args.indices.contains(i + 1) {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoTriageMac", isDirectory: true)
    }
    static func geography() throws -> OfflineGeography {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("Travel/places.json"),
              FileManager.default.fileExists(atPath: resource.path) else {
            throw failure("缺少離線地點資料；請使用完整的旅遊版 .app。")
        }
        return try JSONDecoder().decode(OfflineGeography.self, from: Data(contentsOf: resource))
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoTriage.Travel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func protectedAssets(albums: [AlbumScope], root: URL) throws -> Set<String> {
        // A corrupt review DB is a hard stop, never permission to ignore the user's choices.
        let review = try ReviewPersistence.load(from: root.appendingPathComponent("photos-review.json"))
        var ids = Set(review.decisions.filter { id, decision in
            decision.status == .deleteCandidate || decision.isTemporary ||
            (decision.groupOverride.flatMap { review.manualGroups[$0] }.map {
                $0.contains("音樂") || $0.contains("暫時") || $0.contains("待刪")
            } ?? false)
        }.keys)
        for scope in AlbumResolver.musicCandidates(albums) {
            if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [scope.id], options: nil).firstObject {
                let options = PHFetchOptions(); options.includeAllBurstAssets = true
                PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            }
        }
        return ids
    }
    static func run(output: URL, allLocalPreviews: Bool = false) throws -> TravelLibraryReport {
        let access = LibraryAccess.current()
        var report = TravelLibraryReport(authorization: String(describing: access), status: "permission_required")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard access.canRead else { try save(report, output: output); return report }
        let geography = try geography()
        let snapshot = PhotoLibraryReader.fetch()
        report.albums = AlbumResolver.inventory()
        report.protectedIDs = try protectedAssets(albums: report.albums, root: reviewRoot)
        report.assets = snapshot.records.map {
            TravelAsset(record: $0, locationAccuracy: snapshot.assets[$0.id]?.location?.horizontalAccuracy)
        }
        report.analysis = TravelGrouping.analyze(report.assets, geography: geography, protectedIDs: report.protectedIDs)
        report.status = "metadata_complete"
        try save(report, output: output)
        let seed = Set(report.analysis!.trips.flatMap { $0.sampleIDs + $0.unknownCandidateIDs })
        let indices = report.assets.indices.filter { index in
            let record = report.assets[index].record
            return !report.protectedIDs.contains(record.id) && !record.isScreenshot && record.date != nil &&
                (allLocalPreviews || seed.contains(record.id))
        }
        report.visionRequested = indices.count
        report.status = "analyzing_local_previews"
        let manager = PHImageManager()
        for (position, index) in indices.enumerated() {
            guard LibraryAccess.current().canRead else { report.status = "permission_revoked_partial"; break }
            if let asset = snapshot.assets[report.assets[index].record.id] {
                let result = autoreleasepool { classify(asset, manager: manager) }
                report.assets[index].vision = result
                report.previewStatuses[result.status, default: 0] += 1
            }
            report.visionProcessed = position + 1
            try progress(report, output: output)
            if (position + 1).isMultiple(of: 20) { try save(report, output: output) }
        }
        report.analysis = TravelGrouping.analyze(report.assets, geography: geography, protectedIDs: report.protectedIDs)
        if report.visionProcessed == report.visionRequested { report.status = "completed_visible_metadata_and_trip_previews" }
        try save(report, output: output)
        return report
    }
    private final class PreviewResult: @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        var status = "missing_local_preview"
        var finished = false
    }
    static func classify(_ asset: PHAsset, manager: PHImageManager) -> LocalTravelVision {
        let result = PreviewResult()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        let request = manager.requestImage(for: asset, targetSize: CGSize(width: 640, height: 640),
                                           contentMode: .aspectFit, options: options) { image, info in
            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            result.lock.lock(); defer { result.lock.unlock() }
            guard !result.finished else { return }
            let representations = image?.representations ?? []
            let rasters: [CGImage] = representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
            let largest = rasters.max { $0.width * $0.height < $1.width * $1.height }
            result.image = largest ?? image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            result.status = result.image != nil ? "local" :
                ((info?[PHImageResultIsInCloudKey] as? Bool) == true ? "icloud_only_no_download" : "missing_local_preview")
            result.finished = true; result.done.signal()
        }
        if result.done.wait(timeout: .now() + 12) == .timedOut {
            result.lock.lock(); result.finished = true; result.lock.unlock()
            manager.cancelImageRequest(request)
            return LocalTravelVision(status: "local_preview_timeout_no_download")
        }
        result.lock.lock(); let raster = result.image, status = result.status; result.lock.unlock()
        guard let raster else { return LocalTravelVision(status: status) }
        guard max(raster.width, raster.height) >= min(320, max(asset.pixelWidth, asset.pixelHeight)) else {
            return LocalTravelVision(status: "insufficient_local_preview")
        }
        do {
            let classification = VNClassifyImageRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate; text.automaticallyDetectsLanguage = true
            text.minimumTextHeight = 0.025
            let supported = try text.supportedRecognitionLanguages()
            text.recognitionLanguages = ["en-US", "zh-Hant", "ko-KR", "ja-JP"].filter { supported.contains($0) }
            try VNImageRequestHandler(cgImage: raster, orientation: .up).perform([classification, text])
            var scenes: [String: Double] = [:]
            for observation in classification.results ?? [] where observation.confidence >= 0.15 {
                scenes[observation.identifier] = Double(observation.confidence)
            }
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.65 }.map(\.string)
            return LocalTravelVision(status: "local", scenes: scenes, text: lines)
        } catch { return LocalTravelVision(status: "vision_error") }
    }
    static func save(_ report: TravelLibraryReport, output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try MusicExtractionJob.write(encoder.encode(report), to: output.appendingPathComponent("travel-analysis.json"))
        try progress(report, output: output)
    }
    static func progress(_ report: TravelLibraryReport, output: URL) throws {
        let value: [String: Any] = ["status": report.status, "visibleAssets": report.assets.count,
                                  "visionProcessed": report.visionProcessed, "visionTotal": report.visionRequested,
                                  "highConfidenceTrips": report.analysis?.trips.filter(\.canCreateAlbum).count ?? 0]
        try MusicExtractionJob.write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                                     to: output.appendingPathComponent("travel-progress.json"))
    }
}

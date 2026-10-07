import AppKit
import Photos
import Vision
import PhotoTriageCore

struct AlbumScope: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var path: [String]
    var visibleAssetCount: Int
    var pathLabel: String { path.joined(separator: " / ") }
}

enum AlbumResolver {
    static func visibleAssetCount(_ album: PHAssetCollection) -> Int {
        let options = PHFetchOptions(); options.includeAllBurstAssets = true
        return PHAsset.fetchAssets(in: album, options: options).count
    }
    static func inventory() -> [AlbumScope] {
        guard LibraryAccess.current().canRead else { return [] }
        var result: [AlbumScope] = []
        var visited: Set<String> = []
        func walk(_ fetch: PHFetchResult<PHCollection>, parent: [String], depth: Int) {
            guard depth < 20 else { return }
            fetch.enumerateObjects { collection, _, _ in
                guard visited.insert(collection.localIdentifier).inserted else { return }
                let title = collection.localizedTitle ?? "未命名"
                let path = parent + [title]
                if let album = collection as? PHAssetCollection {
                    result.append(AlbumScope(id: album.localIdentifier, title: title, path: path,
                                             visibleAssetCount: visibleAssetCount(album)))
                } else if let folder = collection as? PHCollectionList {
                    walk(PHCollection.fetchCollections(in: folder, options: nil), parent: path, depth: depth + 1)
                }
            }
        }
        walk(PHCollection.fetchTopLevelUserCollections(with: nil), parent: [], depth: 0)
        // Some shared/user albums can be exposed without a traversable folder hierarchy.
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { album, _, _ in
            if visited.insert(album.localIdentifier).inserted {
                let title = album.localizedTitle ?? "未命名相簿"
                result.append(AlbumScope(id: album.localIdentifier, title: title, path: [title],
                                         visibleAssetCount: visibleAssetCount(album)))
            }
        }
        return result.sorted { $0.pathLabel < $1.pathLabel }
    }
    static func musicCandidates(_ inventory: [AlbumScope]) -> [AlbumScope] {
        let exact = inventory.filter { $0.path == ["選集", "音樂"] }
        if !exact.isEmpty { return exact }
        let chinese = inventory.filter { $0.title == "音樂" }
        if !chinese.isEmpty { return chinese }
        return inventory.filter { ["音乐", "music", "shazam"].contains(SongExtractor.normalize($0.title)) }
    }
}

struct OCRAssetResult: Codable, Sendable {
    var assetID: String
    var date: Date?
    var isScreenshotTagged: Bool
    var thumbnailStatus: String
    var thumbnailWidth: Int?
    var thumbnailHeight: Int?
    var lines: [OCRLine]
    var parse: SongParseResult?
    var error: String?
}

struct MusicExtractionReport: Codable, Sendable {
    var schemaVersion = 1
    var generatedAt = Date()
    var status: String
    var authorization: String
    var resolvedAlbum: AlbumScope?
    var albumCandidates: [AlbumScope]
    var visibleAssetCount = 0
    var processedImageCount = 0
    var screenshotTaggedCount = 0
    var localThumbnailCount = 0
    var iCloudOnlyCount = 0
    var missingThumbnailCount = 0
    var insufficientPreviewCount = 0
    var unsupportedVideoCount = 0
    var errorCount = 0
    var unresolvedImageCount = 0
    var previewLongEdge = 1600
    var sampleLimit: Int?
    var songs: [SongCandidate] = []
    var assets: [OCRAssetResult] = []
    var policy = "Read-only PhotoKit; on-device Vision OCR; network-disabled thumbnails; no photo files exported; every song is a review candidate."
}

enum MusicExtractionJob {
    /// Only the explicitly resolved album is read. All still images are included because imported screenshots may lack the screenshot subtype.
    static func run(albumID: String? = nil, output: URL, previewLongEdge: Int = 1600, sampleLimit: Int? = nil,
                    progress: @escaping (Int, Int) -> Void = { _, _ in }) -> MusicExtractionReport {
        let access = LibraryAccess.current()
        var report = MusicExtractionReport(status: "permission_required", authorization: String(describing: access),
                                           resolvedAlbum: nil, albumCandidates: [])
        guard access.canRead else { return report }
        let inventory = AlbumResolver.inventory()
        let candidates = albumID.map { id in inventory.filter { $0.id == id } } ?? AlbumResolver.musicCandidates(inventory)
        report.albumCandidates = candidates
        guard candidates.count == 1 else {
            report.status = candidates.isEmpty ? "album_not_found" : "album_ambiguous"
            return report
        }
        let scope = candidates[0]
        report.resolvedAlbum = scope
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [scope.id], options: nil).firstObject else {
            report.status = "album_unavailable"; return report
        }
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(in: album, options: options)
        report.visibleAssetCount = fetch.count
        let edge = min(2048, max(640, previewLongEdge))
        report.previewLongEdge = edge
        report.sampleLimit = sampleLimit
        let indices: [Int]
        if let sampleLimit {
            let screenshots = (0..<fetch.count).filter {
                let asset = fetch.object(at: $0)
                return asset.mediaType == .image && asset.mediaSubtypes.contains(.photoScreenshot)
            }
            let eligible = screenshots.isEmpty ? (0..<fetch.count).filter { fetch.object(at: $0).mediaType == .image } : screenshots
            indices = sampleIndices(eligible, limit: min(20, max(1, sampleLimit)))
        } else { indices = Array(0..<fetch.count) }
        let manager = PHImageManager()
        for (position, index) in indices.enumerated() {
            if !LibraryAccess.current().canRead { report.status = "permission_revoked_partial"; break }
            let asset = fetch.object(at: index)
            let result: OCRAssetResult = autoreleasepool {
                guard asset.mediaType == .image else {
                    return OCRAssetResult(assetID: asset.localIdentifier, date: asset.creationDate,
                                          isScreenshotTagged: false, thumbnailStatus: "unsupported_video_or_media", lines: [])
                }
                let thumbnail = thumbnail(asset, manager: manager, size: CGSize(width: edge, height: edge))
                var entry = OCRAssetResult(assetID: asset.localIdentifier, date: asset.creationDate,
                                           isScreenshotTagged: asset.mediaSubtypes.contains(.photoScreenshot),
                                           thumbnailStatus: thumbnail.status, lines: [], error: thumbnail.error)
                guard let image = thumbnail.image else { return entry }
                entry.thumbnailWidth = image.width; entry.thumbnailHeight = image.height
                if !isReadablePreview(width: image.width, height: image.height,
                                      originalWidth: asset.pixelWidth, originalHeight: asset.pixelHeight) {
                    entry.thumbnailStatus = "insufficient_local_preview"
                    return entry
                }
                do {
                    entry.lines = try recognize(image)
                    entry.parse = SongExtractor.parse(entry.lines, assetID: asset.localIdentifier)
                } catch { entry.error = "OCR failed: \(error.localizedDescription)" }
                return entry
            }
            report.assets.append(result)
            if asset.mediaType == .image { report.processedImageCount += 1 }
            if result.isScreenshotTagged { report.screenshotTaggedCount += 1 }
            switch result.thumbnailStatus {
            case "local": report.localThumbnailCount += 1
            case "icloud_only_no_download": report.iCloudOnlyCount += 1
            case "unsupported_video_or_media": report.unsupportedVideoCount += 1
            case "insufficient_local_preview": report.insufficientPreviewCount += 1
            default: report.missingThumbnailCount += 1
            }
            if result.error != nil { report.errorCount += 1 }
            if asset.mediaType == .image,
               result.parse == nil || result.parse!.candidates.isEmpty || !result.parse!.unresolvedLineIndices.isEmpty {
                report.unresolvedImageCount += 1
            }
            progress(position + 1, indices.count)
        }
        report.songs = SongExtractor.deduplicate(report.assets.flatMap { $0.parse?.candidates ?? [] })
        if report.assets.count == indices.count {
            report.status = sampleLimit == nil ? "completed_visible_album" : "completed_preview_sample"
        }
        return report
    }

    static func sampleIndices(_ eligible: [Int], limit: Int) -> [Int] {
        guard !eligible.isEmpty, limit > 0 else { return [] }
        if eligible.count <= limit { return eligible }
        if limit == 1 { return [eligible[eligible.count / 2]] }
        return (0..<limit).map { eligible[$0 * (eligible.count - 1) / (limit - 1)] }
    }
    static func isReadablePreview(width: Int, height: Int, originalWidth: Int, originalHeight: Int) -> Bool {
        let minimum = min(512, max(1, max(originalWidth, originalHeight)))
        return max(width, height) >= minimum
    }
    static func previewOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        return options
    }

    static func recognize(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.004
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["en-US", "zh-Hant", "zh-Hans", "ko-KR"].filter { supported.contains($0) }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(text: text.string, confidence: Double(text.confidence), x: box.minX, y: box.minY,
                           width: box.width, height: box.height)
        }.sorted {
            if $0.y == $1.y { return $0.x < $1.x }
            return $0.y > $1.y
        }
    }

    private static func thumbnail(_ asset: PHAsset, manager: PHImageManager, size: CGSize)
        -> (image: CGImage?, status: String, error: String?) {
        let options = previewOptions()
        var image: CGImage?
        var cloud = false
        var failure: String?
        manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { result, info in
            if let result {
                // Use actual raster pixels, never upscale a tiny cached preview for a false resolution check.
                var largest: CGImage?
                var largestPixelCount = 0
                for representation in result.representations {
                    guard let bitmap = representation as? NSBitmapImageRep, let raster = bitmap.cgImage else { continue }
                    let pixelCount = raster.width * raster.height
                    if pixelCount > largestPixelCount { largest = raster; largestPixelCount = pixelCount }
                }
                image = largest ?? result.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            cloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            failure = (info?[PHImageErrorKey] as? Error)?.localizedDescription
        }
        if let image { return (image, "local", nil) }
        return (nil, cloud ? "icloud_only_no_download" : "missing_local_thumbnail", failure)
    }

    static func save(_ report: MusicExtractionReport, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(report), to: folder.appendingPathComponent("music-extraction.json"))
        try write(Data(SongExtractor.csv(report.songs).utf8), to: folder.appendingPathComponent("songs-review.csv"))
        let rows = report.songs.enumerated().map { index, song in
            "\(index + 1). \(song.title) — \(song.artist ?? "歌手未知") [待確認；\(song.confidence)]\n   Spotify: \(song.spotifySearchURL)\n   YouTube: \(song.youtubeSearchURL)\n   來源: \(song.evidence.map(\.assetID).joined(separator: ", "))"
        }.joined(separator: "\n\n")
        let coverage = report.resolvedAlbum == nil ? "尚未讀取相簿；以下零值不是相簿為空的判定。" : "可見項目：\(report.visibleAssetCount)；已處理圖片：\(report.processedImageCount)；可讀本機預覽：\(report.localThumbnailCount)；iCloud-only：\(report.iCloudOnlyCount)；缺縮圖：\(report.missingThumbnailCount)；預覽太小：\(report.insufficientPreviewCount)；不支援影片：\(report.unsupportedVideoCount)；OCR 錯誤：\(report.errorCount)。"
        let summary = "# 音樂截圖審閱清單\n\n狀態：\(report.status)\n相簿：\(report.resolvedAlbum?.pathLabel ?? "尚未解析")\n\(coverage)\n\n去重候選：\(report.songs.count)；需逐張確認：\(report.unresolvedImageCount)。所有配對均需確認，不代表已找到官方曲目，也未建立任何播放清單。JSON 保留每張的 OCR 原文、座標框與來源。\n\n\(rows)\n"
        try write(Data(summary.utf8), to: folder.appendingPathComponent("songs-review.md"))
    }
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

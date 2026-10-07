import AppKit
import Photos
import PhotoTriageCore

enum LibraryAccess: Equatable {
    case notRequested, authorized, limited, denied, restricted
    static func current() -> Self {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notRequested
        @unknown default: return .restricted
        }
    }
    var canRead: Bool { self == .authorized || self == .limited }
    var label: String {
        switch self {
        case .notRequested: return "尚未要求照片權限"
        case .authorized: return "照片已授權 · 旅遊相簿需確認"
        case .limited: return "僅可見獲授權的照片"
        case .denied: return "照片權限遭拒絕"
        case .restricted: return "照片權限受系統限制"
        }
    }
}

struct LibrarySnapshot {
    let records: [PhotoRecord]
    let albums: [Album]
    let assets: [String: PHAsset]
}

/// PhotoKit metadata and small thumbnail reads only. This type has no library-write API.
enum PhotoLibraryReader {
    static func fetch() -> LibrarySnapshot {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAllBurstAssets = true
        let fetch = PHAsset.fetchAssets(with: options)
        var assets: [String: PHAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video { assets[asset.localIdentifier] = asset }
        }
        var albums: [Album] = []
        var membership: [String: Set<String>] = [:]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let id = collection.localIdentifier
            albums.append(Album(id: id, title: collection.localizedTitle ?? "未命名相簿"))
            PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                membership[asset.localIdentifier, default: []].insert(id)
            }
        }
        let records = assets.values.map { asset in
            PhotoRecord(id: asset.localIdentifier, date: asset.creationDate,
                        coordinate: asset.location.map { Coordinate($0.coordinate.latitude, $0.coordinate.longitude) },
                        kind: asset.mediaType == .video ? .video : .image,
                        isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                        isFavorite: asset.isFavorite, burstID: asset.burstIdentifier,
                        albumIDs: membership[asset.localIdentifier] ?? [], duration: asset.duration,
                        width: asset.pixelWidth, height: asset.pixelHeight)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return LibrarySnapshot(records: records, albums: albums.sorted { $0.title < $1.title }, assets: assets)
    }
}

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var message = "載入本機縮圖…"
    private var requestID: PHImageRequestID?
    private var generation = UUID()
    private static let manager = PHCachingImageManager()
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    func load(_ asset: PHAsset?) {
        stop()
        let currentGeneration = generation
        image = nil
        guard let asset else { message = "照片目前不可見"; return }
        let key = asset.localIdentifier as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        message = "載入本機縮圖…"
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        let size = CGSize(width: 360, height: 280)
        requestID = Self.manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill,
                                              options: options) { [weak self] image, info in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                if let image {
                    self.image = image
                    Self.cache.setObject(image, forKey: key, cost: 360 * 280 * 4)
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    self.message = "僅在 iCloud\n未下載原始檔"
                } else if info?[PHImageErrorKey] != nil {
                    self.message = "縮圖無法讀取\n可重新整理再試"
                } else if (info?[PHImageCancelledKey] as? Bool) != true {
                    self.message = "沒有本機縮圖"
                }
            }
        }
    }
    func stop() {
        generation = UUID()
        if let requestID { Self.manager.cancelImageRequest(requestID) }
        requestID = nil
    }
}

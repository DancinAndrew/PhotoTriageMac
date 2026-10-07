import AppKit
import Photos
import SwiftUI
import PhotoTriageCore

enum ComparisonPreviewState: Equatable {
    case loading, ready(Int), cloud, unavailable, failed, timeout
    var message: String {
        switch self {
        case .loading: return "載入本機預覽…"
        case .ready(let edge): return edge < 1000 ? "只有低解析度本機預覽；不適合判斷細微焦點" : "本機預覽 · \(edge) 像素 · 非原始檔"
        case .cloud: return "素材僅在 iCloud；本程式未下載原始檔"
        case .unavailable: return "照片目前不可見，無法顯示預覽"
        case .failed: return "本機預覽讀取失敗；返回後可重新讀取再試"
        case .timeout: return "本機預覽逾時；未下載原始檔"
        }
    }
}

@MainActor final class ComparisonPreviewLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var state: ComparisonPreviewState = .loading
    private let manager = PHImageManager()
    private var request: PHImageRequestID?
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    static func options() -> PHImageRequestOptions {
        let value = PHImageRequestOptions()
        value.isNetworkAccessAllowed = false; value.deliveryMode = .highQualityFormat; value.resizeMode = .exact
        return value
    }
    func load(record: PhotoRecord, asset: PHAsset?) {
        stop(); image = nil; state = .loading
        if record.demoScene != nil { state = .ready(2048); return }
        if record.id == "demo:cloud" { state = .cloud; return }
        if record.id == "demo:failed" { state = .failed; return }
        guard let asset else { state = .unavailable; return }
        let token = generation
        request = manager.requestImage(for: asset, targetSize: CGSize(width: 2048, height: 2048),
            contentMode: .aspectFit, options: Self.options()) { [weak self] image, info in
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.timeout?.cancel()
                    if let image {
                        self.image = image
                        let edge = image.representations.compactMap { $0 as? NSBitmapImageRep }.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? Int(max(image.size.width, image.size.height))
                        self.state = .ready(edge)
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true { self.state = .cloud }
                    else if (info?[PHImageCancelledKey] as? Bool) != true { self.state = .failed }
                }
            }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.generation == token, self.image == nil else { return }
            self.stop(); self.state = .timeout
        }
    }
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        if let request { manager.cancelImageRequest(request) }; request = nil
    }
}

struct ComparisonPreview: View {
    let record: PhotoRecord
    let asset: PHAsset?
    var zoom: Double = 1
    @StateObject private var loader = ComparisonPreviewLoader()
    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                if record.demoScene != nil || loader.image != nil {
                    let ratio = Double(max(1, record.height)) / Double(max(1, record.width))
                    let width = min(geometry.size.width, geometry.size.height / ratio)
                    ScrollView([.horizontal, .vertical]) {
                        Group {
                            if let scene = record.demoScene { SampleScene(scene: scene) }
                            else if let image = loader.image { Image(nsImage: image).resizable().scaledToFit() }
                        }.frame(width: width * zoom, height: width * ratio * zoom)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }.background(.black.opacity(0.035))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: loader.state == .cloud ? "icloud.slash" : "photo.badge.exclamationmark").font(.largeTitle)
                        Text(loader.state.message).font(.caption).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
                }
            }
            Text(record.demoScene == nil ? loader.state.message : "虛構範例插圖").font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("comparisonPreviewStatus-\(record.id)").qaControl("comparisonPreviewStatus-\(record.id)")
        }.task(id: record.id) { loader.load(record: record, asset: asset) }.onDisappear { loader.stop() }
    }
}

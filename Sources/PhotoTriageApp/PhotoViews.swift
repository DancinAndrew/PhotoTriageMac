import AppKit
import Photos
import SwiftUI
import PhotoTriageCore

struct ThumbnailView: View {
    let record: PhotoRecord
    let asset: PHAsset?
    @StateObject private var loader = ThumbnailLoader()
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let scene = record.demoScene {
                    SampleScene(scene: scene)
                } else if record.id.hasPrefix("demo:") {
                    placeholder("僅在 iCloud（範例）\n未下載原始檔", symbol: "icloud.slash")
                } else if let image = loader.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    placeholder(loader.message, symbol: "photo")
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: record.id) { if !record.id.hasPrefix("demo:") { loader.load(asset) } }
        .onDisappear { loader.stop() }
    }
    private func placeholder(_ message: String, symbol: String) -> some View {
        ZStack {
            Color(red: 0.89, green: 0.92, blue: 0.90)
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.title2)
                Text(message).font(.system(size: 10)).multilineTextAlignment(.center)
            }.foregroundStyle(.secondary).padding(10)
        }
    }
}

/// Fictional illustrations drawn locally; never mistaken for the user's photos.
struct SampleScene: View {
    let scene: Int
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func fill(_ rect: CGRect, _ color: Color) { context.fill(Path(rect), with: .color(color)) }
            func ellipse(_ rect: CGRect, _ color: Color) { context.fill(Path(ellipseIn: rect), with: .color(color)) }
            func polygon(_ points: [CGPoint], _ color: Color) {
                var path = Path(); path.addLines(points); path.closeSubpath(); context.fill(path, with: .color(color))
            }
            switch scene {
            case 0:
                fill(CGRect(x: 0, y: 0, width: w, height: h), Color(red: 0.72, green: 0.84, blue: 0.83))
                ellipse(CGRect(x: w * 0.73, y: h * 0.12, width: 28, height: 28), Color(red: 0.99, green: 0.9, blue: 0.65))
                polygon([.init(x: 0, y: h * 0.8), .init(x: w * 0.25, y: h * 0.28), .init(x: w * 0.6, y: h), .init(x: 0, y: h)], Color(red: 0.34, green: 0.58, blue: 0.5))
                polygon([.init(x: w * 0.3, y: h), .init(x: w * 0.7, y: h * 0.36), .init(x: w, y: h * 0.9), .init(x: w, y: h)], Color(red: 0.21, green: 0.43, blue: 0.35))
                fill(CGRect(x: 0, y: h * 0.85, width: w, height: h * 0.15), Color(red: 0.7, green: 0.78, blue: 0.56))
            case 1:
                fill(CGRect(x: 0, y: 0, width: w, height: h), Color(red: 0.81, green: 0.82, blue: 0.88))
                for index in 0..<7 {
                    let x = Double(index) * w / 7, height = h * (0.38 + Double(index % 3) * 0.12)
                    fill(CGRect(x: x, y: h - height, width: w / 8, height: height), Color(red: 0.31 + Double(index % 2) * 0.1, green: 0.4, blue: 0.46))
                    for row in 0..<3 {
                        fill(CGRect(x: x + 6, y: h - height + Double(row) * 17 + 8, width: 6, height: 7), Color(red: 0.98, green: 0.86, blue: 0.59))
                    }
                }
                fill(CGRect(x: 0, y: h * 0.9, width: w, height: h * 0.1), Color(red: 0.23, green: 0.3, blue: 0.33))
            case 2:
                fill(CGRect(x: 0, y: 0, width: w, height: h), Color(red: 0.79, green: 0.65, blue: 0.52))
                ellipse(CGRect(x: w * 0.21, y: h * 0.08, width: w * 0.62, height: h * 0.84), .white.opacity(0.9))
                ellipse(CGRect(x: w * 0.31, y: h * 0.21, width: w * 0.4, height: h * 0.57), Color(red: 0.90, green: 0.70, blue: 0.36))
                for index in 0..<5 {
                    ellipse(CGRect(x: w * 0.34 + Double(index % 3) * 20, y: h * 0.31 + Double(index / 3) * 23, width: 19, height: 16), Color(red: 0.33, green: 0.50, blue: 0.3))
                }
            case 3:
                fill(CGRect(x: 0, y: 0, width: w, height: h), Color(red: 0.67, green: 0.82, blue: 0.9))
                fill(CGRect(x: 0, y: h * 0.4, width: w, height: h * 0.4), Color(red: 0.21, green: 0.61, blue: 0.69))
                fill(CGRect(x: 0, y: h * 0.8, width: w, height: h * 0.2), Color(red: 0.94, green: 0.85, blue: 0.65))
                polygon([.init(x: w * 0.5, y: h * 0.57), .init(x: w * 0.5, y: h * 0.18), .init(x: w * 0.74, y: h * 0.57)], .white)
                polygon([.init(x: w * 0.44, y: h * 0.62), .init(x: w * 0.8, y: h * 0.62), .init(x: w * 0.73, y: h * 0.72), .init(x: w * 0.51, y: h * 0.72)], Color(red: 0.63, green: 0.33, blue: 0.25))
            default:
                fill(CGRect(x: 0, y: 0, width: w, height: h), Color(red: 0.87, green: 0.88, blue: 0.86))
                fill(CGRect(x: w * 0.24, y: 8, width: w * 0.52, height: h - 16), .white)
                fill(CGRect(x: w * 0.24, y: 8, width: w * 0.52, height: 21), Theme.accent)
                context.draw(Text("範例備忘錄").font(.system(size: 9)).foregroundColor(.white), at: .init(x: w * 0.5, y: 19))
                for index in 0..<5 {
                    fill(CGRect(x: w * 0.29, y: 40 + Double(index) * 13, width: w * (index % 2 == 0 ? 0.37 : 0.28), height: 4), .gray.opacity(0.3))
                }
            }
            context.draw(Text("範例插圖").font(.system(size: 8)).foregroundColor(.white), at: .init(x: w - 25, y: h - 9))
        }
    }
}

struct PhotoCard: View {
    @EnvironmentObject var model: AppModel
    let record: PhotoRecord
    var body: some View {
        let chosen = model.selected.contains(record.id)
        let decision = model.document.decision(for: record.id)
        Button { model.select(record.id, modifiers: NSEvent.modifierFlags) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ThumbnailView(record: record, asset: model.assets[record.id]).frame(height: 136).clipped()
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Theme.accent : .white.opacity(0.85))
                        .font(.system(size: 19)).background(.white.opacity(chosen ? 1 : 0), in: Circle()).padding(8)
                    if record.kind == .video {
                        Text("▶ \(Int(record.duration))s").font(.system(size: 10)).padding(5)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(7)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.date.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "拍攝時間未知")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        if record.isScreenshot { Image(systemName: "camera.viewfinder") }
                        if record.isFavorite { Image(systemName: "heart.fill") }
                        if decision.isTemporary { Image(systemName: "clock") }
                        Text(decision.status.label); Spacer(minLength: 0)
                        if model.locallyClassifiedIDs.contains(record.id) { Image(systemName: "rectangle.stack.fill") }
                        if !decision.albumPlans.isEmpty { Image(systemName: "rectangle.stack.badge.plus") }
                    }.font(.system(size: 9)).foregroundStyle(decision.status == .deleteCandidate ? .red : .secondary)
                }.padding(10)
            }.background(.white, in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(chosen ? Theme.accent : .black.opacity(0.07), lineWidth: chosen ? 2 : 1))
        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: GalleryFramesKey.self,
                                       value: [record.id: geometry.frame(in: .named("galleryViewport"))])
            })
            .accessibilityLabel("\(record.isScreenshot ? "截圖" : record.kind == .video ? "影片" : "照片")，\(record.date?.formatted() ?? "時間未知")，\(decision.status.label)，\(model.classificationLabel(for: record.id))")
            .accessibilityValue(chosen ? "已選取" : "未選取").accessibilityIdentifier("photo-\(record.id)")
    }
}

struct PhotoInspector: View {
    @EnvironmentObject var model: AppModel
    let record: PhotoRecord
    var body: some View {
        let decision = model.document.decision(for: record.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("照片資訊").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { model.closeInspector() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("收合照片資訊，不清除選取")
                        .accessibilityLabel("收合照片資訊").accessibilityIdentifier("closeInspector")
                }
                ThumbnailView(record: record, asset: model.assets[record.id]).frame(height: 145)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                info("拍攝時間", record.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "未知")
                info("位置", record.coordinate?.label ?? "未知（未推測地點）")
                info("尺寸／類型", "\(record.width) × \(record.height) · \(record.kind == .video ? "影片" : "照片")")
                if record.isScreenshot { Label("螢幕截圖", systemImage: "camera.viewfinder").font(.caption) }
                if record.isFavorite { Label("照片庫中的喜好項目", systemImage: "heart.fill").font(.caption) }
                Divider()
                info("審閱狀態", decision.status.label + (decision.isTemporary ? " · 暫時用途" : ""))
                info("分類歸屬", model.classificationLabel(for: record.id))
                info("事件", model.group(for: record)?.title ?? "未分組")
                let names = model.albums.filter { record.albumIDs.contains($0.id) }.map(\.title)
                info("既有相簿", names.isEmpty ? "沒有可見使用者相簿" : names.joined(separator: "、"))
                let local = model.organizerAlbums.filter { $0.assetIDs.contains(record.id) }
                info("本機相簿", local.isEmpty ? "尚未分類" : local.map(\.title).joined(separator: "、"))
                if !decision.albumPlans.isEmpty { info("相簿計畫（未寫入）", decision.albumPlans.map(\.title).joined(separator: "、")) }
                Text("本機相簿調整尚未同步到 Apple 照片。加入或移出相簿不刪除照片。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(16)
        }.background(.white.opacity(0.6))
    }
    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).textSelection(.enabled)
        }
    }
}

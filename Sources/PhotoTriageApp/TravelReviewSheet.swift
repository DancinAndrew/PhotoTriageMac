import SwiftUI
import PhotoTriageCore

struct TravelReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("旅遊行程 · 跨日分類").font(.title2.bold())
            Text("掃描可見照片的時間與 GPS，再以本機縮圖判讀旅行場景。按返家、國家／島嶼與連續時間形成一次行程，無定位或證據不足的照片留給人工確認。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("重新分析可見照片") { model.analyzeTravel() }
                    .buttonStyle(.borderedProminent).disabled(model.travelProgress != nil || !model.access.canRead)
                    .accessibilityIdentifier("analyzeTravel")
                if let report = model.travelReport {
                    Text("\(report.assets.count) 個可見項目 · \(report.analysis?.geotaggedCount ?? 0) 個有效定位").font(.caption)
                }
            }
            if let progress = model.travelProgress { ProgressView(progress) }
            if let error = model.travelError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.travelReport?.analysis?.trips ?? []) { trip in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(trip.title).font(.headline)
                                Spacer(); Text(trip.canCreateAlbum ? "可建立 · \(trip.assetIDs.count) 張" : "人工確認 · \(trip.assetIDs.count) 張")
                                    .foregroundStyle(trip.canCreateAlbum ? Theme.accent : .secondary).font(.caption)
                            }
                            HStack {
                                ForEach(trip.sampleIDs, id: \.self) { id in
                                    if let record = model.records.first(where: { $0.id == id }) {
                                        ThumbnailView(record: record, asset: model.assets[id]).frame(width: 145, height: 100).clipped()
                                    }
                                }
                            }
                            Text(trip.reasons.joined(separator: "；")).font(.caption).foregroundStyle(.secondary)
                            Button("瀏覽行程與待確認照片") { model.setTravelTrip(trip); dismiss() }.font(.caption)
                        }
                        Divider()
                    }
                    if model.travelReport?.analysis?.trips.isEmpty != false {
                        Text("尚無旅遊判讀結果。需要照片授權及本機可讀預覽；不會將未知地點猜成特定旅行。")
                            .foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            }.frame(height: 340)
            Text("旅遊判讀是分類建議。瀏覽後可加入本機相簿；本版本不會寫入 Apple 照片相簿。")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 820).tint(Theme.accent).onAppear { model.loadTravelReport() }
    }
}

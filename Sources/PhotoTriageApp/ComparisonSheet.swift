import SwiftUI
import PhotoTriageCore

struct ComparisonSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let batch: ComparisonBatch
    @State private var keepers: Set<String> = []
    @State private var zoomedID: String?
    @State private var zoom = 1.0
    @State private var error: String?
    private var photos: [PhotoRecord] { batch.assetIDs.compactMap { id in model.records.first { $0.id == id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("並排挑選 · \(photos.count) 張").font(.title2.bold())
                Spacer()
                Text("1–6 切換保留 · C 開啟比較 · Esc 返回／取消").font(.caption).foregroundStyle(.secondary)
            }
            Text("先明確指定保留哪些照片，再將其餘加入本機待刪候選。相似不代表可以刪除；照片、相簿歸屬與原始檔都保留。")
                .font(.callout).foregroundStyle(.secondary)
            if let id = zoomedID, let record = photos.first(where: { $0.id == id }) {
                HStack {
                    Text("放大查看 · \(record.date?.formatted(date: .abbreviated, time: .shortened) ?? "時間未知")")
                    Spacer()
                    ForEach([1.0, 2, 4], id: \.self) { value in
                        Button("\(Int(value))×") { zoom = value }.accessibilityIdentifier("comparisonZoom-\(Int(value))").qaControl("comparisonZoom-\(Int(value))")
                    }
                    keepButton(record, index: batch.assetIDs.firstIndex(of: id) ?? 0)
                }
                ComparisonPreview(record: record, asset: model.assets[id], zoom: zoom).frame(height: 460)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: photos.count == 2 ? 2 : 3), spacing: 14) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, record in
                        VStack(alignment: .leading, spacing: 8) {
                            ComparisonPreview(record: record, asset: model.assets[record.id]).frame(height: photos.count <= 3 ? 330 : 185)
                            HStack {
                                Text("\(index + 1) · \(record.date?.formatted(.dateTime.month().day().hour().minute()) ?? "時間未知")").font(.caption)
                                Spacer()
                                Button { zoomedID = record.id; zoom = 1 } label: { Image(systemName: "plus.magnifyingglass") }
                                    .help("放大本機預覽").accessibilityIdentifier("comparisonEnlarge-\(record.id)").qaControl("comparisonEnlarge-\(record.id)")
                            }
                            HStack {
                                keepButton(record, index: index)
                                Spacer()
                                Text("原標記：\(model.document.decision(for: record.id).status.label)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(10).background(keepers.contains(record.id) ? Theme.accent.opacity(0.08) : .white,
                                                   in: RoundedRectangle(cornerRadius: 10))
                    }
                }.frame(maxHeight: .infinity)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).accessibilityIdentifier("comparisonError").qaControl("comparisonError") }
            Divider()
            HStack {
                Button(zoomedID == nil ? "取消" : "返回並排") {
                    if zoomedID != nil { zoomedID = nil; zoom = 1 }
                    else { model.comparison = nil; dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("comparisonBack").qaControl("comparisonBack")
                Text("保留 \(keepers.count) · 其餘候選 \(batch.assetIDs.count - keepers.count)").font(.caption).monospacedDigit()
                    .accessibilityIdentifier("comparisonDecisionCounts").qaControl("comparisonDecisionCounts")
                Spacer()
                Button("保留所選，其餘加入待刪候選") {
                    do { if try model.completeComparison(batch, keepers: keepers) { dismiss() } }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(keepers.isEmpty || !model.canReview || photos.count != batch.assetIDs.count)
                    .accessibilityIdentifier("confirmComparison").qaControl("confirmComparison")
            }
            Text("放大使用最高 2048 像素的本機預覽，不下載原始檔；⌘Z 可整批恢復原標記。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 940, height: 680).background(Theme.paper).tint(Theme.accent)
    }
    private func keepButton(_ record: PhotoRecord, index: Int) -> some View {
        Button {
            if keepers.contains(record.id) { keepers.remove(record.id) } else { keepers.insert(record.id) }
        } label: {
            Label(keepers.contains(record.id) ? "已選保留" : "選為保留", systemImage: keepers.contains(record.id) ? "checkmark.circle.fill" : "circle")
        }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
            .accessibilityIdentifier("comparisonKeep-\(record.id)").qaControl("comparisonKeep-\(record.id)")
            .accessibilityValue(keepers.contains(record.id) ? "保留" : "未指定")
    }
}

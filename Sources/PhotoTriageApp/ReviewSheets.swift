import SwiftUI
import PhotoTriageCore

struct AlbumPlanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var target = "new"
    @State private var title = ""
    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("加入相簿計畫").font(.title2.bold())
            Text("為 \(model.selected.count) 個項目規劃相簿。只儲存計畫，不會建立或修改照片相簿。")
                .foregroundStyle(.secondary)
            Picker("目的相簿", selection: $target) {
                Text("規劃新相簿").tag("new")
                ForEach(model.albums) { Text($0.title).tag($0.id) }
            }
            if target == "new" { TextField("新相簿名稱", text: $title).textFieldStyle(.roundedBorder) }
            Label("相簿是參照；照片仍在「所有照片」與其他相簿。", systemImage: "info.circle").font(.callout)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("儲存計畫") {
                    let existing = model.albums.first { $0.id == target }
                    let name = existing?.title ?? trimmed
                    let plan = AlbumPlan(id: existing?.id ?? "new:\(name)", title: name, isNew: existing == nil)
                    model.stageAlbum(plan); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty || !model.canReview || (target == "new" && trimmed.isEmpty))
                    .accessibilityIdentifier("saveAlbumPlan")
            }
        }.padding(28).frame(width: 550).tint(Theme.accent)
    }
}

struct GroupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var target = "new"
    @State private var title = ""
    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("改派事件").font(.title2.bold())
            Text("把 \(model.selected.count) 個選取項目放入正確的事件；不變更照片庫相簿。")
                .foregroundStyle(.secondary)
            Picker("目的事件", selection: $target) {
                Text("建立自訂事件").tag("new")
                ForEach(model.groups) { Text("\($0.title) · \($0.assetIDs.count) 個").tag($0.id) }
            }
            if target == "new" { TextField("事件名稱，例如：台南週末", text: $title).textFieldStyle(.roundedBorder) }
            if target.hasPrefix("suggested:") {
                Text("目的事件的既有成員會一起固定為手動分組，之後不隨建議變動。整批可用 ⌘Z 復原。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("恢復自動建議") { model.restoreSuggestedGroup(); dismiss() }
                    .disabled(model.selected.isEmpty || !model.canReview)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存分組") {
                    let destination = model.groups.first { $0.id == target }
                    model.assignGroup(title: destination?.title ?? trimmed, existingID: destination?.id)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty || !model.canReview || (target == "new" && trimmed.isEmpty))
                    .accessibilityIdentifier("saveGroup")
            }
        }.padding(28).frame(width: 590).tint(Theme.accent)
    }
}

struct ReviewPlanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    private var planned: [PhotoRecord] {
        model.records.filter {
            let decision = model.document.decision(for: $0.id)
            return decision.status == .deleteCandidate || !decision.albumPlans.isEmpty
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本機審閱計畫").font(.title2.bold())
            Label("一般相簿計畫與待刪仍是本機標記；旅遊相簿由專用確認畫面建立", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(Theme.accent)
            Text("\(model.planCount) 個相簿參照計畫 · \(model.queueCount) 個待刪候選。照片內容不會包含在匯出檔中。")
                .font(.callout).foregroundStyle(.secondary)
            if !model.unavailableDecisionIDs.isEmpty {
                Text("另有 \(model.unavailableDecisionIDs.count) 個審閱記錄目前無對應的可見照片（可能是權限或照片庫變動）。記錄已保留，匯出時會列出。")
                    .font(.callout).foregroundStyle(.orange)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if planned.isEmpty {
                        Text("尚無可見照片的相簿或待刪計畫。\n選取照片後用 A 或 D 開始。")
                            .foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    ForEach(planned) { record in
                        let decision = model.document.decision(for: record.id)
                        HStack(spacing: 12) {
                            ThumbnailView(record: record, asset: model.assets[record.id]).frame(width: 78, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.date?.formatted() ?? "拍攝時間未知").font(.caption)
                                if decision.status == .deleteCandidate { Text("待刪候選 · 尚未刪除").font(.caption).foregroundStyle(.red) }
                                ForEach(decision.albumPlans, id: \.id) { plan in
                                    Text("→ \(plan.title)\(plan.isNew ? "（規劃新相簿）" : "") · 未寫入").font(.caption)
                                }
                            }
                            Spacer()
                            if decision.status == .deleteCandidate {
                                Button("移出佇列") { model.removeFromQueue(ids: [record.id]) }
                            }
                            if !decision.albumPlans.isEmpty {
                                Button("移除計畫") { model.removeAlbumPlans(ids: [record.id]) }
                            }
                        }.controlSize(.small)
                    }
                }
            }.frame(height: 330)
            Divider()
            HStack {
                Button("匯出計畫 JSON…") { model.exportPlan() }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 750).tint(Theme.accent)
    }
}

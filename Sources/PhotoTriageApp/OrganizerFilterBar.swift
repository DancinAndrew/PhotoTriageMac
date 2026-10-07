import SwiftUI
import PhotoTriageCore

struct OrganizerFilterBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                Picker("媒體", selection: $model.filter.media) {
                    Text("全部類型").tag(MediaKind?.none)
                    Text("照片").tag(MediaKind?.some(.image))
                    Text("影片").tag(MediaKind?.some(.video))
                }.frame(width: 145).accessibilityIdentifier("filterMedia").qaControl("filterMedia")
                Picker("審閱", selection: $model.filter.reviewStatus) {
                    Text("全部狀態").tag(ReviewStatus?.none)
                    ForEach(ReviewStatus.allCases, id: \.self) { status in
                        Text(status.label).tag(ReviewStatus?.some(status))
                    }
                }.frame(width: 200).accessibilityIdentifier("filterReviewStatus").qaControl("filterReviewStatus")
                Toggle("截圖", isOn: $model.filter.screenshotsOnly).accessibilityIdentifier("filterScreenshots").qaControl("filterScreenshots")
                Spacer()
                Button("清除全部條件") { model.resetFilter() }.accessibilityIdentifier("clearAllFilters").qaControl("clearAllFilters")
            }
            HStack(spacing: 13) {
                Toggle("尚無分類歸屬", isOn: $model.filter.unclassifiedOnly)
                Toggle("暫時用途", isOn: $model.filter.temporaryOnly)
                Toggle("密集拍攝", isOn: $model.filter.rapidShotsOnly)
                Toggle("日期範圍", isOn: Binding(get: { model.useDateRange }, set: { model.setDateRangeEnabled($0) }))
                    .accessibilityIdentifier("filterDateRange").qaControl("filterDateRange")
                Toggle("時間未知", isOn: Binding(get: { model.filter.unknownDateOnly }, set: { model.setUnknownDateOnly($0) }))
            }
            if model.useDateRange {
                HStack {
                    DatePicker("從", selection: $model.rangeStart, displayedComponents: .date)
                    DatePicker("到", selection: $model.rangeEnd, displayedComponents: .date)
                    if model.rangeStart > model.rangeEnd { Text("起日需早於迄日").foregroundStyle(.red) }
                }.frame(maxWidth: 600)
            }
            if model.activeFilterChips.isEmpty {
                Text("相簿、媒體、審閱與日期可同時篩選。分類歸屬和審閱狀態分開記錄。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.activeFilterChips, id: \.kind) { chip in
                            Button { model.removeFilterChip(chip.kind) } label: {
                                HStack(spacing: 5) { Text(chip.title); Image(systemName: "xmark").font(.system(size: 8)) }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Theme.accent.opacity(0.09), in: Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("移除條件：\(chip.title)")
                                .accessibilityIdentifier("filterChip-\(chip.kind.rawValue)").qaControl("filterChip-\(chip.kind.rawValue)")
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("activeFilterChips").qaControl("activeFilterChips")
            }
            if model.filter.rapidShotsOnly {
                Text("密集拍攝只依時間、位置或連拍資訊提示，尚未比對畫面，不能判定重複。")
                    .foregroundStyle(.secondary)
            }
        }.toggleStyle(.checkbox).font(.system(size: 11)).padding(.horizontal, 22).padding(.bottom, 13)
    }
}

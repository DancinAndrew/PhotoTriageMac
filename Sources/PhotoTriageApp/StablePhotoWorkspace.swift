import SwiftUI

struct GalleryFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
private struct GalleryReporterKey: EnvironmentKey {
    static var defaultValue: (([String: CGRect]) -> Void)? = nil
}
extension EnvironmentValues {
    var galleryFrameReporter: (([String: CGRect]) -> Void)? {
        get { self[GalleryReporterKey.self] }
        set { self[GalleryReporterKey.self] = newValue }
    }
}

/// The inspector always owns the same width. Selection never changes the grid proposal.
struct StablePhotoWorkspace: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.galleryFrameReporter) private var reportFrames
    var body: some View {
        HStack(spacing: 0) {
            grid.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector.frame(width: 248).frame(maxHeight: .infinity, alignment: .top)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(GalleryFramesKey.self) { reportFrames?($0) }
    }
    private var grid: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if model.visible.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text(model.records.isEmpty ? "沒有可見照片" : "這個相簿或篩選沒有照片").font(.title3)
                            Button("全部照片") { model.setScope(.all) }
                        }.frame(width: geometry.size.width).padding(.vertical, 95)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 166, maximum: 225), spacing: 14)], spacing: 16) {
                            ForEach(model.visible) { record in
                                PhotoCard(record: record).id(record.id)
                            }
                        }.frame(width: max(1, geometry.size.width - 44), alignment: .topLeading).padding(22)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .coordinateSpace(name: "galleryViewport")
                    .accessibilityIdentifier("photoGridViewport")
                    .onChange(of: model.scrollTargetID) { _, id in
                        // Only explicit keyboard navigation requests scrolling, never a mouse click or Select All.
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
            }
        }
    }
    private var inspector: some View {
        Group {
            if model.inspectorVisible, let record = model.focusedRecord {
                PhotoInspector(record: record)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("照片資訊").font(.system(size: 13, weight: .semibold))
                    Text(model.focusedRecord == nil ? "選取照片查看資訊。" : "照片資訊已收合。")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.focusedRecord != nil {
                        Button("顯示照片資訊") { model.inspectorVisible = true }.accessibilityIdentifier("showInspector")
                    }
                    Spacer()
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.background(.white.opacity(0.65)).accessibilityIdentifier("photoInspectorSlot")
    }
}

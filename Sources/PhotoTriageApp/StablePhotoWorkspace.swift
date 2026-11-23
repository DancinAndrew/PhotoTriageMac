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

/// The grid uses the entire workspace unless information is enabled with a selected photo.
struct StablePhotoWorkspace: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.galleryFrameReporter) private var reportFrames
    var body: some View {
        HStack(spacing: 0) {
            grid.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.shouldShowInspector, let record = model.focusedRecord {
                Divider()
                PhotoInspector(record: record).frame(width: 248).frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier("photoInspectorSlot").qaControl("photoInspectorSlot")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(GalleryFramesKey.self) { model.recordGalleryFrames($0); reportFrames?($0) }
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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbnailSize.minimumWidth, maximum: model.thumbnailSize.maximumWidth), spacing: 14)], spacing: 16) {
                            ForEach(model.visible) { record in
                                PhotoCard(record: record).id(record.id)
                            }
                        }.frame(width: max(1, geometry.size.width - 44), alignment: .topLeading).padding(22)
                    }
                    Color.clear.frame(height: 0).background(GalleryScrollPersistence(model: model))
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .coordinateSpace(name: "galleryViewport")
                    .accessibilityIdentifier("photoGridViewport").qaControl("photoGridViewport")
                    .onChange(of: model.scrollTargetID) { _, id in
                        // Only explicit keyboard navigation requests scrolling, never a mouse click or Select All.
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .task(id: model.viewportAnchorToMount.map { $0 + ":" + model.thumbnailSize.rawValue + ":" + String(model.shouldShowInspector) }) {
                        guard let id = model.viewportAnchorToMount else { return }
                        // Mount distant lazy rows first, then restore the saved offset once.
                        proxy.scrollTo(id, anchor: .top)
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        model.completeAnchorMount(id)
                    }
            }
        }
    }
}

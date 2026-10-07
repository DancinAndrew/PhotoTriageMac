import SwiftUI
import PhotoTriageCore

struct LocalAlbumSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let action: AlbumAction
    @State private var name = ""
    @State private var target = "new"
    @State private var includeSelection = false
    @State private var error: String?
    private var isAdding: Bool { action == .addSelection || action == .addSelectionAndComplete }
    private var album: OrganizerAlbum? {
        switch action {
        case .rename(let id), .delete(let id): return model.organizerAlbums.first { $0.id == id }
        default: return nil
        }
    }
    private var title: String {
        switch action {
        case .create: return "新增相簿"
        case .rename: return "重新命名相簿"
        case .delete: return "移除本機相簿"
        case .addSelection: return "加入相簿"
        case .addSelectionAndComplete: return "加入相簿並完成這批"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            if case .delete = action {
                Text("移除「\(album?.title ?? "")」？").font(.headline)
                Text("只移除本程式中的相簿／分類，所有照片與其他相簿都保留。Apple 照片中的來源相簿也會保留。可用 ⌘Z 或『復原相簿操作』恢復。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if isAdding {
                    Text("將選取的 \(model.selected.count) 張照片加入本機相簿。")
                    Picker("目的相簿", selection: $target) {
                        Text("新增相簿…").tag("new")
                        ForEach(model.organizerAlbums.filter { !$0.sourceUnavailable }) { value in
                            Text(pickerLabel(value)).tag(value.id)
                        }
                    }.accessibilityIdentifier("localAlbumTarget")
                }
                if !isAdding || target == "new" {
                    TextField("相簿名稱", text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("localAlbumName")
                }
                if action == .create, !model.selected.isEmpty {
                    Toggle("一併加入目前選取的 \(model.selected.count) 張照片", isOn: $includeSelection)
                }
                Text("分類調整儲存在本機，尚未同步到 Apple 照片。照片仍留在全部照片與其他相簿。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if isAdding {
                    Text("只加入：審閱狀態不變。加入並完成：只把這批的未審閱改為已完成，保留既有保留／待刪標記；⌘Z 一起復原歸屬與審閱。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !model.recentDestinationAlbums.isEmpty {
                        HStack {
                            Text("最近：")
                            ForEach(model.recentDestinationAlbums.prefix(3)) { value in
                                Button(value.title) { target = value.id }.lineLimit(1)
                            }
                        }.font(.caption).accessibilityIdentifier("recentAlbumDestinations")
                    }
                }
            }
            if let album {
                Text("\(model.visibleAlbumCount(album)) 張可見照片 · \(album.sourceLabel)").font(.caption).foregroundStyle(.secondary)
                if !album.origins.isEmpty {
                    Text("原始來源：" + album.origins.map(\.title).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("localAlbumValidationError") }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelLocalAlbum")
                Spacer()
                if isAdding {
                    Button("只加入相簿") { save(completeReview: false) }
                        .keyboardShortcut(action == .addSelection ? KeyboardShortcut.defaultAction : nil)
                        .disabled(!model.canManageAlbums || model.actionableAlbumIDs.isEmpty)
                        .accessibilityIdentifier("confirmLocalAlbum")
                    Button("加入並完成這批") { save(completeReview: true) }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(action == .addSelectionAndComplete ? KeyboardShortcut.defaultAction : nil)
                        .disabled(!model.canManageAlbums || model.actionableAlbumIDs.isEmpty)
                        .accessibilityIdentifier("confirmAlbumAndComplete")
                } else {
                    Button(title) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!model.canManageAlbums).accessibilityIdentifier("confirmLocalAlbum")
                }
            }
        }.padding(26).frame(width: 540).tint(Theme.accent)
            .onAppear { name = album?.title ?? ""; if isAdding { target = model.preferredDestinationID } }
    }
    private func pickerLabel(_ value: OrganizerAlbum) -> String {
        let duplicated = model.organizerAlbums.filter { $0.title == value.title }.count > 1
        let suffix = duplicated ? " · " + String(value.origins.first?.id.prefix(8) ?? value.id.prefix(8)) : ""
        return "\(value.title) · \(model.visibleAlbumCount(value)) 張 · \(value.sourceLabel)\(suffix)"
    }
    private func save(completeReview: Bool = false) {
        do {
            switch action {
            case .create: _ = try model.createLocalAlbum(title: name, includeSelection: includeSelection)
            case .rename(let id): try model.renameLocalAlbum(id: id, title: name)
            case .delete(let id): try model.deleteLocalAlbum(id: id)
            case .addSelection, .addSelectionAndComplete:
                if target == "new" { _ = try model.createLocalAlbum(title: name, includeSelection: true, completeReview: completeReview) }
                else { try model.addSelectionToAlbum(id: target, completeReview: completeReview) }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

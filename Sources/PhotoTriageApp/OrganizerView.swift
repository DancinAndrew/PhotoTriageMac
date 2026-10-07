import AppKit
import SwiftUI
import PhotoTriageCore

enum Theme {
    static let ink = Color(red: 0.13, green: 0.22, blue: 0.23)
    static let accent = Color(red: 0.04, green: 0.42, blue: 0.37)
    static let paper = Color(red: 0.96, green: 0.97, blue: 0.95)
}

struct OrganizerView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 215)
            Divider()
            VStack(spacing: 0) {
                header
                OrganizerFilterBar()
                Divider()
                if let error = model.persistenceError ?? model.localAlbumError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout)
                        .foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = model.destinationError {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                }
                if model.isLoading {
                    Spacer(); ProgressView("讀取可見照片與相簿…"); Spacer()
                } else if !model.isDemo && !model.access.canRead {
                    accessPanel
                } else {
                    StablePhotoWorkspace()
                }
                actionBar
                HStack {
                    Text(model.notice).lineLimit(2)
                    Spacer()
                    Text(model.isDemo ? "範例資料" : "本機分類 · 尚未同步 Apple 照片").foregroundStyle(.secondary)
                }.font(.system(size: 10)).padding(.horizontal, 20).padding(.vertical, 10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.paper)
        }.tint(Theme.accent).foregroundStyle(Theme.ink)
            .sheet(item: $model.albumAction) { LocalAlbumSheet(action: $0).environmentObject(model) }
            .sheet(isPresented: $model.showAlbumSheet) { AlbumPlanSheet().environmentObject(model) }
            .sheet(isPresented: $model.showGroupSheet) { GroupSheet().environmentObject(model) }
            .sheet(isPresented: $model.showPlanSheet) { ReviewPlanSheet().environmentObject(model) }
            .sheet(isPresented: $model.showMusicSheet) { MusicReviewSheet().environmentObject(model) }
            .task {
                if CommandLine.arguments.contains("--connect-photos") { model.connect() }
                DemoUICapture.schedule(model)
            }
            .onChange(of: model.focusedID) { _, _ in DemoUICapture.schedule(model) }
            .onChange(of: model.inspectorVisible) { _, _ in DemoUICapture.schedule(model) }
            .onChange(of: model.organizerAlbums) { _, _ in DemoUICapture.schedule(model) }
            .onChange(of: model.filter) { _, _ in model.filterChanged() }
            .onChange(of: model.useDateRange) { _, enabled in
                if enabled { model.filter.unknownDateOnly = false }
                model.filterChanged()
            }
            .onChange(of: model.rangeStart) { _, _ in model.filterChanged() }
            .onChange(of: model.rangeEnd) { _, _ in model.filterChanged() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("相片整理").font(.system(size: 21, weight: .semibold))
                    Text(model.isDemo ? "PHOTO TRIAGE · 範例" : "PHOTO TRIAGE").font(.system(size: 9, design: .monospaced))
                }
            }.padding(18)
            ForEach([ReviewScope.all, .unclassified, .screenshots]) { scopeButton($0) }
            Menu {
                ForEach([ReviewScope.unreviewed, .kept, .organized, .temporary, .rapidShots, .deleteQueue]) { scope in
                    Button("\(scope.label) · \(model.count(scope))") { model.setScope(scope) }
                }
            } label: { Label("更多篩選", systemImage: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 10)
            Divider().padding(.vertical, 12)
            HStack {
                Text("相簿").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.albumAction = .create } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("新增本機相簿").disabled(!model.canManageAlbums)
                    .accessibilityLabel("新增相簿").accessibilityIdentifier("newLocalAlbum")
            }.padding(.horizontal, 18).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.organizerAlbums) { album in
                        albumButton(album)
                    }
                    if model.organizerAlbums.isEmpty {
                        Text("按 + 建立第一個相簿").font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }.padding(.horizontal, 9)
            }.accessibilityIdentifier("unifiedAlbumList")
            Divider()
            Button(model.isDemo ? "連線 Apple 照片…" : "重新讀取照片") { model.connect() }
                .buttonStyle(.bordered).disabled(model.isLoading).accessibilityIdentifier("connectPhotos").padding(14)
        }.frame(maxHeight: .infinity).background(.white)
    }
    private func scopeButton(_ scope: ReviewScope) -> some View {
        let active = model.scopeIsActive(scope)
        return Button { model.setScope(scope) } label: {
            HStack(spacing: 8) {
                Image(systemName: scope.symbol).frame(width: 16)
                Text(scope == .unclassified ? "未分類" : scope.label); Spacer()
                Text("\(model.count(scope))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: active ? .semibold : .regular)).padding(.horizontal, 13).padding(.vertical, 9)
                .background(active ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("scope-\(scope.rawValue)").padding(.horizontal, 7)
    }
    private func albumButton(_ album: OrganizerAlbum) -> some View {
        Button { model.setOrganizerAlbum(album.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack").frame(width: 16)
                Text(album.title).lineLimit(2)
                Spacer(minLength: 3)
                Text("\(model.visibleAlbumCount(album))").monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.selectedOrganizerAlbumID == album.id ? Theme.accent.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("organizer-album-\(album.id)")
            .contextMenu {
                Button("重新命名…") { model.albumAction = .rename(album.id) }
                Button("移除本機相簿…") { model.albumAction = .delete(album.id) }
            }
    }
    private var title: String {
        if let album = model.currentOrganizerAlbum { return album.title }
        return "全部照片"
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 25, weight: .semibold))
                Text("\(model.visible.count) 張照片" + (model.currentOrganizerAlbum.map { " · " + $0.sourceLabel } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let album = model.currentOrganizerAlbum {
                Menu("相簿…") {
                    Button("重新命名…") { model.albumAction = .rename(album.id) }
                    Button("移除本機相簿…") { model.albumAction = .delete(album.id) }
                }.accessibilityIdentifier("currentAlbumMenu")
            }
            Button("全選目前篩選（\(model.visible.count)）") { model.selectAll() }
                .buttonStyle(.bordered).disabled(!model.canSelectVisible).accessibilityIdentifier("selectAllVisible")
            Button { model.inspectorVisible.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.bordered).disabled(model.focusedID == nil).help("顯示／收合照片資訊")
                .accessibilityIdentifier("toggleInspector")
            Menu {
                Button("復原相簿操作") { model.undoLocalAlbum() }.disabled(model.localAlbums.history.isEmpty || !model.canManageAlbums)
                Button("既有審閱紀錄…") { model.showPlanSheet = true }
                if !model.isDemo { Button("音樂 OCR…") { model.showMusicSheet = true }.disabled(!model.access.canRead) }
                if !model.isDemo { Button("使用範例資料") { model.loadDemo() } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityIdentifier("organizerTools")
        }.padding(.horizontal, 22).padding(.vertical, 18)
    }
    private var accessPanel: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.rectangle.stack").font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text(model.access.label).font(.title2)
            Text("需由你批准 macOS 照片權限，才能顯示照片庫。\n可拒絕或繼續使用範例；本程式不會繞過權限。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("重新檢查權限") { model.connect() }
                Button("使用範例") { model.loadDemo() }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private var actionBar: some View {
        VStack(spacing: 7) {
            Divider()
            HStack(spacing: 9) {
                Text("已選 \(model.selected.count) / \(model.visible.count)").font(.caption).monospacedDigit()
                    .frame(minWidth: 98, alignment: .leading).accessibilityIdentifier("selectionCount")
                Button("加入相簿… A") { model.albumAction = .addSelection }
                    .buttonStyle(.borderedProminent).disabled(!model.canAct || !model.canManageAlbums)
                    .accessibilityIdentifier("addToLocalAlbum")
                if let destination = model.repeatDestinationAlbum {
                    Button { model.repeatDestination() } label: {
                        Text("沿用：\(destination.title)").lineLimit(1).frame(maxWidth: 145)
                    }.disabled(!model.canAct || !model.canManageAlbums)
                        .help("直接加入「\(destination.title)」，審閱狀態不變 · ⇧A")
                        .accessibilityIdentifier("repeatAlbumDestination")
                }
                Button("加入並完成這批") { model.repeatDestination(completeReview: true) }
                    .disabled(!model.canAct || !model.canManageAlbums)
                    .help(model.repeatDestinationAlbum.map { "加入「\($0.title)」並完成這批 · ⌘⇧A" } ?? "選擇相簿並完成這批")
                    .accessibilityIdentifier("addAndCompleteBatch")
                if let album = model.currentOrganizerAlbum {
                    Button("移出相簿") {
                        do { try model.changeLocalAlbumMembers(id: album.id, adding: false) }
                        catch { model.notice = error.localizedDescription }
                    }.disabled(model.selected.isEmpty || !model.canManageAlbums).accessibilityIdentifier("removeFromLocalAlbum")
                }
                Menu("更多…") {
                    Button("保留 K") { model.mark(.kept) }
                    Button("完成審閱 O") { model.mark(.organized) }
                    if !model.recentDestinationAlbums.isEmpty {
                        Menu("最近目的相簿") {
                            ForEach(model.recentDestinationAlbums) { album in
                                Button("加入「\(album.title)」") {
                                    do { try model.addSelectionToAlbum(id: album.id) }
                                    catch { model.notice = error.localizedDescription }
                                }
                            }
                        }
                    }
                    Button("暫時用途 T") { model.toggleTemporary() }
                    Button("加入待刪候選 D") { model.addToDeleteQueue() }
                        .accessibilityIdentifier("addToDeleteQueue")
                }.disabled(!model.canAct)
                Spacer()
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo || !model.canReview || model.hasModal).help("復原 ⌘Z").accessibilityIdentifier("undoOrganizer")
                Button("清除選取") { model.clearSelection() }.buttonStyle(.plain).accessibilityIdentifier("clearSelection")
            }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 22)
            Text("⌘A 全選篩選 · ⇧A 沿用相簿 · ⌘⇧A 加入並完成 · ⌘Z 整批復原 · 相簿操作不刪照片")
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 8)
        }.background(.white)
    }
}

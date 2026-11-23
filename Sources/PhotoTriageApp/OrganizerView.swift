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
                if let error = model.displayPreferenceError {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                }
                if let error = model.workspaceError {
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
            .background(VerificationWindowPlacement())
            .sheet(item: $model.albumAction) { LocalAlbumSheet(action: $0).environmentObject(model) }
            .sheet(isPresented: $model.showAlbumSheet) { AlbumPlanSheet().environmentObject(model) }
            .sheet(isPresented: $model.showGroupSheet) { GroupSheet().environmentObject(model) }
            .sheet(isPresented: $model.showPlanSheet) { ReviewPlanSheet().environmentObject(model) }
            .sheet(isPresented: $model.showMusicSheet) { MusicReviewSheet().environmentObject(model) }
            .sheet(item: $model.comparison) { ComparisonSheet(batch: $0).environmentObject(model) }
            .sheet(item: $model.videoPreview) { VideoPreviewSheet(session: $0).environmentObject(model) }
            .task {
                if AppUIVerification.requested { AppUIVerification.schedule(model); return }
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
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.flushWorkspace() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.flushWorkspace() }
            .onDisappear { model.flushWorkspace() }
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
            scopeButton(.all)
            Divider().padding(.vertical, 12)
            HStack {
                Text("相簿").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.albumAction = .create } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("新增本機相簿").disabled(!model.canManageAlbums)
                    .accessibilityLabel("新增相簿").accessibilityIdentifier("newLocalAlbum").qaControl("newLocalAlbum")
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
            }.accessibilityIdentifier("unifiedAlbumList").qaControl("unifiedAlbumList")
            Divider()
            Button(model.isDemo ? "連線 Apple 照片…" : "重新讀取照片") { model.connect() }
                .buttonStyle(.bordered).disabled(model.isLoading).accessibilityIdentifier("connectPhotos").qaControl("connectPhotos").padding(14)
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
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("scope-\(scope.rawValue)").qaControl("scope-\(scope.rawValue)").padding(.horizontal, 7)
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
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("organizer-album-\(album.id)").qaControl("organizer-album-\(album.id)")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 25, weight: .semibold)).lineLimit(1)
                if let album = model.currentOrganizerAlbum { Text(album.sourceLabel).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("已審閱 \(model.progressCount) / \(model.records.count) · 待刪候選 \(model.queueCount)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("organizerProgress").qaControl("organizerProgress")
            }
            HStack(spacing: 10) {
                Picker("縮圖", selection: Binding(get: { model.thumbnailSize }, set: { model.setThumbnailSize($0) })) {
                    ForEach(ThumbnailSize.allCases, id: \.self) { size in Text(size.label).tag(size) }
                }.pickerStyle(.segmented).frame(width: 160).help("縮圖大小會保存，下次開啟沿用。")
                    .accessibilityIdentifier("thumbnailSize").qaControl("thumbnailSize")
                Spacer()
                Button("並排挑選 C") { model.beginComparison() }.disabled(!model.canCompare)
                    .help("選 2–6 張照片，指定保留及其餘待刪候選").accessibilityIdentifier("compareSelection").qaControl("compareSelection")
                if let album = model.currentOrganizerAlbum {
                    Menu("相簿…") {
                        Button("重新命名…") { model.albumAction = .rename(album.id) }
                        Button("移除本機相簿…") { model.albumAction = .delete(album.id) }
                    }.accessibilityIdentifier("currentAlbumMenu").qaControl("currentAlbumMenu")
                }
                Button("全選目前篩選（\(model.visible.count)）") { model.selectAll() }
                    .buttonStyle(.bordered).disabled(!model.canSelectVisible).accessibilityIdentifier("selectAllVisible").qaControl("selectAllVisible")
                Toggle(isOn: $model.inspectorVisible) { Image(systemName: "info.circle") }
                    .toggleStyle(.button).help(model.inspectorVisible ? "關閉照片資訊 I" : "開啟照片資訊 I；有選取時顯示")
                    .accessibilityLabel("照片資訊開關").accessibilityIdentifier("toggleInspector").qaControl("toggleInspector")
                Menu {
                    Button("復原相簿操作") { model.undoLocalAlbum() }.disabled(model.localAlbums.history.isEmpty || !model.canManageAlbums)
                    Button("既有審閱紀錄…") { model.showPlanSheet = true }
                    if !model.isDemo { Button("音樂 OCR…") { model.showMusicSheet = true }.disabled(!model.access.canRead) }
                    if !model.isDemo { Button("使用範例資料") { model.loadDemo() } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                    .accessibilityIdentifier("organizerTools").qaControl("organizerTools")
            }.controlSize(.small)
        }.padding(.horizontal, 22).padding(.vertical, 16)
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
                    .accessibilityIdentifier("deniedUseDemo").qaControl("deniedUseDemo")
            }
            Spacer()
        }.frame(maxWidth: .infinity).accessibilityIdentifier("photosAccessPanel").qaControl("photosAccessPanel")
    }
    private var actionBar: some View {
        VStack(spacing: 9) {
            Divider()
            HStack(spacing: 9) {
                Text("已選 \(model.selected.count) / \(model.visible.count)").font(.caption).monospacedDigit()
                    .frame(minWidth: 98, alignment: .leading).accessibilityIdentifier("selectionCount").qaControl("selectionCount")
                Button("加入相簿… A") { model.albumAction = .addSelection }
                    .buttonStyle(.borderedProminent).disabled(!model.canAct || !model.canManageAlbums)
                    .accessibilityIdentifier("addToLocalAlbum").qaControl("addToLocalAlbum")
                if let destination = model.repeatDestinationAlbum {
                    Button { model.repeatDestination() } label: { Text("沿用：\(destination.title)").lineLimit(1).frame(maxWidth: 145) }
                        .disabled(!model.canAct || !model.canManageAlbums).help("加入相簿，決策不變 · ⇧A")
                        .accessibilityIdentifier("repeatAlbumDestination").qaControl("repeatAlbumDestination")
                }
                Button("加入並保留") { model.repeatDestination(completeReview: true) }
                    .disabled(!model.canAct || !model.canManageAlbums)
                    .help("加入相簿並將未決策項目標為保留 K；保留既有決策 · ⌘⇧A")
                    .accessibilityIdentifier("addAndCompleteBatch").qaControl("addAndCompleteBatch")
                if let album = model.currentOrganizerAlbum {
                    Button("移出相簿") {
                        do { try model.changeLocalAlbumMembers(id: album.id, adding: false) }
                        catch { model.notice = error.localizedDescription }
                    }.disabled(model.selected.isEmpty || !model.canManageAlbums).accessibilityIdentifier("removeFromLocalAlbum").qaControl("removeFromLocalAlbum")
                }
                if !model.recentDestinationAlbums.isEmpty {
                    Menu("最近相簿…") {
                        ForEach(model.recentDestinationAlbums) { album in
                            Button("加入「\(album.title)」") {
                                do { try model.addSelectionToAlbum(id: album.id) }
                                catch { model.notice = error.localizedDescription }
                            }
                        }
                    }.disabled(!model.canAct || !model.canManageAlbums)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 9) {
                Button("保留 K") { model.mark(.kept) }.disabled(!model.canAct).accessibilityIdentifier("markKeep").qaControl("markKeep")
                Button("暫時用途 T") { model.toggleTemporary() }.disabled(!model.canAct).accessibilityIdentifier("markTemporary").qaControl("markTemporary")
                Button("待刪候選 D") { model.addToDeleteQueue() }.disabled(!model.canAct).accessibilityIdentifier("addToDeleteQueue").qaControl("addToDeleteQueue")
                Button("清除決策 U") { model.resetSelected() }.disabled(!model.canAct).accessibilityIdentifier("resetDecision").qaControl("resetDecision")
                Spacer()
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo || !model.canReview || model.hasModal).help("復原 ⌘Z").accessibilityIdentifier("undoOrganizer").qaControl("undoOrganizer")
                Button("清除選取") { model.clearSelection() }.buttonStyle(.plain).accessibilityIdentifier("clearSelection").qaControl("clearSelection")
            }
            Text("K／T／D 即已審閱 · ⌘A 全選篩選 · C 並排挑選 · I 資訊開關 · ⌘Z 整批復原")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 22).padding(.bottom, 10).background(.white)
    }
}

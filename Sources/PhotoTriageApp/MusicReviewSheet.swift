import SwiftUI
import PhotoTriageCore

struct MusicReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var scopes: [AlbumScope] = []
    @State private var selectedAlbumID = ""
    @State private var showUnresolved = false
    @State private var loadingAlbums = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("音樂截圖 · 本機辨識").font(.title2.bold())
            Text("限定一個相簿，以 Apple Vision 讀取本機小圖文字。照片／相簿不變更；不下載 iCloud 原始檔，不上傳圖片。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("相簿", selection: $selectedAlbumID) {
                    Text(loadingAlbums ? "讀取相簿路徑…" : "請選擇相簿").tag("")
                    ForEach(scopes) { Text("\($0.pathLabel) · \($0.visibleAssetCount) 個可見項目").tag($0.id) }
                }
                Button("開始 OCR（只讀）") { model.extractMusic(albumID: selectedAlbumID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedAlbumID.isEmpty || model.musicProgress != nil)
            }
            if let progress = model.musicProgress { ProgressView(progress).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            if let report = model.musicReport {
                Text("狀態：\(report.status) · \(report.resolvedAlbum?.pathLabel ?? "相簿尚未解析")").font(.caption)
                if report.resolvedAlbum != nil {
                    Text("已處理 \(report.processedImageCount) 張／可見 \(report.visibleAssetCount) 個 · 可讀預覽 \(report.localThumbnailCount) · iCloud-only \(report.iCloudOnlyCount) · 缺縮圖 \(report.missingThumbnailCount) · 預覽太小 \(report.insufficientPreviewCount) · 不支援影片 \(report.unsupportedVideoCount) · OCR 錯誤 \(report.errorCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("顯示未解決的截圖（\(report.unresolvedImageCount)）與 OCR 原文", isOn: $showUnresolved).font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        if report.songs.isEmpty { Text("尚無可配對歌曲；請檢查原文與不可讀項目。這不代表相簿沒有歌曲。") }
                        ForEach(report.songs) { song in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(song.title) — \(song.artist ?? "歌手未知")").font(.headline)
                                Text("待確認 · \(song.confidence) · \(song.evidence.count) 個來源；未比對官方曲目").font(.caption).foregroundStyle(.orange)
                                HStack { Link("Spotify 搜尋", destination: URL(string: song.spotifySearchURL)!)
                                    Link("YouTube 搜尋", destination: URL(string: song.youtubeSearchURL)!) }
                                    .font(.caption)
                                Text(song.evidence.flatMap(\.originalText).joined(separator: " / ")).font(.caption).textSelection(.enabled)
                            }
                            Divider()
                        }
                        if showUnresolved {
                            ForEach(report.assets.filter { entry in
                                entry.parse == nil || entry.parse!.candidates.isEmpty || !entry.parse!.unresolvedLineIndices.isEmpty
                            }, id: \.assetID) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("來源 \(entry.assetID) · \(entry.thumbnailStatus)").font(.caption).foregroundStyle(.secondary)
                                    Text(entry.lines.isEmpty ? (entry.error ?? "沒有可讀本機文字") : entry.lines.map(\.text).joined(separator: "\n"))
                                        .font(.caption).textSelection(.enabled)
                                }
                                Divider()
                            }
                        }
                    }
                }.frame(height: 310)
                if let path = model.musicOutputPath { Text("JSON／CSV／Markdown：\(path)").font(.caption2).textSelection(.enabled) }
            } else {
                Text("每張圖片均會列入覆蓋率；一張可含多首歌。歌名＋歌手的精確正規化配對才合併，來源與原文保留。所有配對需要人工確認，沒有自動建立播放清單。")
                    .foregroundStyle(.secondary).padding(.vertical, 20).frame(height: 190)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 780).tint(Theme.accent)
            .task {
                scopes = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: AlbumResolver.inventory()) }
                }
                let candidates = AlbumResolver.musicCandidates(scopes)
                if candidates.count == 1 { selectedAlbumID = candidates[0].id }
                else if let current = model.filter.albumID { selectedAlbumID = current }
                loadingAlbums = false
            }
    }
}

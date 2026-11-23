import AVKit
import Photos
import SwiftUI
import PhotoTriageCore

struct VideoPreviewSession: Identifiable {
    let id = UUID()
    let initialID: String
    let assetIDs: [String]
}

enum VideoPreviewState: String, Sendable {
    case loading, ready, cloud, unavailable, permission, network, libraryUnavailable, unsupported, space, cancelled, failed, timeout, closed
    var message: String {
        switch self {
        case .loading: return "正在準備影片…"
        case .ready: return "影片已準備好"
        case .cloud: return "Photos 表示此影片需要網路，但尚未提供可播放資料。請確認連線後重試。"
        case .unavailable: return "影片目前不可見或資源不存在。可關閉預覽，重新讀取照片再試。"
        case .permission: return "目前沒有這部影片的存取權限。請關閉預覽，透過「連線 Apple 照片」親自處理授權。"
        case .network: return "影片連線失敗。請確認網路後重試。"
        case .libraryUnavailable: return "照片庫目前無法使用。請確認照片庫所在磁碟可用，再重新讀取照片。"
        case .unsupported: return "此 Mac 無法解讀這部影片的格式。"
        case .space: return "Photos 取得影片時回報空間不足。請確認可用磁碟空間後重試。"
        case .cancelled: return "影片載入已取消"
        case .failed: return "影片準備或讀取失敗。請重試。"
        case .timeout: return "影片載入或緩衝已一段時間沒有進展。請確認連線後重試。"
        case .closed: return "預覽已關閉"
        }
    }
}

/// Retain only domain/code, never URLs, local identifiers, filenames or arbitrary userInfo.
struct VideoFailure: Equatable, Sendable {
    let state: VideoPreviewState
    let domain: String
    let code: Int
    static func classify(_ error: Error) -> VideoFailure {
        var current = error as NSError
        for _ in 0..<5 {
            let state: VideoPreviewState?
            if current.domain == PHPhotosErrorDomain {
                switch current.code {
                case PHPhotosError.Code.userCancelled.rawValue: state = .cancelled
                case PHPhotosError.Code.accessUserDenied.rawValue, PHPhotosError.Code.accessRestricted.rawValue: state = .permission
                case PHPhotosError.Code.identifierNotFound.rawValue, PHPhotosError.Code.missingResource.rawValue: state = .unavailable
                case PHPhotosError.Code.networkError.rawValue: state = .network
                case PHPhotosError.Code.networkAccessRequired.rawValue: state = .cloud
                case PHPhotosError.Code.libraryVolumeOffline.rawValue, PHPhotosError.Code.switchingSystemPhotoLibrary.rawValue,
                     PHPhotosError.Code.relinquishingLibraryBundleToWriter.rawValue: state = .libraryUnavailable
                case PHPhotosError.Code.notEnoughSpace.rawValue: state = .space
                default: state = nil
                }
            } else if current.domain == NSURLErrorDomain {
                switch current.code {
                case URLError.cancelled.rawValue: state = .cancelled
                case URLError.fileDoesNotExist.rawValue: state = .unavailable
                default: state = .network
                }
            } else if current.domain == AVFoundationErrorDomain {
                switch current.code {
                case AVError.Code.decoderNotFound.rawValue, AVError.Code.fileFormatNotRecognized.rawValue: state = .unsupported
                default: state = nil
                }
            } else { state = nil }
            if let state { return VideoFailure(state: state, domain: current.domain, code: current.code) }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== current else { break }
            current = underlying
        }
        return VideoFailure(state: .failed, domain: current.domain, code: current.code)
    }
}

enum VideoSource { case photos(PHAsset), file(URL), unavailable, permission }
struct VideoItemResult {
    var item: AVPlayerItem?
    var state: VideoPreviewState
    var failure: VideoFailure? = nil
}
struct VideoProgress: Sendable {
    var fraction: Double?
    var failure: VideoFailure? = nil
}

@MainActor protocol VideoItemRequesting: AnyObject {
    func request(_ source: VideoSource, progress: @escaping (VideoProgress) -> Void, completion: @escaping (VideoItemResult) -> Void)
    func cancel()
}

/// Cancellation is checked synchronously while PhotoKit's progress stop pointer is valid.
final class VideoRequestLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// The caller is the single user-opened preview; no export, prefetch or library mutation.
@MainActor final class VideoItemRequester: VideoItemRequesting {
    private let manager = PHImageManager()
    private var requestID: PHImageRequestID?
    private var generation = UUID()
    private var lifetime: VideoRequestLifetime?
    static func options(progressHandler: PHAssetVideoProgressHandler? = nil) -> PHVideoRequestOptions {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        options.progressHandler = progressHandler
        return options
    }
    nonisolated static func result(item: AVPlayerItem?, info: [AnyHashable: Any]?) -> VideoItemResult {
        if (info?[PHImageCancelledKey] as? Bool) == true { return VideoItemResult(state: .cancelled) }
        if let item { return VideoItemResult(item: item, state: .loading) }
        if let error = info?[PHImageErrorKey] as? NSError {
            let failure = VideoFailure.classify(error)
            return VideoItemResult(state: failure.state, failure: failure)
        }
        return VideoItemResult(state: (info?[PHImageResultIsInCloudKey] as? Bool) == true ? .cloud : .failed)
    }
    func request(_ source: VideoSource, progress: @escaping (VideoProgress) -> Void, completion: @escaping (VideoItemResult) -> Void) {
        cancel()
        switch source {
        case .permission: completion(VideoItemResult(state: .permission))
        case .unavailable: completion(VideoItemResult(state: .unavailable))
        case .file(let url):
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { completion(VideoItemResult(state: .unavailable)); return }
            completion(VideoItemResult(item: AVPlayerItem(url: url), state: .loading))
        case .photos(let asset):
            guard LibraryAccess.current().canRead else { completion(VideoItemResult(state: .permission)); return }
            // Re-fetch exactly this ID; cached metadata must not hide deletion or limited-access changes.
            guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject,
                  current.mediaType == .video else { completion(VideoItemResult(state: .unavailable)); return }
            let token = generation, lifetime = VideoRequestLifetime()
            self.lifetime = lifetime
            let options = Self.options { [weak self] fraction, error, stop, _ in
                if lifetime.isCancelled { stop.pointee = true; return }
                let update = VideoProgress(fraction: fraction, failure: error.map { VideoFailure.classify($0) })
                DispatchQueue.main.async {
                    guard let self, self.generation == token, !lifetime.isCancelled else { return }
                    progress(update)
                }
            }
            requestID = manager.requestPlayerItem(forVideo: current, options: options) { [weak self] item, info in
                let result = Self.result(item: item, info: info)
                DispatchQueue.main.async {
                    guard let self, self.generation == token, !lifetime.isCancelled else { return }
                    self.requestID = nil
                    guard LibraryAccess.current().canRead else { completion(VideoItemResult(state: .permission)); return }
                    completion(result)
                }
            }
        }
    }
    func cancel() {
        generation = UUID(); lifetime?.cancel(); lifetime = nil
        if let requestID { manager.cancelImageRequest(requestID) }
        requestID = nil
    }
}

@MainActor final class VideoPreviewController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var state: VideoPreviewState = .closed
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = true
    @Published private(set) var wantsPlayback = false
    @Published private(set) var isBuffering = false
    @Published private(set) var progress: Double?
    @Published private(set) var loadingIsSlow = false
    @Published private(set) var failure: VideoFailure?
    private let requester: VideoItemRequesting
    private let activityProvider: () -> Bool
    private var observation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var timeObserver: Any?
    private var isScrubbing = false
    private var resumeAfterScrub = false
    private var lastActivity = 0.0
    private var waitingStarted = 0.0
    private var stallSeconds = 120.0
    private var slowSeconds = 30.0
    init(requester: VideoItemRequesting? = nil, activityProvider: (() -> Bool)? = nil) {
        self.requester = requester ?? VideoItemRequester()
        self.activityProvider = activityProvider ?? { NSApplication.shared.isActive }
        player.isMuted = true
    }
    var statusMessage: String {
        if state == .loading {
            if let progress {
                return progress >= 1 ? "正在完成影片準備…" : "正在從 iCloud 載入影片… \(Int(progress * 100))%"
            }
            return loadingIsSlow ? "影片準備較久，仍在等待 Photos 回應…" : state.message
        }
        if state == .ready {
            if isBuffering { return "正在緩衝影片…" }
            return (isPlaying ? "播放中" : "已暫停") + (isMuted ? " · 靜音" : "")
        }
        return state.message
    }
    func load(_ source: VideoSource, autoplay: Bool = false, timeoutSeconds: Double = 120, slowAfterSeconds: Double = 30) {
        stop(); state = .loading; wantsPlayback = autoplay
        stallSeconds = timeoutSeconds; slowSeconds = slowAfterSeconds
        let token = generation
        startWatchdog(token)
        requester.request(source, progress: { [weak self] update in
            guard let self, self.generation == token, self.state == .loading else { return }
            if let failure = update.failure { self.fail(failure.state, failure: failure); return }
            guard let value = update.fraction, value.isFinite, (0...1).contains(value), value > (self.progress ?? -1) else { return }
            self.progress = value; self.lastActivity = ProcessInfo.processInfo.systemUptime
        }) { [weak self] result in
            guard let self, self.generation == token else { return }
            guard let item = result.item else { self.fail(result.state, failure: result.failure); return }
            self.lastActivity = ProcessInfo.processInfo.systemUptime
            self.observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status, failure = item.error.map { VideoFailure.classify($0) }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if status == .readyToPlay {
                        self.watchdog?.cancel(); self.watchdog = nil; self.state = .ready
                        let seconds = item.duration.seconds
                        self.duration = seconds.isFinite ? max(0, seconds) : 0
                        if self.wantsPlayback, self.activityProvider() { self.player.play() }
                        else { self.wantsPlayback = false }
                    } else if status == .failed { self.fail(failure?.state ?? .failed, failure: failure) }
                }
            }
            self.failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let failure = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError).map { VideoFailure.classify($0) }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.fail(failure?.state ?? .failed, failure: failure)
                }
            }
            self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.pause()
                }
            }
            self.player.replaceCurrentItem(with: item)
            self.playbackObservation = self.player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.isPlaying = status == .playing
                    let waiting = status == .waitingToPlayAtSpecifiedRate && self.wantsPlayback
                    if waiting && !self.isBuffering { self.startWatchdog(token) }
                    self.isBuffering = waiting
                    if !waiting && self.state == .ready { self.watchdog?.cancel(); self.watchdog = nil }
                }
            }
            self.timeObserver = self.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.generation == token, !self.isScrubbing, time.seconds.isFinite else { return }
                    if time.seconds > self.currentTime { self.lastActivity = ProcessInfo.processInfo.systemUptime }
                    self.currentTime = max(0, time.seconds)
                }
            }
        }
    }
    private func startWatchdog(_ token: UUID) {
        watchdog?.cancel()
        waitingStarted = ProcessInfo.processInfo.systemUptime; lastActivity = waitingStarted
        watchdog = Task { [weak self] in
            guard let self else { return }
            let tick = max(0.01, min(1, self.stallSeconds / 4))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(tick)) } catch { return }
                guard self.generation == token, self.state == .loading || (self.state == .ready && self.isBuffering && self.wantsPlayback) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.loadingIsSlow = now - self.waitingStarted >= self.slowSeconds
                if now - self.lastActivity >= self.stallSeconds { self.fail(.timeout); return }
            }
        }
    }
    private func fail(_ state: VideoPreviewState, failure: VideoFailure? = nil) { stop(); self.state = state; self.failure = failure }
    func cancelLoading() { stop(); state = .cancelled }
    func pause() {
        player.pause(); wantsPlayback = false; isPlaying = false; isBuffering = false; resumeAfterScrub = false; isScrubbing = false
        if state == .ready { watchdog?.cancel(); watchdog = nil }
    }
    func togglePlayback() {
        if state == .loading { wantsPlayback.toggle(); return }
        guard state == .ready else { return }
        if wantsPlayback || player.rate > 0 { pause() }
        else {
            if duration > 0, currentTime >= duration - 0.05 { player.seek(to: .zero) }
            wantsPlayback = true; player.play()
        }
    }
    func toggleMute() { isMuted.toggle(); player.isMuted = isMuted }
    func seek(_ seconds: Double) {
        guard state == .ready, seconds.isFinite else { return }
        currentTime = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func scrubbing(_ editing: Bool) {
        if editing { resumeAfterScrub = wantsPlayback || player.rate > 0; wantsPlayback = false; player.pause(); isPlaying = false; isScrubbing = true }
        else { isScrubbing = false; if resumeAfterScrub { wantsPlayback = true; player.play() }; resumeAfterScrub = false }
    }
    func stop() {
        generation = UUID(); requester.cancel()
        watchdog?.cancel(); watchdog = nil
        observation?.invalidate(); observation = nil; playbackObservation?.invalidate(); playbackObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }; failureObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player.pause(); player.isMuted = true; player.replaceCurrentItem(with: nil)
        isPlaying = false; isMuted = true; currentTime = 0; duration = 0; wantsPlayback = false; isBuffering = false
        isScrubbing = false; resumeAfterScrub = false; progress = nil; loadingIsSlow = false; failure = nil; state = .closed
    }
}

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // One always-visible control row below the video, backed by the same AVPlayer.
        view.controlsStyle = .none
        view.allowsVideoFrameAnalysis = false
        view.updatesNowPlayingInfoCenter = false
        view.videoGravity = .resizeAspect
        view.player = player
        view.setAccessibilityIdentifier("nativeVideoPlayer")
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct VideoPreviewSheet: View {
    @EnvironmentObject var model: AppModel
    let session: VideoPreviewSession
    @State private var currentID: String
    @StateObject private var playback: VideoPreviewController
    init(session: VideoPreviewSession) {
        self.session = session
        _currentID = State(initialValue: session.initialID)
        // The isolated native fixture simulates active-app intent without taking user focus.
        let fixtureActivity: (() -> Bool)? = AppUIVerification.requested && CommandLine.arguments.contains("--ui-qa-video") ? { true } : nil
        _playback = StateObject(wrappedValue: VideoPreviewController(activityProvider: fixtureActivity))
    }
    private var index: Int { session.assetIDs.firstIndex(of: currentID) ?? 0 }
    private var record: PhotoRecord? { model.records.first { $0.id == currentID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("影片預覽").font(.title2.bold())
                Text(record?.date?.formatted(date: .abbreviated, time: .shortened) ?? "時間未知").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("關閉") { close() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("closeVideoPreview").qaControl("closeVideoPreview")
            }
            ZStack {
                Color.black
                NativeVideoPlayer(player: playback.player)
                if playback.state == .loading || playback.isBuffering {
                    VStack(spacing: 8) {
                        if playback.state == .loading, let progress = playback.progress { ProgressView(value: progress).frame(width: 240) }
                        else { ProgressView() }
                        Text(playback.statusMessage)
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                else if playback.state != .ready {
                    Text(playback.state.message).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 460).padding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Button { playback.togglePlayback() } label: { Image(systemName: playback.wantsPlayback || playback.isPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(playback.wantsPlayback || playback.isPlaying ? "暫停影片" : "播放影片").accessibilityIdentifier("videoPlayPause").qaControl("videoPlayPause")
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(playback.state != .loading && playback.state != .ready)
                Text(timeLabel(playback.currentTime)).monospacedDigit().frame(width: 48)
                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek($0) }), in: 0...max(0.01, playback.duration), onEditingChanged: { playback.scrubbing($0) })
                    .accessibilityLabel("影片進度").accessibilityIdentifier("videoSeek").disabled(playback.state != .ready || playback.duration <= 0)
                Text(timeLabel(playback.duration)).monospacedDigit().frame(width: 48)
                Button { playback.toggleMute() } label: { Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .accessibilityLabel(playback.isMuted ? "開啟聲音" : "靜音").accessibilityIdentifier("videoMute")
                    .disabled(playback.state != .ready)
            }.font(.callout)
            Text(playback.statusMessage)
                .font(.callout).accessibilityIdentifier("videoPreviewStatus")
            HStack {
                Button("上一部") { move(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0)
                    .accessibilityIdentifier("previousVideo").qaControl("previousVideo")
                Button("下一部") { move(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(index >= session.assetIDs.count - 1)
                    .accessibilityIdentifier("nextVideo").qaControl("nextVideo")
                Text("\(index + 1) / \(session.assetIDs.count)").monospacedDigit().font(.caption)
                Spacer()
                if playback.state == .loading {
                    Button("取消載入") { playback.cancelLoading() }.accessibilityIdentifier("cancelVideoLoading").qaControl("cancelVideoLoading")
                }
                Button(playback.state == .ready ? "重新播放" : "重試") { load() }.disabled(playback.state == .loading)
                    .accessibilityIdentifier("reloadVideo").qaControl("reloadVideo")
            }
        }.padding(22).frame(width: 900, height: 650).background(Theme.paper).tint(Theme.accent)
            .onAppear { load() }
            .onDisappear { playback.stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in playback.pause() }
    }
    private func load() { playback.load(model.videoSource(for: currentID), autoplay: true) }
    private func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private func move(_ offset: Int) {
        let next = index + offset
        guard session.assetIDs.indices.contains(next) else { return }
        playback.stop(); currentID = session.assetIDs[next]; load()
    }
    private func close() { playback.stop(); model.videoPreview = nil }
}

extension AppModel {
    var canOpenVideo: Bool { !hasModal && !isLoading && focusedRecord?.kind == .video }
    func beginVideoPreview(_ id: String? = nil) {
        guard !hasModal, !isLoading, let target = id ?? focusedID,
              visible.contains(where: { $0.id == target && $0.kind == .video }) else { return }
        videoPreview = VideoPreviewSession(initialID: target, assetIDs: visible.filter { $0.kind == .video }.map(\.id))
    }
    func videoSource(for id: String) -> VideoSource {
        if let url = videoFixtureURLs[id] { return .file(url) }
        guard records.contains(where: { $0.id == id && $0.kind == .video }) else { return .unavailable }
        if isDemo { return .unavailable }
        guard LibraryAccess.current().canRead else { return .permission }
        return assets[id].map { .photos($0) } ?? .unavailable
    }
}

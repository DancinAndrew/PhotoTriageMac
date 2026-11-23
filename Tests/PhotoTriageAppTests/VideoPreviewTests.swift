import AVKit
import Photos
import XCTest
import PhotoTriageCore
@testable import PhotoTriageApp

@MainActor final class VideoPreviewTests: XCTestCase {
    var sample: URL { Bundle.module.url(forResource: "video-preview", withExtension: "mp4", subdirectory: "Fixtures")! }
    func waitUntil(_ predicate: @escaping () -> Bool, seconds: Double = 8) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(predicate())
    }
    func testActualLocalPlaybackSeekingAndRelease() async throws {
        let controller = VideoPreviewController()
        controller.load(.file(sample))
        try await waitUntil { controller.state == .ready }
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertTrue(controller.player.isMuted)
        let item = try XCTUnwrap(controller.player.currentItem)
        let video = try await item.asset.loadTracks(withMediaType: .video)
        let audio = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(video.isEmpty); XCTAssertFalse(audio.isEmpty)
        controller.togglePlayback()
        try await waitUntil { controller.player.currentTime().seconds > 0.25 }
        controller.scrubbing(true)
        XCTAssertEqual(controller.player.rate, 0)
        controller.seek(3.5)
        controller.scrubbing(false)
        try await waitUntil { controller.player.currentTime().seconds >= 3.5 }
        controller.pause()
        await controller.player.seek(to: CMTime(seconds: 3.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertEqual(controller.player.currentTime().seconds, 3.5, accuracy: 0.1)
        controller.seek(-10)
        try await waitUntil { controller.player.currentTime().seconds < 0.1 }
        controller.stop()
        XCTAssertNil(controller.player.currentItem); XCTAssertEqual(controller.player.rate, 0)
        XCTAssertEqual(controller.state, .closed)
    }
    func testCloseReopenSwitchAndRepeatedLoadStartPausedMuted() async throws {
        let controller = VideoPreviewController()
        controller.load(.file(sample)); try await waitUntil { controller.state == .ready }
        let old = controller.player.currentItem
        controller.player.isMuted = false; controller.player.play()
        controller.load(.file(sample)); controller.load(.file(sample))
        try await waitUntil { controller.state == .ready }
        XCTAssertFalse(old === controller.player.currentItem)
        XCTAssertEqual(controller.player.rate, 0); XCTAssertTrue(controller.player.isMuted)
        controller.stop(); controller.load(.file(sample))
        try await waitUntil { controller.state == .ready }
        XCTAssertEqual(controller.player.currentTime().seconds, 0, accuracy: 0.1)
        controller.stop()
    }
    func testUnavailablePermissionCorruptFormatAndTimeout() async throws {
        let controller = VideoPreviewController()
        controller.load(.unavailable); XCTAssertEqual(controller.state, .unavailable)
        controller.load(.permission); XCTAssertEqual(controller.state, .permission)
        controller.load(.file(URL(fileURLWithPath: "/missing-video-fixture.mp4")))
        XCTAssertEqual(controller.state, .unavailable)
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("bad-video-\(UUID()).mp4")
        try Data("not a movie".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        controller.load(.file(broken))
        try await waitUntil { [.failed, .unsupported].contains(controller.state) }
        XCTAssertNil(controller.player.currentItem)
        let fake = DeferredVideoRequester()
        let pending = VideoPreviewController(requester: fake)
        pending.load(.unavailable, timeoutSeconds: 0.06)
        try await waitUntil { pending.state == .timeout }
        XCTAssertNil(pending.player.currentItem)
    }
    func testPhotoKitCloudResultAndLateResponsesAreRejected() async throws {
        let fake = DeferredVideoRequester()
        let controller = VideoPreviewController(requester: fake)
        controller.load(.unavailable)
        fake.callbacks[0](VideoItemResult(state: .cloud))
        XCTAssertEqual(controller.state, .cloud)
        controller.load(.unavailable)
        let abandoned = fake.callbacks[1]
        controller.load(.unavailable)
        fake.callbacks[2](VideoItemResult(item: AVPlayerItem(url: sample), state: .loading))
        try await waitUntil { controller.state == .ready }
        let current = controller.player.currentItem
        abandoned(VideoItemResult(state: .failed))
        XCTAssertTrue(current === controller.player.currentItem); XCTAssertEqual(controller.state, .ready)
        controller.stop()
        fake.callbacks[2](VideoItemResult(item: AVPlayerItem(url: sample), state: .loading))
        XCTAssertNil(controller.player.currentItem); XCTAssertEqual(controller.state, .closed)
        XCTAssertGreaterThan(fake.cancellations, 3)
        let options = VideoItemRequester.options()
        XCTAssertTrue(options.isNetworkAccessAllowed); XCTAssertEqual(options.version, .current)
    }
    func testUserOpenAutomaticallyPlaysRealSampleMuted() async throws {
        let controller = VideoPreviewController(activityProvider: { true })
        controller.load(.file(sample), autoplay: true)
        try await waitUntil { controller.player.currentTime().seconds > 0.25 }
        XCTAssertEqual(controller.state, .ready); XCTAssertTrue(controller.player.isMuted)
        XCTAssertTrue(controller.wantsPlayback); XCTAssertTrue(controller.isPlaying)
        controller.stop(); XCTAssertNil(controller.player.currentItem); XCTAssertFalse(controller.wantsPlayback)
    }
    func testPendingPauseAndInactiveAppPreventSurprisePlayback() async throws {
        let fake = DeferredVideoRequester()
        let controller = VideoPreviewController(requester: fake, activityProvider: { true })
        controller.load(.unavailable, autoplay: true); controller.pause()
        fake.callbacks[0](VideoItemResult(item: AVPlayerItem(url: sample), state: .loading))
        try await waitUntil { controller.state == .ready }
        XCTAssertEqual(controller.player.rate, 0); XCTAssertFalse(controller.wantsPlayback)
        controller.stop()
        let inactive = VideoPreviewController(activityProvider: { false })
        inactive.load(.file(sample), autoplay: true)
        try await waitUntil { inactive.state == .ready }
        XCTAssertEqual(inactive.player.rate, 0); XCTAssertFalse(inactive.wantsPlayback)
        inactive.stop()
    }
    func testGenuineProgressExtendsStallDeadlineAndSlowLoadIsSoft() async throws {
        let fake = DeferredVideoRequester()
        let controller = VideoPreviewController(requester: fake, activityProvider: { true })
        controller.load(.unavailable, autoplay: true, timeoutSeconds: 0.2, slowAfterSeconds: 0.01)
        try await Task.sleep(for: .milliseconds(40)); fake.progresses[0](VideoProgress(fraction: 0.1))
        try await Task.sleep(for: .milliseconds(100)); fake.progresses[0](VideoProgress(fraction: 0.2))
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(controller.state, .loading); XCTAssertEqual(controller.progress, 0.2)
        XCTAssertTrue(controller.loadingIsSlow)
        fake.progresses[0](VideoProgress(fraction: .nan)); fake.progresses[0](VideoProgress(fraction: 0.1))
        XCTAssertEqual(controller.progress, 0.2)
        try await waitUntil { controller.state == .timeout }
        XCTAssertNil(controller.player.currentItem); XCTAssertFalse(controller.wantsPlayback)
    }
    func testCancelSwitchLateProgressAndCompletionCannotRevivePlayback() async throws {
        let fake = DeferredVideoRequester()
        let controller = VideoPreviewController(requester: fake, activityProvider: { true })
        controller.load(.unavailable, autoplay: true); fake.progresses[0](VideoProgress(fraction: 0.3))
        controller.load(.unavailable, autoplay: true); fake.progresses[1](VideoProgress(fraction: 0.4))
        fake.progresses[0](VideoProgress(fraction: 0.9))
        fake.callbacks[0](VideoItemResult(item: AVPlayerItem(url: sample), state: .loading))
        XCTAssertEqual(controller.progress, 0.4); XCTAssertNil(controller.player.currentItem)
        controller.cancelLoading(); XCTAssertEqual(controller.state, .cancelled)
        fake.progresses[1](VideoProgress(fraction: 1))
        fake.callbacks[1](VideoItemResult(item: AVPlayerItem(url: sample), state: .loading))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.state, .cancelled); XCTAssertNil(controller.progress)
        XCTAssertNil(controller.player.currentItem); XCTAssertFalse(controller.wantsPlayback)
        let lifetime = VideoRequestLifetime(); XCTAssertFalse(lifetime.isCancelled)
        lifetime.cancel(); XCTAssertTrue(lifetime.isCancelled)
    }
    func testPhotoKitErrorsTakePriorityOverCloudFlagAndUnknownRemainsUnknown() {
        let cases: [(Int, VideoPreviewState)] = [(3169, .network), (3311, .permission), (3310, .permission), (3303, .unavailable), (3201, .unavailable), (3114, .libraryUnavailable), (3305, .space), (3072, .cancelled), (3164, .cloud)]
        for (code, expected) in cases {
            let error = NSError(domain: PHPhotosErrorDomain, code: code)
            let result = VideoItemRequester.result(item: nil, info: [PHImageErrorKey: error, PHImageResultIsInCloudKey: true])
            XCTAssertEqual(result.state, expected); XCTAssertEqual(result.failure?.code, code)
        }
        XCTAssertEqual(VideoItemRequester.result(item: nil, info: nil).state, .failed)
        XCTAssertEqual(VideoItemRequester.result(item: nil, info: [PHImageCancelledKey: true]).state, .cancelled)
        let unknown = NSError(domain: "FixtureUnknown", code: 123, userInfo: ["privateURL": "not-retained"])
        let result = VideoItemRequester.result(item: nil, info: [PHImageErrorKey: unknown, PHImageResultIsInCloudKey: true])
        XCTAssertEqual(result.state, .failed); XCTAssertEqual(result.failure?.domain, "FixtureUnknown")
        let wrapped = NSError(domain: "FixtureWrapper", code: -1, userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        XCTAssertEqual(VideoFailure.classify(wrapped).state, .network)
        XCTAssertEqual(VideoFailure.classify(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decoderNotFound.rawValue)).state, .unsupported)
    }
    func testProgressFailureClearsRequestAndKeepsSpecificCause() {
        let fake = DeferredVideoRequester()
        let controller = VideoPreviewController(requester: fake)
        controller.load(.unavailable, autoplay: true)
        let failure = VideoFailure.classify(URLError(.networkConnectionLost))
        fake.progresses[0](VideoProgress(fraction: 0.4, failure: failure))
        XCTAssertEqual(controller.state, .network); XCTAssertEqual(controller.failure, failure)
        XCTAssertNil(controller.progress); XCTAssertFalse(controller.wantsPlayback)
        fake.callbacks[0](VideoItemResult(state: .cloud)); XCTAssertEqual(controller.state, .network)
    }
    func testOpenNavigationDoesNotModifyReviewAlbumsOrSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoModel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(reviewRoot: root)
        model.records = [PhotoRecord(id: "fixture-a", kind: .video), PhotoRecord(id: "fixture-photo"), PhotoRecord(id: "fixture-b", kind: .video)]
        model.rebuild(); model.select("fixture-a")
        let document = model.document, albums = model.localAlbums, selection = model.selected, focus = model.focusedID
        model.beginVideoPreview()
        let session = try XCTUnwrap(model.videoPreview)
        XCTAssertEqual(session.assetIDs, ["fixture-a", "fixture-b"])
        XCTAssertTrue(model.hasModal); XCTAssertFalse(model.canAct); XCTAssertFalse(model.canOpenVideo)
        model.beginVideoPreview("fixture-b")
        XCTAssertEqual(model.videoPreview?.id, session.id)
        model.videoPreview = nil; model.beginVideoPreview("fixture-b")
        XCTAssertEqual(model.videoPreview?.initialID, "fixture-b")
        XCTAssertEqual(model.document, document); XCTAssertEqual(model.localAlbums, albums)
        XCTAssertEqual(model.selected, selection); XCTAssertEqual(model.focusedID, focus)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.reviewURL.path))
        model.videoPreview = nil; model.filter.media = .image; model.filterChanged()
        model.beginVideoPreview("fixture-b"); XCTAssertNil(model.videoPreview)
    }
}

@MainActor private final class DeferredVideoRequester: VideoItemRequesting {
    var callbacks: [(VideoItemResult) -> Void] = []
    var cancellations = 0
    var progresses: [(VideoProgress) -> Void] = []
    func request(_ source: VideoSource, progress: @escaping (VideoProgress) -> Void, completion: @escaping (VideoItemResult) -> Void) {
        progresses.append(progress); callbacks.append(completion)
    }
    func cancel() { cancellations += 1 }
}

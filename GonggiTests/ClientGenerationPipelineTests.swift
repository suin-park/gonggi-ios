import XCTest
import simd
@testable import Gonggi

@MainActor
final class ClientGenerationPipelineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(true)
    }

    override func tearDown() {
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(nil)
        super.tearDown()
    }

    func testPresenterMapsUploadFailedClearly() {
        let message = SpaceGenerationErrorPresenter.userMessage(for: SpaceGenerationError.uploadFailed)
        XCTAssertTrue(message.contains("업로드에 실패"))
        XCTAssertFalse(message.contains("3D 공간 생성을 시작하지 못했어요"))
    }

    func testPresenterMapsNetworkConnectionLostAsUploadFailure() {
        let message = SpaceGenerationErrorPresenter.userMessage(
            for: SpaceGenerationError.unknown("The network connection was lost.")
        )
        XCTAssertTrue(message.contains("업로드에 실패"))
        XCTAssertFalse(message.contains("3D 공간 생성을 시작하지 못했어요"))
    }

    func testPresenterMapsNSURLErrorNetworkLossAsUploadFailure() {
        let ns = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        let message = SpaceGenerationErrorPresenter.userMessage(for: ns)
        XCTAssertTrue(message.contains("업로드에 실패"))
    }

    func testPackageMissingCopyIsExplicit() {
        XCTAssertTrue(
            SpaceGenerationErrorPresenter.packageMissingUnrecoverable.contains("원본 촬영 패키지")
        )
        XCTAssertTrue(
            SpaceGenerationErrorPresenter.packageMissingUnrecoverable.contains("새로 촬영")
        )
    }

    func testIdempotencyKeyReusesDiagnosticsKey() throws {
        let sessionId = "SESSION_IDEM_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        _ = try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
        var diag = CaptureGenerationDiagnostics.empty
        diag.idempotencyKey = "gonggi-A35FDDA1-2272-4BD3-9870-A89048F52541"
        CaptureDiagnosticsStore.writeGenerationDiagnostics(diag, sessionId: sessionId)
        let key = CapturePackageRetention.resolveIdempotencyKey(
            captureId: "GONGGI_CAPTURE_V1_040",
            sessionId: sessionId
        )
        XCTAssertEqual(key, "gonggi-A35FDDA1-2272-4BD3-9870-A89048F52541")
    }

    func testIdempotencyKeyStablePerCaptureIdWhenNoDiagnostics() throws {
        let sessionId = "SESSION_IDEM2_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        _ = try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
        let a = CapturePackageRetention.resolveIdempotencyKey(
            captureId: "GONGGI_CAPTURE_V1_041",
            sessionId: sessionId
        )
        let b = CapturePackageRetention.resolveIdempotencyKey(
            captureId: "GONGGI_CAPTURE_V1_041",
            sessionId: sessionId
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "gonggi-capture-GONGGI_CAPTURE_V1_041")
    }

    func testSpatialPackageRetentionDetectsFrames() throws {
        let sessionId = "SESSION_PKG_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        let frames = root.appendingPathComponent(SpatialCaptureConfig.framesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: frames.appendingPathComponent("kf_00001.jpg"))
        XCTAssertTrue(
            CapturePackageRetention.hasRetainedSpatialPackage(sessionId: sessionId, packageRootHint: root)
        )
    }

    func testSpatialPackageRetentionFalseWhenEmpty() throws {
        let sessionId = "SESSION_EMPTY_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        XCTAssertFalse(
            CapturePackageRetention.hasRetainedSpatialPackage(sessionId: sessionId, packageRootHint: root)
        )
    }

    func testUploadFailureInjectionShowsRetryWhenPackagePresent() async throws {
        let sessionId = "SESSION_UP_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try makeZipReadyPackage(sessionId: sessionId)
        let service = FailureInjectingSpaceGenerationService()
        await service.setFailAt(.upload)
        let vm = ProcessingViewModel(spaceService: service)
        let summary = makeSummary(sessionId: sessionId, packageRoot: root, valid: true)

        vm.start(summary: summary, qualityProfile: "capture_dense_v2", allowStubVideoInMock: true)
        try await waitUntil(timeout: 8) { vm.errorMessage != nil || vm.handoff != nil }

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("업로드") == true)
        XCTAssertTrue(vm.canRetrySameCapture)
        let uploadCount = await service.uploadCount
        let createCount = await service.createCount
        let startCount = await service.startCount
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(vm.pipelineSteps[1].status, .failed("업로드 실패"))
    }

    func testCreateFailureInjectionDoesNotStartUpload() async throws {
        let sessionId = "SESSION_CR_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try makeZipReadyPackage(sessionId: sessionId)
        let service = FailureInjectingSpaceGenerationService()
        await service.setFailAt(.create)
        let vm = ProcessingViewModel(spaceService: service)
        let summary = makeSummary(sessionId: sessionId, packageRoot: root, valid: true)
        vm.start(summary: summary, allowStubVideoInMock: true)
        try await waitUntil(timeout: 8) { vm.errorMessage != nil }

        let uploadCount = await service.uploadCount
        XCTAssertEqual(uploadCount, 0)
        XCTAssertTrue(vm.canRetrySameCapture)
    }

    func testStartFailureInjectionAfterUpload() async throws {
        let sessionId = "SESSION_ST_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try makeZipReadyPackage(sessionId: sessionId)
        let service = FailureInjectingSpaceGenerationService()
        await service.setFailAt(.start)
        let vm = ProcessingViewModel(spaceService: service)
        let summary = makeSummary(sessionId: sessionId, packageRoot: root, valid: true)
        vm.start(summary: summary, allowStubVideoInMock: true)
        try await waitUntil(timeout: 8) { vm.errorMessage != nil }

        let uploadCount = await service.uploadCount
        let startCount = await service.startCount
        XCTAssertEqual(uploadCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(vm.pipelineSteps[2].status, .failed("요청 실패"))
        XCTAssertTrue(vm.canRetrySameCapture)
    }

    func testRetryReusesSameIdempotencyKey() async throws {
        let sessionId = "SESSION_RT_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try makeZipReadyPackage(sessionId: sessionId)
        let service = FailureInjectingSpaceGenerationService()
        await service.setFailAt(.upload)
        let vm = ProcessingViewModel(spaceService: service)
        let summary = makeSummary(sessionId: sessionId, packageRoot: root, valid: true)
        vm.start(summary: summary, allowStubVideoInMock: true)
        try await waitUntil(timeout: 8) { vm.errorMessage != nil }
        let key1 = await service.lastIdempotencyKey

        await service.setFailAt(.none)
        vm.retrySameCapture(summary: summary, qualityProfile: "capture_dense_v2", allowStubVideoInMock: true)
        try await waitUntil(timeout: 8) { vm.handoff != nil || (vm.errorMessage != nil && !vm.isRunning) }

        let key2 = await service.lastIdempotencyKey
        let createCount = await service.createCount
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(createCount, 2)
        XCTAssertNotNil(vm.handoff)
    }

    func testCancelDuringUploadDoesNotDeletePackageAndAllowsRetry() async throws {
        let sessionId = "SESSION_CX_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let root = try makeZipReadyPackage(sessionId: sessionId)
        let service = FailureInjectingSpaceGenerationService()
        await service.setUploadDelay(500_000_000)
        let vm = ProcessingViewModel(spaceService: service)
        let summary = makeSummary(sessionId: sessionId, packageRoot: root, valid: true)
        vm.start(summary: summary, allowStubVideoInMock: true)
        try await waitUntil(timeout: 5) {
            let uploads = await service.uploadCount
            return uploads >= 1 || vm.errorMessage != nil
        }
        vm.cancel()
        try await waitUntil(timeout: 5) {
            !vm.isRunning && (vm.canRetrySameCapture || vm.errorMessage != nil)
        }

        XCTAssertTrue(
            CapturePackageRetention.hasRetainedSpatialPackage(sessionId: sessionId, packageRootHint: root)
        )
        let cancelCount = await service.cancelCount
        XCTAssertEqual(cancelCount, 0, "local cancel must not DELETE server draft")
        XCTAssertTrue(vm.canRetrySameCapture)
        XCTAssertEqual(vm.errorMessage, SpaceGenerationErrorPresenter.uploadCancelled)
    }

    func testMissingPackageBlocksRetry() async throws {
        let sessionId = "SESSION_MISS_\(UUID().uuidString.prefix(8))"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        _ = try CaptureSessionStore.createSessionDirectory(sessionId: sessionId)
        let service = FailureInjectingSpaceGenerationService()
        let vm = ProcessingViewModel(spaceService: service)
        let emptyRoot = try CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        let summary = makeSummary(sessionId: sessionId, packageRoot: emptyRoot, valid: true)
        vm.start(summary: summary, allowStubVideoInMock: true)
        try await waitUntil(timeout: 5) { vm.errorMessage != nil }

        XCTAssertFalse(vm.canRetrySameCapture)
        XCTAssertTrue(vm.errorMessage?.contains("원본") == true)
        let createCount = await service.createCount
        XCTAssertEqual(createCount, 0)
    }

    // MARK: - Helpers

    private func makeSummary(
        sessionId: String,
        packageRoot: URL,
        valid: Bool
    ) -> CaptureSessionSummary {
        let foundation = CaptureDataFoundationSummary(
            schemaVersion: 1,
            videoFramesWritten: 100,
            poseSamples: 100,
            droppedVideoFrames: 0,
            keyframe3DGSCount: 2,
            depthSamples: 0,
            maxBaselineM: 1.0,
            totalPathLengthM: 2.0,
            translationBaselineGrade: .good,
            viewAngleDiversity: 0.5,
            overlapAvailable: true,
            spatialCapturePackageURL: packageRoot,
            spatialCapturePackageValid: valid
        )
        return CaptureSessionSummary(
            captureId: sessionId,
            sessionId: sessionId,
            startedAt: Date().addingTimeInterval(-30),
            endedAt: Date(),
            quality: .zero,
            fastMotionSegments: 0,
            lowTextureWarnings: 0,
            areasNeedingRevisit: 0,
            suggestedName: "테스트 공간",
            dataFoundation: foundation
        )
    }

    /// Two JPEGs + required JSON so SpatialCapturePackageZipper accepts the package.
    private func makeZipReadyPackage(sessionId: String) throws -> URL {
        let root = try CaptureSessionStore.spatialCapturePackageDirectory(sessionId: sessionId)
        let frames = root.appendingPathComponent(SpatialCaptureConfig.framesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let jpeg = try makeTinyJPEG()
        try jpeg.write(to: frames.appendingPathComponent("kf_00001.jpg"))
        try jpeg.write(to: frames.appendingPathComponent("kf_00002.jpg"))

        let encoder = JSONEncoder()
        let meta = SpatialCapturePackageMetadata(
            captureId: sessionId,
            sessionId: sessionId,
            captureVersion: SpatialCaptureConfig.captureVersion,
            pipelineVersion: SpatialCaptureConfig.pipelineVersion,
            createdAt: "2026-01-01T00:00:00Z",
            deviceModel: "iPhone",
            iOSVersion: "17.0",
            hasLiDAR: false,
            supportsSceneDepth: false,
            supportsSmoothedSceneDepth: false,
            supportsSceneReconstruction: false,
            imageWidth: 2,
            imageHeight: 2,
            selectedKeyframeCount: 2,
            rejectedDecisionCount: 0,
            captureDurationSec: 10,
            totalTranslationDistanceM: 1,
            jpegCompressionQuality: 0.9,
            jpegMaxLongEdge: nil,
            averageJPEGBytes: 10,
            packageBytesEstimate: 20,
            videoMovIncluded: false,
            videoRelativePath: nil
        )
        try encoder.encode(meta).write(to: root.appendingPathComponent(SpatialCaptureConfig.metadataFileName))

        let identity = CaptureFrameContract.encodeTransform(matrix_identity_float4x4)
        let poses = SpatialCapturePosesFile(
            schemaVersion: 1,
            coordinateConvention: SpatialCaptureCoordinateConvention.documentId,
            unit: "meters",
            matrixLayout: "column_major_4x4_camera_to_world",
            frames: [
                SpatialCapturePoseEntry(
                    frameId: "kf_00001",
                    arTimestampSeconds: 1,
                    cameraToWorldColumnMajor: identity,
                    translationMeters: [0, 0, 0],
                    rotationQuaternionXYZw: [0, 0, 0, 1],
                    trackingState: "normal"
                ),
                SpatialCapturePoseEntry(
                    frameId: "kf_00002",
                    arTimestampSeconds: 2,
                    cameraToWorldColumnMajor: identity,
                    translationMeters: [0.2, 0, 0],
                    rotationQuaternionXYZw: [0, 0, 0, 1],
                    trackingState: "normal"
                ),
            ]
        )
        try encoder.encode(poses).write(to: root.appendingPathComponent(SpatialCaptureConfig.posesFileName))

        let intrinsics = SpatialCaptureIntrinsicsFile(
            schemaVersion: 1,
            frames: [
                SpatialCaptureIntrinsicsEntry(
                    frameId: "kf_00001", fx: 1, fy: 1, cx: 0, cy: 0, width: 2, height: 2,
                    pixelSpace: "arkit_sensor"
                ),
                SpatialCaptureIntrinsicsEntry(
                    frameId: "kf_00002", fx: 1, fy: 1, cx: 0, cy: 0, width: 2, height: 2,
                    pixelSpace: "arkit_sensor"
                ),
            ]
        )
        try encoder.encode(intrinsics).write(to: root.appendingPathComponent(SpatialCaptureConfig.intrinsicsFileName))

        let quality = SpatialCaptureQualityFile(
            schemaVersion: 1,
            session: SpatialCaptureSessionQuality(
                acceptedFrames: 2,
                rejectedDecisions: 0,
                averageSharpness: nil,
                trackingFailureCount: 0,
                totalTranslationM: 0.2,
                observedCoverage: 0.5,
                qualityCoverage: 0.5,
                viewAngleDiversity: 0.5,
                captureDurationSec: 10,
                translationBaselineGrade: "good"
            ),
            frames: []
        )
        try encoder.encode(quality).write(to: root.appendingPathComponent(SpatialCaptureConfig.qualityFileName))

        let convention = try JSONSerialization.data(
            withJSONObject: SpatialCaptureCoordinateConvention.jsonObject,
            options: [.prettyPrinted]
        )
        try convention.write(
            to: root.appendingPathComponent(SpatialCaptureConfig.coordinateConventionFileName)
        )

        try SpatialCapturePackageValidator.validate(packageRoot: root)
        return root
    }

    private func makeTinyJPEG() throws -> Data {
        // Minimal valid-enough JPEG for package tests (SOI+EOI).
        Data([0xFF, 0xD8, 0xFF, 0xD9])
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

private extension FailureInjectingSpaceGenerationService {
    func setFailAt(_ value: FailAt) {
        failAt = value
    }

    func setUploadDelay(_ ns: UInt64) {
        uploadDelayNanoseconds = ns
    }
}

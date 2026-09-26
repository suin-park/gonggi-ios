import XCTest
import simd
@testable import Gonggi

/// Build 71 client (unchanged app code) against the formal-feature server responses.
/// Records what the Processing screen and the Library card show. Lines prefixed [B71IMPACT].
@MainActor
final class B71FormalServerImpactTests: XCTestCase {
    private var requests: [(method: String, path: String, body: [String: Any])] = []

    override func setUp() {
        super.setUp()
        // Build 71 shows the 3D flow only when the beta toggle is on (internal testers).
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(true)
        MobileAuthTokenStore.shared.setAccessToken("test-token")
        requests = []
    }

    override func tearDown() {
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(nil)
        MobileAuthTokenStore.shared.setAccessToken(nil)
        super.tearDown()
    }

    private func report(_ s: String) {
        print("[B71IMPACT] \(s)")
    }

    private static let jobJSON: (String, String) -> String = { status, err in
        """
        {"id":"job1","spaceId":"space1","status":"\(status)","stage":"\(status)","errorCode":\(err.isEmpty ? "null" : "\"\(err)\""),
         "metrics":{"qualityProfile":"spatial_package_colmap_fastergs_native_v1"},"progress":null}
        """
    }

    /// Stub: create → PUT → start with the given create/start responses.
    private func makeService(create: (Int, String), start: (Int, String)) -> LockerSpaceGenerationService {
        let session = MockURLProtocol.makeSession { [weak self] request in
            let path = request.url?.path ?? ""
            var body: [String: Any] = [:]
            if let data = request.httpBody ?? request.httpBodyStreamData(),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = obj
            }
            DispatchQueue.main.async { self?.requests.append((request.httpMethod ?? "", path, body)) }
            if path.hasSuffix("/spatial-package") {
                return (create.0, Data(create.1.utf8))
            }
            if path.hasSuffix("/start") {
                return (start.0, Data(start.1.utf8))
            }
            if request.httpMethod == "PUT" {
                return (200, Data())
            }
            return (404, Data("{}".utf8))
        }
        return LockerSpaceGenerationService(session: session)
    }

    private var createOK: (Int, String) {
        (200, """
        {"space":{"id":"space1"},"job":\(Self.jobJSON("uploading", "")),"uploadUrl":"https://r2.example/put"}
        """)
    }

    private func runProcessing(_ service: LockerSpaceGenerationService, name: String) async throws -> ProcessingViewModel {
        let sessionId = "SESSION_B71_\(name)_\(UUID().uuidString.prefix(6))"
        let root = try makeZipReadyPackage(sessionId: sessionId)
        addTeardownBlock { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let vm = ProcessingViewModel(spaceService: service)
        vm.start(summary: makeSummary(sessionId: sessionId, packageRoot: root, valid: true), allowStubVideoInMock: true)
        try await waitUntil(timeout: 20) { !vm.isRunning && (vm.handoff != nil || vm.errorMessage != nil) }
        return vm
    }

    func testA_InternalUserNativeStartsAndRequestsStayV1() async throws {
        let service = makeService(create: createOK, start: (200, """
        {"job":\(Self.jobJSON("queued", "")),"submitted":true,"reason":"submitted"}
        """))
        let vm = try await runProcessing(service, name: "A")
        try await Task.sleep(nanoseconds: 200_000_000)
        let create = requests.first { $0.path.hasSuffix("/spatial-package") }
        let start = requests.first { $0.path.hasSuffix("/start") }
        report("A handoff=\(vm.handoff != nil) error=\(vm.errorMessage ?? "nil")")
        report("A createProfile=\(create?.body["qualityProfile"] ?? "nil") startProfile=\(start?.body["qualityProfile"] ?? "nil")")
        XCTAssertNotNil(vm.handoff)
    }

    func testB_NotInRolloutCreateForbidden() async throws {
        let service = makeService(
            create: (403, #"{"error":"VIDEO_GAUSSIAN_CREATE_FORBIDDEN","message":"3D space record is not available right now"}"#),
            start: (500, "{}")
        )
        let vm = try await runProcessing(service, name: "B")
        report("B error=\(vm.errorMessage ?? "nil") | retryButton=\(vm.canRetrySameCapture) | steps=\(vm.pipelineSteps.map { "\($0.kind):\($0.status)" })")
        XCTAssertNotNil(vm.errorMessage)
    }

    func testC_NativeUnavailableAtStart() async throws {
        GaussianGenerationStore.shared.bind(userId: "b71-impact-test")
        defer { GaussianGenerationStore.shared.unbind() }
        let service = makeService(create: createOK, start: (503, #"{"error":"NATIVE_UNAVAILABLE","message":"NATIVE_SUBMIT_BLOCKED:..."}"#))
        let vm = try await runProcessing(service, name: "C")
        report("C error=\(vm.errorMessage ?? "nil") | retryButton=\(vm.canRetrySameCapture)")
        let card = GaussianGenerationStore.shared.record(spaceId: "space1")
        report("C libraryCard status=\(card?.status ?? "no card (store unbound in test)") label=\(card?.userFacingStatusLabel ?? "-")")
        XCTAssertNotNil(vm.errorMessage)
    }

    func testD_JobLimitAtCreate() async throws {
        for code in ["JOB_LIMIT_ACTIVE", "JOB_LIMIT_DAILY"] {
            requests = []
            let service = makeService(create: (429, #"{"error":"\#(code)","message":"x"}"#), start: (500, "{}"))
            let vm = try await runProcessing(service, name: "D\(code)")
            report("D \(code) error=\(vm.errorMessage ?? "nil") | retryButton=\(vm.canRetrySameCapture)")
        }
    }

    func testE_LibraryPollingOfServerStates() async throws {
        for (status, err) in [("queued", ""), ("training", ""), ("completed", ""), ("failed", "NATIVE_UNAVAILABLE"),
                              ("failed", "OFFICIAL_TRAIN_FAILED"), ("expired", "JOB_EXPIRED"), ("uploading", "")] {
            let json = #"{"job":\#(Self.jobJSON(status, err))}"#
            let session = MockURLProtocol.makeSession { _ in (200, Data(json.utf8)) }
            let service = LockerSpaceGenerationService(session: session)
            service.seedJobContext(jobId: "job1", spaceId: "space1", qualityProfile: "spatial_package_v1")
            let st = try await service.fetchStatus(jobId: "job1")
            let failed = st.steps.contains { if case .failed = $0.status { return true }; return false }
            // Build 71 AppState.pollGaussianJobsOnce mapping:
            let mapped = failed ? "failed" : (st.overallProgress >= 0.99 ? "ready" : "processing")
            report("E server=\(status)/\(err.isEmpty ? "-" : err) → b71 card=\(mapped) (progress \(st.overallProgress))")
        }
    }

    // MARK: - Helpers (copied verbatim from build 71 ClientGenerationPipelineTests)

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

private extension URLRequest {
    /// URLProtocol often receives the body as a stream.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

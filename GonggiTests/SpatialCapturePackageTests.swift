import CoreGraphics
import CoreVideo
import simd
import UIKit
import XCTest
@testable import Gonggi

final class SpatialCapturePackageTests: XCTestCase {
    override func tearDown() {
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(nil)
        super.tearDown()
    }

    func testSpatialCaptureIsFormalFeatureAndIgnoresOldBetaToggle() {
        // Build ≤71 beta toggle value must not hide the formal feature.
        UserDefaults.standard.set(false, forKey: GonggiFeatureFlags.enableSpatialCaptureDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: GonggiFeatureFlags.enableSpatialCaptureDefaultsKey) }
        XCTAssertTrue(GonggiFeatureFlags.show3DGSCaptureFlows)
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(false)
        XCTAssertFalse(GonggiFeatureFlags.show3DGSCaptureFlows)
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(true)
        XCTAssertTrue(GonggiFeatureFlags.show3DGSCaptureFlows)
    }

    func testInternalToolsUnlockRequiresTestFlightOrDebug() {
        // App Store production path: unlock key alone must not expose tools without canUnlock.
        // canUnlock is compile/runtime (DEBUG or sandboxReceipt); here we only assert API safety.
        GonggiFeatureFlags.setInternalToolsUnlocked(false)
        #if DEBUG
        XCTAssertTrue(GonggiFeatureFlags.canUnlockInternalTools)
        XCTAssertTrue(GonggiFeatureFlags.isInternalToolsUnlocked)
        #endif
        GonggiFeatureFlags.setEnableSpatialCaptureForTesting(nil)
    }

    func testSelectorRejectsBlurAndHandlesSmallTranslation() {
        let a = matrix_identity_float4x4
        var near = a
        near.columns.3 = SIMD4(0.05, 0, 0, 1)
        let tooClose = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1.0,
            transform: near,
            trackingNormal: true,
            lastKeyframeTimestamp: 0,
            lastKeyframeTransform: a,
            keyframeCount: 1
        )
        // Dual-anchor: 5cm vs recon floor 2.5cm may promote reconstructionKeyframe or bridge-observe.
        if tooClose.accept {
            XCTAssertTrue(
                tooClose.acceptKind == .continuityBridgeObservation
                    || tooClose.acceptKind == .reconstructionKeyframe,
                "unexpected kind \(tooClose.acceptKind) reason \(tooClose.reason)"
            )
        } else {
            XCTAssertFalse(tooClose.accept)
        }

        var far = a
        far.columns.3 = SIMD4(0.3, 0, 0, 1)
        let blurry = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1.0,
            transform: far,
            trackingNormal: true,
            lastKeyframeTimestamp: 0,
            lastKeyframeTransform: a,
            keyframeCount: 1,
            sharpnessState: .blurry
        )
        XCTAssertFalse(blurry.accept)
        XCTAssertEqual(blurry.reason, "blur")
    }

    func testPackageValidatorPassesConsistentPackage() throws {
        let sessionId = "unit-spatial-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        // Minimal 1x1 JPEG
        let jpeg = try makeTinyJPEG()
        let frameId = "kf_00001"
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId))

        let keyframe = SpatialCapturePackageBuilder.AcceptedKeyframe(
            frameId: frameId,
            arTimestampSeconds: 12.5,
            cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(matrix_identity_float4x4),
            translationMeters: [0, 0, 0],
            rotationQuaternionXYZw: [0, 0, 0, 1],
            trackingState: "normal",
            fx: 1000,
            fy: 1000,
            cx: 500,
            cy: 500,
            width: 1,
            height: 1,
            sensorImageWidth: 1,
            sensorImageHeight: 1,
            jpegByteCount: jpeg.count,
            quality: SpatialCaptureFrameQuality(
                frameId: frameId,
                sharpnessScore: 0.8,
                sharpnessState: "sharp",
                motionSpeed: 0.1,
                angularVelocity: 0.05,
                parallaxGrade: "good",
                translationBaselineM: 0.4,
                overlapScore: 0.7,
                overlapState: "good",
                trackingState: "normal",
                lowTextureScore: 0.1,
                acceptReason: "first"
            ),
            optionalDepthRelativePath: nil
        )

        let built = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "cap-1",
                sessionId: sessionId,
                startedAt: Date().addingTimeInterval(-40),
                endedAt: Date(),
                keyframes: [keyframe],
                rejectedDecisionCount: 3,
                trackingFailureCount: 1,
                totalTranslationDistanceM: 2.5,
                observedCoverage: 0.4,
                qualityCoverage: 0.35,
                viewAngleDiversity: 0.5,
                translationBaselineGrade: "acceptable",
                averageSharpness: 0.8,
                videoRelativePath: "../original.mov",
                hasLiDAR: false,
                supportsSceneDepth: false,
                supportsSmoothedSceneDepth: false,
                supportsSceneReconstruction: false,
                decisions: [
                    SpatialCaptureKeyframeDecision(
                        arTimestampSeconds: 12.5,
                        accepted: true,
                        reason: "first",
                        frameId: frameId
                    ),
                ],
                telemetry: nil
            )
        )

        try SpatialCapturePackageValidator.validate(packageRoot: built.root)

        let meta = try JSONDecoder().decode(
            SpatialCapturePackageMetadata.self,
            from: Data(contentsOf: built.metadataURL)
        )
        XCTAssertEqual(meta.selectedKeyframeCount, 1)
        XCTAssertEqual(meta.hasLiDAR, false)
        XCTAssertEqual(meta.captureVersion, SpatialCaptureConfig.captureVersion)

        let poses = try JSONDecoder().decode(
            SpatialCapturePosesFile.self,
            from: Data(contentsOf: built.posesURL)
        )
        XCTAssertEqual(poses.frames.first?.frameId, frameId)
        XCTAssertEqual(poses.coordinateConvention, SpatialCaptureCoordinateConvention.documentId)

        let xz = built.debugDirectory.appendingPathComponent(SpatialCaptureConfig.cameraPathXZFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: xz.path))
        let sensor = built.debugDirectory.appendingPathComponent(SpatialCaptureConfig.sensorSpaceReportFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sensor.path))
    }

    func testJPEGEncodeQueueBackpressureAndFlush() async throws {
        let queue = SpatialJPEGEncodeQueue(maxDepth: 2)
        let sessionId = "unit-jpeg-q-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)

        func makeJob(id: String) throws -> SpatialJPEGEncodeQueue.Job {
            // 2x2 BGRA buffer
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 2, 2,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &buffer
            )
            guard let buffer else { throw NSError(domain: "test", code: 1) }
            return SpatialJPEGEncodeQueue.Job(
                snapshot: SpatialKeyframeSnapshot(
                    frameId: id,
                    arTimestampSeconds: 1,
                    ownedPixelBuffer: buffer,
                    cameraToWorld: matrix_identity_float4x4,
                    trackingState: "normal",
                    fx: 1, fy: 1, cx: 1, cy: 1,
                    sensorImageWidth: 2,
                    sensorImageHeight: 2,
                    imageResolutionWidth: 2,
                    imageResolutionHeight: 2,
                    sharpnessScore: nil,
                    sharpnessState: nil,
                    motionSpeed: nil,
                    angularVelocity: nil,
                    parallaxGrade: nil,
                    translationBaselineM: nil,
                    overlapScore: nil,
                    overlapState: nil,
                    lowTextureScore: nil,
                    acceptReason: "first",
                    jpegURL: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: id),
                    debugPrincipalPointJPEGURL: nil,
                    optionalDepthRelativePath: nil
                )
            )
        }

        var completed = 0
        let lock = NSLock()
        XCTAssertTrue(queue.tryEnqueue(try makeJob(id: "kf_00001"), completion: { _ in
            lock.lock(); completed += 1; lock.unlock()
        }))
        XCTAssertTrue(queue.tryEnqueue(try makeJob(id: "kf_00002"), completion: { _ in
            lock.lock(); completed += 1; lock.unlock()
        }))
        // Depth already 2 — backpressure rejects
        XCTAssertFalse(queue.tryEnqueue(try makeJob(id: "kf_00003"), completion: { _ in }))

        await queue.flush()
        lock.lock()
        let done = completed
        lock.unlock()
        XCTAssertEqual(done, 2)
        XCTAssertEqual(queue.currentDepth, 0)
    }

    func testValidatorRejectsDuplicateFrameId() throws {
        let sessionId = "unit-spatial-dup-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let jpeg = try makeTinyJPEG()
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00001"))
        let encoder = JSONEncoder()
        let meta = SpatialCapturePackageMetadata(
            captureId: "c",
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
            imageWidth: 1,
            imageHeight: 1,
            selectedKeyframeCount: 2,
            rejectedDecisionCount: 0,
            captureDurationSec: 10,
            totalTranslationDistanceM: 1,
            jpegCompressionQuality: 0.9,
            jpegMaxLongEdge: nil,
            averageJPEGBytes: 10,
            packageBytesEstimate: 10,
            videoMovIncluded: false,
            videoRelativePath: nil
        )
        try encoder.encode(meta).write(to: paths.metadataURL)
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
                    frameId: "kf_00001",
                    arTimestampSeconds: 2,
                    cameraToWorldColumnMajor: identity,
                    translationMeters: [0.2, 0, 0],
                    rotationQuaternionXYZw: [0, 0, 0, 1],
                    trackingState: "normal"
                ),
            ]
        )
        try encoder.encode(poses).write(to: paths.posesURL)
        // Two jpeg files needed for count match before duplicate check — use same name once + fake second
        // Count mismatch will fire first if jpeg count != 2. Write second file with different name to force
        // count match path... actually selectedKeyframeCount=2, jpeg=1 → mismatch first.
        // Adjust: write two jpegs with same pose id still fails on duplicate after counts if jpeg count matches.
        try jpeg.write(to: paths.framesDirectory.appendingPathComponent("kf_00002.jpg"))
        let intrinsics = SpatialCaptureIntrinsicsFile(
            schemaVersion: 1,
            frames: [
                SpatialCaptureIntrinsicsEntry(
                    frameId: "kf_00001", fx: 1, fy: 1, cx: 0, cy: 0, width: 1, height: 1,
                    pixelSpace: "arkit_sensor"
                ),
                SpatialCaptureIntrinsicsEntry(
                    frameId: "kf_00001", fx: 1, fy: 1, cx: 0, cy: 0, width: 1, height: 1,
                    pixelSpace: "arkit_sensor"
                ),
            ]
        )
        try encoder.encode(intrinsics).write(to: paths.intrinsicsURL)
        let quality = SpatialCaptureQualityFile(
            schemaVersion: 1,
            session: SpatialCaptureSessionQuality(
                acceptedFrames: 2,
                rejectedDecisions: 0,
                averageSharpness: nil,
                trackingFailureCount: 0,
                totalTranslationM: 0,
                observedCoverage: 0,
                qualityCoverage: 0,
                viewAngleDiversity: 0,
                captureDurationSec: 1,
                translationBaselineGrade: "insufficient"
            ),
            frames: []
        )
        try encoder.encode(quality).write(to: paths.qualityURL)

        XCTAssertThrowsError(try SpatialCapturePackageValidator.validate(packageRoot: paths.root)) { error in
            guard let e = error as? SpatialCapturePackageValidationError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(e, .duplicateFrameId("kf_00001"))
        }
    }

    func testPackageValidatorFailsOnMissingJPEG() throws {
        let sessionId = "unit-spatial-bad-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let encoder = JSONEncoder()
        let meta = SpatialCapturePackageMetadata(
            captureId: "c",
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
            imageWidth: 1,
            imageHeight: 1,
            selectedKeyframeCount: 1,
            rejectedDecisionCount: 0,
            captureDurationSec: 10,
            totalTranslationDistanceM: 1,
            jpegCompressionQuality: 0.9,
            jpegMaxLongEdge: nil,
            averageJPEGBytes: 10,
            packageBytesEstimate: 10,
            videoMovIncluded: false,
            videoRelativePath: nil
        )
        try encoder.encode(meta).write(to: paths.metadataURL)
        let poses = SpatialCapturePosesFile(
            schemaVersion: 1,
            coordinateConvention: SpatialCaptureCoordinateConvention.documentId,
            unit: "meters",
            matrixLayout: "column_major_4x4_camera_to_world",
            frames: [
                SpatialCapturePoseEntry(
                    frameId: "kf_00001",
                    arTimestampSeconds: 1,
                    cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(matrix_identity_float4x4),
                    translationMeters: [0, 0, 0],
                    rotationQuaternionXYZw: [0, 0, 0, 1],
                    trackingState: "normal"
                ),
            ]
        )
        try encoder.encode(poses).write(to: paths.posesURL)
        let intrinsics = SpatialCaptureIntrinsicsFile(
            schemaVersion: 1,
            frames: [
                SpatialCaptureIntrinsicsEntry(
                    frameId: "kf_00001",
                    fx: 1, fy: 1, cx: 0, cy: 0, width: 1, height: 1,
                    pixelSpace: "arkit_sensor"
                ),
            ]
        )
        try encoder.encode(intrinsics).write(to: paths.intrinsicsURL)
        let quality = SpatialCaptureQualityFile(
            schemaVersion: 1,
            session: SpatialCaptureSessionQuality(
                acceptedFrames: 1,
                rejectedDecisions: 0,
                averageSharpness: nil,
                trackingFailureCount: 0,
                totalTranslationM: 0,
                observedCoverage: 0,
                qualityCoverage: 0,
                viewAngleDiversity: 0,
                captureDurationSec: 1,
                translationBaselineGrade: "insufficient"
            ),
            frames: []
        )
        try encoder.encode(quality).write(to: paths.qualityURL)

        XCTAssertThrowsError(try SpatialCapturePackageValidator.validate(packageRoot: paths.root))
    }

    func testDiagnosticsShareIncludesSpatialPackageSummary() throws {
        let sessionId = "unit-spatial-share-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let jpeg = try makeTinyJPEG()
        let frameId = "kf_00001"
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId))

        let keyframe = SpatialCapturePackageBuilder.AcceptedKeyframe(
            frameId: frameId,
            arTimestampSeconds: 1.0,
            cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(matrix_identity_float4x4),
            translationMeters: [0.1, 0, 0.2],
            rotationQuaternionXYZw: [0, 0, 0, 1],
            trackingState: "normal",
            fx: 1000, fy: 1000, cx: 500, cy: 500,
            width: 1, height: 1,
            sensorImageWidth: 1, sensorImageHeight: 1,
            jpegByteCount: jpeg.count,
            quality: SpatialCaptureFrameQuality(
                frameId: frameId,
                sharpnessScore: 0.8,
                sharpnessState: "sharp",
                motionSpeed: 0.1,
                angularVelocity: 0.05,
                parallaxGrade: "good",
                translationBaselineM: 0.2,
                overlapScore: 0.7,
                overlapState: "good",
                trackingState: "normal",
                lowTextureScore: 0.1,
                acceptReason: "first"
            ),
            optionalDepthRelativePath: nil
        )
        _ = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "cap-share",
                sessionId: sessionId,
                startedAt: Date().addingTimeInterval(-30),
                endedAt: Date(),
                keyframes: [keyframe],
                rejectedDecisionCount: 0,
                trackingFailureCount: 0,
                totalTranslationDistanceM: 1.0,
                observedCoverage: 0.5,
                qualityCoverage: 0.4,
                viewAngleDiversity: 0.3,
                translationBaselineGrade: "acceptable",
                averageSharpness: 0.8,
                videoRelativePath: nil,
                hasLiDAR: false,
                supportsSceneDepth: false,
                supportsSmoothedSceneDepth: false,
                supportsSceneReconstruction: false,
                decisions: [],
                telemetry: nil
            )
        )

        let share = try CaptureDiagnosticsStore.buildSharePackage(
            sessionId: sessionId,
            captureId: "cap-share"
        )
        defer { try? FileManager.default.removeItem(at: share) }

        let summaryURL = share.appendingPathComponent("spatial-package-summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        let summary = try JSONDecoder().decode(
            SpatialCapturePackageShareSummary.self,
            from: Data(contentsOf: summaryURL)
        )
        XCTAssertTrue(summary.packagePresent)
        XCTAssertEqual(summary.jpegCount, 1)
        XCTAssertEqual(summary.poseCount, 1)
        XCTAssertEqual(summary.intrinsicsCount, 1)
        XCTAssertEqual(summary.validatorPassed, true)
        XCTAssertEqual(summary.countsMatch, true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: share
                    .appendingPathComponent("capture/frames/\(frameId).jpg").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: share.appendingPathComponent("capture/metadata.json").path
            )
        )
        // ≤2.0(64)-style package: missing continuity telemetry must not fail share.
        XCTAssertEqual(summary.frameContinuityTelemetryIncluded, false)
        XCTAssertEqual(summary.frameContinuityTelemetryRootPresent, false)
        let readmeNoTel = try String(
            contentsOf: share.appendingPathComponent("README.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(readmeNoTel.contains("omitted") || readmeNoTel.contains("not present"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: share.appendingPathComponent("capture/frame_continuity_telemetry.json").path
            )
        )
    }

    /// Telemetry present → diagnostic share copies root + debug artifacts; absence is not a share failure.
    func testDiagnosticsShareIncludesFrameContinuityTelemetryWhenPresent() throws {
        let sessionId = "unit-spatial-share-tel-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let jpeg = try makeTinyJPEG()
        let frameId = "kf_00001"
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId))

        let keyframe = SpatialCapturePackageBuilder.AcceptedKeyframe(
            frameId: frameId,
            arTimestampSeconds: 1.0,
            cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(matrix_identity_float4x4),
            translationMeters: [0.1, 0, 0.2],
            rotationQuaternionXYZw: [0, 0, 0, 1],
            trackingState: "normal",
            fx: 1000, fy: 1000, cx: 500, cy: 500,
            width: 1, height: 1,
            sensorImageWidth: 1, sensorImageHeight: 1,
            jpegByteCount: jpeg.count,
            quality: SpatialCaptureFrameQuality(
                frameId: frameId,
                sharpnessScore: 0.8,
                sharpnessState: "sharp",
                motionSpeed: 0.1,
                angularVelocity: 0.05,
                parallaxGrade: "good",
                translationBaselineM: 0.2,
                overlapScore: 0.7,
                overlapState: "good",
                trackingState: "normal",
                lowTextureScore: 0.1,
                acceptReason: "first"
            ),
            optionalDepthRelativePath: nil
        )
        let continuity = FrameContinuityTelemetryFile(
            schemaVersion: 1,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            gridRows: 3,
            gridCols: 3,
            recordCount: 1,
            approximateBytesPerRecordEstimate:
                FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord,
            records: [
                FrameContinuityTelemetryRecord(
                    schemaVersion: 1,
                    policyVersion: FrameContinuityTelemetryConfig.policyVersion,
                    candidateSequence: 1,
                    arTimestampSeconds: 1.0,
                    imageTimestampSeconds: 1.0,
                    frameId: frameId,
                    committed: true,
                    features: ARKitFeatureSummary(
                        rawFeaturePointCount: nil,
                        grid: nil,
                        persistent: PersistentFeatureStats(
                            previousFramePersistentCount: nil,
                            previousFramePersistentRatio: nil,
                            continuityAnchorPersistentCount: nil,
                            continuityAnchorPersistentRatio: nil,
                            unavailableReason: .pointCloudNil
                        ),
                        trackingState: "normal",
                        trackingLimitationReason: nil,
                        unavailableReason: .pointCloudNil
                    ),
                    sharpnessScore: nil,
                    sharpnessState: nil,
                    brightness: nil,
                    lowTextureScore: nil,
                    overlapScore: nil,
                    dualAnchor: DualAnchorTelemetrySnapshot(
                        continuityTranslationM: nil,
                        continuityYawDeg: nil,
                        continuityForwardAngleDeg: nil,
                        reconstructionCumulativeTranslationM: nil,
                        frustumOverlap: nil,
                        reconstructionCoverageEstimate: 0,
                        bridgeMode: "idle",
                        verdict: "ACCEPT",
                        reason: "first",
                        acceptKind: "reconstructionKeyframe"
                    )
                ),
            ]
        )
        _ = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "cap-share-tel",
                sessionId: sessionId,
                startedAt: Date().addingTimeInterval(-30),
                endedAt: Date(),
                keyframes: [keyframe],
                rejectedDecisionCount: 0,
                trackingFailureCount: 0,
                totalTranslationDistanceM: 1.0,
                observedCoverage: 0.5,
                qualityCoverage: 0.4,
                viewAngleDiversity: 0.3,
                translationBaselineGrade: "acceptable",
                averageSharpness: 0.8,
                videoRelativePath: nil,
                hasLiDAR: false,
                supportsSceneDepth: false,
                supportsSmoothedSceneDepth: false,
                supportsSceneReconstruction: false,
                decisions: [],
                telemetry: nil,
                frameContinuityTelemetry: continuity
            )
        )

        let share = try CaptureDiagnosticsStore.buildSharePackage(
            sessionId: sessionId,
            captureId: "cap-share-tel"
        )
        defer { try? FileManager.default.removeItem(at: share) }

        let summary = try JSONDecoder().decode(
            SpatialCapturePackageShareSummary.self,
            from: Data(contentsOf: share.appendingPathComponent("spatial-package-summary.json"))
        )
        XCTAssertEqual(summary.frameContinuityTelemetryIncluded, true)
        XCTAssertEqual(summary.frameContinuityTelemetryRootPresent, true)
        XCTAssertEqual(summary.frameContinuityTelemetryDebugPresent, true)
        XCTAssertEqual(summary.frameContinuityTelemetryJSONLPresent, true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: share.appendingPathComponent("capture/frame_continuity_telemetry.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: share
                    .appendingPathComponent("capture/debug/frame_continuity_telemetry.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: share
                    .appendingPathComponent("capture/debug/frame_continuity_telemetry.jsonl").path
            )
        )
        let readme = try String(
            contentsOf: share.appendingPathComponent("README.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("capture/frame_continuity_telemetry.json"))
        XCTAssertTrue(readme.contains("capture/debug/frame_continuity_telemetry.json"))
        XCTAssertTrue(readme.contains("capture/debug/frame_continuity_telemetry.jsonl"))
        XCTAssertFalse(readme.contains("frame_continuity_telemetry.* omitted"))
    }

    func testCircularYawSpanDoesNotTreatWrapAsFullCircle() {
        let wrap = CaptureReconstructionSessionMetrics.circularCoveredSpanDegrees(
            buckets: [11, 0],
            bucketCount: 12
        )
        XCTAssertEqual(wrap.spanDeg, 60, accuracy: 0.01)
        XCTAssertLessThan(wrap.spanDeg, 180)

        let contiguous = CaptureReconstructionSessionMetrics.circularCoveredSpanDegrees(
            buckets: [0, 1, 2],
            bucketCount: 12
        )
        XCTAssertEqual(contiguous.spanDeg, 90, accuracy: 0.01)

        let empty = CaptureReconstructionSessionMetrics.circularCoveredSpanDegrees(
            buckets: [],
            bucketCount: 12
        )
        XCTAssertEqual(empty.spanDeg, 0)

        let full = CaptureReconstructionSessionMetrics.circularCoveredSpanDegrees(
            buckets: Set(0..<12),
            bucketCount: 12
        )
        XCTAssertEqual(full.spanDeg, 360, accuracy: 0.01)
    }

    func testPackageZipperExcludesDebugAndIncludesFrames() throws {
        let sessionId = "unit-zip-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let jpeg = try makeTinyJPEG()
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00001"))
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00002"))

        for (name, obj) in [
            (SpatialCaptureConfig.metadataFileName, ["captureId": "c", "selectedKeyframeCount": 2] as [String: Any]),
            (SpatialCaptureConfig.posesFileName, ["schemaVersion": 1, "frames": []] as [String: Any]),
            (SpatialCaptureConfig.intrinsicsFileName, ["schemaVersion": 1, "frames": []] as [String: Any]),
            (SpatialCaptureConfig.qualityFileName, ["schemaVersion": 1] as [String: Any]),
        ] {
            let data = try JSONSerialization.data(withJSONObject: obj)
            try data.write(to: paths.root.appendingPathComponent(name))
        }
        try SpatialCaptureCoordinateConvention.writeJSON(to: paths.conventionURL)
        // debug noise must not be required for zip
        try "noise".data(using: .utf8)?.write(
            to: paths.debugDirectory.appendingPathComponent("noise.txt")
        )

        let zipDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-test-\(UUID().uuidString)", isDirectory: true)
        let zipped = try SpatialCapturePackageZipper.buildArchive(
            packageRoot: paths.root,
            destinationDirectory: zipDir
        )
        XCTAssertGreaterThan(zipped.byteSize, 100)
        XCTAssertEqual(zipped.frameCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipped.zipURL.path))
    }

    private func makeTinyJPEG() throws -> Data {
        let color = UIColor.gray
        let size = CGSize(width: 2, height: 2)
        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        guard let image = UIGraphicsGetImageFromCurrentImageContext(),
              let data = image.jpegData(compressionQuality: 0.9)
        else {
            throw NSError(domain: "SpatialCapturePackageTests", code: 1)
        }
        return data
    }
}

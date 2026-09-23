import Foundation
import simd
import XCTest
@testable import Gonggi

final class FrameContinuityTelemetryTests: XCTestCase {
    func testSchemaRoundTripAndVersion() throws {
        let grid = FeatureGridOccupancy(
            rows: 3, cols: 3,
            cellCounts: [1, 0, 0, 0, 2, 0, 0, 0, 3],
            occupiedCellCount: 3,
            totalInBoundsPoints: 6,
            maxCellFraction: 0.5
        )
        let record = FrameContinuityTelemetryRecord(
            schemaVersion: FrameContinuityTelemetryConfig.schemaVersion,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            candidateSequence: 1,
            arTimestampSeconds: 12.5,
            imageTimestampSeconds: 12.5,
            frameId: "kf_00001",
            committed: true,
            features: ARKitFeatureSummary(
                rawFeaturePointCount: 42,
                grid: grid,
                persistent: PersistentFeatureStats(
                    previousFramePersistentCount: 10,
                    previousFramePersistentRatio: 0.25,
                    continuityAnchorPersistentCount: 8,
                    continuityAnchorPersistentRatio: 0.2,
                    unavailableReason: .none
                ),
                trackingState: "normal",
                trackingLimitationReason: nil,
                unavailableReason: .none
            ),
            sharpnessScore: 0.9,
            sharpnessState: "sharp",
            brightness: 0.55,
            lowTextureScore: 0.2,
            overlapScore: 0.8,
            dualAnchor: DualAnchorTelemetrySnapshot(
                continuityTranslationM: 0.05,
                continuityYawDeg: 4.0,
                continuityForwardAngleDeg: 3.5,
                reconstructionCumulativeTranslationM: 0.12,
                frustumOverlap: 0.88,
                reconstructionCoverageEstimate: 0.4,
                bridgeMode: "tracking",
                verdict: "ACCEPT",
                reason: "continuity_ok",
                acceptKind: "reconstructionKeyframe"
            )
        )
        let file = FrameContinuityTelemetryFile(
            schemaVersion: 1,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            gridRows: 3,
            gridCols: 3,
            recordCount: 1,
            approximateBytesPerRecordEstimate:
                FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord,
            records: [record]
        )
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(FrameContinuityTelemetryFile.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.gridRows, 3)
        XCTAssertEqual(decoded.gridCols, 3)
        XCTAssertEqual(decoded.records.first?.frameId, "kf_00001")
        XCTAssertEqual(decoded.records.first?.features.grid?.occupiedCellCount, 3)
        XCTAssertEqual(decoded.records.first?.dualAnchor.acceptKind, "reconstructionKeyframe")
    }

    func testLegacyPackageMetadataStillDecodesWithoutTelemetryField() throws {
        // Older 2.0(64) metadata JSON has no continuity telemetry reference.
        let json = """
        {
          "captureId": "c1",
          "sessionId": "s1",
          "captureVersion": "spatial-capture-package-v1",
          "pipelineVersion": "gonggi-spatial-capture-v1",
          "createdAt": "2026-09-17T00:00:00Z",
          "deviceModel": "iPhone15,2",
          "iOSVersion": "18.0",
          "hasLiDAR": true,
          "supportsSceneDepth": true,
          "supportsSmoothedSceneDepth": false,
          "supportsSceneReconstruction": true,
          "imageWidth": 1920,
          "imageHeight": 1440,
          "selectedKeyframeCount": 2,
          "rejectedDecisionCount": 0,
          "captureDurationSec": 10,
          "totalTranslationDistanceM": 1.0,
          "jpegCompressionQuality": 0.92,
          "videoMovIncluded": false
        }
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(SpatialCapturePackageMetadata.self, from: json)
        XCTAssertEqual(meta.captureId, "c1")
        XCTAssertEqual(meta.selectedKeyframeCount, 2)
    }

    func testUnavailableNullFallbackFields() throws {
        let summary = ARKitFeatureSummary(
            rawFeaturePointCount: nil,
            grid: nil,
            persistent: PersistentFeatureStats(
                previousFramePersistentCount: nil,
                previousFramePersistentRatio: nil,
                continuityAnchorPersistentCount: nil,
                continuityAnchorPersistentRatio: nil,
                unavailableReason: .pointCloudNil
            ),
            trackingState: "limited",
            trackingLimitationReason: "limited_insufficient_features",
            unavailableReason: .pointCloudNil
        )
        let data = try JSONEncoder().encode(summary)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue(obj?["rawFeaturePointCount"] is NSNull || obj?["rawFeaturePointCount"] == nil)
        let decoded = try JSONDecoder().decode(ARKitFeatureSummary.self, from: data)
        XCTAssertNil(decoded.rawFeaturePointCount)
        XCTAssertEqual(decoded.unavailableReason, .pointCloudNil)
        XCTAssertEqual(decoded.persistent.unavailableReason, .pointCloudNil)
    }

    func testPersistentIdentifiersUnsupportedLeavesNullCounts() throws {
        let stats = PersistentFeatureStats(
            previousFramePersistentCount: nil,
            previousFramePersistentRatio: nil,
            continuityAnchorPersistentCount: nil,
            continuityAnchorPersistentRatio: nil,
            unavailableReason: .identifiersUnsupported
        )
        XCTAssertNil(stats.previousFramePersistentCount)
        XCTAssertEqual(stats.unavailableReason, .identifiersUnsupported)
    }

    func testGridBoundaryAndOrientationProjection() {
        // Camera at origin looking -Z; points in front project into image.
        let w2c = matrix_identity_float4x4
        let fx: Float = 100
        let fy: Float = 100
        let cx: Float = 50
        let cy: Float = 50
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, -1), // center
            SIMD3(-0.4, -0.4, -1), // near top-left
            SIMD3(0.4, 0.4, -1), // near bottom-right
            SIMD3(10, 10, -1), // out of bounds
            SIMD3(0, 0, 1), // behind camera
        ]
        let grid = FeatureGridProjector.occupancy(
            worldPoints: points,
            worldToCamera: w2c,
            fx: fx, fy: fy, cx: cx, cy: cy,
            imageWidth: 100, imageHeight: 100
        )
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.rows, 3)
        XCTAssertEqual(grid?.cols, 3)
        XCTAssertEqual(grid?.cellCounts.count, 9)
        XCTAssertGreaterThan(grid?.totalInBoundsPoints ?? 0, 0)
        XCTAssertLessThan(grid?.totalInBoundsPoints ?? 99, points.count)
        XCTAssertGreaterThan(grid?.occupiedCellCount ?? 0, 0)
        XCTAssertGreaterThan(grid?.maxCellFraction ?? 0, 0)
    }

    func testPackageWritesContinuityTelemetryToRootAndZip() throws {
        let sessionId = "unit-cont-tel-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00001"))
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00002"))

        func kf(_ id: String, t: Double) -> SpatialCapturePackageBuilder.AcceptedKeyframe {
            SpatialCapturePackageBuilder.AcceptedKeyframe(
                frameId: id,
                arTimestampSeconds: t,
                cameraToWorldColumnMajor: Array(repeating: 0, count: 16),
                translationMeters: [0, 0, 0],
                rotationQuaternionXYZw: [0, 0, 0, 1],
                trackingState: "normal",
                fx: 1, fy: 1, cx: 1, cy: 1,
                width: 2, height: 2,
                sensorImageWidth: 2, sensorImageHeight: 2,
                jpegByteCount: jpeg.count,
                quality: SpatialCaptureFrameQuality(
                    frameId: id,
                    sharpnessScore: 1,
                    sharpnessState: "sharp",
                    motionSpeed: 0,
                    angularVelocity: 0,
                    parallaxGrade: "acceptable",
                    translationBaselineM: 0.1,
                    overlapScore: 1,
                    overlapState: "good",
                    trackingState: "normal",
                    lowTextureScore: 0.1,
                    acceptReason: "first"
                ),
                optionalDepthRelativePath: nil
            )
        }

        let continuity = FrameContinuityTelemetryFile(
            schemaVersion: 1,
            policyVersion: FrameContinuityTelemetryConfig.policyVersion,
            gridRows: 3,
            gridCols: 3,
            recordCount: 2,
            approximateBytesPerRecordEstimate:
                FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord,
            records: [
                FrameContinuityTelemetryRecord(
                    schemaVersion: 1,
                    policyVersion: FrameContinuityTelemetryConfig.policyVersion,
                    candidateSequence: 1,
                    arTimestampSeconds: 1.0,
                    imageTimestampSeconds: 1.0,
                    frameId: "kf_00001",
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
                FrameContinuityTelemetryRecord(
                    schemaVersion: 1,
                    policyVersion: FrameContinuityTelemetryConfig.policyVersion,
                    candidateSequence: 2,
                    arTimestampSeconds: 1.3,
                    imageTimestampSeconds: 1.3,
                    frameId: nil,
                    committed: false,
                    features: ARKitFeatureSummary(
                        rawFeaturePointCount: nil,
                        grid: nil,
                        persistent: PersistentFeatureStats(
                            previousFramePersistentCount: nil,
                            previousFramePersistentRatio: nil,
                            continuityAnchorPersistentCount: nil,
                            continuityAnchorPersistentRatio: nil,
                            unavailableReason: .identifiersUnsupported
                        ),
                        trackingState: "normal",
                        trackingLimitationReason: nil,
                        unavailableReason: .identifiersUnsupported
                    ),
                    sharpnessScore: nil,
                    sharpnessState: nil,
                    brightness: nil,
                    lowTextureScore: nil,
                    overlapScore: nil,
                    dualAnchor: DualAnchorTelemetrySnapshot(
                        continuityTranslationM: 0.02,
                        continuityYawDeg: 20,
                        continuityForwardAngleDeg: 18,
                        reconstructionCumulativeTranslationM: 0.02,
                        frustumOverlap: 0.5,
                        reconstructionCoverageEstimate: 0.1,
                        bridgeMode: "bridging",
                        verdict: "BRIDGE_REQUIRED",
                        reason: "bridge_angular_delta",
                        acceptKind: "none"
                    )
                ),
            ]
        )

        let built = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "cap-tel",
                sessionId: sessionId,
                startedAt: Date().addingTimeInterval(-10),
                endedAt: Date(),
                keyframes: [kf("kf_00001", t: 1.0), kf("kf_00002", t: 2.0)],
                rejectedDecisionCount: 1,
                trackingFailureCount: 0,
                totalTranslationDistanceM: 1,
                observedCoverage: 0.2,
                qualityCoverage: 0.2,
                viewAngleDiversity: 0.2,
                translationBaselineGrade: "acceptable",
                averageSharpness: 0.9,
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

        let rootTel = built.root.appendingPathComponent(SpatialCaptureConfig.frameContinuityTelemetryFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootTel.path))
        let decoded = try JSONDecoder().decode(
            FrameContinuityTelemetryFile.self,
            from: Data(contentsOf: rootTel)
        )
        XCTAssertEqual(decoded.recordCount, 2)
        XCTAssertEqual(decoded.records.filter { !$0.committed }.count, 1)
        XCTAssertEqual(decoded.records.first?.imageTimestampSeconds, 1.0)
        // Durable keyframe = enqueue (committed) + frameId + on-disk JPEG.
        XCTAssertEqual(decoded.records.first?.jpegEnqueueSucceeded, true)
        XCTAssertEqual(decoded.records.first?.durableJPEGPresent, true)
        XCTAssertEqual(decoded.records[1].jpegEnqueueSucceeded, false)
        XCTAssertEqual(decoded.records[1].durableJPEGPresent, false)

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let zipped = try SpatialCapturePackageZipper.buildArchive(packageRoot: built.root, destinationDirectory: dest)
        XCTAssertGreaterThan(zipped.byteSize, 0)
        // Ensure ZIP contains the continuity telemetry entry name (store method: name appears as UTF-8).
        let zipData = try Data(contentsOf: zipped.zipURL)
        let needle = Data(SpatialCaptureConfig.frameContinuityTelemetryFileName.utf8)
        XCTAssertNotNil(zipData.range(of: needle))
    }

    func testZipWithoutTelemetryFileStillWorksForLegacyPackages() throws {
        let sessionId = "unit-legacy-zip-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let paths = try SpatialCapturePackageBuilder.prepareDirectories(sessionId: sessionId)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00001"))
        try jpeg.write(to: SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: "kf_00002"))
        _ = try SpatialCapturePackageBuilder.build(
            input: SpatialCapturePackageBuilder.BuildInput(
                captureId: "cap-legacy",
                sessionId: sessionId,
                startedAt: Date().addingTimeInterval(-5),
                endedAt: Date(),
                keyframes: [
                    SpatialCapturePackageBuilder.AcceptedKeyframe(
                        frameId: "kf_00001",
                        arTimestampSeconds: 1,
                        cameraToWorldColumnMajor: Array(repeating: 0, count: 16),
                        translationMeters: [0, 0, 0],
                        rotationQuaternionXYZw: [0, 0, 0, 1],
                        trackingState: "normal",
                        fx: 1, fy: 1, cx: 1, cy: 1,
                        width: 2, height: 2,
                        sensorImageWidth: 2, sensorImageHeight: 2,
                        jpegByteCount: jpeg.count,
                        quality: SpatialCaptureFrameQuality(
                            frameId: "kf_00001",
                            sharpnessScore: nil,
                            sharpnessState: nil,
                            motionSpeed: nil,
                            angularVelocity: nil,
                            parallaxGrade: nil,
                            translationBaselineM: nil,
                            overlapScore: nil,
                            overlapState: nil,
                            trackingState: "normal",
                            lowTextureScore: nil,
                            acceptReason: "first"
                        ),
                        optionalDepthRelativePath: nil
                    ),
                    SpatialCapturePackageBuilder.AcceptedKeyframe(
                        frameId: "kf_00002",
                        arTimestampSeconds: 2,
                        cameraToWorldColumnMajor: Array(repeating: 0, count: 16),
                        translationMeters: [0.1, 0, 0],
                        rotationQuaternionXYZw: [0, 0, 0, 1],
                        trackingState: "normal",
                        fx: 1, fy: 1, cx: 1, cy: 1,
                        width: 2, height: 2,
                        sensorImageWidth: 2, sensorImageHeight: 2,
                        jpegByteCount: jpeg.count,
                        quality: SpatialCaptureFrameQuality(
                            frameId: "kf_00002",
                            sharpnessScore: nil,
                            sharpnessState: nil,
                            motionSpeed: nil,
                            angularVelocity: nil,
                            parallaxGrade: nil,
                            translationBaselineM: nil,
                            overlapScore: nil,
                            overlapState: nil,
                            trackingState: "normal",
                            lowTextureScore: nil,
                            acceptReason: "continuity_ok"
                        ),
                        optionalDepthRelativePath: nil
                    ),
                ],
                rejectedDecisionCount: 0,
                trackingFailureCount: 0,
                totalTranslationDistanceM: 0.1,
                observedCoverage: 0.1,
                qualityCoverage: 0.1,
                viewAngleDiversity: 0.1,
                translationBaselineGrade: "acceptable",
                averageSharpness: nil,
                videoRelativePath: nil,
                hasLiDAR: false,
                supportsSceneDepth: false,
                supportsSmoothedSceneDepth: false,
                supportsSceneReconstruction: false,
                decisions: [],
                telemetry: nil,
                frameContinuityTelemetry: nil
            )
        )
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let zipped = try SpatialCapturePackageZipper.buildArchive(packageRoot: paths.root, destinationDirectory: dest)
        XCTAssertGreaterThan(zipped.frameCount, 1)
        let zipData = try Data(contentsOf: zipped.zipURL)
        let needle = Data(SpatialCaptureConfig.frameContinuityTelemetryFileName.utf8)
        XCTAssertNil(zipData.range(of: needle))
    }

    func testRetentionKeepsTransitionsBeyondStableRingCap() throws {
        let collector = FrameContinuityTelemetryCollector()
        // Flood stable rejects past the 2_500 stable ring, then emit a late reacquire + recovery.
        let firstFaultTs = 10.0
        collector.recordSyntheticCandidate(
            arTimestampSeconds: firstFaultTs,
            committed: false,
            verdict: CaptureBridgeVerdict.reacquire.rawValue,
            reason: "reacquire_continuity_lost",
            acceptKind: CaptureAcceptKind.none.rawValue,
            bridgeMode: "reacquiring"
        )
        // Many identical stable rejects — must downsample, not permanently duplicate.
        for i in 1...20_000 {
            collector.recordSyntheticCandidate(
                arTimestampSeconds: firstFaultTs + Double(i) * (1.0 / 60.0),
                committed: false,
                verdict: CaptureBridgeVerdict.reject.rawValue,
                reason: "pose_jitter",
                acceptKind: CaptureAcceptKind.none.rawValue
            )
        }
        let recoveryTs = firstFaultTs + 400.0
        collector.recordSyntheticCandidate(
            arTimestampSeconds: recoveryTs,
            committed: true,
            frameId: "kf_00999",
            verdict: CaptureBridgeVerdict.accept.rawValue,
            reason: "continuity_ok",
            acceptKind: CaptureAcceptKind.reconstructionKeyframe.rawValue,
            updateContinuitySet: true
        )
        let snap = collector.snapshotFile()
        let stats = collector.retentionStats()
        XCTAssertGreaterThan(stats.permanent, 0)
        XCTAssertLessThanOrEqual(stats.stable, FrameContinuityTelemetryConfig.maxInMemoryRecords)
        XCTAssertTrue(
            snap.records.contains { $0.dualAnchor.reason == "reacquire_continuity_lost" },
            "first fault transition must survive beyond stable ring"
        )
        XCTAssertTrue(
            snap.records.contains { $0.dualAnchor.reason == "continuity_ok" && $0.committed },
            "last recovery transition must remain"
        )
        // Ordering + unique sequences.
        var seen = Set<Int>()
        var lastTs = -Double.infinity
        for r in snap.records {
            XCTAssertFalse(seen.contains(r.candidateSequence))
            seen.insert(r.candidateSequence)
            XCTAssertGreaterThanOrEqual(r.arTimestampSeconds, lastTs - 1e-9)
            lastTs = r.arTimestampSeconds
        }
        // Same transition reason must not be permanently stored every stable frame.
        let reacquirePerm = snap.records.filter { $0.dualAnchor.reason == "reacquire_continuity_lost" }
        XCTAssertEqual(reacquirePerm.count, 1)
    }

    /// Real `JSONEncoder` byte measurement for a ~150s / ~9000 ARFrame-style synthetic session.
    func testSyntheticSessionTelemetryByteMeasurement() throws {
        let collector = FrameContinuityTelemetryCollector()
        let arFrameCount = 9_000 // ~150s @ 60 Hz
        let dt = 150.0 / Double(arFrameCount)

        // Seed accept
        collector.recordSyntheticCandidate(
            arTimestampSeconds: 0,
            committed: true,
            frameId: "kf_00001",
            verdict: CaptureBridgeVerdict.accept.rawValue,
            reason: "first",
            acceptKind: CaptureAcceptKind.reconstructionKeyframe.rawValue,
            updateContinuitySet: true
        )

        var nextAccept = 180
        for i in 1..<arFrameCount {
            let t = Double(i) * dt
            if i == 500 {
                collector.recordSyntheticCandidate(
                    arTimestampSeconds: t,
                    committed: false,
                    verdict: CaptureBridgeVerdict.bridgeRequired.rawValue,
                    reason: "bridge_step_too_large",
                    acceptKind: CaptureAcceptKind.none.rawValue,
                    bridgeMode: "bridging"
                )
            } else if i == 800 {
                collector.recordSyntheticCandidate(
                    arTimestampSeconds: t,
                    committed: false,
                    verdict: CaptureBridgeVerdict.reacquire.rawValue,
                    reason: "reacquire_continuity_lost",
                    acceptKind: CaptureAcceptKind.none.rawValue,
                    bridgeMode: "reacquiring"
                )
            } else if i == 1_200 {
                collector.recordSyntheticCandidate(
                    arTimestampSeconds: t,
                    committed: true,
                    frameId: "kf_00050",
                    verdict: CaptureBridgeVerdict.accept.rawValue,
                    reason: "continuity_ok",
                    acceptKind: CaptureAcceptKind.reconstructionKeyframe.rawValue,
                    updateContinuitySet: true
                )
            } else if i == nextAccept {
                collector.recordSyntheticCandidate(
                    arTimestampSeconds: t,
                    committed: true,
                    frameId: String(format: "kf_%05d", i),
                    verdict: CaptureBridgeVerdict.accept.rawValue,
                    reason: "continuity_ok",
                    acceptKind: CaptureAcceptKind.reconstructionKeyframe.rawValue,
                    updateContinuitySet: true
                )
                nextAccept += 180
            } else if i == 2_000 {
                collector.recordSyntheticCandidate(
                    arTimestampSeconds: t,
                    committed: true,
                    frameId: "kf_bridge",
                    verdict: CaptureBridgeVerdict.accept.rawValue,
                    reason: "continuity_bridge_observation",
                    acceptKind: CaptureAcceptKind.continuityBridgeObservation.rawValue,
                    bridgeMode: "bridging",
                    updateContinuitySet: true
                )
            } else {
                collector.recordSyntheticCandidate(
                    arTimestampSeconds: t,
                    committed: false,
                    verdict: CaptureBridgeVerdict.reject.rawValue,
                    reason: "min_interval",
                    acceptKind: CaptureAcceptKind.none.rawValue
                )
            }
        }

        let file = collector.snapshotFile()
        let stats = collector.retentionStats()
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        let prettyData = try pretty.encode(file)
        let compact = JSONEncoder()
        let compactData = try compact.encode(file)

        let lineEncoder = JSONEncoder()
        var jsonlBytes = 0
        for r in file.records {
            let line = try lineEncoder.encode(r)
            jsonlBytes += line.count + 1
        }

        let bytesPerPretty = file.recordCount == 0 ? 0 : prettyData.count / file.recordCount
        let bytesPerCompact = file.recordCount == 0 ? 0 : compactData.count / file.recordCount

        // Scale retained count linearly for duration estimates (same mix density).
        func projectedPrettyBytes(minutes: Double) -> Int {
            let scale = (minutes * 60.0) / 150.0
            return Int(Double(prettyData.count) * scale)
        }

        XCTAssertEqual(arFrameCount, 9_000)
        XCTAssertEqual(stats.merged, file.recordCount)
        XCTAssertGreaterThan(stats.permanent, 5)
        XCTAssertGreaterThan(stats.stable, 0)
        XCTAssertLessThanOrEqual(stats.stable, FrameContinuityTelemetryConfig.maxInMemoryRecords)
        XCTAssertTrue(file.records.contains { $0.dualAnchor.reason == "reacquire_continuity_lost" })
        XCTAssertTrue(file.records.contains { $0.dualAnchor.reason == "continuity_bridge_observation" })
        XCTAssertTrue(file.records.contains { $0.dualAnchor.reason == "first" })
        // Old 420B estimate is incompatible with pretty-printed package encoding.
        XCTAssertGreaterThan(bytesPerPretty, 800)
        XCTAssertLessThan(bytesPerPretty, 3_500)
        XCTAssertEqual(
            file.approximateBytesPerRecordEstimate,
            FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord
        )
        // Keep estimate within ~25% of measured pretty bytes/record.
        let est = FrameContinuityTelemetryConfig.approximateBytesPerPrettyPrintedRecord
        XCTAssertLessThan(abs(bytesPerPretty - est), max(400, est / 3))

        // Surface measured sizes in failure messages for Gate logs / report.
        XCTAssertGreaterThan(
            prettyData.count,
            0,
            """
            telemetry measure: ARFrames=\(arFrameCount) retained=\(file.recordCount) \
            permanent=\(stats.permanent) stable=\(stats.stable) \
            prettyJSON=\(prettyData.count)B compactJSON=\(compactData.count)B jsonl=\(jsonlBytes)B \
            B/rec_pretty=\(bytesPerPretty) B/rec_compact=\(bytesPerCompact) \
            proj2min=\(projectedPrettyBytes(minutes: 2)) \
            proj4min=\(projectedPrettyBytes(minutes: 4)) \
            proj8min=\(projectedPrettyBytes(minutes: 8))
            """
        )
        _ = projectedPrettyBytes(minutes: 2)
        _ = projectedPrettyBytes(minutes: 4)
        _ = projectedPrettyBytes(minutes: 8)
        _ = bytesPerCompact
        _ = jsonlBytes
    }
}

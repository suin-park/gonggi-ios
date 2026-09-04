import Foundation
import simd

/// Orchestrates panorama reconstruction and file export after Hybrid Space Capture.
///
/// Reconstruction uses `PanoramaEngineProtocol` (production default: Legacy).
/// `Panorama360ViewerView` only receives the resulting panorama URL — never the engine id.
enum Quick360Reconstruction {
    struct Result: Equatable {
        let panoramaURL: URL
        let coverageMaskURL: URL
        let metadataURL: URL
        let reportURL: URL
        let floorTextureURL: URL?
        let report: Quick360PanoramaReport
    }

    static func reconstruct(
        engine: Quick360CaptureEngine,
        mockMode: Bool
    ) async throws -> Result {
        let sessionId = engine.sessionId
        let endedAt = Date()
        _ = try CaptureSessionStore.createPanoramaDirectory(sessionId: sessionId)

        let originTransform = engine.originTransform
        let panoramaURL = try CaptureSessionStore.quick360EquirectangularURL(sessionId: sessionId)
        let stitchOutput: PanoramaStitcher.Output

        if mockMode {
            stitchOutput = PanoramaStitcher.mockPanorama()
            try PanoramaExporter.writeJPEG(
                rgba: stitchOutput.rgba,
                width: stitchOutput.width,
                height: stitchOutput.height,
                to: panoramaURL
            )
        } else {
            let inputs = engine.pendingKeyframeJPEGs().enumerated().compactMap { idx, pair -> PanoramaStitcher.InputKeyframe? in
                let (kf, jpeg) = pair
                guard let (rgba, w, h) = Quick360FrameEncoder.loadRGBA(fromJPEG: jpeg) else { return nil }
                // Sensor K on metadata → portrait remap + scale to JPEG pixels (matches live brush).
                let portraitK = Quick360FrameEncoder.portraitKeyframeIntrinsics(
                    sensor: kf.intrinsics,
                    jpegWidth: w,
                    jpegHeight: h
                )
                return PanoramaStitcher.InputKeyframe(
                    index: idx,
                    rgba: rgba,
                    width: w,
                    height: h,
                    cameraTransform: kf.cameraTransform,
                    intrinsics: portraitK,
                    dynamicRatio: kf.dynamicRatio,
                    sharpness: kf.sharpness,
                    exposure: kf.exposure,
                    translationM: kf.translationM,
                    fileName: kf.fileName,
                    yawRad: kf.yawRad,
                    pitchRad: kf.pitchRad
                )
            }

            let engineInput = PanoramaEngineInput(
                sessionId: sessionId,
                keyframes: inputs,
                originTransform: originTransform,
                captureBasis: engine.captureBasis,
                selectedKeyframeMeta: engine.selectedKeyframes,
                targets: engine.targets,
                coverageReport: engine.sphericalCoverage.report(),
                outputWidth: Quick360Config.outputWidth,
                outputHeight: Quick360Config.outputHeight,
                outputPanoramaURL: panoramaURL
            )

            stitchOutput = try await runSelectedEngine(
                input: engineInput,
                selection: PanoramaEngineSelection.resolved()
            )

            if Quick360Config.writeStitchDebugArtifacts {
                _ = try? PanoramaStitchDebug.write(sessionId: sessionId, output: stitchOutput)
                if let first = inputs.first {
                    _ = try? PanoramaOrientationDebug.writeKeyframeArtifacts(
                        sessionId: sessionId,
                        rgba: first.rgba,
                        width: first.width,
                        height: first.height,
                        index: 0
                    )
                }
            }
        }

        let maskURL = try CaptureSessionStore.quick360CoverageMaskURL(sessionId: sessionId)
        let metadataURL = try CaptureSessionStore.quick360MetadataURL(sessionId: sessionId)
        let reportURL = try CaptureSessionStore.quick360ReportURL(sessionId: sessionId)

        // Production path may already have JPEG from Legacy engine; rewrite is byte-identical.
        // Build 24 A/B may return after disk reload — if rgba empty but JPEG exists, keep file.
        if !stitchOutput.rgba.isEmpty {
            try PanoramaExporter.writeJPEG(
                rgba: stitchOutput.rgba,
                width: stitchOutput.width,
                height: stitchOutput.height,
                to: panoramaURL
            )
        } else if !FileManager.default.fileExists(atPath: panoramaURL.path) {
            throw PanoramaEngineError.encodeFailed
        }

        if Quick360Config.writeStitchDebugArtifacts {
            _ = try? PanoramaOrientationDebug.writeEquirectArtifacts(
                sessionId: sessionId,
                rgba: stitchOutput.rgba,
                width: stitchOutput.width,
                height: stitchOutput.height
            )
        }

        let (maskRGBA, _, _) = PanoramaCoverageMask.generate(
            coverageFlags: stitchOutput.coverageFlags,
            width: stitchOutput.width,
            height: stitchOutput.height
        )
        try PanoramaExporter.writePNG(
            rgba: maskRGBA,
            width: stitchOutput.width,
            height: stitchOutput.height,
            to: maskURL
        )

        var floorTextureURL: URL?
        var floorMeta: CapturedFloorSurfaceMetadata?
        if let floorSnap = engine.snapshotFloorForExport() {
            _ = try CaptureSessionStore.createFloorDirectory(sessionId: sessionId)
            let texURL = try CaptureSessionStore.quick360FloorTextureURL(sessionId: sessionId)
            let confURL = try CaptureSessionStore.quick360FloorConfidenceMaskURL(sessionId: sessionId)
            let metaURL = try CaptureSessionStore.quick360FloorMetadataURL(sessionId: sessionId)
            try PanoramaExporter.writeJPEG(
                rgba: floorSnap.rgba,
                width: floorSnap.surface.textureWidth,
                height: floorSnap.surface.textureHeight,
                to: texURL
            )
            try PanoramaExporter.writePNG(
                rgba: floorSnap.confidenceRGBA,
                width: floorSnap.surface.textureWidth,
                height: floorSnap.surface.textureHeight,
                to: confURL
            )
            floorMeta = CapturedFloorSurfaceMetadata(surface: floorSnap.surface)
            try PanoramaExporter.writeJSON(floorMeta!, to: metaURL)
            floorTextureURL = texURL
        }

        let iso = ISO8601DateFormatter()
        let metadata = Quick360CaptureMetadata(
            sessionId: sessionId,
            captureId: engine.captureId,
            startedAt: iso.string(from: engine.startedAt),
            endedAt: iso.string(from: endedAt),
            originTransform: CaptureKeyframeRecord.encodeTransform(originTransform),
            outputWidth: stitchOutput.width,
            outputHeight: stitchOutput.height,
            targetCount: engine.targets.count,
            selectedKeyframeCount: engine.selectedKeyframes.count,
            cameraNotes: Quick360CameraNotes.notes(for: mockMode),
            keyframes: engine.selectedKeyframes,
            lightingSamples: engine.lightingSamples,
            floor: floorMeta
        )
        try PanoramaExporter.writeJSON(metadata, to: metadataURL)

        let duration = endedAt.timeIntervalSince(engine.startedAt)
        let sphereCov = Double(engine.sphereBrush.coveragePercent())
        let sphereGood = Double(engine.sphereBrush.goodCoveragePercent())
        let cov = engine.sphericalCoverage.report()
        let floor = engine.floorSurface
        let peakMemEstimate =
            Double(stitchOutput.width * stitchOutput.height * 4)
            / (1024.0 * 1024.0)
            + Double(engine.selectedKeyframes.count) * 1.5
        let report = Quick360PanoramaReport(
            candidateFrameCount: engine.candidateFrameCount,
            selectedKeyframeCount: engine.selectedKeyframes.count,
            coveragePercent: stitchOutput.coveragePercent,
            uncoveredPercent: stitchOutput.uncoveredPercent,
            maxTranslationM: engine.translationState.maxDistanceM,
            averageTranslationM: engine.translationState.averageDistanceM,
            rejectedFrames: engine.rejectedFrames,
            dynamicFrameRejects: engine.dynamicFrameRejects,
            stitchTimeSec: stitchOutput.stitchTimeSec,
            outputWidth: stitchOutput.width,
            outputHeight: stitchOutput.height,
            outputByteSize: PanoramaExporter.fileByteSize(at: panoramaURL),
            alignmentRefinementApplied: stitchOutput.alignmentApplied,
            parallaxWarpLevel: PanoramaParallaxWarp.level,
            createdAt: iso.string(from: endedAt),
            sphereCoveragePercent: sphereCov,
            sphereGoodCoveragePercent: sphereGood,
            floorDetected: floor != nil,
            floorTrackingConfidence: floor?.trackingConfidence ?? 0,
            floorCoveragePercent: Double(floor?.coveragePercent ?? 0),
            floorGoodCoveragePercent: Double(floor?.goodCoveragePercent ?? 0),
            floorExtentM: floor.map { [$0.extent.x, $0.extent.y, $0.extent.z] } ?? [],
            floorTextureUpdateCount: floor?.textureUpdateCount ?? 0,
            sphereBrushUpdateCount: engine.sphereBrush.updateCount,
            captureDurationSec: duration,
            acceptedKeyframeCount: stitchOutput.acceptedKeyframeCount,
            rejectedKeyframeCount: stitchOutput.rejectedKeyframeCount,
            averageAngularSpacingDeg: stitchOutput.averageAngularSpacingDeg,
            visualRefinementAttempts: stitchOutput.visualRefinementAttempts,
            successfulRefinements: stitchOutput.successfulRefinements,
            averageMatchCount: stitchOutput.averageMatchCount,
            averageInlierRatio: stitchOutput.averageInlierRatio,
            averageReprojectionError: stitchOutput.averageReprojectionError,
            highParallaxFrameCount: stitchOutput.highParallaxFrameCount,
            keyframePlacements: stitchOutput.keyframePlacements,
            horizontalCoveragePercent: Double(cov.horizontalPercent),
            upperCoveragePercent: Double(cov.upperPercent),
            lowerCoveragePercent: Double(cov.lowerPercent),
            zenithCoveragePercent: Double(cov.zenithPercent),
            nadirCoveragePercent: Double(cov.nadirPercent),
            overallSphericalCoveragePercent: Double(cov.overallPercent),
            weakCoveragePercent: Double(cov.weakPercent),
            missingCoveragePercent: Double(cov.missingPercent),
            peakMemoryMBEstimate: peakMemEstimate
        )
        try PanoramaExporter.writeJSON(report, to: reportURL)

        return Result(
            panoramaURL: panoramaURL,
            coverageMaskURL: maskURL,
            metadataURL: metadataURL,
            reportURL: reportURL,
            floorTextureURL: floorTextureURL,
            report: report
        )
    }

    /// Runs the selected engine. Production / default: Legacy only.
    /// `.abCompare` (DEBUG override or TestFlight flag): Legacy user output + OpenCV A/B artifacts.
    /// `.openCV`: OpenCV first; on failure fall back to Legacy so the session stays usable.
    static func runSelectedEngine(
        input: PanoramaEngineInput,
        selection: PanoramaEngineSelection
    ) async throws -> PanoramaStitcher.Output {
        switch selection {
        case .legacy:
            let out = try await GonggiLegacyPanoramaEngine().stitch(input: input)
            guard let stitch = out.stitchOutput else {
                throw PanoramaEngineError.encodeFailed
            }
            return stitch

        case .openCV:
            let openCVOut = try await OpenCVPanoramaEngine().stitch(input: input)
            if openCVOut.success, let stitch = openCVOut.stitchOutput {
                return stitch
            }
            // Phase 1 stub: keep capture usable.
            let legacy = try await GonggiLegacyPanoramaEngine().stitch(input: input)
            guard let stitch = legacy.stitchOutput else {
                throw PanoramaEngineError.encodeFailed
            }
            return stitch

        case .abCompare:
            let legacyEngine = GonggiLegacyPanoramaEngine()
            let legacyOut = try await legacyEngine.stitch(input: input)
            guard let stitchHeavy = legacyOut.stitchOutput else {
                throw PanoramaEngineError.encodeFailed
            }

            // Persist A/B legacy JPEG from disk (Legacy already wrote outputPanoramaURL).
            // Release Legacy RGBA + keyframe pixel buffers before OpenCV (Build 24 jetsam).
            let lightLegacy = legacyOut.releasingHeavyPixelBuffers()
            let lightInput = input.releasingKeyframePixelBuffers()
            let openCVOut = try await OpenCVPanoramaEngine().stitch(input: lightInput)
            try? PanoramaABTestWriter.write(
                sessionId: input.sessionId,
                legacy: lightLegacy,
                openCV: openCVOut
            )

            // Lazy-reload Legacy equirect from disk for downstream mask / rewrite.
            var stitch = stitchHeavy.releasingHeavyPixelBuffers()
            if let data = try? Data(contentsOf: input.outputPanoramaURL),
               let reloaded = Quick360FrameEncoder.loadRGBA(fromJPEG: data),
               reloaded.width == stitch.width,
               reloaded.height == stitch.height {
                stitch = stitch.replacingRGBA(reloaded.rgba)
            }
            return stitch
        }
    }
}

extension Quick360SelectedKeyframe {
    var cameraTransform: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(transform[0], transform[1], transform[2], transform[3]),
            SIMD4(transform[4], transform[5], transform[6], transform[7]),
            SIMD4(transform[8], transform[9], transform[10], transform[11]),
            SIMD4(transform[12], transform[13], transform[14], transform[15])
        ))
    }
}

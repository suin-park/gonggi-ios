import Foundation
import simd

/// Orchestrates panorama reconstruction and file export after Quick 360 capture.
enum Quick360Reconstruction {
    struct Result: Equatable {
        let panoramaURL: URL
        let coverageMaskURL: URL
        let metadataURL: URL
        let reportURL: URL
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
        let stitchOutput: PanoramaStitcher.Output

        if mockMode {
            stitchOutput = PanoramaStitcher.mockPanorama()
        } else {
            let inputs = engine.pendingKeyframeJPEGs().enumerated().compactMap { idx, pair -> PanoramaStitcher.InputKeyframe? in
                let (kf, jpeg) = pair
                guard let (rgba, w, h) = Quick360FrameEncoder.loadRGBA(fromJPEG: jpeg) else { return nil }
                return PanoramaStitcher.InputKeyframe(
                    index: idx,
                    rgba: rgba,
                    width: w,
                    height: h,
                    cameraTransform: kf.cameraTransform,
                    intrinsics: kf.intrinsics,
                    dynamicRatio: kf.dynamicRatio
                )
            }
            stitchOutput = PanoramaStitcher.stitch(
                keyframes: inputs,
                originTransform: originTransform
            )
        }

        let panoramaURL = try CaptureSessionStore.quick360EquirectangularURL(sessionId: sessionId)
        let maskURL = try CaptureSessionStore.quick360CoverageMaskURL(sessionId: sessionId)
        let metadataURL = try CaptureSessionStore.quick360MetadataURL(sessionId: sessionId)
        let reportURL = try CaptureSessionStore.quick360ReportURL(sessionId: sessionId)

        try PanoramaExporter.writeJPEG(
            rgba: stitchOutput.rgba,
            width: stitchOutput.width,
            height: stitchOutput.height,
            to: panoramaURL
        )

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
            keyframes: engine.selectedKeyframes
        )
        try PanoramaExporter.writeJSON(metadata, to: metadataURL)

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
            createdAt: iso.string(from: endedAt)
        )
        try PanoramaExporter.writeJSON(report, to: reportURL)

        return Result(
            panoramaURL: panoramaURL,
            coverageMaskURL: maskURL,
            metadataURL: metadataURL,
            reportURL: reportURL,
            report: report
        )
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

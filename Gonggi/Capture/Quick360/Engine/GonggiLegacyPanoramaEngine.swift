import Foundation
import simd

/// Production reconstruction engine — thin wrapper over `PanoramaStitcher`.
/// Output bytes/resolution must match calling `PanoramaStitcher.stitch` directly.
struct GonggiLegacyPanoramaEngine: PanoramaEngineProtocol {
    let identifier = PanoramaEngineID.legacy

    func stitch(input: PanoramaEngineInput) async throws -> PanoramaEngineOutput {
        let start = Date()
        // Empty keyframes: same behavior as calling `PanoramaStitcher.stitch` directly.

        let stitchOutput = PanoramaStitcher.stitch(
            keyframes: input.keyframes,
            originTransform: input.originTransform,
            captureBasis: input.captureBasis,
            outWidth: input.outputWidth,
            outHeight: input.outputHeight
        )

        try PanoramaExporter.writeJPEG(
            rgba: stitchOutput.rgba,
            width: stitchOutput.width,
            height: stitchOutput.height,
            to: input.outputPanoramaURL
        )

        let elapsed = Date().timeIntervalSince(start)
        let fallback: Int? = {
            let attempts = stitchOutput.visualRefinementAttempts
            guard attempts > 0 else { return 0 }
            return max(0, attempts - stitchOutput.successfulRefinements)
        }()
        let peakMem =
            Double(stitchOutput.width * stitchOutput.height * 4) / (1024.0 * 1024.0)
            + Double(input.keyframes.count) * 1.5

        let report = PanoramaEngineRunReport(
            engine: identifier,
            success: true,
            finalResolution: "\(stitchOutput.width)x\(stitchOutput.height)",
            selectedKeyframeCount: stitchOutput.acceptedKeyframeCount,
            processingTimeMs: elapsed * 1000,
            peakMemoryMB: peakMem,
            coveragePercent: stitchOutput.coveragePercent,
            seamMetric: nil,
            alignmentRefinementSuccess: stitchOutput.alignmentApplied,
            visualRefinementAttempts: stitchOutput.visualRefinementAttempts,
            successfulRefinements: stitchOutput.successfulRefinements,
            fallbackCount: fallback,
            highParallaxCount: stitchOutput.highParallaxFrameCount,
            outputFilePath: input.outputPanoramaURL.path,
            failureReason: nil,
            openCVMetricsJSON: nil
        )

        return PanoramaEngineOutput(
            engineIdentifier: identifier,
            success: true,
            panoramaURL: input.outputPanoramaURL,
            width: stitchOutput.width,
            height: stitchOutput.height,
            rgba: stitchOutput.rgba,
            coverageFlags: stitchOutput.coverageFlags,
            processingTimeSec: elapsed,
            stitchOutput: stitchOutput,
            failureReason: nil,
            report: report
        )
    }
}

import CoreVideo
import Foundation
import simd

/// Builds JPEG enqueue snapshots from a held pending slot — same intrinsics / resolution
/// contract as the live `ARFrame` path (`enqueueSpatialKeyframe`).
enum PendingAngularRescueSnapshotBuilder {
    static func makeSnapshot(
        ownedBuffer: CVPixelBuffer,
        slot: PendingAngularRescueSlot,
        frameId: String,
        trackingLabel: String,
        paths: SpatialCapturePackagePaths,
        sharpSnap: FrameSharpnessAnalyzer.Snapshot,
        lastSample: TelemetrySample?,
        eval: TranslationBaselineAnalyzer.Evaluation,
        lowTexture: Double,
        overlapScore: Double?,
        overlapState: String?,
        debugPrincipalPoint: Bool = SpatialCaptureConfig.debugDrawPrincipalPoint
    ) -> SpatialKeyframeSnapshot {
        let sensorW = CVPixelBufferGetWidth(ownedBuffer)
        let sensorH = CVPixelBufferGetHeight(ownedBuffer)
        let jpegURL = SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId)
        let debugURL: URL? = debugPrincipalPoint
            ? SpatialCapturePackageBuilder.debugPrincipalPointJPEGURL(paths: paths, frameId: frameId)
            : nil
        return SpatialKeyframeSnapshot(
            frameId: frameId,
            arTimestampSeconds: slot.timestamp,
            ownedPixelBuffer: ownedBuffer,
            cameraToWorld: slot.transform,
            trackingState: trackingLabel,
            fx: slot.fx,
            fy: slot.fy,
            cx: slot.cx,
            cy: slot.cy,
            sensorImageWidth: sensorW,
            sensorImageHeight: sensorH,
            imageResolutionWidth: slot.imageResolutionWidth,
            imageResolutionHeight: slot.imageResolutionHeight,
            sharpnessScore: sharpSnap.score,
            sharpnessState: sharpSnap.state.rawValue,
            motionSpeed: lastSample?.translationSpeedMps,
            angularVelocity: lastSample?.angularVelocityRadPerSec,
            parallaxGrade: eval.grade.rawValue,
            translationBaselineM: eval.translationBaselineM,
            overlapScore: overlapScore,
            overlapState: overlapState,
            lowTextureScore: lowTexture,
            acceptReason: slot.reason,
            jpegURL: jpegURL,
            debugPrincipalPointJPEGURL: debugURL,
            optionalDepthRelativePath: nil
        )
    }
}

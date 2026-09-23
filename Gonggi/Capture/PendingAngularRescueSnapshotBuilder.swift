import CoreVideo
import Foundation
import simd

/// Builds JPEG enqueue snapshots from a held pending slot — same intrinsics / resolution
/// contract as the live `ARFrame` path (`enqueueSpatialKeyframe`).
/// Quality fields come from `slot.quality` (hold-time measurements); missing → nil, never fakes.
enum PendingAngularRescueSnapshotBuilder {
    static func makeSnapshot(
        ownedBuffer: CVPixelBuffer,
        slot: PendingAngularRescueSlot,
        frameId: String,
        trackingLabel: String,
        paths: SpatialCapturePackagePaths,
        debugPrincipalPoint: Bool = SpatialCaptureConfig.debugDrawPrincipalPoint
    ) -> SpatialKeyframeSnapshot {
        let sensorW = CVPixelBufferGetWidth(ownedBuffer)
        let sensorH = CVPixelBufferGetHeight(ownedBuffer)
        let jpegURL = SpatialCapturePackageBuilder.frameJPEGURL(paths: paths, frameId: frameId)
        let debugURL: URL? = debugPrincipalPoint
            ? SpatialCapturePackageBuilder.debugPrincipalPointJPEGURL(paths: paths, frameId: frameId)
            : nil
        let q = slot.quality
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
            sharpnessScore: q?.sharpnessScore,
            sharpnessState: q?.sharpnessState,
            motionSpeed: q?.motionSpeed,
            angularVelocity: q?.angularVelocity,
            parallaxGrade: q?.parallaxGrade,
            translationBaselineM: q?.translationBaselineM,
            overlapScore: q?.overlapScore,
            overlapState: q?.overlapState,
            lowTextureScore: q?.lowTextureScore,
            acceptReason: slot.reason,
            jpegURL: jpegURL,
            debugPrincipalPointJPEGURL: debugURL,
            optionalDepthRelativePath: nil
        )
    }
}

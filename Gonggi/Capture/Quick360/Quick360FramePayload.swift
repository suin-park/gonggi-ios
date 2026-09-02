import ARKit
import CoreImage
import Foundation
import simd

/// Owned, Sendable frame data copied while `ARFrame.capturedImage` is still valid.
/// Never store or hop `ARFrame` / `CVPixelBuffer` across queues — that caused Build 3 EXC_BAD_ACCESS.
struct Quick360FramePayload: Sendable {
    let timestamp: Double
    let cameraTransform: simd_float4x4
    let intrinsics: CameraIntrinsics
    let analysisGrayscale: [UInt8]
    let jpegData: Data?

    /// Must be called on the ARSession delegate queue (or any thread) **before** the
    /// `session(_:didUpdate:)` callback returns — ARKit recycles the pixel buffer after.
    static func copyOwned(from frame: ARFrame, includeJPEG: Bool) -> Quick360FramePayload {
        let transform = frame.camera.transform
        let intrinsics = Quick360FrameEncoder.intrinsics(from: frame)
        let gray = Quick360FrameEncoder.analysisGrayscale(from: frame.capturedImage)
        let jpeg = includeJPEG ? Quick360FrameEncoder.jpegData(from: frame.capturedImage) : nil
        return Quick360FramePayload(
            timestamp: frame.timestamp,
            cameraTransform: transform,
            intrinsics: intrinsics,
            analysisGrayscale: gray,
            jpegData: jpeg
        )
    }
}

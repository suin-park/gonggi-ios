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
    /// Low-res RGB thumbnail for live sphere/floor brush (owned bytes).
    let brushRGBA: [UInt8]
    let brushWidth: Int
    let brushHeight: Int
    let ambientIntensity: Float?
    let ambientColorTemperature: Float?

    /// Must be called on the ARSession delegate queue (or any thread) **before** the
    /// `session(_:didUpdate:)` callback returns — ARKit recycles the pixel buffer after.
    static func copyOwned(
        from frame: ARFrame,
        includeJPEG: Bool,
        includeBrush: Bool
    ) -> Quick360FramePayload {
        let transform = frame.camera.transform
        let intrinsics = Quick360FrameEncoder.intrinsics(from: frame)
        let gray = Quick360FrameEncoder.analysisGrayscale(from: frame.capturedImage)
        let jpeg = includeJPEG ? Quick360FrameEncoder.jpegData(from: frame.capturedImage) : nil
        var brushRGBA: [UInt8] = []
        var brushW = 0
        var brushH = 0
        if includeBrush,
           let rendered = Quick360FrameEncoder.renderRGBA(
            from: frame.capturedImage,
            maxWidth: Quick360Config.brushThumbMaxWidth
           ) {
            brushRGBA = rendered.rgba
            brushW = rendered.width
            brushH = rendered.height
        }
        let light = frame.lightEstimate
        return Quick360FramePayload(
            timestamp: frame.timestamp,
            cameraTransform: transform,
            intrinsics: intrinsics,
            analysisGrayscale: gray,
            jpegData: jpeg,
            brushRGBA: brushRGBA,
            brushWidth: brushW,
            brushHeight: brushH,
            ambientIntensity: light.map { Float($0.ambientIntensity) },
            ambientColorTemperature: light.map { Float($0.ambientColorTemperature) }
        )
    }
}

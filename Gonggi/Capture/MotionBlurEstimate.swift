import CoreVideo
import Foundation

/// Motion smear of a candidate photo in pixels, from what ARKit already reports for the frame:
/// exposure time × image-plane speed (rotation ω·fx, plus translation v·fx at an assumed 1.5 m scene depth).
/// Content-independent, so a sharp plain wall is not mistaken for blur.
///
/// Why (V1_061, 10-25): Laplacian sharpness of the saved photos halved above ~0.3 rad/s and 142 of 520 photos
/// were saved while turning faster than 0.4 rad/s. `FrameSharpnessAnalyzer` samples a 64-point grid
/// (~22 px apart, no averaging), which cannot see 5–15 px smears, so every saved photo was recorded "sharp".
enum MotionBlurEstimate {
    /// Spatial-capture keyframe gate (selector rejects "motion_blur"). Off = build 32 behaviour.
    static var gateEnabled = true
    /// Reject above this estimated smear (pixels in the 1920-wide photo). First device capture calibrates it
    /// (quality.json now records `exposureDurationSec` and `motionBlurPx` for every saved photo).
    static var maxBlurPx: Double = 8.0
    static let assumedDepthM: Double = 1.5

    static func pixels(angularVelocity: Double?, translationSpeed: Double?, exposureSec: Double, fx: Double) -> Double? {
        guard exposureSec > 0, exposureSec.isFinite, fx > 0, let w = angularVelocity, w.isFinite, w >= 0 else { return nil }
        let v = translationSpeed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        return exposureSec * fx * (w + v / assumedDepthM)
    }

    /// Value passed to `KeyframeSelector3DGS`: nil (no gate) when the gate is off.
    static func selectorInput(_ px: Double?) -> Double? {
        gateEnabled ? px : nil
    }

    /// Laplacian variance of a saved photo's luma at half resolution over the central 50 % of the frame
    /// (2×2 box average, then 4-neighbour Laplacian). Recorded per photo for diagnostics; not a gate,
    /// because plain surfaces score low however sharp they are.
    static func keyframeLaplacianVariance(pixelBuffer: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let w = width / 4, h = height / 4                      // half-res samples covering the central half
        let x0 = width / 4, y0 = height / 4
        guard w >= 8, h >= 8 else { return nil }
        var half = [Float](repeating: 0, count: w * h)
        for j in 0..<h {
            let r0 = (y0 + 2 * j) * rowBytes, r1 = r0 + rowBytes
            for i in 0..<w {
                let x = x0 + 2 * i
                half[j * w + i] = (Float(src[r0 + x]) + Float(src[r0 + x + 1]) + Float(src[r1 + x]) + Float(src[r1 + x + 1])) * 0.25
            }
        }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for j in 1..<(h - 1) {
            for i in 1..<(w - 1) {
                let k = j * w + i
                let lap = Double(half[k - 1] + half[k + 1] + half[k - w] + half[k + w] - 4 * half[k])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}

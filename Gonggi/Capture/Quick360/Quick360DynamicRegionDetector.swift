import Foundation
import simd

/// Prototype dynamic-region detector via pose-gated residual image difference.
enum Quick360DynamicRegionDetector {
    struct State: Equatable {
        var lastGrayscale: [UInt8]?
        var lastWidth: Int
        var lastHeight: Int
        var lastYawRad: Float?
        var lastPitchRad: Float?
    }

    /// Camera rotation above this is treated as expected guided motion, not dynamic objects.
    static let expectedRotationThresholdDeg: Float = 4.5

    static func initial() -> State {
        State(lastGrayscale: nil, lastWidth: 0, lastHeight: 0, lastYawRad: nil, lastPitchRad: nil)
    }

    /// Returns dynamic ratio 0…1 (higher = more unexplained temporal change).
    static func dynamicRatio(
        state: State,
        grayscale: [UInt8],
        width: Int,
        height: Int,
        yawRad: Float,
        pitchRad: Float
    ) -> (ratio: Float, newState: State) {
        let newState = State(
            lastGrayscale: grayscale,
            lastWidth: width,
            lastHeight: height,
            lastYawRad: yawRad,
            lastPitchRad: pitchRad
        )

        guard let prev = state.lastGrayscale,
              let lastYaw = state.lastYawRad,
              let lastPitch = state.lastPitchRad,
              prev.count == grayscale.count,
              state.lastWidth == width,
              state.lastHeight == height else {
            return (0, newState)
        }

        let angularDeltaDeg = SphericalMath.angularDistanceDeg(
            yawA: lastYaw, pitchA: lastPitch,
            yawB: yawRad, pitchB: pitchRad
        )
        if angularDeltaDeg > expectedRotationThresholdDeg {
            return (0, newState)
        }

        let alignment = PanoramaAlignmentRefiner.estimateTranslationalOffset(
            reference: prev,
            target: grayscale,
            width: width,
            height: height
        )
        let ratio = Quick360ImageAnalysis.residualDifferenceRatio(
            reference: prev,
            current: grayscale,
            width: width,
            height: height,
            shiftDx: Int(alignment.dx.rounded()),
            shiftDy: Int(alignment.dy.rounded())
        )
        return (ratio, newState)
    }

    static func shouldWaitForClear(ratio: Float, threshold: Float = 0.35) -> Bool {
        ratio >= threshold
    }
}

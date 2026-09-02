import Foundation

/// Prototype dynamic-region detector via temporal image difference.
enum Quick360DynamicRegionDetector {
    struct State: Equatable {
        var lastGrayscale: [UInt8]?
        var lastWidth: Int
        var lastHeight: Int
    }

    static func initial() -> State {
        State(lastGrayscale: nil, lastWidth: 0, lastHeight: 0)
    }

    /// Returns dynamic ratio 0…1 (higher = more motion between frames).
    static func dynamicRatio(
        state: State,
        grayscale: [UInt8],
        width: Int,
        height: Int
    ) -> (ratio: Float, newState: State) {
        guard let prev = state.lastGrayscale,
              prev.count == grayscale.count,
              state.lastWidth == width,
              state.lastHeight == height else {
            return (0, State(lastGrayscale: grayscale, lastWidth: width, lastHeight: height))
        }
        let ratio = Quick360ImageAnalysis.differenceRatio(a: prev, b: grayscale)
        return (ratio, State(lastGrayscale: grayscale, lastWidth: width, lastHeight: height))
    }

    static func shouldWaitForClear(ratio: Float, threshold: Float = 0.35) -> Bool {
        ratio >= threshold
    }
}

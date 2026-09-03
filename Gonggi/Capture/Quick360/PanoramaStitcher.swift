import Foundation
import simd

/// Full panorama stitching: selected keyframes → visual refinement → project → seam → export.
enum PanoramaStitcher {
    struct InputKeyframe {
        let index: Int
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let cameraTransform: simd_float4x4
        let intrinsics: CameraIntrinsics
        let dynamicRatio: Float
        let sharpness: Float
        let exposure: Float
        let translationM: Float
        let fileName: String
        let yawRad: Float
        let pitchRad: Float

        init(
            index: Int,
            rgba: [UInt8],
            width: Int,
            height: Int,
            cameraTransform: simd_float4x4,
            intrinsics: CameraIntrinsics,
            dynamicRatio: Float,
            sharpness: Float = 1,
            exposure: Float = 1,
            translationM: Float = 0,
            fileName: String = "",
            yawRad: Float = 0,
            pitchRad: Float = 0
        ) {
            self.index = index
            self.rgba = rgba
            self.width = width
            self.height = height
            self.cameraTransform = cameraTransform
            self.intrinsics = intrinsics
            self.dynamicRatio = dynamicRatio
            self.sharpness = sharpness
            self.exposure = exposure
            self.translationM = translationM
            self.fileName = fileName
            self.yawRad = yawRad
            self.pitchRad = pitchRad
        }
    }

    struct Output {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let coverageFlags: [Bool]
        let coveragePercent: Double
        let uncoveredPercent: Double
        let alignmentApplied: Bool
        let stitchTimeSec: Double
        let acceptedKeyframeCount: Int
        let rejectedKeyframeCount: Int
        let averageAngularSpacingDeg: Double
        let visualRefinementAttempts: Int
        let successfulRefinements: Int
        let averageMatchCount: Double
        let averageInlierRatio: Double
        let averageReprojectionError: Double
        let highParallaxFrameCount: Int
        let keyframePlacements: [PanoramaKeyframePlacementReport]
        let seamPreferredFrame: [Int16]
        let refinementMatchDebug: [PanoramaAlignmentRefiner.PairMatchDebug]
    }

    static func stitch(
        keyframes: [InputKeyframe],
        originTransform: simd_float4x4,
        outWidth: Int = Quick360Config.outputWidth,
        outHeight: Int = Quick360Config.outputHeight
    ) -> Output {
        let start = Date()
        let gate = PanoramaKeyframeAngularGate.selectForFinalStitch(
            yawRad: keyframes.map(\.yawRad),
            pitchRad: keyframes.map(\.pitchRad),
            sharpness: keyframes.map(\.sharpness),
            exposure: keyframes.map(\.exposure),
            dynamicRatio: keyframes.map(\.dynamicRatio),
            translationM: keyframes.map(\.translationM)
        )
        let selected = gate.acceptedIndices.map { keyframes[$0] }
        let working: [InputKeyframe] = selected.isEmpty ? keyframes : selected

        let refinement = PanoramaAlignmentRefiner.refineSequence(
            keyframes: working,
            fileNames: working.map(\.fileName),
            originTransform: originTransform
        )

        let colorGains = PanoramaExposureCompensator.computeScalesWithOverlap(
            keyframes: working,
            originTransform: originTransform
        )

        let pixelCount = outWidth * outHeight
        var accumColors = [SIMD3<Float>](repeating: .zero, count: pixelCount)
        var accumWeights = [Float](repeating: 0, count: pixelCount)
        var coverage = [Bool](repeating: false, count: pixelCount)
        var perFrameColors: [[SIMD3<Float>]] = []
        var perFrameWeights: [[Float]] = []
        var perFrameDynamic: [Float] = []
        var highParallaxFlags: [Bool] = []

        for (i, kf) in working.enumerated() {
            let gain = i < colorGains.count ? colorGains[i] : SIMD3<Float>(1, 1, 1)
            let scaledRGBA = PanoramaExposureCompensator.applyColorGain(to: kf.rgba, gain: gain)
            let transform = i < refinement.placements.count
                ? refinement.placements[i].projectionTransform
                : kf.cameraTransform
            let (colors, weights, cov) = PanoramaSphericalProjector.projectKeyframe(
                rgba: scaledRGBA,
                width: kf.width,
                height: kf.height,
                cameraTransform: transform,
                originTransform: originTransform,
                intrinsics: kf.intrinsics,
                keyframeIndex: kf.index,
                outWidth: outWidth,
                outHeight: outHeight
            )
            perFrameColors.append(colors)
            perFrameWeights.append(weights)
            perFrameDynamic.append(kf.dynamicRatio)
            highParallaxFlags.append(
                i < refinement.placements.count ? refinement.placements[i].highParallax : false
            )

            let weightScale: Float = highParallaxFlags[i] ? 0.75 : 1
            for p in 0..<pixelCount {
                accumColors[p] += colors[p] * weightScale
                accumWeights[p] += weights[p] * weightScale
                coverage[p] = coverage[p] || cov[p]
            }
        }

        let blended = PanoramaSeamBlender.blend(
            accumColors: accumColors,
            accumWeights: accumWeights,
            perFrameColors: perFrameColors,
            perFrameWeights: perFrameWeights,
            perFrameDynamic: perFrameDynamic,
            highParallaxFlags: highParallaxFlags,
            width: outWidth,
            height: outHeight
        )
        let corrected = PanoramaParallaxWarp.applyLocalCorrection(
            colors: blended.colors,
            width: outWidth,
            height: outHeight
        )

        let rgba = colorsToRGBA(corrected, width: outWidth, height: outHeight)
        let (_, covPct, uncovPct) = PanoramaCoverageMask.generate(
            coverageFlags: coverage,
            width: outWidth,
            height: outHeight
        )
        let elapsed = Date().timeIntervalSince(start)
        let rejectedCount = keyframes.count - working.count

        return Output(
            rgba: rgba,
            width: outWidth,
            height: outHeight,
            coverageFlags: coverage,
            coveragePercent: covPct,
            uncoveredPercent: uncovPct,
            alignmentApplied: refinement.anyApplied,
            stitchTimeSec: elapsed,
            acceptedKeyframeCount: working.count,
            rejectedKeyframeCount: max(0, rejectedCount),
            averageAngularSpacingDeg: gate.averageSpacingDeg,
            visualRefinementAttempts: refinement.attempts,
            successfulRefinements: refinement.successes,
            averageMatchCount: refinement.averageMatchCount,
            averageInlierRatio: refinement.averageInlierRatio,
            averageReprojectionError: refinement.averageReprojError,
            highParallaxFrameCount: refinement.highParallaxCount,
            keyframePlacements: refinement.placements.map(\.report),
            seamPreferredFrame: blended.seam.preferredFrame,
            refinementMatchDebug: refinement.matchDebug
        )
    }

    static func colorsToRGBA(_ colors: [SIMD3<Float>], width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<colors.count {
            let c = colors[i]
            let bi = i * 4
            rgba[bi] = UInt8(simd_clamp(c.x * 255, 0, 255))
            rgba[bi + 1] = UInt8(simd_clamp(c.y * 255, 0, 255))
            rgba[bi + 2] = UInt8(simd_clamp(c.z * 255, 0, 255))
            rgba[bi + 3] = 255
        }
        return rgba
    }

    /// Synthetic panorama for mock mode.
    static func mockPanorama(
        width: Int = Quick360Config.outputWidth,
        height: Int = Quick360Config.outputHeight
    ) -> Output {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var coverage = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let u = Float(x) / Float(width)
                rgba[idx] = UInt8(u * 200 + 30)
                rgba[idx + 1] = UInt8((1 - u) * 180 + 40)
                rgba[idx + 2] = 120
                rgba[idx + 3] = 255
                coverage[y * width + x] = true
            }
        }
        return Output(
            rgba: rgba,
            width: width,
            height: height,
            coverageFlags: coverage,
            coveragePercent: 100,
            uncoveredPercent: 0,
            alignmentApplied: false,
            stitchTimeSec: 0.01,
            acceptedKeyframeCount: 0,
            rejectedKeyframeCount: 0,
            averageAngularSpacingDeg: 0,
            visualRefinementAttempts: 0,
            successfulRefinements: 0,
            averageMatchCount: 0,
            averageInlierRatio: 0,
            averageReprojectionError: 0,
            highParallaxFrameCount: 0,
            keyframePlacements: [],
            seamPreferredFrame: [Int16](repeating: -1, count: width * height),
            refinementMatchDebug: []
        )
    }
}

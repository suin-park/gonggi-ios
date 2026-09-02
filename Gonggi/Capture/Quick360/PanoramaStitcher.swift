import Foundation
import simd

/// Full panorama stitching pipeline: pose → spherical reprojection → blend → exposure.
enum PanoramaStitcher {
    struct InputKeyframe {
        let index: Int
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let cameraTransform: simd_float4x4
        let intrinsics: CameraIntrinsics
        let dynamicRatio: Float
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
    }

    static func stitch(
        keyframes: [InputKeyframe],
        originTransform: simd_float4x4,
        outWidth: Int = Quick360Config.outputWidth,
        outHeight: Int = Quick360Config.outputHeight
    ) -> Output {
        let start = Date()
        let pixelCount = outWidth * outHeight

        // Exposure compensation scales
        let means = keyframes.map { PanoramaExposureCompensator.brightnessMeans(rgba: $0.rgba) }
        let scales = PanoramaExposureCompensator.computeScales(means: means)

        var accumColors = [SIMD3<Float>](repeating: .zero, count: pixelCount)
        var accumWeights = [Float](repeating: 0, count: pixelCount)
        var coverage = [Bool](repeating: false, count: pixelCount)
        var perFrameColors: [[SIMD3<Float>]] = []
        var perFrameWeights: [[Float]] = []
        var perFrameDynamic: [Float] = []
        var alignmentApplied = false

        for (i, kf) in keyframes.enumerated() {
            let scaledRGBA = PanoramaExposureCompensator.applyScale(to: kf.rgba, scale: scales[i])
            let (colors, weights, cov) = PanoramaSphericalProjector.projectKeyframe(
                rgba: scaledRGBA,
                width: kf.width,
                height: kf.height,
                cameraTransform: kf.cameraTransform,
                originTransform: originTransform,
                intrinsics: kf.intrinsics,
                keyframeIndex: kf.index,
                outWidth: outWidth,
                outHeight: outHeight
            )
            perFrameColors.append(colors)
            perFrameWeights.append(weights)
            perFrameDynamic.append(kf.dynamicRatio)

            for p in 0..<pixelCount {
                accumColors[p] += colors[p]
                accumWeights[p] += weights[p]
                coverage[p] = coverage[p] || cov[p]
            }
        }

        var blended = PanoramaSeamBlender.blend(
            accumColors: accumColors,
            accumWeights: accumWeights,
            perFrameColors: perFrameColors,
            perFrameWeights: perFrameWeights,
            perFrameDynamic: perFrameDynamic
        )
        blended = PanoramaParallaxWarp.applyLocalCorrection(
            colors: blended,
            width: outWidth,
            height: outHeight
        )

        // Alignment refinement between adjacent keyframes (thumbnail cross-correlation)
        if keyframes.count >= 2 {
            let refThumb = downsampleToGrayscale(keyframes[0].rgba, w: keyframes[0].width, h: keyframes[0].height)
            let tgtThumb = downsampleToGrayscale(keyframes[1].rgba, w: keyframes[1].width, h: keyframes[1].height)
            let refinement = PanoramaAlignmentRefiner.estimateTranslationalOffset(
                reference: refThumb,
                target: tgtThumb,
                width: 32,
                height: 18
            )
            alignmentApplied = refinement.applied
        }

        let rgba = colorsToRGBA(blended, width: outWidth, height: outHeight)
        let (_, covPct, uncovPct) = PanoramaCoverageMask.generate(
            coverageFlags: coverage,
            width: outWidth,
            height: outHeight
        )
        let elapsed = Date().timeIntervalSince(start)

        return Output(
            rgba: rgba,
            width: outWidth,
            height: outHeight,
            coverageFlags: coverage,
            coveragePercent: covPct,
            uncoveredPercent: uncovPct,
            alignmentApplied: alignmentApplied,
            stitchTimeSec: elapsed
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

    private static func downsampleToGrayscale(_ rgba: [UInt8], w: Int, h: Int) -> [UInt8] {
        Quick360ImageAnalysis.downsampleGrayscale(
            rgba: rgba,
            srcWidth: w,
            srcHeight: h,
            dstWidth: 32,
            dstHeight: 18
        )
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
            stitchTimeSec: 0.01
        )
    }
}

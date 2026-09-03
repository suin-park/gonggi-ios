import Foundation
import simd

/// Visual alignment refinement: ARKit pose is initial guess; overlap match + RANSAC may adjust yaw/pitch.
/// Does not modify live brush / gravity / portrait coordinate pipelines.
enum PanoramaAlignmentRefiner {
    struct Placement: Equatable {
        var index: Int
        var fileName: String
        var initialYawRad: Float
        var initialPitchRad: Float
        var refinedYawRad: Float
        var refinedPitchRad: Float
        var deltaYawRad: Float
        var deltaPitchRad: Float
        var matchCount: Int
        var inlierCount: Int
        var inlierRatio: Float
        var reprojectionError: Float
        var accepted: Bool
        var highParallax: Bool
        var rejectReason: String?
        /// Camera transform used for final spherical projection (refined or ARKit).
        var projectionTransform: simd_float4x4

        var report: PanoramaKeyframePlacementReport {
            PanoramaKeyframePlacementReport(
                index: index,
                fileName: fileName,
                initialYawDeg: initialYawRad * 180 / .pi,
                initialPitchDeg: initialPitchRad * 180 / .pi,
                refinedYawDeg: refinedYawRad * 180 / .pi,
                refinedPitchDeg: refinedPitchRad * 180 / .pi,
                deltaYawDeg: deltaYawRad * 180 / .pi,
                deltaPitchDeg: deltaPitchRad * 180 / .pi,
                matchCount: matchCount,
                inlierCount: inlierCount,
                inlierRatio: inlierRatio,
                reprojectionError: reprojectionError,
                refinementAccepted: accepted,
                highParallax: highParallax,
                rejectReason: rejectReason
            )
        }
    }

    struct SequenceResult: Equatable {
        var placements: [Placement]
        var attempts: Int
        var successes: Int
        var highParallaxCount: Int
        var averageMatchCount: Double
        var averageInlierRatio: Double
        var averageReprojError: Double
        var anyApplied: Bool
        var matchDebug: [PairMatchDebug]
    }

    struct PairMatchDebug: Equatable {
        var leftIndex: Int
        var rightIndex: Int
        var matches: [PanoramaFeatureMatcher.Match]
        var inlierIndices: [Int]
        var accepted: Bool
    }

    /// Legacy thumbnail translational probe (kept for unit tests / fallback).
    struct RefinementResult: Equatable {
        let applied: Bool
        let dx: Float
        let dy: Float
    }

    static func estimateTranslationalOffset(
        reference: [UInt8],
        target: [UInt8],
        width: Int,
        height: Int
    ) -> RefinementResult {
        guard reference.count == target.count, reference.count == width * height else {
            return RefinementResult(applied: false, dx: 0, dy: 0)
        }
        let searchRadius = 3
        var bestDx = 0
        var bestDy = 0
        var bestScore: Float = -1
        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                var score: Float = 0
                var count = 0
                for y in searchRadius..<(height - searchRadius) {
                    for x in searchRadius..<(width - searchRadius) {
                        let refIdx = y * width + x
                        let tx = x + dx
                        let ty = y + dy
                        guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                        let tgtIdx = ty * width + tx
                        let diff = abs(Int(reference[refIdx]) - Int(target[tgtIdx]))
                        score += 1 - Float(diff) / 255
                        count += 1
                    }
                }
                if count > 0 {
                    score /= Float(count)
                    if score > bestScore {
                        bestScore = score
                        bestDx = dx
                        bestDy = dy
                    }
                }
            }
        }
        let applied = bestScore > 0.85 && (bestDx != 0 || bestDy != 0)
        return RefinementResult(applied: applied, dx: Float(bestDx), dy: Float(bestDy))
    }

    /// Refine a keyframe sequence. Keyframe 0 anchors; each next pair may adjust placement.
    static func refineSequence(
        keyframes: [PanoramaStitcher.InputKeyframe],
        fileNames: [String],
        originTransform: simd_float4x4
    ) -> SequenceResult {
        var placements: [Placement] = []
        var matchDebug: [PairMatchDebug] = []
        var attempts = 0
        var successes = 0
        var highParallaxCount = 0
        var matchSum = 0
        var inlierRatioSum: Double = 0
        var reprojSum: Double = 0
        var successStats = 0

        for (i, kf) in keyframes.enumerated() {
            let yp = SphericalMath.relativeYawPitchRad(
                cameraTransform: kf.cameraTransform,
                originTransform: originTransform
            )
            let name = i < fileNames.count ? fileNames[i] : String(format: "keyframe_%04d", i)
            if i == 0 {
                placements.append(Placement(
                    index: i,
                    fileName: name,
                    initialYawRad: yp.yaw,
                    initialPitchRad: yp.pitch,
                    refinedYawRad: yp.yaw,
                    refinedPitchRad: yp.pitch,
                    deltaYawRad: 0,
                    deltaPitchRad: 0,
                    matchCount: 0,
                    inlierCount: 0,
                    inlierRatio: 0,
                    reprojectionError: 0,
                    accepted: false,
                    highParallax: false,
                    rejectReason: "anchor",
                    projectionTransform: kf.cameraTransform
                ))
                continue
            }

            attempts += 1
            let prev = keyframes[i - 1]
            let prevPlacement = placements[i - 1]
            let refined = refinePair(
                left: prev,
                right: kf,
                leftProjection: prevPlacement.projectionTransform,
                originTransform: originTransform,
                index: i,
                fileName: name,
                initialYaw: yp.yaw,
                initialPitch: yp.pitch
            )
            placements.append(refined.placement)
            matchDebug.append(refined.debug)
            matchSum += refined.placement.matchCount
            if refined.placement.accepted {
                successes += 1
                successStats += 1
                inlierRatioSum += Double(refined.placement.inlierRatio)
                reprojSum += Double(refined.placement.reprojectionError)
            }
            if refined.placement.highParallax {
                highParallaxCount += 1
            }
        }

        let avgMatch = attempts > 0 ? Double(matchSum) / Double(attempts) : 0
        let avgInlier = successStats > 0 ? inlierRatioSum / Double(successStats) : 0
        let avgReproj = successStats > 0 ? reprojSum / Double(successStats) : 0
        return SequenceResult(
            placements: placements,
            attempts: attempts,
            successes: successes,
            highParallaxCount: highParallaxCount,
            averageMatchCount: avgMatch,
            averageInlierRatio: avgInlier,
            averageReprojError: avgReproj,
            anyApplied: successes > 0,
            matchDebug: matchDebug
        )
    }

    private struct PairOutcome {
        var placement: Placement
        var debug: PairMatchDebug
    }

    private static func refinePair(
        left: PanoramaStitcher.InputKeyframe,
        right: PanoramaStitcher.InputKeyframe,
        leftProjection: simd_float4x4,
        originTransform: simd_float4x4,
        index: Int,
        fileName: String,
        initialYaw: Float,
        initialPitch: Float
    ) -> PairOutcome {
        func fallback(_ reason: String, highParallax: Bool = false) -> PairOutcome {
            let p = Placement(
                index: index,
                fileName: fileName,
                initialYawRad: initialYaw,
                initialPitchRad: initialPitch,
                refinedYawRad: initialYaw,
                refinedPitchRad: initialPitch,
                deltaYawRad: 0,
                deltaPitchRad: 0,
                matchCount: 0,
                inlierCount: 0,
                inlierRatio: 0,
                reprojectionError: 0,
                accepted: false,
                highParallax: highParallax,
                rejectReason: reason,
                projectionTransform: right.cameraTransform
            )
            return PairOutcome(
                placement: p,
                debug: PairMatchDebug(
                    leftIndex: left.index,
                    rightIndex: right.index,
                    matches: [],
                    inlierIndices: [],
                    accepted: false
                )
            )
        }

        guard let region = PanoramaOverlapEstimator.estimate(
            leftIntrinsics: left.intrinsics,
            rightIntrinsics: right.intrinsics,
            leftTransform: leftProjection,
            rightTransform: right.cameraTransform,
            originTransform: originTransform
        ) else {
            return fallback("overlap_too_small")
        }
        if region.overlapFraction < Quick360Config.keyframeMinOverlapFraction {
            return fallback("overlap_below_threshold")
        }

        guard let leftPatch = PanoramaOverlapEstimator.grayscalePatch(
            rgba: left.rgba, width: left.width, height: left.height,
            x0: region.leftX0, y0: region.leftY0, x1: region.leftX1, y1: region.leftY1
        ),
        let rightPatch = PanoramaOverlapEstimator.grayscalePatch(
            rgba: right.rgba, width: right.width, height: right.height,
            x0: region.rightX0, y0: region.rightY0, x1: region.rightX1, y1: region.rightY1
        ) else {
            return fallback("patch_extract_failed")
        }

        let leftThumb = downsampleIfNeeded(leftPatch.gray, w: leftPatch.w, h: leftPatch.h)
        let rightThumb = downsampleIfNeeded(rightPatch.gray, w: rightPatch.w, h: rightPatch.h)
        let scaleL = Float(leftThumb.w) / Float(max(leftPatch.w, 1))
        let corners = PanoramaFeatureMatcher.detectCorners(
            gray: leftThumb.gray, width: leftThumb.w, height: leftThumb.h
        )
        let matches = PanoramaFeatureMatcher.matchCorners(
            leftGray: leftThumb.gray, leftW: leftThumb.w, leftH: leftThumb.h,
            rightGray: rightThumb.gray, rightW: rightThumb.w, rightH: rightThumb.h,
            leftCorners: corners
        )
        guard matches.count >= Quick360Config.refinementMinMatches else {
            return fallback("feature_count_low")
        }
        guard let ransac = PanoramaRANSAC.fitTranslation(matches: matches) else {
            return fallback("ransac_failed")
        }
        guard ransac.inlierRatio >= Quick360Config.refinementMinInlierRatio else {
            return fallback("inlier_ratio_low")
        }
        guard ransac.meanReprojError <= Quick360Config.refinementMaxReprojPx else {
            return fallback("reproj_error_high")
        }
        guard PanoramaRANSAC.isModelPlausible(matches: matches, result: ransac) else {
            return fallback("scale_shear_reject")
        }

        let highParallax = PanoramaRANSAC.detectHighParallax(
            matches: matches,
            inlierIndices: ransac.inlierIndices
        )

        // Pixel flow in thumb → angle via left focal length (scaled).
        let fx = max(left.intrinsics.fx * scaleL * Float(leftPatch.w) / Float(max(left.intrinsics.width, 1)), 1)
        let fy = max(left.intrinsics.fy * scaleL * Float(leftPatch.h) / Float(max(left.intrinsics.height, 1)), 1)
        // Overlap patches: dx in patch space; sign: rightward content motion → negative yaw correction of new frame.
        let dYaw = -ransac.model.dx / fx
        let dPitch = ransac.model.dy / fy

        let maxYaw = Quick360Config.refinementMaxYawDeltaDeg * .pi / 180
        let maxPitch = Quick360Config.refinementMaxPitchDeltaDeg * .pi / 180
        if abs(dYaw) > maxYaw || abs(dPitch) > maxPitch {
            return fallback("delta_exceeds_gate", highParallax: highParallax)
        }

        let refinedYaw = initialYaw + dYaw
        let refinedPitch = initialPitch + dPitch
        let projection = applyYawPitchDelta(
            to: right.cameraTransform,
            deltaYaw: dYaw,
            deltaPitch: dPitch
        )
        let placement = Placement(
            index: index,
            fileName: fileName,
            initialYawRad: initialYaw,
            initialPitchRad: initialPitch,
            refinedYawRad: refinedYaw,
            refinedPitchRad: refinedPitch,
            deltaYawRad: dYaw,
            deltaPitchRad: dPitch,
            matchCount: matches.count,
            inlierCount: ransac.inlierIndices.count,
            inlierRatio: ransac.inlierRatio,
            reprojectionError: ransac.meanReprojError,
            accepted: true,
            highParallax: highParallax,
            rejectReason: nil,
            projectionTransform: projection
        )
        return PairOutcome(
            placement: placement,
            debug: PairMatchDebug(
                leftIndex: left.index,
                rightIndex: right.index,
                matches: matches,
                inlierIndices: ransac.inlierIndices,
                accepted: true
            )
        )
    }

    /// Rotate camera optical axes by small yaw (world Y) then pitch (camera right) — stitch only.
    static func applyYawPitchDelta(
        to camera: simd_float4x4,
        deltaYaw: Float,
        deltaPitch: Float
    ) -> simd_float4x4 {
        let cy = cos(deltaYaw), sy = sin(deltaYaw)
        let yawR = simd_float3x3(
            SIMD3(cy, 0, -sy),
            SIMD3(0, 1, 0),
            SIMD3(sy, 0, cy)
        )
        let right = simd_normalize(simd_float3(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z))
        let cp = cos(deltaPitch), sp = sin(deltaPitch)
        // Rodrigues around camera right.
        let K = simd_float3x3(
            SIMD3(0, -right.z, right.y),
            SIMD3(right.z, 0, -right.x),
            SIMD3(-right.y, right.x, 0)
        )
        let pitchR = simd_float3x3(diagonal: SIMD3(1, 1, 1))
            + sp * K
            + (1 - cp) * (K * K)

        let R0 = simd_float3x3(
            SIMD3(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z),
            SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z),
            SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        )
        let R1 = pitchR * (yawR * R0)
        var out = camera
        out.columns.0 = SIMD4(R1.columns.0.x, R1.columns.0.y, R1.columns.0.z, 0)
        out.columns.1 = SIMD4(R1.columns.1.x, R1.columns.1.y, R1.columns.1.z, 0)
        out.columns.2 = SIMD4(R1.columns.2.x, R1.columns.2.y, R1.columns.2.z, 0)
        return out
    }

    private static func downsampleIfNeeded(
        _ gray: [UInt8],
        w: Int,
        h: Int
    ) -> (gray: [UInt8], w: Int, h: Int) {
        let maxW = Quick360Config.refinementMatchThumbMaxWidth
        guard max(w, h) > maxW else { return (gray, w, h) }
        let scale = Float(maxW) / Float(max(w, h))
        let nw = max(8, Int(Float(w) * scale))
        let nh = max(8, Int(Float(h) * scale))
        var out = [UInt8](repeating: 0, count: nw * nh)
        for y in 0..<nh {
            for x in 0..<nw {
                let sx = min(w - 1, Int(Float(x) / scale))
                let sy = min(h - 1, Int(Float(y) / scale))
                out[y * nw + x] = gray[sy * w + sx]
            }
        }
        return (out, nw, nh)
    }
}

/// Parallax-aware local warp hook — V1 still identity; detection lives in refinement report.
enum PanoramaParallaxWarp {
    static let level = "detect_only_v1"

    static func applyLocalCorrection(
        colors: [SIMD3<Float>],
        width: Int,
        height: Int
    ) -> [SIMD3<Float>] {
        colors
    }
}

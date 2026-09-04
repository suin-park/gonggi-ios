import Foundation
import simd

/// Build 27 PoC — depth-assisted proxy-geometry LatLong reprojection.
/// Streaming: ≤1 full-res frame resident. Failures never abort the session.
struct DepthReprojectionPanoramaEngine: PanoramaEngineProtocol {
    var identifier: String { PanoramaEngineID.depthReproject }

    var depthProvider: any DepthMapProviding = MonocularProxyDepthEstimator()
    /// Subsample source pixels for speed (1 = full; 2 = half).
    var sourceStride: Int = 2
    var writeDebugArtifacts: Bool = true
    /// Which virtual centers to evaluate (Build 27 compares A/B/C when all listed).
    var centerModesToRun: [DepthReprojectionMath.PanoramaCenterMode] = [
        .firstCamera, .medianCameras, .leastParallax
    ]

    func stitch(input: PanoramaEngineInput) async throws -> PanoramaEngineOutput {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            return try await stitchThrowing(input: input, t0: t0)
        } catch {
            return .failure(
                engine: identifier,
                reason: error.localizedDescription,
                processingTimeSec: CFAbsoluteTimeGetCurrent() - t0
            )
        }
    }

    private func stitchThrowing(input: PanoramaEngineInput, t0: CFAbsoluteTime) async throws -> PanoramaEngineOutput {
        guard !input.keyframes.isEmpty else {
            throw PanoramaEngineError.emptyKeyframes
        }
        let outW = input.outputWidth
        let outH = input.outputHeight
        guard PanoramaEquirectOrientationContract.isValidResolution(width: outW, height: outH)
                || (outW > 0 && outH > 0 && abs(Double(outW) / Double(outH) - 2) < 0.05) else {
            throw PanoramaEngineError.unavailable(engine: identifier, reason: "invalid output resolution")
        }

        let debugRoot: URL?
        if writeDebugArtifacts {
            let dir = try PanoramaABPaths.directory(sessionId: input.sessionId)
                .appendingPathComponent("depth_reproject", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            debugRoot = dir
        } else {
            debugRoot = nil
        }

        // Preserve capture metadata sidecar for proxy-geometry / 3DGS research.
        if let debugRoot {
            try? writeCaptureSidecar(input: input, to: debugRoot.appendingPathComponent("capture_inputs.json"))
        }

        let centers = input.keyframes.map { DepthReprojectionMath.cameraCenter($0.cameraTransform) }
        let centerModes = centerModesToRun.isEmpty
            ? [DepthReprojectionMath.PanoramaCenterMode.medianCameras]
            : centerModesToRun

        var metrics = DepthReprojectionMetrics()
        metrics.inputKeyframeCount = input.keyframes.count
        metrics.depthSourceMode = depthProvider.mode.rawValue
        metrics.depthProviderLabel = (depthProvider as? MonocularProxyDepthEstimator) != nil
            ? "monocularProxy_geometric_mvs_lite"
            : depthProvider.mode.rawValue

        var bestCompose: DepthReprojectionCanvas.ComposeResult?
        var bestMode: DepthReprojectionMath.PanoramaCenterMode = .medianCameras
        var bestPeakMB: Double = 0

        for mode in centerModes {
            let O = DepthReprojectionMath.panoramaCenter(cameraCenters: centers, mode: mode)
            let canvas = DepthReprojectionCanvas(width: outW, height: outH)
            var depthValidPixels = 0
            var depthTotal = 0
            var maxResident = 0

            for (fi, kf) in input.keyframes.enumerated() {
                // Streaming load: prefer in-memory RGBA; else JPEG from session.
                var rgba = kf.rgba
                var w = kf.width
                var h = kf.height
                if rgba.isEmpty, !kf.fileName.isEmpty {
                    let url = try CaptureSessionStore.quick360KeyframeURL(
                        sessionId: input.sessionId,
                        fileName: kf.fileName
                    )
                    if let data = try? Data(contentsOf: url),
                       let loaded = Quick360FrameEncoder.loadRGBA(fromJPEG: data) {
                        rgba = loaded.rgba
                        w = loaded.width
                        h = loaded.height
                    }
                }
                guard !rgba.isEmpty, w > 0, h > 0 else { continue }
                maxResident = 1

                let neighbors = neighborHints(
                    for: fi, input: input, sessionId: input.sessionId, maxNeighbors: 2
                )
                let depthMap = depthProvider.depthMap(
                    rgba: rgba, width: w, height: h, frameIndex: fi,
                    cameraTransform: kf.cameraTransform, intrinsics: kf.intrinsics,
                    neighbors: neighbors
                )

                depthTotal += depthMap.pixelCount
                for c in depthMap.confidence where c > 0.05 { depthValidPixels += 1 }

                if let debugRoot, mode == .medianCameras {
                    try? writeDepthDebug(
                        depthMap: depthMap, rgba: rgba, width: w, height: h,
                        index: fi, dir: debugRoot
                    )
                }

                reprojectFrame(
                    rgba: rgba, width: w, height: h,
                    depthMap: depthMap,
                    cameraToWorld: kf.cameraTransform,
                    K: kf.intrinsics,
                    origin: O,
                    canvas: canvas,
                    exposure: max(0.5, min(1.5, kf.exposure))
                )

                // Release frame pixels (streaming).
                rgba = []
                _ = rgba
            }

            bestPeakMB = max(bestPeakMB, estimateCanvasMB(outW: outW, outH: outH) + 40)

            let composed = canvas.compose()
            if let debugRoot {
                let tag = mode.rawValue
                try? PanoramaExporter.writeJPEG(
                    rgba: composed.rgba, width: outW, height: outH,
                    to: debugRoot.appendingPathComponent("reprojection_\(tag).jpg")
                )
            }

            if bestCompose == nil || composed.coveragePercent > (bestCompose?.coveragePercent ?? 0) {
                bestCompose = composed
                bestMode = mode
                metrics.depthValidPercent = depthTotal > 0
                    ? 100.0 * Double(depthValidPixels) / Double(depthTotal) : 0
                metrics.maxResidentFullResFrames = maxResident
                metrics.overlapConflictPercent = composed.conflictPercent
                metrics.depthDiscontinuityRejectPercent = composed.discontinuityRejectPercent
                metrics.avgSourcesPerLatLongPixel = composed.avgSources
                metrics.p90SourcesPerPixel = composed.p90Sources
                metrics.holeCapturePercent = composed.holeCapturePercent
                metrics.holeDepthInvalidPercent = composed.holeDepthPercent
                metrics.holeVisibilityPercent = composed.holeVisibilityPercent
                metrics.holeOverlapPercent = composed.holeOverlapPercent
            }
        }

        guard var compose = bestCompose else {
            throw PanoramaEngineError.unavailable(engine: identifier, reason: "empty compose")
        }

        metrics.panoramaCenterMode = bestMode.rawValue
        metrics.finalCoveragePercent = compose.coveragePercent
        metrics.holePercent = compose.holePercent
        metrics.observedPixelPercent = compose.observedPercent
        metrics.reprojectionAcceptedPercent = compose.coveragePercent
        metrics.ghostingRiskPercent = min(100, compose.conflictPercent * 1.5)
        metrics.peakMemoryMBEstimate = bestPeakMB
        metrics.outputResolution = "\(outW)x\(outH)"

        // Feather confidence boundaries lightly (no GraphCut).
        compose.rgba = featherHoles(rgba: compose.rgba, hole: compose.holeMask, width: outW, height: outH)

        if let debugRoot {
            try PanoramaExporter.writeJPEG(
                rgba: compose.rgba, width: outW, height: outH,
                to: debugRoot.appendingPathComponent("depth_reproject_4096x2048.jpg")
            )
            // Also copy to AB root alias name for side-by-side.
            let ab = try PanoramaABPaths.directory(sessionId: input.sessionId)
            try? PanoramaExporter.writeJPEG(
                rgba: compose.rgba, width: outW, height: outH,
                to: ab.appendingPathComponent(PanoramaABPaths.depthReprojectPanorama)
            )

            try writeHoleMaskPNG(compose.holeMask, width: outW, height: outH,
                                 to: debugRoot.appendingPathComponent("hole_mask.png"))

            let canvasForViz = DepthReprojectionCanvas(width: outW, height: outH)
            // Reuse compose hole as coverage viz
            var cov = [UInt8](repeating: 0, count: outW * outH * 4)
            for i in 0..<outW * outH {
                let v: UInt8 = compose.holeMask[i] == 0 ? 255 : 0
                cov[i * 4] = v; cov[i * 4 + 1] = v; cov[i * 4 + 2] = v; cov[i * 4 + 3] = 255
            }
            try? PanoramaExporter.writeJPEG(
                rgba: cov, width: outW, height: outH,
                to: debugRoot.appendingPathComponent("reprojection_coverage.jpg")
            )
            _ = canvasForViz

            let metricsURL = debugRoot.appendingPathComponent("metrics.json")
            try PanoramaExporter.writeJSON(metrics, to: metricsURL)
        }

        // Primary engine output URL (PoC path — not user-facing when A/B).
        try PanoramaExporter.writeJPEG(
            rgba: compose.rgba, width: outW, height: outH, to: input.outputPanoramaURL
        )

        let dt = CFAbsoluteTimeGetCurrent() - t0
        let coverageFlags = compose.holeMask.map { $0 == 0 }
        let stitch = PanoramaStitcher.Output(
            rgba: compose.rgba,
            width: outW,
            height: outH,
            coverageFlags: coverageFlags,
            coveragePercent: compose.coveragePercent,
            uncoveredPercent: compose.holePercent,
            alignmentApplied: true,
            stitchTimeSec: dt,
            acceptedKeyframeCount: input.keyframes.count,
            rejectedKeyframeCount: 0,
            averageAngularSpacingDeg: 0,
            visualRefinementAttempts: 0,
            successfulRefinements: 0,
            averageMatchCount: 0,
            averageInlierRatio: 0,
            averageReprojectionError: 0,
            highParallaxFrameCount: 0,
            keyframePlacements: [],
            seamPreferredFrame: [],
            refinementMatchDebug: []
        )

        let metricsJSON = (try? JSONEncoder().encode(metrics)).flatMap { String(data: $0, encoding: .utf8) }

        return PanoramaEngineOutput(
            engineIdentifier: identifier,
            success: true,
            panoramaURL: input.outputPanoramaURL,
            width: outW,
            height: outH,
            rgba: compose.rgba,
            coverageFlags: coverageFlags,
            processingTimeSec: dt,
            stitchOutput: stitch,
            failureReason: nil,
            report: PanoramaEngineRunReport(
                engine: identifier,
                success: true,
                finalResolution: metrics.outputResolution,
                selectedKeyframeCount: input.keyframes.count,
                processingTimeMs: dt * 1000,
                peakMemoryMB: bestPeakMB,
                coveragePercent: compose.coveragePercent,
                seamMetric: nil,
                alignmentRefinementSuccess: true,
                visualRefinementAttempts: nil,
                successfulRefinements: nil,
                fallbackCount: 0,
                highParallaxCount: nil,
                outputFilePath: input.outputPanoramaURL.path,
                failureReason: nil,
                openCVMetricsJSON: metricsJSON
            )
        )
    }

    // MARK: - Reproject one frame

    private func reprojectFrame(
        rgba: [UInt8],
        width: Int,
        height: Int,
        depthMap: DepthFrameMap,
        cameraToWorld: simd_float4x4,
        K: CameraIntrinsics,
        origin: simd_float3,
        canvas: DepthReprojectionCanvas,
        exposure: Float
    ) {
        let step = max(1, sourceStride)
        let longEdge = Float(max(width, height))
        let camFwd = SphericalMath.forwardVector(from: cameraToWorld)

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let dx = min(depthMap.width - 1, x * depthMap.width / max(width, 1))
                let dy = min(depthMap.height - 1, y * depthMap.height / max(height, 1))
                let didx = dy * depthMap.width + dx
                let d = depthMap.depth[didx]
                let c = depthMap.confidence[didx]
                if c < 0.04 || d < 1e-3 {
                    continue
                }

                let ray = DepthReprojectionMath.cameraRay(u: Float(x), v: Float(y), K: K)
                let Pw = DepthReprojectionMath.worldPoint(
                    depth: d, rayCam: ray, cameraToWorld: cameraToWorld
                )
                let dir = simd_normalize(Pw - origin)
                let viewCos = abs(simd_dot(camFwd, dir))
                let (px, py) = DepthReprojectionMath.equirectPixel(
                    direction: dir, width: canvas.width, height: canvas.height
                )
                let radius = DepthReprojectionMath.splatRadius(
                    depth: d, viewCos: max(0.2, viewCos),
                    sourceLongEdge: longEdge, outWidth: canvas.width
                )

                let o = (y * width + x) * 4
                let r = Float(rgba[o]) * exposure
                let g = Float(rgba[o + 1]) * exposure
                let b = Float(rgba[o + 2]) * exposure

                // Depth gradient gate from confidence already lowered on edges.
                let depthGradHigh = c < 0.25
                let centerProx = 1 - min(1, abs(px / Float(canvas.width - 1) - 0.5) * 0.3)
                let w = c * max(0.2, viewCos) * centerProx

                let depthFromOrigin = simd_length(Pw - origin)
                canvas.splat(
                    colorR: min(255, r), colorG: min(255, g), colorB: min(255, b),
                    px: px, py: py, radius: radius, weight: w,
                    depthFromOrigin: depthFromOrigin,
                    depthConfidence: c,
                    depthGradientHigh: depthGradHigh
                )
            }
        }
    }

    private func neighborHints(
        for index: Int,
        input: PanoramaEngineInput,
        sessionId: String,
        maxNeighbors: Int
    ) -> [DepthNeighborHint] {
        let kfs = input.keyframes
        guard index < kfs.count else { return [] }
        let yi = kfs[index].yawRad
        let pi = kfs[index].pitchRad
        var scored: [(Float, Int)] = []
        for (j, kf) in kfs.enumerated() where j != index {
            let ang = SphericalMath.angularDistanceRad(
                yawA: yi, pitchA: pi, yawB: kf.yawRad, pitchB: kf.pitchRad
            )
            if ang < 0.7 { scored.append((ang, j)) }
        }
        scored.sort { $0.0 < $1.0 }
        var out: [DepthNeighborHint] = []
        for (_, j) in scored.prefix(maxNeighbors) {
            let kf = kfs[j]
            if !kf.rgba.isEmpty {
                out.append(DepthNeighborHint(
                    index: j, rgba: kf.rgba, width: kf.width, height: kf.height,
                    cameraTransform: kf.cameraTransform, intrinsics: kf.intrinsics
                ))
                continue
            }
            guard !kf.fileName.isEmpty,
                  let url = try? CaptureSessionStore.quick360KeyframeURL(
                    sessionId: sessionId, fileName: kf.fileName
                  ),
                  let data = try? Data(contentsOf: url),
                  let loaded = Quick360FrameEncoder.loadRGBA(fromJPEG: data)
            else { continue }
            // Downscale neighbor proxy for MVS to keep peak resident low.
            let (sRGBA, sw, sh) = Self.downscaleRGBA(loaded.rgba, width: loaded.width, height: loaded.height, maxLongEdge: 320)
            let scale = Float(sw) / Float(max(1, loaded.width))
            let sK = CameraIntrinsics(
                fx: kf.intrinsics.fx * scale,
                fy: kf.intrinsics.fy * scale,
                cx: kf.intrinsics.cx * scale,
                cy: kf.intrinsics.cy * scale,
                width: sw,
                height: sh
            )
            out.append(DepthNeighborHint(
                index: j, rgba: sRGBA, width: sw, height: sh,
                cameraTransform: kf.cameraTransform, intrinsics: sK
            ))
        }
        return out
    }

    private static func downscaleRGBA(
        _ rgba: [UInt8], width: Int, height: Int, maxLongEdge: Int
    ) -> (rgba: [UInt8], width: Int, height: Int) {
        let long = max(width, height)
        if long <= maxLongEdge { return (rgba, width, height) }
        let s = Float(maxLongEdge) / Float(long)
        let nw = max(1, Int(Float(width) * s))
        let nh = max(1, Int(Float(height) * s))
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        for y in 0..<nh {
            let sy = min(height - 1, Int(Float(y) / s))
            for x in 0..<nw {
                let sx = min(width - 1, Int(Float(x) / s))
                let si = (sy * width + sx) * 4
                let di = (y * nw + x) * 4
                out[di] = rgba[si]
                out[di + 1] = rgba[si + 1]
                out[di + 2] = rgba[si + 2]
                out[di + 3] = 255
            }
        }
        return (out, nw, nh)
    }

    private func featherHoles(rgba: [UInt8], hole: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = rgba
        for y in 1..<height - 1 {
            for x in 1..<width - 1 {
                let i = y * width + x
                if hole[i] == 0 { continue }
                // If any neighbor covered, soft-fill from neighbors (tiny feather only).
                var sr = 0, sg = 0, sb = 0, c = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let j = (y + dy) * width + (x + dx)
                        if hole[j] == 0 {
                            sr += Int(rgba[j * 4]); sg += Int(rgba[j * 4 + 1]); sb += Int(rgba[j * 4 + 2]); c += 1
                        }
                    }
                }
                if c >= 3 {
                    out[i * 4] = UInt8(sr / c)
                    out[i * 4 + 1] = UInt8(sg / c)
                    out[i * 4 + 2] = UInt8(sb / c)
                    out[i * 4 + 3] = 255
                }
            }
        }
        return out
    }

    private func estimateCanvasMB(outW: Int, outH: Int) -> Double {
        // 6 float buffers + u16 + u8 ≈ 6*4 + 2 + 1 = 27 bytes/px
        Double(outW * outH * 27) / (1024 * 1024)
    }

    private func writeCaptureSidecar(input: PanoramaEngineInput, to url: URL) throws {
        struct FrameMeta: Codable {
            var index: Int
            var fileName: String
            var yawRad: Float
            var pitchRad: Float
            var translationM: Float
            var fx: Float; var fy: Float; var cx: Float; var cy: Float
            var width: Int; var height: Int
            var transform: [Float]
            var targetId: Int?
            var timestamp: Double?
            var qualityScore: Float?
        }
        struct Side: Codable {
            var sessionId: String
            var originTransform: [Float]
            var firstForwardYawRad: Float
            var firstForwardPitchRad: Float
            var outputWidth: Int
            var outputHeight: Int
            var frames: [FrameMeta]
        }
        let origin = CaptureKeyframeRecord.encodeTransform(input.originTransform)
        var frames: [FrameMeta] = []
        for (i, kf) in input.keyframes.enumerated() {
            let meta = input.selectedKeyframeMeta.first { $0.fileName == kf.fileName }
            frames.append(FrameMeta(
                index: i,
                fileName: kf.fileName,
                yawRad: kf.yawRad,
                pitchRad: kf.pitchRad,
                translationM: kf.translationM,
                fx: kf.intrinsics.fx, fy: kf.intrinsics.fy,
                cx: kf.intrinsics.cx, cy: kf.intrinsics.cy,
                width: kf.width, height: kf.height,
                transform: CaptureKeyframeRecord.encodeTransform(kf.cameraTransform),
                targetId: meta?.targetId,
                timestamp: meta?.timestamp,
                qualityScore: meta?.qualityScore
            ))
        }
        let side = Side(
            sessionId: input.sessionId,
            originTransform: origin,
            firstForwardYawRad: input.firstForwardYawRad,
            firstForwardPitchRad: input.firstForwardPitchRad,
            outputWidth: input.outputWidth,
            outputHeight: input.outputHeight,
            frames: frames
        )
        try PanoramaExporter.writeJSON(side, to: url)
    }

    private func writeDepthDebug(
        depthMap: DepthFrameMap,
        rgba: [UInt8],
        width: Int,
        height: Int,
        index: Int,
        dir: URL
    ) throws {
        let tag = String(format: "frame_%02d", index)
        var depthRGB = [UInt8](repeating: 0, count: depthMap.pixelCount * 4)
        var confRGB = [UInt8](repeating: 0, count: depthMap.pixelCount * 4)
        let med = depthMap.medianPositiveDepth() ?? 2
        for i in 0..<depthMap.pixelCount {
            let t = UInt8(clamping: Int(min(1, depthMap.depth[i] / (med * 2)) * 255))
            depthRGB[i * 4] = t; depthRGB[i * 4 + 1] = t; depthRGB[i * 4 + 2] = t; depthRGB[i * 4 + 3] = 255
            let c = UInt8(clamping: Int(depthMap.confidence[i] * 255))
            confRGB[i * 4] = c; confRGB[i * 4 + 1] = c; confRGB[i * 4 + 2] = c; confRGB[i * 4 + 3] = 255
        }
        try PanoramaExporter.writeJPEG(
            rgba: depthRGB, width: depthMap.width, height: depthMap.height,
            to: dir.appendingPathComponent("\(tag)_depth.jpg")
        )
        try PanoramaExporter.writeJPEG(
            rgba: confRGB, width: depthMap.width, height: depthMap.height,
            to: dir.appendingPathComponent("\(tag)_depth_confidence.jpg")
        )
        // Tiny source thumb already available via keyframe; skip heavy reprojected per-frame for memory.
        _ = rgba; _ = width; _ = height
    }

    private func writeHoleMaskPNG(_ mask: [UInt8], width: Int, height: Int, to url: URL) throws {
        // Reuse JPEG writer as grayscale RGB for simplicity (PNG optional).
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            let v = mask[i]
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v; rgba[i * 4 + 3] = 255
        }
        let jpg = url.deletingPathExtension().appendingPathExtension("png.jpg")
        try PanoramaExporter.writeJPEG(rgba: rgba, width: width, height: height, to: jpg)
        // Also write requested name via copy of jpeg bytes if png encoder unavailable.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: jpg, to: url)
    }
}

struct DepthReprojectionMetrics: Codable, Equatable, Sendable {
    var inputKeyframeCount: Int = 0
    var depthSourceMode: String = DepthSourceMode.monocularProxy.rawValue
    var depthProviderLabel: String = ""
    var panoramaCenterMode: String = ""
    var finalCoveragePercent: Double = 0
    var holePercent: Double = 0
    var observedPixelPercent: Double = 0
    var depthValidPercent: Double = 0
    var reprojectionAcceptedPercent: Double = 0
    var avgSourcesPerLatLongPixel: Double = 0
    var p90SourcesPerPixel: Double = 0
    var overlapConflictPercent: Double = 0
    var depthDiscontinuityRejectPercent: Double = 0
    var ghostingRiskPercent: Double = 0
    var holeCapturePercent: Double = 0
    var holeDepthInvalidPercent: Double = 0
    var holeVisibilityPercent: Double = 0
    var holeOverlapPercent: Double = 0
    var maxResidentFullResFrames: Int = 0
    var peakMemoryMBEstimate: Double = 0
    var outputResolution: String = ""
    var medianPairAlignmentErrorPx: Double?
    var p90PairAlignmentErrorPx: Double?
}

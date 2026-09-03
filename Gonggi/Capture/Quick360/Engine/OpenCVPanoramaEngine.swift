import Foundation

/// OpenCV reconstruction engine — Swift façade over `OpenCVPanoramaBridge`.
///
/// Call chain:
/// ```
/// Swift OpenCVPanoramaEngine
///   → OpenCVPanoramaBridge (ObjC)
///   → OpenCVPanoramaBridge.mm (ObjC++)
///   → C++ OpenCV detail::* modules
/// ```
/// Production default remains Legacy (`PanoramaEngineSelection`).
struct OpenCVPanoramaEngine: PanoramaEngineProtocol {
    let identifier = PanoramaEngineID.openCV

    var isAvailable: Bool {
        OpenCVPanoramaBridge.isAvailable()
    }

    /// OpenCV library version (e.g. "4.10.0") when linked.
    static var linkedOpenCVVersion: String {
        OpenCVPanoramaBridge.openCVVersionString()
    }

    /// Phase 2A smoke: exercise C++ via bridge.
    static func smokeTestAdd(_ a: Int, _ b: Int) -> Int {
        Int(OpenCVPanoramaBridge.smokeTestAddLeft(a, right: b))
    }

    func stitch(input: PanoramaEngineInput) async throws -> PanoramaEngineOutput {
        let start = Date()

        guard isAvailable else {
            return .failure(
                engine: identifier,
                reason: "OpenCV panorama engine not linked"
            )
        }

        guard !input.keyframes.isEmpty else {
            return .failure(engine: identifier, reason: "No keyframes to stitch")
        }

        // Prefer on-disk JPEG paths from selected keyframe meta; else write temp JPEGs.
        let prepared = try Self.prepareKeyframeFiles(input: input)
        defer {
            for url in prepared.temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let request = OpenCVPanoramaStitchRequest()
        request.keyframeJPEGPaths = prepared.paths
        request.rotationsRowMajor9 = prepared.rotations.map { row in
            row.map { NSNumber(value: $0) }
        }
        request.fx = prepared.fx.map { NSNumber(value: $0) }
        request.fy = prepared.fy.map { NSNumber(value: $0) }
        request.cx = prepared.cx.map { NSNumber(value: $0) }
        request.cy = prepared.cy.map { NSNumber(value: $0) }
        request.imageWidths = prepared.widths.map { NSNumber(value: $0) }
        request.imageHeights = prepared.heights.map { NSNumber(value: $0) }
        request.outputPath = input.outputPanoramaURL.path
        request.outputWidth = input.outputWidth
        request.outputHeight = input.outputHeight
        request.firstForwardYawDeg = input.firstForwardYawRad * 180 / .pi
        request.firstForwardPitchDeg = input.firstForwardPitchRad * 180 / .pi
        request.yawDeg = prepared.yawDeg.map { NSNumber(value: $0) }
        request.pitchDeg = prepared.pitchDeg.map { NSNumber(value: $0) }
        request.translationM = prepared.translationM.map { NSNumber(value: $0) }

        if let debugRoot = try? PanoramaABPaths.directory(sessionId: input.sessionId)
            .appendingPathComponent("opencv", isDirectory: true) {
            try? FileManager.default.createDirectory(at: debugRoot, withIntermediateDirectories: true)
            request.debugDirectoryPath = debugRoot.path
        }

        let bridgeResult = OpenCVPanoramaBridge.stitch(with: request)
        let elapsed = Date().timeIntervalSince(start)

        if bridgeResult.success,
           FileManager.default.fileExists(atPath: input.outputPanoramaURL.path) {
            // Decode for in-memory A/B / tests when needed (optional).
            let report = PanoramaEngineRunReport(
                engine: identifier,
                success: true,
                finalResolution: "\(input.outputWidth)x\(input.outputHeight)",
                selectedKeyframeCount: prepared.paths.count,
                processingTimeMs: bridgeResult.processingTimeMs > 0
                    ? bridgeResult.processingTimeMs
                    : elapsed * 1000,
                peakMemoryMB: bridgeResult.peakMemoryMB,
                coveragePercent: nil,
                seamMetric: nil,
                alignmentRefinementSuccess: nil,
                visualRefinementAttempts: nil,
                successfulRefinements: nil,
                fallbackCount: nil,
                highParallaxCount: nil,
                outputFilePath: input.outputPanoramaURL.path,
                failureReason: nil,
                openCVMetricsJSON: bridgeResult.metricsJSON
            )
            return PanoramaEngineOutput(
                engineIdentifier: identifier,
                success: true,
                panoramaURL: input.outputPanoramaURL,
                width: input.outputWidth,
                height: input.outputHeight,
                rgba: nil,
                coverageFlags: nil,
                processingTimeSec: elapsed,
                stitchOutput: nil,
                failureReason: nil,
                report: report
            )
        }

        let reason = bridgeResult.errorMessage
            ?? "OpenCV stitch failed"
        return PanoramaEngineOutput(
            engineIdentifier: identifier,
            success: false,
            panoramaURL: nil,
            width: 0,
            height: 0,
            rgba: nil,
            coverageFlags: nil,
            processingTimeSec: elapsed,
            stitchOutput: nil,
            failureReason: reason,
            report: PanoramaEngineRunReport(
                engine: identifier,
                success: false,
                finalResolution: nil,
                selectedKeyframeCount: prepared.paths.count,
                processingTimeMs: bridgeResult.processingTimeMs > 0
                    ? bridgeResult.processingTimeMs
                    : elapsed * 1000,
                peakMemoryMB: bridgeResult.peakMemoryMB,
                coveragePercent: nil,
                seamMetric: nil,
                alignmentRefinementSuccess: nil,
                visualRefinementAttempts: nil,
                successfulRefinements: nil,
                fallbackCount: nil,
                highParallaxCount: nil,
                outputFilePath: nil,
                failureReason: reason,
                openCVMetricsJSON: bridgeResult.metricsJSON
            )
        )
    }

    // MARK: - Keyframe file prep (POD paths for bridge)

    private struct PreparedKeyframes {
        var paths: [String]
        var rotations: [[Float]]
        var fx: [Float]
        var fy: [Float]
        var cx: [Float]
        var cy: [Float]
        var widths: [Int]
        var heights: [Int]
        var yawDeg: [Float]
        var pitchDeg: [Float]
        var translationM: [Float]
        var temporaryURLs: [URL]
    }

    private static func prepareKeyframeFiles(input: PanoramaEngineInput) throws -> PreparedKeyframes {
        var paths: [String] = []
        var rotations: [[Float]] = []
        var fx: [Float] = []
        var fy: [Float] = []
        var cx: [Float] = []
        var cy: [Float] = []
        var widths: [Int] = []
        var heights: [Int] = []
        var yawDeg: [Float] = []
        var pitchDeg: [Float] = []
        var translationM: [Float] = []
        var temps: [URL] = []

        let basis = input.captureBasis
            ?? Quick360CaptureBasis.make(fromStartCamera: input.originTransform)
            ?? Quick360CaptureBasis(
                worldUp: Quick360CaptureBasis.gravityUp,
                referenceForward: simd_float3(0, 0, -1),
                referenceRight: simd_float3(1, 0, 0)
            )

        for (i, kf) in input.keyframes.enumerated() {
            let jpegURL: URL
            let fileName: String = {
                if !kf.fileName.isEmpty { return kf.fileName }
                if i < input.selectedKeyframeMeta.count {
                    return input.selectedKeyframeMeta[i].fileName
                }
                return ""
            }()
            if !fileName.isEmpty,
               let stored = try? CaptureSessionStore.quick360KeyframeURL(
                sessionId: input.sessionId,
                fileName: fileName
               ),
               FileManager.default.fileExists(atPath: stored.path) {
                jpegURL = stored
            } else {
                jpegURL = try writeTempJPEG(kf: kf, index: i, temps: &temps)
            }

            paths.append(jpegURL.path)
            widths.append(kf.width)
            heights.append(kf.height)
            fx.append(kf.intrinsics.fx)
            fy.append(kf.intrinsics.fy)
            cx.append(kf.intrinsics.cx)
            cy.append(kf.intrinsics.cy)
            yawDeg.append(kf.yawRad * 180 / .pi)
            pitchDeg.append(kf.pitchRad * 180 / .pi)
            translationM.append(kf.translationM)

            // Roll-free camera→world (same axes as live / Legacy spherical projector).
            let frame = Quick360StabilizedCameraFrame.make(
                fromCamera: kf.cameraTransform,
                worldUp: basis.worldUp
            )
            let R = frame?.rotation ?? Quick360CaptureBasis.cameraRotation(from: kf.cameraTransform)
            // Row-major 3×3 for the ObjC++ bridge.
            rotations.append([
                R.columns.0.x, R.columns.1.x, R.columns.2.x,
                R.columns.0.y, R.columns.1.y, R.columns.2.y,
                R.columns.0.z, R.columns.1.z, R.columns.2.z
            ])
        }

        return PreparedKeyframes(
            paths: paths,
            rotations: rotations,
            fx: fx, fy: fy, cx: cx, cy: cy,
            widths: widths,
            heights: heights,
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            translationM: translationM,
            temporaryURLs: temps
        )
    }

    private static func writeTempJPEG(
        kf: PanoramaStitcher.InputKeyframe,
        index: Int,
        temps: inout [URL]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gonggi-opencv-kf-\(UUID().uuidString)-\(index).jpg")
        try PanoramaExporter.writeJPEG(
            rgba: kf.rgba,
            width: kf.width,
            height: kf.height,
            to: url
        )
        temps.append(url)
        return url
    }
}

/// Documented POD contract (kept for tests / Phase docs).
enum OpenCVPanoramaBridgeContract {
    struct PlannedRequest: Codable, Equatable {
        var keyframeJPEGPaths: [String]
        var rotationsRowMajor9: [[Float]]
        var fx: [Float]
        var fy: [Float]
        var cx: [Float]
        var cy: [Float]
        var imageWidths: [Int]
        var imageHeights: [Int]
        var outputPath: String
        var outputWidth: Int
        var outputHeight: Int
        var firstForwardYawDeg: Float
        var firstForwardPitchDeg: Float
    }

    struct PlannedResponse: Codable, Equatable {
        var success: Bool
        var errorMessage: String?
        var processingTimeMs: Double?
        var peakMemoryMB: Double?
    }

    static let documentedBoundary = """
    Swift → OpenCVPanoramaBridge (ObjC) → .mm → C++ OpenCV
    Pass only POD / paths; never SwiftUI or ARFrame.
    Output must obey PanoramaEquirectOrientationContract.
    """
}

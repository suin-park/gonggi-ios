import Foundation
import simd

// MARK: - Orientation output contract (engine-agnostic)

/// Equirect / viewer contract every `PanoramaEngine` must satisfy.
/// OpenCV Phase 2 must not reintroduce ±90° / mirror hacks in the viewer.
enum PanoramaEquirectOrientationContract {
    static let aspectRatio: Double = 2.0
    static let defaultWidth = Quick360Config.outputWidth
    static let defaultHeight = Quick360Config.outputHeight

    /// yaw = 0 → first capture forward → equirect U = 0.5
    static let forwardU: Float = 0.5
    /// +pitch → image top (smaller V)
    static let zenithVNearTop: Float = 0.0
    static let nadirVNearBottom: Float = 1.0

    static func isValidResolution(width: Int, height: Int) -> Bool {
        width == defaultWidth
            && height == defaultHeight
            && SphericalMath.isValidEquirectangularAspect(width: width, height: height)
    }

    static func forwardPixel(width: Int = defaultWidth, height: Int = defaultHeight) -> (x: Int, y: Int) {
        let x = Int((forwardU * Float(width - 1)).rounded())
        let y = height / 2
        return (x, y)
    }
}

// MARK: - Protocol

protocol PanoramaEngineProtocol {
    var identifier: String { get }
    func stitch(input: PanoramaEngineInput) async throws -> PanoramaEngineOutput
}

enum PanoramaEngineID {
    static let legacy = "gonggi.legacy"
    static let openCV = "gonggi.opencv"
    static let depthReproject = "gonggi.depthReproject"
}

enum PanoramaEngineError: Error, Equatable, LocalizedError {
    case notImplemented(engine: String)
    case unavailable(engine: String, reason: String)
    case emptyKeyframes
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .notImplemented(let e):
            return "Panorama engine '\(e)' is not implemented yet"
        case .unavailable(let e, let reason):
            return "Panorama engine '\(e)' unavailable: \(reason)"
        case .emptyKeyframes:
            return "No keyframes to stitch"
        case .encodeFailed:
            return "Failed to encode panorama"
        }
    }
}

// MARK: - Input / Output (reuse existing stitch types)

struct PanoramaEngineInput {
    let sessionId: String
    let keyframes: [PanoramaStitcher.InputKeyframe]
    let originTransform: simd_float4x4
    let captureBasis: Quick360CaptureBasis?
    /// Selected keyframe metadata (paths / scores) — optional for stitch-only tests.
    let selectedKeyframeMeta: [Quick360SelectedKeyframe]
    let targets: [Quick360SphericalTarget]
    let coverageReport: Quick360SphericalCoverageReport?
    let outputWidth: Int
    let outputHeight: Int
    /// Where the engine should write its primary JPEG (production path or A/B copy).
    let outputPanoramaURL: URL

    /// First-forward reference (gravity capture basis): yaw=0, pitch=0 → U=0.5.
    var firstForwardYawRad: Float { 0 }
    var firstForwardPitchRad: Float { 0 }

    /// Build 24: drop in-memory keyframe RGBA before OpenCV (disk JPEG paths remain).
    func releasingKeyframePixelBuffers() -> PanoramaEngineInput {
        let stripped = keyframes.map { kf in
            PanoramaStitcher.InputKeyframe(
                index: kf.index,
                rgba: [],
                width: kf.width,
                height: kf.height,
                cameraTransform: kf.cameraTransform,
                intrinsics: kf.intrinsics,
                dynamicRatio: kf.dynamicRatio,
                sharpness: kf.sharpness,
                exposure: kf.exposure,
                translationM: kf.translationM,
                fileName: kf.fileName,
                yawRad: kf.yawRad,
                pitchRad: kf.pitchRad
            )
        }
        return PanoramaEngineInput(
            sessionId: sessionId,
            keyframes: stripped,
            originTransform: originTransform,
            captureBasis: captureBasis,
            selectedKeyframeMeta: selectedKeyframeMeta,
            targets: targets,
            coverageReport: coverageReport,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            outputPanoramaURL: outputPanoramaURL
        )
    }
}

struct PanoramaEngineOutput {
    let engineIdentifier: String
    let success: Bool
    let panoramaURL: URL?
    let width: Int
    let height: Int
    let rgba: [UInt8]?
    let coverageFlags: [Bool]?
    let processingTimeSec: Double
    let stitchOutput: PanoramaStitcher.Output?
    let failureReason: String?
    let report: PanoramaEngineRunReport

    /// Drop large RGBA after artifacts are on disk (A/B → OpenCV).
    func releasingHeavyPixelBuffers() -> PanoramaEngineOutput {
        PanoramaEngineOutput(
            engineIdentifier: engineIdentifier,
            success: success,
            panoramaURL: panoramaURL,
            width: width,
            height: height,
            rgba: nil,
            coverageFlags: coverageFlags,
            processingTimeSec: processingTimeSec,
            stitchOutput: stitchOutput?.releasingHeavyPixelBuffers(),
            failureReason: failureReason,
            report: report
        )
    }

    static func failure(
        engine: String,
        reason: String,
        processingTimeSec: Double = 0
    ) -> PanoramaEngineOutput {
        PanoramaEngineOutput(
            engineIdentifier: engine,
            success: false,
            panoramaURL: nil,
            width: 0,
            height: 0,
            rgba: nil,
            coverageFlags: nil,
            processingTimeSec: processingTimeSec,
            stitchOutput: nil,
            failureReason: reason,
            report: PanoramaEngineRunReport(
                engine: engine,
                success: false,
                finalResolution: nil,
                selectedKeyframeCount: 0,
                processingTimeMs: processingTimeSec * 1000,
                peakMemoryMB: nil,
                coveragePercent: nil,
                seamMetric: nil,
                alignmentRefinementSuccess: nil,
                visualRefinementAttempts: nil,
                successfulRefinements: nil,
                fallbackCount: nil,
                highParallaxCount: nil,
                outputFilePath: nil,
                failureReason: reason,
                openCVMetricsJSON: nil
            )
        )
    }
}

/// Per-engine metrics for A/B (nullable when not measurable yet).
struct PanoramaEngineRunReport: Codable, Equatable, Sendable {
    var engine: String
    var success: Bool
    var finalResolution: String?
    var selectedKeyframeCount: Int
    var processingTimeMs: Double
    var peakMemoryMB: Double?
    var coveragePercent: Double?
    var seamMetric: Double?
    var alignmentRefinementSuccess: Bool?
    var visualRefinementAttempts: Int?
    var successfulRefinements: Int?
    var fallbackCount: Int?
    var highParallaxCount: Int?
    var outputFilePath: String?
    var failureReason: String?
    /// Optional OpenCV metrics JSON blob (Phase 2D).
    var openCVMetricsJSON: String?
}

/// Side-by-side A/B summary written to `ab_report.json`.
struct PanoramaABComparisonReport: Codable, Equatable, Sendable {
    var sessionId: String
    var createdAt: String
    var legacy: PanoramaEngineRunReport
    var openCV: PanoramaEngineRunReport
    var depthReproject: PanoramaEngineRunReport?
    var notes: String?
}

enum PanoramaABPaths {
    static let folderName = "ab"
    static let legacyPanorama = "legacy_panorama.jpg"
    static let openCVPanorama = "opencv_panorama.jpg"
    /// Build 26 rotation-graph OpenCV alias for side-by-side naming.
    static let openCVRotationPanorama = "opencv_rotation.jpg"
    static let depthReprojectPanorama = "depth_reproject_4096x2048.jpg"
    static let legacyReport = "legacy_report.json"
    static let openCVReport = "opencv_report.json"
    static let depthReprojectReport = "depth_reproject_report.json"
    static let abReport = "ab_report.json"

    static func directory(sessionId: String) throws -> URL {
        let dir = try CaptureSessionStore.createPanoramaDirectory(sessionId: sessionId)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Top-level A/B files + nested `opencv/` debug tree for AirDrop / Files.
    static func shareableArtifactURLs(sessionId: String) -> [URL] {
        guard let dir = try? directory(sessionId: sessionId),
              let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var urls: [URL] = []
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(item)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    static func openCVPanoramaURL(sessionId: String) -> URL? {
        guard let dir = try? directory(sessionId: sessionId) else { return nil }
        let url = dir.appendingPathComponent(openCVPanorama)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

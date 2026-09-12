import ARKit
import CoreMedia
import Foundation
import simd
import UIKit

enum CaptureMetricAvailability: String, Codable, Equatable, Sendable {
    case notAvailable
    case available
}

// MARK: - Coordinate / orientation contract

/// Explicit contract for stored transforms. **Do not treat as COLMAP.**
struct CaptureCoordinateSystem: Codable, Equatable, Sendable {
    /// `cameraTransform` maps points from camera space into world space (camera → world).
    var cameraTransformConvention: String
    var handedness: String
    /// ARKit: +X right, +Y up, +Z toward viewer (camera looks down −Z).
    var axisMeaning: String
    var worldUp: String
    var worldOrigin: String
    var interfaceOrientationNote: String
    var imageOrientationNote: String
    var colmapNote: String
    /// Intrinsics apply to **native capturedImage** pixel space — not display-rotated frames.
    var intrinsicsCoordinateSpace: String
    var serverDecodeNote: String

    static let arkitDefault = CaptureCoordinateSystem(
        cameraTransformConvention: "camera_to_world",
        handedness: "right_handed",
        axisMeaning: "x_right_y_up_z_toward_viewer; camera_forward_is_negative_z",
        worldUp: "+Y",
        worldOrigin: "ARKit_session_world_origin_at_run_start",
        interfaceOrientationNote: "UIDevice orientation applied as AVAssetWriterInput.transform on video track only; pose matrices stay ARKit world",
        imageOrientationNote: "ARFrame.capturedImage is landscape sensor buffer written without pixel rotate; portrait display uses preferredTransform",
        colmapNote: "ARKit matrices are NOT COLMAP c2w/w2c; convert explicitly before SfM/3DGS ingest",
        intrinsicsCoordinateSpace: "ARCamera.intrinsics are in ARFrame.capturedImage / ARCamera.imageResolution pixel coordinates (native buffer, not preferredTransform-rotated display)",
        serverDecodeNote: "If decoder applies preferredTransform, remapped pixels MUST NOT use native intrinsics without rotating K; prefer decode without transform and use native W×H + intrinsics"
    )

    enum CodingKeys: String, CodingKey {
        case cameraTransformConvention, handedness, axisMeaning, worldUp, worldOrigin
        case interfaceOrientationNote, imageOrientationNote, colmapNote
        case intrinsicsCoordinateSpace, serverDecodeNote
    }

    init(
        cameraTransformConvention: String,
        handedness: String,
        axisMeaning: String,
        worldUp: String,
        worldOrigin: String,
        interfaceOrientationNote: String,
        imageOrientationNote: String,
        colmapNote: String,
        intrinsicsCoordinateSpace: String = CaptureCoordinateSystem.arkitDefault.intrinsicsCoordinateSpace,
        serverDecodeNote: String = CaptureCoordinateSystem.arkitDefault.serverDecodeNote
    ) {
        self.cameraTransformConvention = cameraTransformConvention
        self.handedness = handedness
        self.axisMeaning = axisMeaning
        self.worldUp = worldUp
        self.worldOrigin = worldOrigin
        self.interfaceOrientationNote = interfaceOrientationNote
        self.imageOrientationNote = imageOrientationNote
        self.colmapNote = colmapNote
        self.intrinsicsCoordinateSpace = intrinsicsCoordinateSpace
        self.serverDecodeNote = serverDecodeNote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraTransformConvention = try c.decode(String.self, forKey: .cameraTransformConvention)
        handedness = try c.decode(String.self, forKey: .handedness)
        axisMeaning = try c.decode(String.self, forKey: .axisMeaning)
        worldUp = try c.decode(String.self, forKey: .worldUp)
        worldOrigin = try c.decode(String.self, forKey: .worldOrigin)
        interfaceOrientationNote = try c.decode(String.self, forKey: .interfaceOrientationNote)
        imageOrientationNote = try c.decode(String.self, forKey: .imageOrientationNote)
        colmapNote = try c.decode(String.self, forKey: .colmapNote)
        intrinsicsCoordinateSpace = try c.decodeIfPresent(String.self, forKey: .intrinsicsCoordinateSpace)
            ?? CaptureCoordinateSystem.arkitDefault.intrinsicsCoordinateSpace
        serverDecodeNote = try c.decodeIfPresent(String.self, forKey: .serverDecodeNote)
            ?? CaptureCoordinateSystem.arkitDefault.serverDecodeNote
    }
}

/// Session-level orientation / resolution binding for reconstruction ingest.
struct CaptureImageOrientationContract: Codable, Equatable, Sendable {
    var capturedImageWidth: Int
    var capturedImageHeight: Int
    var cameraImageResolutionWidth: Int
    var cameraImageResolutionHeight: Int
    var interfaceOrientation: String
    /// Affine preferredTransform of the video track: [a, b, c, d, tx, ty].
    var videoPreferredTransform: [Double]
    var intrinsicsCoordinateSpace: String
    var pixelBuffersRotatedInWriter: Bool
    var note: String
}

struct CaptureCameraInfo: Codable, Equatable, Sendable {
    var preferredFPS: Double
    var recordedWidth: Int
    var recordedHeight: Int
    var codec: String
    var videoFileName: String
    var orientation: CaptureImageOrientationContract?
}

struct CaptureVec3: Codable, Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float

    init(_ v: SIMD3<Float>) {
        x = v.x; y = v.y; z = v.z
    }

    init(x: Float, y: Float, z: Float) {
        self.x = x; self.y = y; self.z = z
    }
}

struct CaptureQuat: Codable, Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float
    var w: Float

    init(_ q: simd_quatf) {
        x = q.vector.x; y = q.vector.y; z = q.vector.z; w = q.vector.w
    }
}

struct CaptureIntrinsicsSample: Codable, Equatable, Sendable {
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
}

/// One row per **successfully written** video frame (same ARFrame as pose/intrinsics).
/// **Server SoT for sync:** match MOV sample PTS to `videoPTSValue`/`videoPTSTimescale` (or `videoPTSSeconds`).
struct CaptureFrameSample: Codable, Equatable, Sendable {
    var frameIndex: Int

    /// Absolute ARKit `ARFrame.timestamp` as Double seconds (full floating precision).
    var arTimestampSeconds: Double
    /// Rational form of AR timestamp (same clock as writer source time).
    var arTimestampValue: Int64
    var arTimestampTimescale: Int32

    /// CMTime presentation timestamp written to AVAssetWriter (relative to first frame).
    var videoPTSValue: Int64
    var videoPTSTimescale: Int32
    /// Convenience seconds — prefer rational fields for exact match.
    var videoPTSSeconds: Double

    /// Legacy alias of `videoPTSSeconds` for older readers.
    var videoPTS: Double { videoPTSSeconds }
    /// Legacy alias of `arTimestampSeconds`.
    var arTimestamp: Double { arTimestampSeconds }

    var imageWidth: Int
    var imageHeight: Int
    var intrinsics: CaptureIntrinsicsSample
    /// Column-major 4×4 camera-to-world (16 floats), ARKit `ARCamera.transform`.
    var cameraTransform: [Float]
    var translation: CaptureVec3
    var rotationQuaternion: CaptureQuat
    var trackingState: String
    var exposureDuration: Double?
    /// Apple ARCamera does not expose ISO on ARFrame — always nil.
    var iso: Float?
    var sceneDepthReference: String?
    var depthConfidenceReference: String?
    var isKeyframe3DGS: Bool
    /// Meters vs last accepted 3DGS keyframe (translation baseline, not optical parallax).
    var translationBaselineM: Float?
    var translationBaselineGrade: CaptureTranslationBaselineGrade

    enum CodingKeys: String, CodingKey {
        case frameIndex
        case arTimestampSeconds, arTimestampValue, arTimestampTimescale
        case arTimestamp // legacy decode
        case videoPTSValue, videoPTSTimescale, videoPTSSeconds
        case videoPTS // legacy decode
        case imageWidth, imageHeight, intrinsics, cameraTransform
        case translation, rotationQuaternion, trackingState
        case exposureDuration, iso
        case sceneDepthReference, depthConfidenceReference
        case isKeyframe3DGS
        case translationBaselineM, translationBaselineGrade
        case baselineToLastKeyframeM, parallaxGrade // legacy
    }

    init(
        frameIndex: Int,
        arTimestampSeconds: Double,
        arTimestampValue: Int64,
        arTimestampTimescale: Int32,
        videoPTSValue: Int64,
        videoPTSTimescale: Int32,
        videoPTSSeconds: Double,
        imageWidth: Int,
        imageHeight: Int,
        intrinsics: CaptureIntrinsicsSample,
        cameraTransform: [Float],
        translation: CaptureVec3,
        rotationQuaternion: CaptureQuat,
        trackingState: String,
        exposureDuration: Double?,
        iso: Float?,
        sceneDepthReference: String?,
        depthConfidenceReference: String?,
        isKeyframe3DGS: Bool,
        translationBaselineM: Float?,
        translationBaselineGrade: CaptureTranslationBaselineGrade
    ) {
        self.frameIndex = frameIndex
        self.arTimestampSeconds = arTimestampSeconds
        self.arTimestampValue = arTimestampValue
        self.arTimestampTimescale = arTimestampTimescale
        self.videoPTSValue = videoPTSValue
        self.videoPTSTimescale = videoPTSTimescale
        self.videoPTSSeconds = videoPTSSeconds
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.intrinsics = intrinsics
        self.cameraTransform = cameraTransform
        self.translation = translation
        self.rotationQuaternion = rotationQuaternion
        self.trackingState = trackingState
        self.exposureDuration = exposureDuration
        self.iso = iso
        self.sceneDepthReference = sceneDepthReference
        self.depthConfidenceReference = depthConfidenceReference
        self.isKeyframe3DGS = isKeyframe3DGS
        self.translationBaselineM = translationBaselineM
        self.translationBaselineGrade = translationBaselineGrade
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frameIndex = try c.decode(Int.self, forKey: .frameIndex)
        if let s = try c.decodeIfPresent(Double.self, forKey: .arTimestampSeconds) {
            arTimestampSeconds = s
        } else {
            arTimestampSeconds = try c.decode(Double.self, forKey: .arTimestamp)
        }
        arTimestampValue = try c.decodeIfPresent(Int64.self, forKey: .arTimestampValue) ?? 0
        arTimestampTimescale = try c.decodeIfPresent(Int32.self, forKey: .arTimestampTimescale) ?? 600
        videoPTSValue = try c.decodeIfPresent(Int64.self, forKey: .videoPTSValue) ?? 0
        videoPTSTimescale = try c.decodeIfPresent(Int32.self, forKey: .videoPTSTimescale) ?? 600
        if let s = try c.decodeIfPresent(Double.self, forKey: .videoPTSSeconds) {
            videoPTSSeconds = s
        } else {
            videoPTSSeconds = try c.decode(Double.self, forKey: .videoPTS)
        }
        imageWidth = try c.decode(Int.self, forKey: .imageWidth)
        imageHeight = try c.decode(Int.self, forKey: .imageHeight)
        intrinsics = try c.decode(CaptureIntrinsicsSample.self, forKey: .intrinsics)
        cameraTransform = try c.decode([Float].self, forKey: .cameraTransform)
        translation = try c.decode(CaptureVec3.self, forKey: .translation)
        rotationQuaternion = try c.decode(CaptureQuat.self, forKey: .rotationQuaternion)
        trackingState = try c.decode(String.self, forKey: .trackingState)
        exposureDuration = try c.decodeIfPresent(Double.self, forKey: .exposureDuration)
        iso = try c.decodeIfPresent(Float.self, forKey: .iso)
        sceneDepthReference = try c.decodeIfPresent(String.self, forKey: .sceneDepthReference)
        depthConfidenceReference = try c.decodeIfPresent(String.self, forKey: .depthConfidenceReference)
        isKeyframe3DGS = try c.decodeIfPresent(Bool.self, forKey: .isKeyframe3DGS) ?? false
        translationBaselineM = try c.decodeIfPresent(Float.self, forKey: .translationBaselineM)
            ?? c.decodeIfPresent(Float.self, forKey: .baselineToLastKeyframeM)
        if let g = try c.decodeIfPresent(CaptureTranslationBaselineGrade.self, forKey: .translationBaselineGrade) {
            translationBaselineGrade = g
        } else {
            translationBaselineGrade = try c.decodeIfPresent(CaptureTranslationBaselineGrade.self, forKey: .parallaxGrade)
                ?? .insufficient
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frameIndex, forKey: .frameIndex)
        try c.encode(arTimestampSeconds, forKey: .arTimestampSeconds)
        try c.encode(arTimestampValue, forKey: .arTimestampValue)
        try c.encode(arTimestampTimescale, forKey: .arTimestampTimescale)
        try c.encode(arTimestampSeconds, forKey: .arTimestamp)
        try c.encode(videoPTSValue, forKey: .videoPTSValue)
        try c.encode(videoPTSTimescale, forKey: .videoPTSTimescale)
        try c.encode(videoPTSSeconds, forKey: .videoPTSSeconds)
        try c.encode(videoPTSSeconds, forKey: .videoPTS)
        try c.encode(imageWidth, forKey: .imageWidth)
        try c.encode(imageHeight, forKey: .imageHeight)
        try c.encode(intrinsics, forKey: .intrinsics)
        try c.encode(cameraTransform, forKey: .cameraTransform)
        try c.encode(translation, forKey: .translation)
        try c.encode(rotationQuaternion, forKey: .rotationQuaternion)
        try c.encode(trackingState, forKey: .trackingState)
        try c.encodeIfPresent(exposureDuration, forKey: .exposureDuration)
        try c.encodeIfPresent(iso, forKey: .iso)
        try c.encodeIfPresent(sceneDepthReference, forKey: .sceneDepthReference)
        try c.encodeIfPresent(depthConfidenceReference, forKey: .depthConfidenceReference)
        try c.encode(isKeyframe3DGS, forKey: .isKeyframe3DGS)
        try c.encodeIfPresent(translationBaselineM, forKey: .translationBaselineM)
        try c.encode(translationBaselineGrade, forKey: .translationBaselineGrade)
        // Deprecated aliases for transitional readers.
        try c.encodeIfPresent(translationBaselineM, forKey: .baselineToLastKeyframeM)
        try c.encode(translationBaselineGrade, forKey: .parallaxGrade)
    }
}

struct CaptureDepthSummary: Codable, Equatable, Sendable {
    var sceneDepthConfigured: Bool
    var samplesWritten: Int
    var directory: String
    var note: String
    var rgbDepthSamePixelSpace: Bool
    var alignmentNote: String

    enum CodingKeys: String, CodingKey {
        case sceneDepthConfigured, samplesWritten, directory, note
        case rgbDepthSamePixelSpace, alignmentNote
    }

    init(
        sceneDepthConfigured: Bool,
        samplesWritten: Int,
        directory: String,
        note: String,
        rgbDepthSamePixelSpace: Bool = false,
        alignmentNote: String = "RGB and depth resolutions differ; do not assume same pixel coordinates."
    ) {
        self.sceneDepthConfigured = sceneDepthConfigured
        self.samplesWritten = samplesWritten
        self.directory = directory
        self.note = note
        self.rgbDepthSamePixelSpace = rgbDepthSamePixelSpace
        self.alignmentNote = alignmentNote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneDepthConfigured = try c.decode(Bool.self, forKey: .sceneDepthConfigured)
        samplesWritten = try c.decode(Int.self, forKey: .samplesWritten)
        directory = try c.decode(String.self, forKey: .directory)
        note = try c.decode(String.self, forKey: .note)
        rgbDepthSamePixelSpace = try c.decodeIfPresent(Bool.self, forKey: .rgbDepthSamePixelSpace) ?? false
        alignmentNote = try c.decodeIfPresent(String.self, forKey: .alignmentNote)
            ?? "RGB and depth resolutions differ; do not assume same pixel coordinates."
    }
}

struct CaptureSyncSummary: Codable, Equatable, Sendable {
    var videoFramesWritten: Int
    var poseSamples: Int
    var droppedVideoFrames: Int
    var keyframe3DGSCount: Int
    var syncSourceOfTruth: String
    var note: String

    enum CodingKeys: String, CodingKey {
        case videoFramesWritten, poseSamples, droppedVideoFrames, keyframe3DGSCount
        case syncSourceOfTruth, note
    }

    init(
        videoFramesWritten: Int,
        poseSamples: Int,
        droppedVideoFrames: Int,
        keyframe3DGSCount: Int,
        syncSourceOfTruth: String = CaptureFrameContract.syncSourceOfTruth,
        note: String
    ) {
        self.videoFramesWritten = videoFramesWritten
        self.poseSamples = poseSamples
        self.droppedVideoFrames = droppedVideoFrames
        self.keyframe3DGSCount = keyframe3DGSCount
        self.syncSourceOfTruth = syncSourceOfTruth
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoFramesWritten = try c.decode(Int.self, forKey: .videoFramesWritten)
        poseSamples = try c.decode(Int.self, forKey: .poseSamples)
        droppedVideoFrames = try c.decode(Int.self, forKey: .droppedVideoFrames)
        keyframe3DGSCount = try c.decode(Int.self, forKey: .keyframe3DGSCount)
        syncSourceOfTruth = try c.decodeIfPresent(String.self, forKey: .syncSourceOfTruth)
            ?? CaptureFrameContract.syncSourceOfTruth
        note = try c.decode(String.self, forKey: .note)
    }
}

struct CaptureQualitySummaryV2: Codable, Equatable, Sendable {
    /// Heuristic translation baseline grade (NOT depth-aware parallax).
    var translationBaselineGrade: CaptureTranslationBaselineGrade
    var translationBaselineScore: Double
    var maxBaselineM: Double
    var totalPathLengthM: Double
    var viewAngleDiversity: Double
    var overlapAvailability: CaptureMetricAvailability
    var overlapScoreDeprecated: Double?

    /// Legacy encode key.
    var parallaxGrade: CaptureTranslationBaselineGrade { translationBaselineGrade }
    var parallaxScore: Double { translationBaselineScore }

    enum CodingKeys: String, CodingKey {
        case translationBaselineGrade, translationBaselineScore
        case maxBaselineM, totalPathLengthM, viewAngleDiversity
        case overlapAvailability, overlapScoreDeprecated
        case parallaxGrade, parallaxScore
    }

    init(
        translationBaselineGrade: CaptureTranslationBaselineGrade,
        translationBaselineScore: Double,
        maxBaselineM: Double,
        totalPathLengthM: Double,
        viewAngleDiversity: Double,
        overlapAvailability: CaptureMetricAvailability,
        overlapScoreDeprecated: Double? = nil
    ) {
        self.translationBaselineGrade = translationBaselineGrade
        self.translationBaselineScore = translationBaselineScore
        self.maxBaselineM = maxBaselineM
        self.totalPathLengthM = totalPathLengthM
        self.viewAngleDiversity = viewAngleDiversity
        self.overlapAvailability = overlapAvailability
        self.overlapScoreDeprecated = overlapScoreDeprecated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let g = try c.decodeIfPresent(CaptureTranslationBaselineGrade.self, forKey: .translationBaselineGrade) {
            translationBaselineGrade = g
        } else {
            translationBaselineGrade = try c.decodeIfPresent(CaptureTranslationBaselineGrade.self, forKey: .parallaxGrade)
                ?? .insufficient
        }
        translationBaselineScore = try c.decodeIfPresent(Double.self, forKey: .translationBaselineScore)
            ?? c.decodeIfPresent(Double.self, forKey: .parallaxScore)
            ?? translationBaselineGrade.score
        maxBaselineM = try c.decode(Double.self, forKey: .maxBaselineM)
        totalPathLengthM = try c.decode(Double.self, forKey: .totalPathLengthM)
        viewAngleDiversity = try c.decode(Double.self, forKey: .viewAngleDiversity)
        overlapAvailability = try c.decode(CaptureMetricAvailability.self, forKey: .overlapAvailability)
        overlapScoreDeprecated = try c.decodeIfPresent(Double.self, forKey: .overlapScoreDeprecated)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(translationBaselineGrade, forKey: .translationBaselineGrade)
        try c.encode(translationBaselineScore, forKey: .translationBaselineScore)
        try c.encode(translationBaselineGrade, forKey: .parallaxGrade)
        try c.encode(translationBaselineScore, forKey: .parallaxScore)
        try c.encode(maxBaselineM, forKey: .maxBaselineM)
        try c.encode(totalPathLengthM, forKey: .totalPathLengthM)
        try c.encode(viewAngleDiversity, forKey: .viewAngleDiversity)
        try c.encode(overlapAvailability, forKey: .overlapAvailability)
        try c.encodeIfPresent(overlapScoreDeprecated, forKey: .overlapScoreDeprecated)
    }
}

struct CapturePosesFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var sessionId: String
    /// Sync SoT reminder for consumers.
    var syncSourceOfTruth: String
    var frames: [CaptureFrameSample]

    init(
        schemaVersion: Int,
        sessionId: String,
        frames: [CaptureFrameSample],
        syncSourceOfTruth: String = CaptureFrameContract.syncSourceOfTruth
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.syncSourceOfTruth = syncSourceOfTruth
        self.frames = frames
    }
}

enum CaptureFrameContract {
    static let posesFileName = "poses.json"
    static let depthDirectoryName = "depth"
    static let schemaVersion = 2
    static let syncSourceOfTruth = "videoPTS (CMTime value/timescale); frameIndex 1:1 invariant retained"

    static let writerTimescale: Int32 = 600

    static func encodeTransform(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    static func translation(from m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func quaternion(from m: simd_float4x4) -> simd_quatf {
        simd_quatf(m)
    }

    static func trackingLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_unknown"
            }
        }
    }

    static func cmTime(fromSeconds seconds: TimeInterval, timescale: Int32 = writerTimescale) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    static func interfaceOrientationLabel() -> String {
        switch UIDevice.current.orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown_or_portrait_default"
        }
    }

    static func encodeAffine(_ t: CGAffineTransform) -> [Double] {
        [t.a, t.b, t.c, t.d, t.tx, t.ty]
    }

    static func makeOrientationContract(
        capturedWidth: Int,
        capturedHeight: Int,
        imageResolution: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CaptureImageOrientationContract {
        CaptureImageOrientationContract(
            capturedImageWidth: capturedWidth,
            capturedImageHeight: capturedHeight,
            cameraImageResolutionWidth: Int(imageResolution.width.rounded()),
            cameraImageResolutionHeight: Int(imageResolution.height.rounded()),
            interfaceOrientation: interfaceOrientationLabel(),
            videoPreferredTransform: encodeAffine(preferredTransform),
            intrinsicsCoordinateSpace: "native_capturedImage_pixels",
            pixelBuffersRotatedInWriter: false,
            note: "Pixel buffers are appended in native landscape sensor orientation; preferredTransform rotates for display only. Intrinsics match native W×H."
        )
    }

    /// Downsample path for DEBUG top-down plot (XZ plane).
    static func topDownPath(from frames: [CaptureFrameSample], maxPoints: Int = 64) -> [CaptureVec3] {
        guard !frames.isEmpty else { return [] }
        if frames.count <= maxPoints {
            return frames.map { CaptureVec3(x: $0.translation.x, y: 0, z: $0.translation.z) }
        }
        var out: [CaptureVec3] = []
        let step = Double(frames.count - 1) / Double(maxPoints - 1)
        for i in 0..<maxPoints {
            let idx = min(frames.count - 1, Int((Double(i) * step).rounded()))
            let t = frames[idx].translation
            out.append(CaptureVec3(x: t.x, y: 0, z: t.z))
        }
        return out
    }
}

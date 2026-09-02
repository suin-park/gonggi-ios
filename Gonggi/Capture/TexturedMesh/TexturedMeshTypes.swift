import Foundation
import simd

/// Configuration limits for prototype textured mesh capture.
enum TexturedMeshLimits {
    static let maxKeyframes = 48
    static let minKeyframeIntervalSec: Double = 0.5
    static let minTranslationM: Float = 0.12
    static let minRotationRad: Float = 0.26
    static let meshSnapshotIntervalSec: Double = 0.5
    static let maxKeyframePixelWidth = 1280
    static let keyframeJPEGQuality: CGFloat = 0.72
}

struct CameraIntrinsics: Equatable, Codable {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Int
    let height: Int
}

struct CaptureKeyframeRecord: Codable, Equatable {
    let index: Int
    let timestamp: Double
    let fileName: String
    let intrinsics: CameraIntrinsics
    let transform: [Float]

    var cameraTransform: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(transform[0], transform[1], transform[2], transform[3]),
            SIMD4(transform[4], transform[5], transform[6], transform[7]),
            SIMD4(transform[8], transform[9], transform[10], transform[11]),
            SIMD4(transform[12], transform[13], transform[14], transform[15])
        ))
    }

    static func encodeTransform(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w,
        ]
    }
}

struct MeshAnchorSnapshot: Equatable {
    let anchorId: UUID
    let transform: simd_float4x4
    let vertices: [SIMD3<Float>]
    let indices: [UInt32]
}

struct MergedMeshGeometry: Equatable {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var vertexColors: [SIMD3<Float>]

    var vertexCount: Int { vertices.count }
    var triangleCount: Int { indices.count / 3 }
}

struct TexturedMeshReport: Codable, Equatable {
    let vertexCount: Int
    let triangleCount: Int
    let keyframeCount: Int
    let texturedVertexCount: Int
    let texturedCoveragePercent: Double
    let reconstructionTimeSec: Double
    let outputByteSize: Int64
    let peakMemoryEstimateMB: Double
    let usdzFileName: String
    let createdAt: String
}

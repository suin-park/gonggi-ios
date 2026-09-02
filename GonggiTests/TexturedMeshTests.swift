import simd
import XCTest
@testable import Gonggi

final class CameraProjectionTests: XCTestCase {
  func testProjectVisiblePoint() {
    let intrinsics = CameraIntrinsics(fx: 1000, fy: 1000, cx: 640, cy: 360, width: 1280, height: 720)
    var camera = matrix_identity_float4x4
    camera.columns.3 = SIMD4<Float>(0, 0, 0, 1)

    let projected = CameraProjection.project(
      worldPoint: SIMD3<Float>(0, 0, -1),
      worldNormal: SIMD3<Float>(0, 0, 1),
      cameraTransform: camera,
      intrinsics: intrinsics
    )

    XCTAssertNotNil(projected)
    XCTAssertEqual(projected?.pixel.x, 640, accuracy: 1)
    XCTAssertEqual(projected?.pixel.y, 360, accuracy: 1)
  }

  func testProjectRejectsBehindCamera() {
    let intrinsics = CameraIntrinsics(fx: 1000, fy: 1000, cx: 640, cy: 360, width: 1280, height: 720)
  var camera = matrix_identity_float4x4
    let projected = CameraProjection.project(
      worldPoint: SIMD3<Float>(0, 0, 1),
      worldNormal: SIMD3<Float>(0, 0, -1),
      cameraTransform: camera,
      intrinsics: intrinsics
    )
    XCTAssertNil(projected)
  }
}

final class KeyframeSelectorLogicTests: XCTestCase {
  func testFirstKeyframeAlwaysCaptured() {
    let decision = KeyframeSelector.shouldCapture(
      timestamp: 1,
      cameraTransform: matrix_identity_float4x4,
      lastKeyframe: nil,
      keyframeCount: 0,
      meshAnchorCount: 0,
      lastMeshAnchorCount: 0,
      trackingNormal: true
    )
    XCTAssertTrue(decision.shouldCapture)
  }

  func testRespectsMaxKeyframes() {
    let last = CaptureKeyframeRecord(
      index: 48,
      timestamp: 0,
      fileName: "keyframe_0048.jpg",
      intrinsics: CameraIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 100, height: 100),
      transform: CaptureKeyframeRecord.encodeTransform(matrix_identity_float4x4)
    )
    let decision = KeyframeSelector.shouldCapture(
      timestamp: 10,
      cameraTransform: matrix_identity_float4x4,
      lastKeyframe: last,
      keyframeCount: TexturedMeshLimits.maxKeyframes,
      meshAnchorCount: 5,
      lastMeshAnchorCount: 0,
      trackingNormal: true
    )
    XCTAssertFalse(decision.shouldCapture)
  }

  func testTranslationTriggersKeyframe() {
    let last = CaptureKeyframeRecord(
      index: 1,
      timestamp: 0,
      fileName: "keyframe_0001.jpg",
      intrinsics: CameraIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 100, height: 100),
      transform: CaptureKeyframeRecord.encodeTransform(matrix_identity_float4x4)
    )
    var moved = matrix_identity_float4x4
    moved.columns.3 = SIMD4<Float>(0.5, 0, 0, 1)
    let decision = KeyframeSelector.shouldCapture(
      timestamp: 1,
      cameraTransform: moved,
      lastKeyframe: last,
      keyframeCount: 1,
      meshAnchorCount: 1,
      lastMeshAnchorCount: 1,
      trackingNormal: true
    )
    XCTAssertTrue(decision.shouldCapture)
    XCTAssertEqual(decision.reason, "translation")
  }
}

final class MeshMergerTests: XCTestCase {
  func testMergePreservesWorldScale() {
    let snapshot = MeshAnchorSnapshot(
      anchorId: UUID(),
      transform: matrix_identity_float4x4,
      vertices: [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
      ],
      indices: [0, 1, 2]
    )
    let merged = MeshMerger.merge(snapshots: [snapshot])
    XCTAssertEqual(merged.vertexCount, 3)
    XCTAssertEqual(merged.triangleCount, 1)
    XCTAssertEqual(merged.vertices[1].x, 1, accuracy: 0.001)
  }

  func testVertexNormalsGenerated() {
    let snapshot = MeshAnchorSnapshot(
      anchorId: UUID(),
      transform: matrix_identity_float4x4,
      vertices: [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
      ],
      indices: [0, 1, 2]
    )
    let merged = MeshMerger.merge(snapshots: [snapshot])
    XCTAssertEqual(merged.normals.count, merged.vertices.count)
    XCTAssertGreaterThan(abs(merged.normals[0].z), 0.5)
  }
}

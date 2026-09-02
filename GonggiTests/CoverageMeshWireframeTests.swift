import simd
import XCTest
@testable import Gonggi

final class CoverageSpatialIndexTests: XCTestCase {
    func testLookupReturnsCellState() {
        let index = CoverageSpatialIndex()
        var cell = CoverageCell(id: "0_0_0")
        cell.state = .good
        index.replace(cells: ["0_0_0": cell])

        let state = index.state(at: SIMD3<Float>(0.1, 0.1, 0.1))
        XCTAssertEqual(state, .good)
    }

    func testLookupReturnsUnseenForUnknownCell() {
        let index = CoverageSpatialIndex()
        XCTAssertEqual(index.state(at: .zero), .unseen)
    }

    func testResetClearsCells() {
        let index = CoverageSpatialIndex()
        index.replace(cells: ["1_0_0": CoverageCell(id: "1_0_0", state: .acceptable)])
        index.reset()
        XCTAssertEqual(index.state(at: SIMD3<Float>(0.6, 0, 0)), .unseen)
    }
}

final class CoverageMeshWireStyleTests: XCTestCase {
    func testGoodMapsToCapturedBucket() {
        XCTAssertEqual(CoverageMeshWireStyle.bucket(for: .good), .captured)
    }

    func testInsufficientMapsToNeedsCaptureBucket() {
        XCTAssertEqual(CoverageMeshWireStyle.bucket(for: .insufficient), .needsCapture)
        XCTAssertEqual(CoverageMeshWireStyle.bucket(for: .acceptable), .needsCapture)
        XCTAssertEqual(CoverageMeshWireStyle.bucket(for: .unseen), .needsCapture)
    }
}

final class ARMeshWireframeBuilderTests: XCTestCase {
    func testClassifyEdgesSplitsByCoverageState() {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(1, 0, 0),
            SIMD3(0, 1, 0),
            SIMD3(1, 1, 0),
        ]
        let faces: [UInt32] = [0, 1, 2, 1, 3, 2]
        let transform = matrix_identity_float4x4

        let meshes = ARMeshWireframeBuilder.classifyEdges(
            vertices: vertices,
            faces: faces,
            anchorTransform: transform,
            coverageStateAt: { position in
                position.x > 0.5 ? .good : .insufficient
            }
        )

        XCTAssertFalse(meshes.needsCapture.positions.isEmpty)
        XCTAssertFalse(meshes.captured.positions.isEmpty)
        XCTAssertEqual(meshes.needsCapture.indices.count % 2, 0)
        XCTAssertEqual(meshes.captured.indices.count % 2, 0)
    }

    func testClassifyEdgesDeduplicatesSharedEdges() {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(1, 0, 0),
            SIMD3(0.5, 1, 0),
        ]
        let faces: [UInt32] = [0, 1, 2]
        let transform = matrix_identity_float4x4

        let meshes = ARMeshWireframeBuilder.classifyEdges(
            vertices: vertices,
            faces: faces,
            anchorTransform: transform,
            coverageStateAt: { _ in .insufficient }
        )

        XCTAssertEqual(meshes.needsCapture.indices.count, 6)
        XCTAssertTrue(meshes.captured.positions.isEmpty)
    }

    func testCoverageModelSpatialLookupMatchesGrid() {
        var model = CoverageModelV1()
        for i in 0..<8 {
            var t = matrix_identity_float4x4
            let angle = Float(i) * 0.4
            t.columns.2 = SIMD4<Float>(sin(angle), 0, -cos(angle), 0)
            t.columns.0 = SIMD4<Float>(cos(angle), 0, sin(angle), 0)
            model.observe(cameraTransform: t, motionQuality: 0.9)
        }
        XCTAssertNotEqual(model.state(at: .zero), .unseen)
    }
}

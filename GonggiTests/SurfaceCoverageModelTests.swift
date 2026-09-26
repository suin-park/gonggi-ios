import simd
import XCTest
@testable import Gonggi

/// Guide v2 stage 1 — surface ("what was seen") coverage.
final class SurfaceCoverageModelTests: XCTestCase {
    /// Vertical wall facing +z at z = `z`, width along x, height along y.
    private func wall(id: UUID = UUID(), x: Float = 0, z: Float = -3, width: Float = 4, height: Float = 2.5) -> SurfacePlaneSample {
        // Anchor local y = normal (+z world); local x = world x; local z = x × y = world -y.
        let m = simd_float4x4(columns: (
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(0, -1, 0, 0),
            simd_float4(x, 0, z, 1)
        ))
        return SurfacePlaneSample(id: id, transform: m, center: .zero, width: width, height: height,
                                  rotationOnYAxis: 0, isVertical: true)
    }

    private func keyframe(at p: simd_float3, lookAt t: simd_float3, sharp: Bool = true) -> SurfaceCoverageModel.Keyframe {
        let f = simd_normalize(t - p)
        let right = simd_normalize(simd_cross(f, simd_float3(0, 1, 0)))
        let up = simd_cross(right, f)
        let m = simd_float4x4(columns: (simd_float4(right, 0), simd_float4(up, 0), simd_float4(-f, 0), simd_float4(p, 1)))
        return .init(cameraToWorld: m, fx: 1435, fy: 1435, cx: 960, cy: 720, width: 1920, height: 1440, sharp: sharp)
    }

    private func nearest(_ model: SurfaceCoverageModel, _ p: simd_float3) -> SurfaceCoverageModel.Surface {
        model.surfaces.min { simd_distance($0.center, p) < simd_distance($1.center, p) }!
    }

    private func walkAlongWall(_ model: inout SurfaceCoverageModel, z: Float, count: Int = 30, sharp: Bool = true) {
        for i in 0..<count {
            let x = -1.2 + 2.4 * Float(i) / Float(count - 1)
            model.observeKeyframe(keyframe(at: simd_float3(x, 0, z), lookAt: simd_float3(x * 0.3, 0, -3), sharp: sharp))
        }
    }

    func testCloseViewsFromSeveralDirectionsAreEnough() {
        var model = SurfaceCoverageModel()
        model.updatePlanes([wall()])
        walkAlongWall(&model, z: -1)
        XCTAssertEqual(nearest(model, simd_float3(0, 0, -3)).state, .enough)
        XCTAssertGreaterThan(model.summary().enoughAreaRatio, 0)
    }

    func testViewsOnlyFromFarAwayAreFarOnly() {
        var model = SurfaceCoverageModel()
        model.updatePlanes([wall()])
        walkAlongWall(&model, z: 1.5)
        let s = nearest(model, simd_float3(0, 0, -3))
        XCTAssertGreaterThan(s.views, 0)
        XCTAssertEqual(s.state, .farOnly)
    }

    func testSingleStandingSpotIsOneSide() {
        var model = SurfaceCoverageModel()
        model.updatePlanes([wall()])
        for _ in 0..<30 {
            model.observeKeyframe(keyframe(at: simd_float3(0, 0, -1), lookAt: simd_float3(0, 0, -3)))
        }
        XCTAssertEqual(nearest(model, simd_float3(0, 0, -3)).state, .oneSide)
    }

    func testBlurryKeyframesDoNotCount() {
        var model = SurfaceCoverageModel()
        model.updatePlanes([wall()])
        walkAlongWall(&model, z: -1, sharp: false)
        XCTAssertEqual(nearest(model, simd_float3(0, 0, -3)).state, .unseen)
        XCTAssertEqual(model.summary().sharpKeyframeCount, 0)
    }

    func testNearerPlaneOccludesWall() {
        var model = SurfaceCoverageModel()
        // Partition 1 m wide at z = -2 between the camera (z = -1) and the wall (z = -3).
        model.updatePlanes([wall(), wall(z: -2, width: 1, height: 2)])
        for _ in 0..<30 {
            model.observeKeyframe(keyframe(at: simd_float3(0, 0, -1), lookAt: simd_float3(0, 0, -3)))
        }
        let behind = model.surfaces.filter { abs($0.center.z + 3) < 0.05 && abs($0.center.x) < 0.3 && abs($0.center.y) < 0.3 }
        XCTAssertFalse(behind.isEmpty)
        XCTAssertTrue(behind.allSatisfy { $0.views == 0 }, "wall tiles behind the partition must not count as seen")
    }

    func testPlanesDetectedLaterReplayEarlierKeyframes() {
        var model = SurfaceCoverageModel()
        walkAlongWall(&model, z: -1)
        XCTAssertTrue(model.surfaces.isEmpty)
        model.updatePlanes([wall()])
        XCTAssertEqual(nearest(model, simd_float3(0, 0, -3)).state, .enough)
    }

    func testGrowingPlaneKeepsTileStatsWithoutDuplicates() {
        var model = SurfaceCoverageModel()
        let id = UUID()
        model.updatePlanes([wall(id: id, width: 2, height: 2)])
        walkAlongWall(&model, z: -1)
        let before = nearest(model, simd_float3(0.25, 0.25, -3)).views
        model.updatePlanes([wall(id: id, width: 4, height: 2.5)])
        XCTAssertEqual(nearest(model, simd_float3(0.25, 0.25, -3)).views, before)
        // 4 m × 2.5 m on a 0.5 m lattice → at most 8 × 6 tiles, never the union of old + new.
        XCTAssertLessThanOrEqual(model.summary().planeTileCount, 48)
    }

    func testFeaturePointClustersBecomeSurfaces() {
        var model = SurfaceCoverageModel()
        let cluster = (0..<20).map { i in simd_float3(0.05 + Float(i % 4) * 0.02, 0.55, -2.05 - Float(i / 4) * 0.02) }
        model.addFeaturePoints(cluster)
        walkAlongWall(&model, z: 0)
        XCTAssertEqual(model.summary().featureVoxelCount, 1)
        XCTAssertGreaterThan(nearest(model, simd_float3(0.1, 0.6, -2.1)).views, 0)
    }

    func testDegenerateInputsNeverTrap() {
        var model = SurfaceCoverageModel()
        var bad = wall()
        bad.transform.columns.3 = simd_float4(.nan, 0, .infinity, 1)
        model.updatePlanes([bad, wall()])
        model.addFeaturePoints([simd_float3(.nan, 0, 0), simd_float3(.infinity, 1, 1), simd_float3(1e9, 0, 0)])
        walkAlongWall(&model, z: -1)
        _ = model.summary()
        XCTAssertEqual(nearest(model, simd_float3(0, 0, -3)).state, .enough)
    }

    func testQualityFileDecodesWithAndWithoutSurfaceCoverage() throws {
        var model = SurfaceCoverageModel()
        model.updatePlanes([wall()])
        walkAlongWall(&model, z: -1)
        let file = SpatialCaptureQualityFile(
            schemaVersion: 2,
            session: SpatialCaptureSessionQuality(
                acceptedFrames: 30, rejectedDecisions: 0, averageSharpness: nil, trackingFailureCount: 0,
                totalTranslationM: 2.4, observedCoverage: 1, qualityCoverage: 1, viewAngleDiversity: 0.5,
                captureDurationSec: 30, translationBaselineGrade: "good"
            ),
            frames: [],
            surfaceCoverage: model.summary()
        )
        let data = try JSONEncoder().encode(file)
        XCTAssertEqual(try JSONDecoder().decode(SpatialCaptureQualityFile.self, from: data), file)

        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "surfaceCoverage")
        let old = try JSONDecoder().decode(
            SpatialCaptureQualityFile.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(old.surfaceCoverage)
    }
}

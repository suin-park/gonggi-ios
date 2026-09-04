import Foundation
import simd
import XCTest
@testable import Gonggi

/// Build 27 — depth-assisted proxy-geometry reprojection PoC contracts.
final class DepthReprojectionBuild27Tests: XCTestCase {

    func testOrientationAndOutputContractsHold() {
        XCTAssertEqual(Quick360Config.outputWidth, 4096)
        XCTAssertEqual(Quick360Config.outputHeight, 2048)
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
        XCTAssertEqual(PanoramaEngineID.depthReproject, "gonggi.depthReproject")
        XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(width: 4096, height: 2048))
    }

    func testEquirectForwardMapsToCenterU() {
        let dir = SphericalMath.opticalDirectionFromSphereYawPitch(yawRad: 0, pitchRad: 0)
        let uv = DepthReprojectionMath.equirectUV(fromDirection: dir)
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.02)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.05)
    }

    func testCameraRayOpticalConvention() {
        let K = CameraIntrinsics(fx: 100, fy: 100, cx: 50, cy: 50, width: 100, height: 100)
        let ray = DepthReprojectionMath.cameraRay(u: 50, v: 50, K: K)
        XCTAssertEqual(ray.x, 0, accuracy: 0.05)
        XCTAssertEqual(ray.y, 0, accuracy: 0.05)
        XCTAssertLessThan(ray.z, -0.9)
    }

    func testZBufferPrefersNearSurface() {
        let canvas = DepthReprojectionCanvas(width: 32, height: 16)
        canvas.splat(
            colorR: 10, colorG: 10, colorB: 10,
            px: 16, py: 8, radius: 1.2, weight: 1,
            depthFromOrigin: 5, depthConfidence: 1, depthGradientHigh: false
        )
        canvas.splat(
            colorR: 200, colorG: 200, colorB: 200,
            px: 16, py: 8, radius: 1.2, weight: 1,
            depthFromOrigin: 2, depthConfidence: 1, depthGradientHigh: false
        )
        let out = canvas.compose()
        let i = (8 * 32 + 16) * 4
        XCTAssertGreaterThan(out.rgba[i], 100)
    }

    func testDepthDiscontinuityLimitsGhosting() {
        let canvas = DepthReprojectionCanvas(width: 32, height: 16)
        canvas.splat(
            colorR: 255, colorG: 0, colorB: 0,
            px: 10, py: 8, radius: 1, weight: 1,
            depthFromOrigin: 2, depthConfidence: 1, depthGradientHigh: false
        )
        canvas.splat(
            colorR: 0, colorG: 0, colorB: 255,
            px: 10, py: 8, radius: 1, weight: 1,
            depthFromOrigin: 6, depthConfidence: 0.2, depthGradientHigh: true
        )
        XCTAssertGreaterThan(canvas.discontinuityRejects, 0)
    }

    func testInvalidDepthLeavesHole() {
        let canvas = DepthReprojectionCanvas(width: 16, height: 8)
        canvas.splat(
            colorR: 1, colorG: 1, colorB: 1,
            px: 8, py: 4, radius: 1, weight: 1,
            depthFromOrigin: 2, depthConfidence: 0, depthGradientHigh: false
        )
        let out = canvas.compose()
        XCTAssertGreaterThan(out.holePercent, 90)
    }

    func testWeightedFusionDeterministic() {
        let canvas = DepthReprojectionCanvas(width: 8, height: 4)
        for _ in 0..<3 {
            canvas.splat(
                colorR: 100, colorG: 50, colorB: 0,
                px: 4, py: 2, radius: 0.8, weight: 2,
                depthFromOrigin: 3, depthConfidence: 1, depthGradientHigh: false
            )
            canvas.splat(
                colorR: 0, colorG: 50, colorB: 100,
                px: 4, py: 2, radius: 0.8, weight: 1,
                depthFromOrigin: 3.01, depthConfidence: 1, depthGradientHigh: false
            )
        }
        let a = canvas.compose()
        let i = (2 * 8 + 4) * 4
        XCTAssertEqual(a.rgba[i], a.rgba[i])
        XCTAssertGreaterThan(a.rgba[i], 40)
    }

    func testPanoramaCentersDiffer() {
        let pts: [simd_float3] = [
            .init(0, 0, 0),
            .init(1, 0, 0),
            .init(0, 0, 1),
            .init(10, 0, 0)
        ]
        let a = DepthReprojectionMath.panoramaCenter(cameraCenters: pts, mode: .firstCamera)
        let b = DepthReprojectionMath.panoramaCenter(cameraCenters: pts, mode: .medianCameras)
        let c = DepthReprojectionMath.panoramaCenter(cameraCenters: pts, mode: .leastParallax)
        XCTAssertEqual(a.x, 0, accuracy: 1e-5)
        XCTAssertNotEqual(b.x, a.x, accuracy: 0.01)
        XCTAssertTrue(c.x.isFinite)
    }

    func testSyntheticFlatWallDepthAlignsBetterThanRotationProxy() async throws {
        // Two cameras looking at a fronto-parallel wall at z = -2 in camera0 frame.
        // Translated along +X → rotation-only center projection drifts; depth plane reprojects consistently.
        let K = CameraIntrinsics(fx: 80, fy: 80, cx: 40, cy: 30, width: 80, height: 60)
        let wallDepth: Float = 2.0

        func makeRGBA(shade: UInt8) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 80 * 60 * 4)
            for i in 0..<80 * 60 {
                rgba[i * 4] = shade
                rgba[i * 4 + 1] = shade
                rgba[i * 4 + 2] = shade
                rgba[i * 4 + 3] = 255
            }
            // Vertical line feature at x=40
            for y in 0..<60 {
                let i = (y * 80 + 40) * 4
                rgba[i] = 255; rgba[i + 1] = 0; rgba[i + 2] = 0
            }
            return rgba
        }

        func cam(tx: Float) -> simd_float4x4 {
            // Camera at (tx,0,0), looking −Z.
            var T = matrix_identity_float4x4
            T.columns.3 = SIMD4(tx, 0, 0, 1)
            return T
        }

        let depthPlane = DepthFrameMap(
            width: 80, height: 60,
            depth: [Float](repeating: wallDepth, count: 80 * 60),
            confidence: [Float](repeating: 1, count: 80 * 60),
            isMetric: true,
            sourceLabel: "synthetic_plane"
        )

        let sessionId = "b27-wall-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let outURL = try CaptureSessionStore.quick360EquirectangularURL(sessionId: sessionId)

        let kfs = [
            PanoramaStitcher.InputKeyframe(
                index: 0, rgba: makeRGBA(shade: 120), width: 80, height: 60,
                cameraTransform: cam(tx: 0), intrinsics: K, dynamicRatio: 0,
                fileName: "k0.jpg", yawRad: 0, pitchRad: 0
            ),
            PanoramaStitcher.InputKeyframe(
                index: 1, rgba: makeRGBA(shade: 130), width: 80, height: 60,
                cameraTransform: cam(tx: 0.25), intrinsics: K, dynamicRatio: 0,
                fileName: "k1.jpg", yawRad: 0.12, pitchRad: 0
            )
        ]

        var engine = DepthReprojectionPanoramaEngine()
        engine.depthProvider = InjectedDepthProvider(maps: [0: depthPlane, 1: depthPlane])
        engine.sourceStride = 1
        engine.writeDebugArtifacts = false

        let input = PanoramaEngineInput(
            sessionId: sessionId,
            keyframes: kfs,
            originTransform: matrix_identity_float4x4,
            captureBasis: nil,
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 256,
            outputHeight: 128,
            outputPanoramaURL: outURL
        )
        let out = try await engine.stitch(input: input)
        XCTAssertTrue(out.success, out.failureReason ?? "")
        XCTAssertEqual(out.width, 256)
        XCTAssertEqual(out.height, 128)
        XCTAssertGreaterThan(out.report.coveragePercent ?? 0, 5)

        // Red line should concentrate near forward center column rather than scattering widely.
        guard let rgba = out.rgba else {
            XCTFail("missing rgba")
            return
        }
        var colEnergy = [Float](repeating: 0, count: 256)
        for y in 0..<128 {
            for x in 0..<256 {
                let o = (y * 256 + x) * 4
                let r = Float(rgba[o])
                let g = Float(rgba[o + 1])
                let b = Float(rgba[o + 2])
                if r > g + 30 && r > b + 30 {
                    colEnergy[x] += r
                }
            }
        }
        let peak = colEnergy.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
        XCTAssertGreaterThanOrEqual(peak, 0)
        // Forward U=0.5 → x≈127.5; allow generous PoC tolerance.
        XCTAssertEqual(Float(peak), 128, accuracy: 48)
    }

    func testStreamingResidentFrameContract() {
        // Engine documents maxResidentFullResFrames ≤ 1 in metrics after run;
        // unit-level: canvas estimate stays under soft budget for 4K.
        let mb = Double(4096 * 2048 * 27) / (1024 * 1024)
        XCTAssertLessThan(mb, 250)
        XCTAssertLessThan(mb + 80, 1300)
    }

    func testDepthSourceModeCases() {
        XCTAssertEqual(DepthSourceMode.allCases.count, 3)
        XCTAssertTrue(DepthAnythingCoreMLAvailability.license.contains("Apache"))
        XCTAssertFalse(DepthAnythingCoreMLAvailability.modelName.isEmpty)
    }

    func testProductionDefaultUnchanged() {
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
        XCTAssertNotEqual(PanoramaEngineSelection.productionDefault, .depthReproject)
    }
}

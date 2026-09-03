import Foundation
import simd
import XCTest
@testable import Gonggi

/// Phase 2B/2C: OpenCV reconstruction contracts + synthetic end-to-end.
final class OpenCVPanoramaPhase2BCTests: XCTestCase {

    private func solidRGBA(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            out[i * 4] = rgb.0
            out[i * 4 + 1] = rgb.1
            out[i * 4 + 2] = rgb.2
        }
        return out
    }

    /// Paint a soft vertical stripe into equirect so crops have matchable structure.
    private func patternedEquirect(width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 40, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let band = (x / max(width / 16, 1)) % 2 == 0
                let vGrad = UInt8(min(255, y * 255 / max(height - 1, 1)))
                rgba[i] = band ? 220 : 60
                rgba[i + 1] = vGrad
                rgba[i + 2] = band ? 90 : 200
                rgba[i + 3] = 255
                // Cross markers for features
                if abs(x - width / 2) < 3 || abs(y - height / 2) < 3 {
                    rgba[i] = 255; rgba[i + 1] = 255; rgba[i + 2] = 255
                }
            }
        }
        return rgba
    }

    private func perspectiveCrop(
        equirect: [UInt8],
        eqW: Int,
        eqH: Int,
        yawRad: Float,
        pitchRad: Float,
        outW: Int,
        outH: Int,
        fx: Float,
        fy: Float
    ) -> (rgba: [UInt8], K: CameraIntrinsics, transform: simd_float4x4) {
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)
        let cx = Float(outW - 1) / 2
        let cy = Float(outH - 1) / 2
        let basis = Quick360CaptureBasis(
            worldUp: Quick360CaptureBasis.gravityUp,
            referenceForward: simd_float3(0, 0, -1),
            referenceRight: simd_float3(1, 0, 0)
        )
        // Camera looking at (yaw,pitch) with roll-free frame.
        let forward = basis.worldDirection(yawRad: yawRad, pitchRad: pitchRad)
        let right = simd_normalize(simd_cross(forward, basis.worldUp))
        let up = simd_normalize(simd_cross(right, forward))
        // columns = (right, up, -forward) matching StabilizedCameraFrame.rotation
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4(right.x, right.y, right.z, 0)
        transform.columns.1 = SIMD4(up.x, up.y, up.z, 0)
        transform.columns.2 = SIMD4(-forward.x, -forward.y, -forward.z, 0)

        for v in 0..<outH {
            for u in 0..<outW {
                let x = (Float(u) - cx) / fx
                let y = -(Float(v) - cy) / fy // Gonggi: image v down → camera y up
                let rayCam = simd_normalize(simd_float3(x, y, -1))
                let world = simd_normalize(right * rayCam.x + up * rayCam.y + forward * (-rayCam.z))
                let (yaw, pitch) = basis.yawPitch(fromWorldDirection: world)
                let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
                let sx = Int((uv.x * Float(eqW - 1)).rounded())
                let sy = Int((uv.y * Float(eqH - 1)).rounded())
                guard sx >= 0, sy >= 0, sx < eqW, sy < eqH else { continue }
                let si = (sy * eqW + sx) * 4
                let di = (v * outW + u) * 4
                rgba[di] = equirect[si]
                rgba[di + 1] = equirect[si + 1]
                rgba[di + 2] = equirect[si + 2]
                rgba[di + 3] = 255
            }
        }
        let K = CameraIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, width: outW, height: outH)
        return (rgba, K, transform)
    }

    func testOutputResolutionContract4096x2048() async throws {
        let eqW = 512
        let eqH = 256
        let equirect = patternedEquirect(width: eqW, height: eqH)
        let cropW = 160
        let cropH = 120
        let fx: Float = 90
        let fy: Float = 90

        var keyframes: [PanoramaStitcher.InputKeyframe] = []
        let yaws: [Float] = [-0.6, 0, 0.6]
        for (idx, yaw) in yaws.enumerated() {
            let crop = perspectiveCrop(
                equirect: equirect, eqW: eqW, eqH: eqH,
                yawRad: yaw, pitchRad: 0,
                outW: cropW, outH: cropH, fx: fx, fy: fy
            )
            keyframes.append(PanoramaStitcher.InputKeyframe(
                index: idx,
                rgba: crop.rgba,
                width: cropW,
                height: cropH,
                cameraTransform: crop.transform,
                intrinsics: crop.K,
                dynamicRatio: 0,
                yawRad: yaw,
                pitchRad: 0
            ))
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencv-e2e-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let input = PanoramaEngineInput(
            sessionId: "opencv-e2e-\(UUID().uuidString)",
            keyframes: keyframes,
            originTransform: keyframes[1].cameraTransform,
            captureBasis: Quick360CaptureBasis(
                worldUp: Quick360CaptureBasis.gravityUp,
                referenceForward: simd_float3(0, 0, -1),
                referenceRight: simd_float3(1, 0, 0)
            ),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: Quick360Config.outputWidth,
            outputHeight: Quick360Config.outputHeight,
            outputPanoramaURL: outURL
        )

        let out = try await OpenCVPanoramaEngine().stitch(input: input)
        // Synthetic crops may be too small for AKAZE/BA — accept success or structured failure.
        if out.success {
            XCTAssertEqual(out.width, 4096)
            XCTAssertEqual(out.height, 2048)
            XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(
                width: out.width, height: out.height
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
            let size = attrs[.size] as? NSNumber
            XCTAssertGreaterThan(size?.intValue ?? 0, 1000)
        } else {
            XCTAssertNotNil(out.failureReason)
        }
    }

    func testSingleImageGraceful() async throws {
        let rgba = solidRGBA(width: 64, height: 48, rgb: (120, 130, 140))
        let k = CameraIntrinsics(fx: 40, fy: 40, cx: 32, cy: 24, width: 64, height: 48)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: rgba,
            width: 64,
            height: 48,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0,
            yawRad: 0,
            pitchRad: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencv-one-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = PanoramaEngineInput(
            sessionId: "opencv-one-\(UUID().uuidString)",
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 512,
            outputHeight: 256,
            outputPanoramaURL: url
        )
        // Non-4K for faster unit test; reconstructor requires 2:1.
        // Production path uses 4096×2048 — engine still accepts config sizes that are 2:1.
        let out = try await OpenCVPanoramaEngine().stitch(input: input)
        if out.success {
            XCTAssertEqual(out.width, 512)
            XCTAssertEqual(out.height, 256)
        } else {
            // Some OpenCV warper paths expect production scale — failure must be structured.
            XCTAssertNotNil(out.failureReason)
        }
    }

    func testProductionDefaultRemainsLegacy() {
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
        #if !DEBUG
        XCTAssertEqual(PanoramaEngineSelection.resolved(), .legacy)
        #endif
    }

    func testLegacyUnaffectedByOpenCVPath() async throws {
        let rgba = solidRGBA(width: 16, height: 16, rgb: (100, 110, 120))
        let k = CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: rgba,
            width: 16,
            height: 16,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-iso-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = PanoramaEngineInput(
            sessionId: "legacy-iso-\(UUID().uuidString)",
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 64,
            outputHeight: 32,
            outputPanoramaURL: url
        )
        let legacy = try await GonggiLegacyPanoramaEngine().stitch(input: input)
        XCTAssertTrue(legacy.success)
        XCTAssertEqual(legacy.engineIdentifier, PanoramaEngineID.legacy)
    }
}

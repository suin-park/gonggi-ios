import Foundation
import simd
import XCTest
@testable import Gonggi

/// Build 24 — memory-bounded two-pass / streaming OpenCV architecture contracts.
final class OpenCVPanoramaBuild24MemoryTests: XCTestCase {

    func testOrientationAnd4KContractUnchanged() {
        XCTAssertEqual(Quick360Config.outputWidth, 4096)
        XCTAssertEqual(Quick360Config.outputHeight, 2048)
        XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(
            width: 4096, height: 2048
        ))
        XCTAssertEqual(PanoramaEquirectOrientationContract.forwardU, 0.5, accuracy: 1e-5)
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
    }

    func testKeyframePixelBufferReleaseContract() {
        let rgba = [UInt8](repeating: 90, count: 8 * 8 * 4)
        let k = CameraIntrinsics(fx: 5, fy: 5, cx: 4, cy: 4, width: 8, height: 8)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: rgba,
            width: 8,
            height: 8,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0,
            fileName: "kf0.jpg"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("b24-strip-\(UUID().uuidString).jpg")
        let input = PanoramaEngineInput(
            sessionId: "b24-strip",
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: nil,
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 64,
            outputHeight: 32,
            outputPanoramaURL: url
        )
        let light = input.releasingKeyframePixelBuffers()
        XCTAssertTrue(light.keyframes[0].rgba.isEmpty)
        XCTAssertEqual(light.keyframes[0].width, 8)
        XCTAssertEqual(light.keyframes[0].fileName, "kf0.jpg")
        XCTAssertFalse(input.keyframes[0].rgba.isEmpty)
    }

    func testLegacyOutputPixelBufferReleaseContract() {
        let rgba = [UInt8](repeating: 10, count: 4 * 2 * 4)
        let out = PanoramaStitcher.Output(
            rgba: rgba,
            width: 4,
            height: 2,
            coverageFlags: [true, false, true, false, true, false, true, false],
            coveragePercent: 50,
            uncoveredPercent: 50,
            alignmentApplied: false,
            stitchTimeSec: 0.1,
            acceptedKeyframeCount: 1,
            rejectedKeyframeCount: 0,
            averageAngularSpacingDeg: 0,
            visualRefinementAttempts: 0,
            successfulRefinements: 0,
            averageMatchCount: 0,
            averageInlierRatio: 0,
            averageReprojectionError: 0,
            highParallaxFrameCount: 0,
            keyframePlacements: [],
            seamPreferredFrame: [0, 1, 0, 1, 0, 1, 0, 1],
            refinementMatchDebug: []
        )
        let light = out.releasingHeavyPixelBuffers()
        XCTAssertTrue(light.rgba.isEmpty)
        XCTAssertTrue(light.seamPreferredFrame.isEmpty)
        XCTAssertEqual(light.coverageFlags.count, 8)
        XCTAssertEqual(light.width, 4)
    }

    func testOpenCVFailureLeavesLegacyValid() async throws {
        let rgba = [UInt8](repeating: 140, count: 16 * 16 * 4)
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
        let sessionId = "b24-ab-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let legacyURL = try CaptureSessionStore.quick360EquirectangularURL(sessionId: sessionId)
        let input = PanoramaEngineInput(
            sessionId: sessionId,
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 64,
            outputHeight: 32,
            outputPanoramaURL: legacyURL
        )
        let stitch = try await Quick360Reconstruction.runSelectedEngine(
            input: input,
            selection: .abCompare
        )
        XCTAssertEqual(stitch.width, 64)
        XCTAssertEqual(stitch.height, 32)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let ab = try PanoramaABPaths.directory(sessionId: sessionId)
            .appendingPathComponent(PanoramaABPaths.abReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ab.path))
    }

    func testStreamingArchitectureMetricsWhenPresent() async throws {
        var patterned = [UInt8](repeating: 100, count: 32 * 24 * 4)
        for y in 0..<24 {
            for x in 0..<32 where (x + y) % 3 == 0 {
                let i = (y * 32 + x) * 4
                patterned[i] = 220
                patterned[i + 1] = 40
                patterned[i + 2] = 40
                patterned[i + 3] = 255
            }
        }
        let k = CameraIntrinsics(fx: 20, fy: 20, cx: 16, cy: 12, width: 32, height: 24)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: patterned,
            width: 32,
            height: 24,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0,
            yawRad: 0,
            pitchRad: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("b24-arch-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let sessionId = "b24-arch-\(UUID().uuidString)"
        let input = PanoramaEngineInput(
            sessionId: sessionId,
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 256,
            outputHeight: 128,
            outputPanoramaURL: url
        )
        let out = try await OpenCVPanoramaEngine().stitch(input: input)
        if let json = out.report.openCVMetricsJSON {
            XCTAssertTrue(
                json.contains("two_pass_streaming") || json.contains("memoryArchitecture"),
                "Expected two-pass architecture tag: \(json)"
            )
            XCTAssertFalse(json.contains("BlocksGain"))
            if json.contains("maxWarpedResidentCount") {
                // Full-res resident warped frames must stay ≤ 2 (target 1).
                if let range = json.range(of: "\"maxWarpedResidentCount\":") {
                    let rest = json[range.upperBound...]
                    let digits = rest.prefix(while: { $0.isNumber || $0 == "-" })
                    if let v = Int(digits) {
                        XCTAssertLessThanOrEqual(v, 2, "full-res warped resident too high: \(v)")
                    }
                }
            }
            if json.contains("maxLoadedFullResCount") {
                if let range = json.range(of: "\"maxLoadedFullResCount\":") {
                    let rest = json[range.upperBound...]
                    let digits = rest.prefix(while: { $0.isNumber || $0 == "-" })
                    if let v = Int(digits) {
                        XCTAssertLessThanOrEqual(v, 2)
                    }
                }
            }
        } else if !out.success {
            XCTAssertNotNil(out.failureReason)
        }

        // memory_trace.jsonl should exist under A/B opencv debug when stitch ran.
        if let trace = try? PanoramaABPaths.directory(sessionId: sessionId)
            .appendingPathComponent("opencv/memory_trace.jsonl"),
           FileManager.default.fileExists(atPath: trace.path),
           let text = try? String(contentsOf: trace, encoding: .utf8) {
            XCTAssertTrue(text.contains("\"stage\""))
            XCTAssertTrue(text.contains("physFootprintMB"))
        }
    }

    func testBridgeSmokeStillWorks() {
        XCTAssertTrue(OpenCVPanoramaBridge.isAvailable())
        XCTAssertEqual(OpenCVPanoramaBridge.smokeTestAddLeft(2, right: 3), 5)
    }
}

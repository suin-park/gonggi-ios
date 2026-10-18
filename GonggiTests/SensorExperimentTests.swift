import XCTest
import CoreVideo
@testable import Gonggi

/// 기록하기 › 실험(센서 검사)의 순수 로직 검증. 실기기 센서 결과가 아니다.
final class SensorExperimentTests: XCTestCase {

    // MARK: 노출 설정

    func testFeatureFlagParsing() {
        XCTAssertTrue(SensorExperimentFeature.isEnabled(infoValue: "YES", env: nil))
        XCTAssertTrue(SensorExperimentFeature.isEnabled(infoValue: true, env: nil))
        XCTAssertTrue(SensorExperimentFeature.isEnabled(infoValue: NSNumber(value: 1), env: nil))
        XCTAssertFalse(SensorExperimentFeature.isEnabled(infoValue: "NO", env: nil))
        XCTAssertFalse(SensorExperimentFeature.isEnabled(infoValue: nil, env: nil), "값이 없으면 꺼짐")
        XCTAssertFalse(SensorExperimentFeature.isEnabled(infoValue: "maybe", env: nil), "해석 불가면 꺼짐")
        XCTAssertFalse(SensorExperimentFeature.isEnabled(infoValue: "YES", env: "0"), "환경변수가 우선")
        XCTAssertTrue(SensorExperimentFeature.isEnabled(infoValue: "NO", env: "true"))
    }

    func testRecordHomeCopyHasExperimentRow() {
        XCTAssertEqual(RecordHomeCopy.experimentSection, "실험")
        XCTAssertFalse(RecordHomeCopy.sensorExperiment.line.contains("\n"))
    }

    // MARK: 수학

    func testPercentileGapsHz() {
        XCTAssertNil(ExpMath.percentile([], 0.5))
        XCTAssertEqual(ExpMath.percentile([5, 1, 3], 0.5), 3)
        XCTAssertEqual(ExpMath.percentile([1, 2, 3, 4], 1), 4)
        XCTAssertEqual(ExpMath.gaps([0, 1, 3]), [1, 2])
        XCTAssertEqual(ExpMath.hz([0, 0.5, 1.0])!, 2.0, accuracy: 1e-9)
        XCTAssertNil(ExpMath.hz([1]))
        XCTAssertNil(ExpMath.hz([1, 1]))
    }

    func testNearestOffsetsIsSignedAndSymmetric() {
        let off = ExpMath.nearestOffsets(reference: [1.0, 2.0, 3.0], other: [1.01, 1.97, 3.5])
        XCTAssertEqual(off[0], 0.01, accuracy: 1e-9)
        XCTAssertEqual(off[1], -0.03, accuracy: 1e-9)
        XCTAssertEqual(off[2], 0.5, accuracy: 1e-9)
        XCTAssertTrue(ExpMath.nearestOffsets(reference: [1], other: []).isEmpty)
    }

    func testHalfFloat() {
        XCTAssertEqual(ExpMath.halfToFloat(0x3C00), 1.0)
        XCTAssertEqual(ExpMath.halfToFloat(0xC000), -2.0)
        XCTAssertEqual(ExpMath.halfToFloat(0x0000), 0.0)
        XCTAssertEqual(ExpMath.halfToFloat(0x3800), 0.5)
        XCTAssertTrue(ExpMath.halfToFloat(0x7C00).isInfinite)
        XCTAssertTrue(ExpMath.halfToFloat(0x7E00).isNaN)
        XCTAssertEqual(ExpMath.halfToFloat(0x0001), Float(sign: .plus, exponent: -24, significand: 1), "가장 작은 비정규 수")
    }

    func testRateMeter() {
        var m = ExpRateMeter()
        for i in 0...10 { m.add(Double(i) * 0.1) }
        XCTAssertEqual(m.hz!, 10.0, accuracy: 1e-9)
        XCTAssertEqual(m.total, 11)
        XCTAssertEqual(m.rate(in: 0.0...0.5)!, 12.0, accuracy: 1e-9, "6개 / 0.5초")
        XCTAssertEqual(m.times(in: 0.25...0.55).count, 3)
    }

    // MARK: 깊이 버퍼

    private func makeBuffer(_ type: OSType, w: Int, h: Int, fill: (Int, Int) -> Float) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, type, nil, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { throw XCTSkip("이 환경에서 \(ExpSys.fourCC(type)) 버퍼를 만들 수 없음") }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h {
            for x in 0..<w {
                let v = fill(x, y)
                let row = base.advanced(by: y * bpr)
                if type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DisparityFloat32 {
                    row.assumingMemoryBound(to: Float.self)[x] = v
                } else {
                    row.assumingMemoryBound(to: UInt16.self)[x] = Self.floatToHalf(v)
                }
            }
        }
        return buf
    }

    private static func floatToHalf(_ f: Float) -> UInt16 {
        if f.isNaN { return 0x7E00 }
        if f == 0 { return 0 }
        // 테스트에서 쓰는 단순 값(1, 2, 0.5 등)만 정확히 다룬다.
        let bits = f.bitPattern
        let sign = UInt16((bits >> 31) & 1) << 15
        let exp = Int((bits >> 23) & 0xFF) - 127 + 15
        let man = UInt16((bits >> 13) & 0x3FF)
        return sign | UInt16(exp << 10) | man
    }

    func testDepthStatsValidityAndGrid() throws {
        // 왼쪽 절반은 2.0, 오른쪽 절반은 NaN. 그리고 한 줄은 0.
        let pb = try makeBuffer(kCVPixelFormatType_DepthFloat32, w: 64, h: 48) { x, y in
            if y == 10 { return 0 }
            return x < 32 ? 2.0 : .nan
        }
        let s = try XCTUnwrap(ExpDepthPixels.stats(pb, targetSamples: 64 * 48))
        XCTAssertEqual(s.width, 64)
        XCTAssertEqual(s.validRatio, 0.5 * (47.0 / 48.0), accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(s.p50), 2.0, accuracy: 1e-6)
        XCTAssertEqual(s.gridMedian.count, 48)
        XCTAssertEqual(try XCTUnwrap(s.gridMedian[0]), 2.0, accuracy: 1e-6, "왼쪽 위 칸")
        XCTAssertNil(s.gridMedian[7], "오른쪽 위 칸은 모두 NaN")
        XCTAssertEqual(s.gridValid[7], 0, accuracy: 1e-9)
        XCTAssertTrue(ExpDepthPixels.isSupported(kCVPixelFormatType_DepthFloat32))
        XCTAssertFalse(ExpDepthPixels.isSupported(kCVPixelFormatType_32BGRA))
        XCTAssertNil(ExpDepthPixels.stats(try makeBuffer(kCVPixelFormatType_32BGRA, w: 4, h: 4) { _, _ in 0 }))
    }

    func testDisparityHalfFloatStatsAndColorize() throws {
        let pb = try makeBuffer(kCVPixelFormatType_DisparityFloat16, w: 40, h: 30) { x, _ in x < 20 ? 1.0 : 2.0 }
        let s = try XCTUnwrap(ExpDepthPixels.stats(pb))
        XCTAssertEqual(s.validRatio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.min), 1.0, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(s.max), 2.0, accuracy: 1e-3)
        XCTAssertTrue(ExpDepthPixels.isDisparity(kCVPixelFormatType_DisparityFloat16))
        let img = try XCTUnwrap(ExpDepthPixels.colorized(pb, maxWidth: 20))
        XCTAssertLessThanOrEqual(img.width, 20)
        XCTAssertGreaterThan(img.height, 0)
        let data = try XCTUnwrap(ExpDepthPixels.float32Data(pb))
        XCTAssertEqual(data.count, 40 * 30 * 4)
        XCTAssertNotNil(s.dictionary()["gridMedian"])
        XCTAssertNil(s.dictionary(includeGrid: false)["gridMedian"], "격자를 빼면 로그 줄이 짧아진다")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(expJSONSafe(s.dictionary())))
    }

    func testRampEndpoints() {
        XCTAssertTrue(ExpDepthPixels.ramp(0) == (0, 0, 255))
        XCTAssertTrue(ExpDepthPixels.ramp(1) == (255, 0, 0))
        _ = ExpDepthPixels.ramp(-5); _ = ExpDepthPixels.ramp(5)   // 범위를 벗어나도 죽지 않는다
    }

    func testCenterValueUsesMiddleCells() {
        var med = [Double?](repeating: nil, count: 48)
        for i in [19, 20, 27, 28] { med[i] = 3.0 }
        let s = ExpDepthFrameStats(width: 8, height: 6, pixelType: "fdep", sampled: 48, validRatio: 1, min: 1, p5: 1, p50: 2, p95: 3, max: 3,
                                   gridCols: 8, gridRows: 6, gridMedian: med, gridValid: [Double](repeating: 1, count: 48))
        XCTAssertEqual(ExperimentDepthRunner.centerValue(s), 3.0)
        XCTAssertEqual(ExperimentDepthRunner.centerValid(s), 1.0)
        XCTAssertNil(ExperimentDepthRunner.centerValue(nil))
    }

    // MARK: 결과 분류

    func testDepthOutcomeKeepsFailureKindsApart() {
        func o(perm: Bool = false, dev: Bool = true, fmt: Bool = true, err: String? = nil, conn: Bool = true, intr: Int = 0, cb: Int = 0) -> ExpOutcome {
            ExpDepthClassifier.outcome(permissionDenied: perm, deviceFound: dev, formatsPresent: fmt, setupError: err,
                                       outputConnected: conn, interruptions: intr, depthCallbacks: cb)
        }
        XCTAssertEqual(o(perm: true), .permissionDenied)
        guard case .unsupported = o(dev: false) else { return XCTFail("장치 없음은 미지원") }
        guard case .unsupported = o(fmt: false) else { return XCTFail("포맷 없음은 미지원") }
        guard case .setupFailed = o(err: "x") else { return XCTFail("설정 오류는 설정 실패") }
        guard case .setupFailed = o(conn: false) else { return XCTFail("연결 실패는 설정 실패") }
        guard case .interrupted = o(intr: 1) else { return XCTFail("콜백 없이 중단은 중단") }
        XCTAssertEqual(o(), .noData, "연결됐지만 콜백이 없으면 수신 없음")
        XCTAssertEqual(o(cb: 3), .ok)
        XCTAssertEqual(o(intr: 2, cb: 3), .ok, "콜백이 왔다면 수신 확인(중단 이벤트는 따로 보고)")
        XCTAssertFalse(ExpOutcome.noData.isOK)
    }

    func testStagesAreIndependentAndLabeled() {
        XCTAssertEqual(ExpDepthStage.allCases.count, 5)
        XCTAssertEqual(ExpStageState.unknown.label, "확인 못함")
        XCTAssertEqual(ExpEndReason.thermal.label, "기기 온도(serious 이상)로 자동 종료")
    }

    // MARK: 동기화

    func testSyncVerdict() {
        // 30Hz: 한계 = 16.7ms
        let good = Array(repeating: 0.005, count: 60)
        guard case .pass = ExpSync.evaluate(offsets: good, videoHz: 30, clockStable: true) else { return XCTFail("5ms는 통과") }
        let bad = Array(repeating: 0.030, count: 60)
        guard case .fail = ExpSync.evaluate(offsets: bad, videoHz: 30, clockStable: true) else { return XCTFail("30ms는 실패") }
        guard case .unknown = ExpSync.evaluate(offsets: good, videoHz: 30, clockStable: false) else { return XCTFail("시계 불안정이면 판정 불가") }
        guard case .unknown = ExpSync.evaluate(offsets: [0.001], videoHz: 30, clockStable: true) else { return XCTFail("표본 부족은 판정 불가") }
        guard case .unknown = ExpSync.evaluate(offsets: good, videoHz: nil, clockStable: true) else { return XCTFail("빈도 모르면 판정 불가") }
        XCTAssertTrue(ExpSync.isClockStable(deltas: [0.1000, 0.1005, 0.1010]))
        XCTAssertFalse(ExpSync.isClockStable(deltas: [0.1, 0.2]))
        XCTAssertFalse(ExpSync.isClockStable(deltas: []))
    }

    // MARK: 공존 판정

    private func phase(_ n: String, ar: Double? = nil, v: Double? = nil, d: Double? = nil, are: Int = 0, ave: Int = 0) -> ExpPhaseStats {
        ExpPhaseStats(name: n, seconds: 10, arHz: ar, videoHz: v, depthHz: d, arEvents: are, avEvents: ave)
    }

    func testCoexistVerdicts() {
        let aloneAR = phase("ar", ar: 60), aloneAV = phase("av", v: 30, d: 30)
        XCTAssertEqual(ExpCoexist.evaluate(aloneAR: aloneAR, aloneAV: aloneAV, both: phase("both", ar: 58, v: 29, d: 29)), .coexists)

        // 한쪽이 무너짐
        if case .failed(let r) = ExpCoexist.evaluate(aloneAR: aloneAR, aloneAV: aloneAV, both: phase("both", ar: 0, v: 29, d: 29)) {
            XCTAssertTrue(r.contains { $0.contains("ARKit") })
        } else { XCTFail("ARKit가 0Hz면 실패") }

        // 중단 이벤트가 있으면 빈도가 괜찮아도 실패
        if case .failed(let r) = ExpCoexist.evaluate(aloneAR: aloneAR, aloneAV: aloneAV, both: phase("both", ar: 60, v: 30, d: 30, are: 1)) {
            XCTAssertTrue(r.contains { $0.contains("중단") })
        } else { XCTFail("중단 이벤트는 실패") }

        // 절반으로 떨어짐
        guard case .failed = ExpCoexist.evaluate(aloneAR: aloneAR, aloneAV: aloneAV, both: phase("both", ar: 30, v: 30, d: 30)) else { return XCTFail("단독 대비 50%는 실패") }

        // 기준이 없으면 절대 기준만 본다
        XCTAssertEqual(ExpCoexist.evaluate(aloneAR: nil, aloneAV: nil, both: phase("both", ar: 50, v: 25, d: 25)), .coexists)
        guard case .failed = ExpCoexist.evaluate(aloneAR: nil, aloneAV: nil, both: phase("both", ar: 50, v: 25, d: 2)) else { return XCTFail("깊이 2Hz는 절대 기준 미달") }

        guard case .unknown = ExpCoexist.evaluate(aloneAR: aloneAR, aloneAV: aloneAV, both: nil) else { return XCTFail("함께 도는 구간이 없으면 판정 불가") }
        XCTAssertFalse(ExpCoexistVerdict.failed(["x"]).isCoexists)
    }

    // MARK: 카메라 소유권

    @MainActor
    func testCameraGateHandsOverOneAtATime() async {
        let gate = ExperimentCameraGate()
        let a = await gate.acquire("a")
        XCTAssertTrue(a)
        let b = await gate.acquire("b", timeout: 0.3)
        XCTAssertFalse(b, "앞 소유자가 놓기 전에는 얻을 수 없다")
        gate.release("b")                      // 소유자가 아니면 무시
        XCTAssertEqual(gate.owner, "a")
        gate.release("a")
        let c = await gate.acquire("b", timeout: 0.3)
        XCTAssertTrue(c)
        gate.release("b")
        XCTAssertNil(gate.owner)
    }

    // MARK: 로그

    func testJSONSafeReplacesNonFinite() {
        let safe = expJSONSafe(["a": Double.nan, "b": [Float.infinity, 1.5], "c": "x"]) as! [String: Any]
        XCTAssertTrue(safe["a"] is NSNull)
        XCTAssertTrue((safe["b"] as! [Any])[0] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(safe))
    }

    func testRunLogWritesJSONLAndEnforcesLimits() throws {
        let log = try XCTUnwrap(ExperimentRunLog(kind: .sensorBasic, settings: ["t": 1], limits: .init(maxBytes: 1_000_000, maxLines: 8)))
        defer {
            try? FileManager.default.removeItem(at: log.url)
            try? FileManager.default.removeItem(at: log.summaryURL)
        }
        for i in 0..<30 { log.write("ar", ["n": i, "bad": Double.nan]) }
        log.finish(summary: ["ok": true], summaryText: "요약")
        let text = try String(contentsOf: log.url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertGreaterThan(lines.count, 2)
        for l in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(l.utf8)), "모든 줄이 JSON: \(l)")
        }
        let kinds = lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["kind"] as? String }
        XCTAssertEqual(kinds.first, "header")
        XCTAssertEqual(kinds.last, "summary", "요약은 한도와 상관없이 마지막에 기록된다")
        XCTAssertTrue(kinds.contains("log_limit"), "한도에 닿으면 표시가 남는다")
        XCTAssertLessThan(kinds.filter { $0 == "ar" }.count, 30, "한도를 넘은 줄은 기록되지 않는다")
        XCTAssertEqual(try String(contentsOf: log.summaryURL, encoding: .utf8), "요약")
        // 닫힌 뒤의 write는 무시된다
        log.write("late")
        XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), text)
    }

    func testRunStoreListsAndShares() throws {
        let log = try XCTUnwrap(ExperimentRunLog(kind: .depthStream, settings: [:]))
        defer {
            try? FileManager.default.removeItem(at: log.url)
            try? FileManager.default.removeItem(at: log.summaryURL)
        }
        log.finish(summary: [:], summaryText: "ok-summary")
        let run = try XCTUnwrap(ExperimentRunStore.list().first { $0.baseName == log.baseName })
        XCTAssertEqual(run.experiment, ExperimentKind.depthStream.rawValue)
        XCTAssertNotNil(run.startedAt)
        XCTAssertEqual(ExperimentRunStore.summaryText(for: run), "ok-summary")
        let items = ExperimentRunStore.shareItems(for: run)
        XCTAssertTrue(items.contains(run.jsonlURL))
        XCTAssertTrue(items.contains(run.summaryURL))
    }

    func testEventsCountByWindow() {
        let e = ExpEvents()
        e.add(source: "ar", kind: "interrupted")
        e.add(source: "av", kind: "error")
        XCTAssertEqual(e.count(source: "ar"), 1)
        XCTAssertEqual(e.count(source: "av", kinds: ["interrupted"]), 0)
        XCTAssertEqual(e.count(source: nil, kinds: ["error", "interrupted"]), 2)
        XCTAssertEqual(e.count(from: ExpSys.hostNow() + 100), 0)
    }

    func testDepthKindDescriptionKeepsMeaningsApart() {
        XCTAssertTrue(ExpDepthKind.describe(kCVPixelFormatType_DisparityFloat16).contains("disparity"))
        XCTAssertTrue(ExpDepthKind.describe(kCVPixelFormatType_DepthFloat32).contains("camera-Z"))
        XCTAssertTrue(ExpDepthKind.describe(kCVPixelFormatType_DepthFloat32).contains("accuracy"))
    }

    func testGuideCoversEightSteps() {
        XCTAssertEqual(ExperimentGuideText.steps.map(\.id), Array(1...8))
        XCTAssertTrue(ExperimentGuideText.distanceNote.contains("camera-Z"))
        XCTAssertTrue(ExperimentGuideText.distanceNote.contains("range"))
    }
}

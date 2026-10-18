import Foundation

enum ExpCoexistTest: String, CaseIterable, Identifiable {
    case arAlone, depthAlone, arThenDepth, depthThenAR

    var id: String { rawValue }

    var kind: ExperimentKind {
        switch self {
        case .arAlone: return .coexistARAlone
        case .depthAlone: return .coexistDepthAlone
        case .arThenDepth: return .coexistARThenDepth
        case .depthThenAR: return .coexistDepthThenAR
        }
    }

    var title: String { kind.title.replacingOccurrences(of: "공존: ", with: "") }

    var detail: String {
        switch self {
        case .arAlone: return "ARKit만 실행해 기준 빈도를 잰다."
        case .depthAlone: return "후면 영상·깊이만 실행해 기준 빈도를 잰다."
        case .arThenDepth: return "ARKit를 먼저 실행하고, 중간에 후면 깊이를 시작한다."
        case .depthThenAR: return "후면 깊이를 먼저 실행하고, 중간에 ARKit를 시작한다."
        }
    }
}

struct ExpCoexistResult {
    var text: String
    var dictionary: [String: Any]
    var coexist: ExpCoexistVerdict?
    var poseVideoSync: ExpSyncVerdict?
    var depthVideoSync: ExpSyncVerdict?
    var endReason: ExpEndReason
    var phases: [ExpPhaseStats]
}

struct ExpCoexistProgress {
    var phase: String
    var phaseElapsed: Double
    var totalElapsed: Double
    var arHz: Double?
    var videoHz: Double?
    var depthHz: Double?
    var events: Int
    var message: String
}

/// 같은 카메라를 ARKit과 후면 깊이 스트림이 동시에 쓸 수 있는지 시간 순서대로 측정한다.
/// 객체가 둘 만들어졌다는 사실은 공존의 증거가 아니다. 구간 안에서 실제로 두 스트림이 계속 들어오는지, 중단·오류가 없는지로 판정한다.
/// 공존 성공과 RGB·깊이·포즈 동기화 성공은 따로 판정한다.
final class ExperimentCoexistRunner: @unchecked Sendable {
    /// 앞서 실행한 단독 검사에서 얻은 기준 빈도(같은 앱 실행 안에서만 유지).
    static let baselines = Baselines()

    final class Baselines: @unchecked Sendable {
        private let lock = NSLock()
        private var ar: ExpPhaseStats?
        private var av: ExpPhaseStats?
        func set(ar v: ExpPhaseStats) { lock.lock(); ar = v; lock.unlock() }
        func set(av v: ExpPhaseStats) { lock.lock(); av = v; lock.unlock() }
        var arValue: ExpPhaseStats? { lock.lock(); defer { lock.unlock() }; return ar }
        var avValue: ExpPhaseStats? { lock.lock(); defer { lock.unlock() }; return av }
    }

    let test: ExpCoexistTest
    var onProgress: ((ExpCoexistProgress) -> Void)?

    private let log: ExperimentRunLog?
    private let soloSeconds: Double
    private let settle = 2.0
    private let cancelLock = NSLock()
    private var cancelReason: ExpEndReason?

    init(test: ExpCoexistTest, log: ExperimentRunLog?, seconds: Double = 30) {
        self.test = test
        self.log = log
        self.soloSeconds = seconds
    }

    func cancel(_ reason: ExpEndReason) {
        cancelLock.lock(); if cancelReason == nil { cancelReason = reason }; cancelLock.unlock()
    }

    private var cancelled: ExpEndReason? {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelReason
    }

    // MARK: 실행

    func run() async -> ExpCoexistResult {
        let ar = ExperimentARRunner(log: log)
        let av = ExperimentDepthRunner(options: .init(previewDepth: false, statsEvery: 0), log: log)
        ar.onAutoStop = { [weak self] r in self?.cancel(r) }
        av.onAutoStop = { [weak self] r in self?.cancel(r) }
        _ = ExperimentARRunner.logSupport(log)

        var phases: [ExpPhaseStats] = []
        var windows: [(name: String, range: ClosedRange<Double>, ar: Bool, av: Bool)] = []
        let t0 = ExpSys.hostNow()
        var avPrepared = ExperimentDepthRunner.SetupResult()
        var abortReason: String?

        func wait(_ label: String, seconds: Double, arOn: Bool, avOn: Bool) async -> ClosedRange<Double> {
            let start = ExpSys.hostNow()
            log?.write("coexist_phase_begin", ["phase": label, "seconds": seconds, "arOn": arOn, "avOn": avOn])
            while ExpSys.hostNow() - start < seconds, cancelled == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
                emit(label: label, phaseStart: start, runStart: t0, ar: ar, av: av, arOn: arOn, avOn: avOn)
            }
            let end = ExpSys.hostNow()
            log?.write("coexist_phase_end", ["phase": label])
            return start...end
        }

        switch test {
        case .arAlone:
            ar.start(options: .init(), phase: "ARKit 단독")
            let w = await wait("ARKit 단독", seconds: soloSeconds, arOn: true, avOn: false)
            windows.append(("ARKit 단독", w, true, false))

        case .depthAlone:
            avPrepared = await av.prepare()
            if avPrepared.outputConnected, avPrepared.error == nil {
                await av.start()
                let w = await wait("후면 깊이 단독", seconds: soloSeconds, arOn: false, avOn: true)
                windows.append(("후면 깊이 단독", w, false, true))
            } else {
                abortReason = "후면 깊이를 시작할 수 없음: \(describeSetup(avPrepared))"
            }

        case .arThenDepth:
            ar.start(options: .init(), phase: "ARKit 먼저")
            let w1 = await wait("1. ARKit 단독", seconds: 10, arOn: true, avOn: false)
            windows.append(("1. ARKit 단독", w1, true, false))
            if cancelled == nil {
                // 깊이 쪽 준비(권한·장치·포맷·세션 구성)도 ARKit이 돌고 있는 상태에서 한다.
                avPrepared = await av.prepare()
                if avPrepared.outputConnected, avPrepared.error == nil {
                    await av.start()
                    let w2 = await wait("2. ARKit + 후면 깊이", seconds: 15, arOn: true, avOn: true)
                    windows.append(("2. ARKit + 후면 깊이", w2, true, true))
                    await av.stop()
                    let w3 = await wait("3. 깊이 중지 후 ARKit만", seconds: 6, arOn: true, avOn: false)
                    windows.append(("3. 깊이 중지 후 ARKit만", w3, true, false))
                } else {
                    abortReason = "후면 깊이를 시작할 수 없음: \(describeSetup(avPrepared))"
                }
            }

        case .depthThenAR:
            avPrepared = await av.prepare()
            if avPrepared.outputConnected, avPrepared.error == nil {
                await av.start()
                let w1 = await wait("1. 후면 깊이 단독", seconds: 10, arOn: false, avOn: true)
                windows.append(("1. 후면 깊이 단독", w1, false, true))
                if cancelled == nil {
                    ar.start(options: .init(), phase: "깊이 다음 ARKit")
                    let w2 = await wait("2. 후면 깊이 + ARKit", seconds: 15, arOn: true, avOn: true)
                    windows.append(("2. 후면 깊이 + ARKit", w2, true, true))
                    ar.stop()
                    let w3 = await wait("3. ARKit 중지 후 깊이만", seconds: 6, arOn: false, avOn: true)
                    windows.append(("3. ARKit 중지 후 깊이만", w3, false, true))
                }
            } else {
                abortReason = "후면 깊이를 시작할 수 없음: \(describeSetup(avPrepared))"
            }
        }

        // 항상 정리: 두 소스를 모두 멈추고 연결을 끊는다.
        ar.stop()
        await av.stop()

        let end: ExpEndReason = cancelled ?? (abortReason == nil ? .completed : .failed)

        // 구간별 통계
        let arTimes = ar.frameHostTimes
        let ts = av.timestampSnapshot()
        for w in windows {
            let usable = (w.range.lowerBound + settle)...max(w.range.upperBound, w.range.lowerBound + settle + 0.001)
            func rate(_ t: [Double]) -> Double? {
                let len = usable.upperBound - usable.lowerBound
                guard len > 1 else { return nil }
                return Double(t.filter { usable.contains($0) }.count) / len
            }
            phases.append(ExpPhaseStats(
                name: w.name, seconds: w.range.upperBound - w.range.lowerBound,
                arHz: w.ar ? rate(arTimes) : nil, videoHz: w.av ? rate(ts.video) : nil, depthHz: w.av ? rate(ts.depth) : nil,
                arEvents: ar.events.count(source: "ar", kinds: ["interrupted", "error"], from: w.range.lowerBound, to: w.range.upperBound),
                avEvents: av.events.count(source: "av", kinds: ["interrupted", "error"], from: w.range.lowerBound, to: w.range.upperBound)))
        }

        var result = assemble(phases: phases, windows: windows, arTimes: arTimes, ts: ts, ar: ar, av: av,
                              avSetup: avPrepared, abort: abortReason, end: end)
        result.endReason = end
        return result
    }

    private func describeSetup(_ s: ExperimentDepthRunner.SetupResult) -> String {
        if s.permissionDenied { return "카메라 권한 없음" }
        if !s.deviceFound { return "듀얼 와이드 카메라 미발견(미지원)" }
        if !s.formatsPresent { return "영상·깊이 호환 포맷 없음(미지원)" }
        return s.error ?? "깊이 출력 연결 실패"
    }

    private func emit(label: String, phaseStart: Double, runStart: Double, ar: ExperimentARRunner, av: ExperimentDepthRunner, arOn: Bool, avOn: Bool) {
        let now = ExpSys.hostNow()
        func recent(_ t: [Double]) -> Double? {
            let r = t.filter { now - $0 <= 2.0 }
            return r.count > 1 ? Double(r.count - 1) / max(r.last! - r.first!, 0.001) : nil
        }
        let ts = avOn ? av.timestampSnapshot() : (video: [], depth: [])
        let p = ExpCoexistProgress(
            phase: label, phaseElapsed: now - phaseStart, totalElapsed: now - runStart,
            arHz: arOn ? recent(ar.frameHostTimes) : nil, videoHz: avOn ? recent(ts.video) : nil, depthHz: avOn ? recent(ts.depth) : nil,
            events: ar.events.all.count + av.events.all.count, message: "")
        onProgress?(p)
    }

    // MARK: 판정·요약

    private func assemble(phases: [ExpPhaseStats], windows: [(name: String, range: ClosedRange<Double>, ar: Bool, av: Bool)],
                          arTimes: [Double], ts: (video: [Double], depth: [Double]),
                          ar: ExperimentARRunner, av: ExperimentDepthRunner,
                          avSetup: ExperimentDepthRunner.SetupResult, abort: String?, end: ExpEndReason) -> ExpCoexistResult {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
        var text = "공존 검사 요약 — \(test.title)\n종료: \(end.label)\n"
        if let abort { text += "중단 사유: \(abort)\n" }
        text += "\n구간별 수신 빈도 (구간 시작 \(settle)초는 제외)\n"
        for p in phases {
            text += "■ \(p.name): ARKit \(f(p.arHz)) Hz · 영상 \(f(p.videoHz)) Hz · 깊이 \(f(p.depthHz)) Hz · 중단/오류 AR \(p.arEvents)건 / AV \(p.avEvents)건\n"
        }

        var coexist: ExpCoexistVerdict?
        var poseSync: ExpSyncVerdict?
        var depthSync: ExpSyncVerdict?
        var baselineNote = ""
        let isCombined = (test == .arThenDepth || test == .depthThenAR)

        // 단독 검사 결과는 같은 앱 실행 안에서 기준으로 보관한다.
        if test == .arAlone, let p = phases.first { Self.baselines.set(ar: p) }
        if test == .depthAlone, let p = phases.first { Self.baselines.set(av: p) }

        if isCombined {
            let aloneAR = phases.first { $0.arHz != nil && $0.videoHz == nil } ?? Self.baselines.arValue
            let aloneAV = phases.first { $0.videoHz != nil && $0.arHz == nil } ?? Self.baselines.avValue
            let both = phases.first { $0.arHz != nil && $0.videoHz != nil }
            if abort != nil, both == nil {
                coexist = .unknown("후면 깊이를 시작하지 못해 함께 도는 구간을 만들 수 없음")
            } else {
                coexist = ExpCoexist.evaluate(aloneAR: aloneAR, aloneAV: aloneAV, both: both)
            }
            baselineNote = "저하 비교 기준: ARKit \(aloneAR == nil ? "없음(절대 기준만)" : "있음"), 후면 깊이 \(aloneAV == nil ? "없음(절대 기준만. 먼저 '후면 깊이 단독'을 실행하면 비교 가능)" : "있음")"
            text += "\n공존 판정: \(coexist!.label)\n\(baselineNote)\n"
            text += "기준(잠정): 함께 도는 구간에서 각 스트림이 단독의 \(Int(ExpCoexist.keepRatio * 100))% 이상, 절대 \(Int(ExpCoexist.minHz))Hz 이상, 중단·오류 0건.\n"

            // 동기화 판정은 공존 판정과 별개다.
            if let bothW = windows.first(where: { $0.ar && $0.av }) {
                let r = (bothW.range.lowerBound + settle)...bothW.range.upperBound
                let v = ts.video.filter { r.contains($0) }
                let d = ts.depth.filter { r.contains($0) }
                let a = arTimes.filter { r.contains($0) }
                let stable = ExpSync.isClockStable(deltas: ar.clockDeltaSamples)
                let vHz = ExpMath.hz(v)
                depthSync = ExpSync.evaluate(offsets: ExpMath.nearestOffsets(reference: v, other: d), videoHz: vHz, clockStable: true)
                poseSync = ExpSync.evaluate(offsets: ExpMath.nearestOffsets(reference: v, other: a), videoHz: vHz, clockStable: stable)
                if coexist?.isCoexists != true {
                    text += "동기화: 공존이 확인되지 않아 평가하지 않는다 (참고 값만 기록).\n"
                }
                text += "RGB·깊이 동기화: \(depthSync!.label)\n포즈(ARFrame)·영상 동기화: \(poseSync!.label)\n"
                text += "※ ARFrame.timestamp(systemUptime)와 AV PTS(host clock)가 같은 기준이라는 것은 시작·검사 중 두 시계 차이가 일정했는지로 확인했다 (안정: \(stable ? "예" : "아니오")).\n"
                text += "※ 포즈-영상이 같은 센서 프레임인지는 이 값으로 증명되지 않는다. 시간 근접도만 본 것이다.\n"
            } else {
                text += "동기화: 함께 도는 구간이 없어 평가하지 않았다.\n"
            }
        } else {
            text += "\n(단독 검사: 공존 판정은 하지 않는다. 이 결과는 같은 앱 실행 안에서 이어서 하는 공존 검사의 기준 빈도로 쓰인다.)\n"
        }
        let ev = ar.events.all + av.events.all
        text += "\n이벤트 \(ev.count)건" + (ev.isEmpty ? "\n" : ": " + ev.map { "\($0.source):\($0.kind) \($0.detail)" }.joined(separator: "; ") + "\n")
        text += "열 상태(종료 시): \(ExpSys.thermal), 메모리 \(f(ExpSys.footprintMB())) MB\n"
        text += "\n해석 주의\n  - '공존'은 구간 안에서 두 스트림이 실제로 계속 수신되었다는 뜻이다. 동기화 정확도나 데이터 품질을 뜻하지 않는다.\n  - 한 순서에서 성공했다고 반대 순서도 성공한다고 볼 수 없다. 두 순서를 모두 실행한다.\n  - 이 판정 기준은 잠정이다. 기기·장면·열 상태에 따라 반복해 확인한다.\n"

        var d: [String: Any] = [
            "test": test.rawValue, "endReason": end.rawValue, "abort": expNN(abort),
            "phases": phases.map { ["name": $0.name, "seconds": $0.seconds, "arHz": expNN($0.arHz), "videoHz": expNN($0.videoHz),
                                     "depthHz": expNN($0.depthHz), "arEvents": $0.arEvents, "avEvents": $0.avEvents] },
            "events": ev.map { ["source": $0.source, "kind": $0.kind, "detail": $0.detail, "host": $0.hostTime] },
            "avSetup": ["permissionDenied": avSetup.permissionDenied, "deviceFound": avSetup.deviceFound, "formatsPresent": avSetup.formatsPresent,
                        "outputConnected": avSetup.outputConnected, "error": expNN(avSetup.error), "format": expNN(avSetup.chosen?.label)],
            "thresholds": ["keepRatio": ExpCoexist.keepRatio, "minHz": ExpCoexist.minHz, "note": "잠정 기준"],
            "baselineNote": baselineNote
        ]
        d["coexistVerdict"] = expNN(coexist?.label)
        d["coexistOK"] = expNN(coexist.map { $0.isCoexists })
        d["depthVideoSync"] = expNN(depthSync?.label)
        d["poseVideoSync"] = expNN(poseSync?.label)
        return ExpCoexistResult(text: text, dictionary: d, coexist: coexist, poseVideoSync: poseSync, depthVideoSync: depthSync, endReason: end, phases: phases)
    }
}

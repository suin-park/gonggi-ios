import Foundation
import simd

/// 진행 상황(화면 표시용).
struct SGSProgress: Equatable {
    var stage: Int
    var stageName: String
    var detail: String
    var fraction: Double            // 단계 안 진행(0...1)
    var elapsed: Double             // 전체 경과(초)
    var stageElapsed: Double
    var stageETA: Double?           // 이 단계 남은 시간 추정(초): 지금까지의 속도로 계산
    var thermal: String
    var memoryMB: Double
    var resumed: Bool
}

/// 촬영 후 매끈한 표면 3DGS 전체 실행. 백그라운드 스레드에서 run()을 부른다.
/// 단계: 0 읽기 → 1 포즈·지도 맞춤(posejoint) → 2 표면(prep_start) → 3 매끈한 표면 학습(nc) → 4 포즈 다시 맞춤·원뿔·색 평활 준비 → 5 화질 보정 학습(shtvpc) → 6 저장.
/// 1~3단계 결과는 작업 폴더에 남겨, 중간에 멈춰도 같은 설정이면 끝난 단계부터 이어 한다(반복 도중 상태는 저장하지 않는다).
final class SGSPipeline {
    static let stageNames = ["사진·지도 읽기", "포즈·지도 맞춤", "표면 만들기", "매끈한 표면 학습", "포즈 다시 맞춤·준비", "화질 보정 학습", "저장"]

    let source: GSOStore.Item
    let settings: SGSSettings
    private let isCancelled: () -> Bool
    private let report: (SGSProgress) -> Void
    private let t0 = CFAbsoluteTimeGetCurrent()
    private var stageStart = CFAbsoluteTimeGetCurrent()
    private var stage = 0
    private var stageRecords: [[String: Any]] = []
    private var thermalLog: [[String: Any]] = []
    private var lastThermal = ""
    private var pausedSeconds = 0.0
    private var peakMB = 0.0
    private var lastReport = 0.0
    private var resumedStages: [String] = []
    private var notes: [String] = []

    enum RunError: Error, LocalizedError {
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "멈췄어요. 끝난 단계는 저장돼 있어 같은 설정으로 다시 시작하면 이어서 해요."
            case .failed(let s): return s
            }
        }
    }

    init(source: GSOStore.Item, settings: SGSSettings, isCancelled: @escaping () -> Bool, report: @escaping (SGSProgress) -> Void) {
        self.source = source; self.settings = settings; self.isCancelled = isCancelled; self.report = report
    }

    // MARK: 진행·열·메모리

    private func now() -> Double { CFAbsoluteTimeGetCurrent() - t0 }

    private func sampleSystem() {
        let th = ExpSys.thermal
        if th != lastThermal { thermalLog.append(["t": now(), "state": th]); lastThermal = th }
        if let m = ExpSys.footprintMB() { peakMB = max(peakMB, m) }
    }

    /// 매우 뜨거우면(critical) 식을 때까지 쉰다. 쉰 시간은 따로 기록한다.
    private func thermalGate() throws {
        while ProcessInfo.processInfo.thermalState == .critical {
            if isCancelled() { throw RunError.cancelled }
            post(detail: "기기가 매우 뜨거워 식을 때까지 쉬는 중", fraction: nil, force: true)
            Thread.sleep(forTimeInterval: 5)
            pausedSeconds += 5
            sampleSystem()
        }
    }

    private var lastFraction = 0.0
    private func post(detail: String, fraction: Double?, force: Bool = false) {
        let t = now()
        if !force && t - lastReport < 0.25 { return }
        lastReport = t
        sampleSystem()
        if let f = fraction { lastFraction = f }
        let se = CFAbsoluteTimeGetCurrent() - stageStart
        let eta: Double? = lastFraction > 0.02 ? se / lastFraction * (1 - lastFraction) : nil
        report(SGSProgress(stage: stage, stageName: SGSPipeline.stageNames[stage], detail: detail, fraction: lastFraction, elapsed: t, stageElapsed: se,
                           stageETA: eta, thermal: ExpSys.thermal, memoryMB: ExpSys.footprintMB() ?? 0, resumed: !resumedStages.isEmpty))
    }

    private func begin(_ s: Int) {
        stage = s; stageStart = CFAbsoluteTimeGetCurrent(); lastFraction = 0
        post(detail: "시작", fraction: 0, force: true)
    }

    private func finish(_ s: Int, timer: SGSTimer?, iterations: Int, extra: [String: Any] = [:], resumed: Bool = false) {
        var r: [String: Any] = ["stage": s, "name": SGSPipeline.stageNames[s], "seconds": CFAbsoluteTimeGetCurrent() - stageStart, "iterations": iterations, "resumedFromCheckpoint": resumed]
        if let tm = timer {
            let snap = tm.snapshot()
            r["secondsBy"] = snap.sums
            if !snap.iterMs.isEmpty {
                let s = snap.iterMs.sorted()
                r["iterationMs"] = ["p50": s[s.count / 2], "p95": s[min(s.count - 1, Int(Double(s.count) * 0.95))], "mean": s.reduce(0, +) / Double(s.count), "count": s.count]
            }
        }
        for (k, v) in extra { r[k] = v }
        r["thermalAtEnd"] = ExpSys.thermal
        stageRecords.append(r)
    }

    private func checkCancel() throws { if isCancelled() { throw RunError.cancelled } }

    // MARK: 실행

    func run() throws -> URL {
        // 0) 읽기
        begin(0)
        let loaded: GSOLoadedSpace
        do { loaded = try GSOStore.load(url: source.url) } catch { throw RunError.failed("저장 지도(.kmogs)를 읽지 못했어요: \(error.localizedDescription)") }
        let map0 = GSOGaussians(persisted: loaded.persisted)
        guard map0.count > 0 else { throw RunError.failed("저장 지도에 가우시안이 없어요.") }
        guard let rurl = source.replayURL else { throw RunError.failed("재생 자료(.kmoreplay)가 없어요. 촬영 화면에서 '연구 기록'을 켜고 촬영·저장한 결과만 쓸 수 있어요.") }
        let fs: SGSFrameSet
        do {
            fs = try SGSFrameSet(url: rurl, mode: settings.mode, trainWidth: settings.trainWidth, poseWidth: settings.poseWidth, mapViewIDs: Set(loaded.cameras.map { $0.id }),
                                 progress: { [weak self] d, n in self?.post(detail: "사진 읽는 중 \(d)/\(n)", fraction: Double(d) / Double(max(1, n))) }, isCancelled: isCancelled)
        } catch { throw RunError.failed(error.localizedDescription) }
        try checkCancel()
        notes += fs.notes
        let base = SGSStore.baseName(source: source, trainW: fs.trainW)
        let work = SGSStore.workDir(base: base)
        let fp = settings.fingerprint(trainW: fs.trainW) + "-f\(fs.count)-g\(map0.count)"
        try prepareWork(work, fingerprint: fp)
        finish(0, timer: nil, iterations: 0, extra: ["frames": fs.count, "hi": "\(fs.hiW)x\(fs.hiH)", "train": "\(fs.trainW)x\(fs.trainH)", "pose": "\(fs.poseW)x\(fs.poseH)",
                                                     "trainImagesInMemory": fs.cacheAll, "mapGaussians": map0.count, "segment": fs.segment])

        // 1) 포즈·지도 맞춤
        begin(1)
        var joint: GSOGaussians
        let jointURL = work.appendingPathComponent("joint.bin"), jposeURL = work.appendingPathComponent("poses_joint.json")
        if let d = try? Data(contentsOf: jointURL), let m = SGSStore.decode(d), let pd = try? Data(contentsOf: jposeURL), restorePoses(pd, into: fs) {
            joint = m.g; resumedStages.append("joint")
            finish(1, timer: nil, iterations: 0, resumed: true)
        } else {
            let tm = SGSTimer()
            let fit = SGSMapFit(map0)
            let rounds = max(1, settings.jointRounds), per = max(1, settings.jointIterations / rounds)
            var rng = SGSRandom(seed: settings.seed)
            let unitsPerRound = Double(fs.count + per)
            var poseStats: [[String: Any]] = []
            for r in 0..<rounds {
                var rot: [Double] = [], tr: [Double] = []
                for i in 0..<fs.count {
                    try checkCancel(); try thermalGate()
                    let f = fs.frames[i]
                    let res = tm.measure("pose") { SGSPose.refine(target: f.poseRGB, idx: f.poseIdx, cam0: fs.camera(i, width: fs.poseW, height: fs.poseH), gaussians: fit.g, stopOnSmallStep: true) }
                    fs.applyDelta(i, res.delta)
                    rot.append(norm3(res.delta, 0) * 180 / Double.pi)
                    tr.append(norm3(res.delta, 3) * 1000)
                    post(detail: "라운드 \(r + 1)/\(rounds) · 사진 포즈 맞춤 \(i + 1)/\(fs.count)", fraction: (Double(r) * unitsPerRound + Double(i + 1)) / (Double(rounds) * unitsPerRound))
                }
                poseStats.append(["round": r + 1, "rotDegMedian": median(rot), "transMMMedian": median(tr)])
                fit.resetAdam()
                var order: [Int] = []
                for it in 0..<per {
                    try checkCancel(); try thermalGate()
                    if order.isEmpty { order = rng.permutation(fs.count) }
                    let i = order.removeLast()
                    let ti = CFAbsoluteTimeGetCurrent()
                    guard let tg = tm.measure("decode", { fs.trainTarget(i) }) else { continue }
                    let t = tm.measure("targets") { SGSTargets.make(rgb: tg.rgb, mask: tg.mask, width: fs.trainW, height: fs.trainH, mode: settings.mode) }
                    fit.step(camera: fs.trainCamera(i), targets: t, timer: tm)
                    tm.iteration((CFAbsoluteTimeGetCurrent() - ti) * 1000)
                    post(detail: "라운드 \(r + 1)/\(rounds) · 지도 맞춤 \(it + 1)/\(per)", fraction: (Double(r) * unitsPerRound + Double(fs.count + it + 1)) / (Double(rounds) * unitsPerRound))
                }
            }
            joint = fit.g
            try? SGSStore.write(SGSStore.encode(gaussians: joint), jointURL)
            try? SGSStore.write(posesData(fs), jposeURL)
            finish(1, timer: tm, iterations: rounds * per, extra: ["poseRounds": poseStats])
        }

        // 2) 표면
        begin(2)
        var start: SGSModel
        let startURL = work.appendingPathComponent("surfels_start.bin")
        var surfaceStats: [String: Any] = [:]
        if let d = try? Data(contentsOf: startURL), let m = SGSStore.decode(d) {
            start = m; resumedStages.append("surface")
            finish(2, timer: nil, iterations: 0, resumed: true)
        } else {
            let tm = SGSTimer()
            var views: [SGSSurface.DepthView] = []
            for i in 0..<fs.count {
                try checkCancel()
                let c = fs.camera(i, width: fs.w640, height: fs.h640)
                let st = tm.measure("depth_render") { GSORaster.forward(joint, camera: c, rules: .display) }
                var z = [Float](repeating: 0, count: c.width * c.height)
                let mk = fs.frames[i].mask640
                for p in 0..<z.count {
                    let a = 1 - st.transmittance[p]
                    if a > 0.5 && mk[p] != 0 { z[p] = st.depth[p] / max(a, 1e-3) }
                }
                views.append(SGSSurface.DepthView(cam: c, z: z, rgb: fs.frames[i].rgb640))
                post(detail: "지도 깊이 \(i + 1)/\(fs.count)", fraction: 0.3 * Double(i + 1) / Double(fs.count))
            }
            post(detail: "표면 융합·원반 배치 중", fraction: 0.35, force: true)
            let visTol: Float = settings.mode == .product ? 0.006 : 1.5 * settings.voxel
            guard let res = SGSSurface.build(views: views, voxel: settings.voxel, depthMax: settings.depthTrunc, targetCount: settings.surfels, visTol: visTol,
                                             mode: settings.mode, timer: tm, isCancelled: isCancelled) else {
                try checkCancel()
                throw RunError.failed("표면을 만들지 못했어요(지도 깊이가 부족하거나 표면 점이 너무 적어요).")
            }
            start = SGSModel(g: res.gaussians, spacing: res.spacing)
            surfaceStats = res.stats
            try? SGSStore.write(SGSStore.encode(start), startURL)
            finish(2, timer: tm, iterations: 0, extra: ["surface": res.stats])
        }

        // 3) 매끈한 표면 학습(nc)
        begin(3)
        var nc: SGSModel
        let ncURL = work.appendingPathComponent("nc.bin")
        if let d = try? Data(contentsOf: ncURL), let m = SGSStore.decode(d) {
            nc = m; resumedStages.append("nc")
            finish(3, timer: nil, iterations: 0, resumed: true)
        } else {
            let tm = SGSTimer()
            let fit = SGSSurfelFit(model: start, mode: settings.mode, lambda: settings.ncLambda, useSH: false, useTV: false, useCone: false, frames: fs.count)
            let iters = settings.ncIterations, ncStart = iters / 4
            var rng = SGSRandom(seed: settings.seed &+ 1)
            var order: [Int] = []
            var trace: [[String: Any]] = []
            for it in 0..<iters {
                try checkCancel(); try thermalGate()
                if order.isEmpty { order = rng.permutation(fs.count) }
                let i = order.removeLast()
                let ti = CFAbsoluteTimeGetCurrent()
                guard let tg = tm.measure("decode", { fs.trainTarget(i) }) else { continue }
                let t = tm.measure("targets") { SGSTargets.make(rgb: tg.rgb, mask: tg.mask, width: fs.trainW, height: fs.trainH, mode: settings.mode) }
                let info = fit.step(frame: i, camera: fs.trainCamera(i), targets: t, useNormal: settings.ncLambda > 0 && it >= ncStart, logNormal: it % 100 == 0, timer: tm)
                tm.iteration((CFAbsoluteTimeGetCurrent() - ti) * 1000)
                if it % 100 == 0 { trace.append(["it": it, "loss": info.loss, "normalLoss": info.normalLoss, "angleDeg": info.angleDeg]) }
                post(detail: "반복 \(it + 1)/\(iters)" + (it >= ncStart ? " · 법선 일치 켬" : " · 법선 일치는 \(ncStart)회부터"), fraction: Double(it + 1) / Double(iters))
            }
            nc = fit.model
            try? SGSStore.write(SGSStore.encode(nc), ncURL)
            finish(3, timer: tm, iterations: iters, extra: ["ncStart": ncStart, "trace": trace])
        }

        // 4) 포즈 다시 맞춤(시작 원반 지도 기준, 8회) → 시야 원뿔 → 이웃·λ_TV
        begin(4)
        let tmPrep = SGSTimer()
        var rot2: [Double] = [], tr2: [Double] = []
        for i in 0..<fs.count {
            try checkCancel(); try thermalGate()
            let f = fs.frames[i]
            let res = tmPrep.measure("pose") { SGSPose.refine(target: f.poseRGB, idx: f.poseIdx, cam0: fs.camera(i, width: fs.poseW, height: fs.poseH), gaussians: nc.g, iterations: 8, stopOnSmallStep: false) }
            fs.applyDelta(i, res.delta)
            rot2.append(norm3(res.delta, 0) * 180 / Double.pi)
            tr2.append(norm3(res.delta, 3) * 1000)
            post(detail: "사진 포즈 다시 맞춤 \(i + 1)/\(fs.count)", fraction: 0.6 * Double(i + 1) / Double(fs.count))
        }
        let fit = SGSSurfelFit(model: nc, mode: settings.mode, lambda: settings.ncLambda, useSH: true, useTV: true, useCone: true, frames: fs.count)
        post(detail: "시야 원뿔 계산 중", fraction: 0.65, force: true)
        let coneTol: Float = settings.mode == .product ? 0.004 : settings.voxel
        tmPrep.measure("cones") { fit.buildCones(cameras: (0..<fs.count).map { fs.camera($0, width: fs.w640, height: fs.h640) }, tol: coneTol) }
        try checkCancel()
        post(detail: "색 평활 이웃 찾는 중", fraction: 0.8, force: true)
        tmPrep.measure("neighbours") { fit.buildNeighbours() }
        var samples: [(cam: GSOCamera, targets: SGSTargets)] = []
        for i in stride(from: 0, to: fs.count, by: 5).prefix(20) {
            if let tg = fs.trainTarget(i) { samples.append((fs.trainCamera(i), SGSTargets.make(rgb: tg.rgb, mask: tg.mask, width: fs.trainW, height: fs.trainH, mode: settings.mode))) }
        }
        tmPrep.measure("tv_calibration") { fit.calibrateTV(samples: samples) }
        samples = []
        let coneDeg: [Double] = fit.model.coneR.map { Double($0) * 180 / Double.pi }.sorted()
        finish(4, timer: tmPrep, iterations: 0, extra: ["poseRotDegMedian": median(rot2), "poseTransMMMedian": median(tr2), "lamTV": fit.lamTV,
                                                      "coneDegP10P50P90": pick3(coneDeg)])

        // 5) 화질 보정 학습(shtvpc)
        begin(5)
        let tm5 = SGSTimer()
        var rng5 = SGSRandom(seed: settings.seed &+ 11)
        var order5: [Int] = []
        var trace5: [[String: Any]] = []
        let iters5 = settings.appearIterations
        for it in 0..<iters5 {
            try checkCancel(); try thermalGate()
            if order5.isEmpty { order5 = rng5.permutation(fs.count) }
            let i = order5.removeLast()
            let ti = CFAbsoluteTimeGetCurrent()
            guard let tg = tm5.measure("decode", { fs.trainTarget(i) }) else { continue }
            let t = tm5.measure("targets") { SGSTargets.make(rgb: tg.rgb, mask: tg.mask, width: fs.trainW, height: fs.trainH, mode: settings.mode) }
            let info = fit.step(frame: i, camera: fs.trainCamera(i), targets: t, useNormal: settings.ncLambda > 0, logNormal: false, timer: tm5)
            if it % 50 == 0 { SGSExposure.regauge(&fit.exposure) }
            tm5.iteration((CFAbsoluteTimeGetCurrent() - ti) * 1000)
            if it % 100 == 0 { trace5.append(["it": it, "loss": info.loss, "normalLoss": info.normalLoss, "angleDeg": info.angleDeg]) }
            post(detail: "반복 \(it + 1)/\(iters5)", fraction: Double(it + 1) / Double(iters5))
        }
        let gains: [Double] = fit.exposure.map { Double($0.gain.x + $0.gain.y + $0.gain.z) / 3 }.sorted()
        finish(5, timer: tm5, iterations: iters5, extra: ["trace": trace5, "exposureGainP5P50P95": pick3(gains, lo: 0.05, hi: 0.95)])

        // 6) 저장
        begin(6)
        let out = SGSStore.output(base: base)
        try save(model: fit.model, exposure: fit.exposure, lamTV: fit.lamTV, fs: fs, to: out, surfaceStats: surfaceStats)
        post(detail: "저장했어요", fraction: 1, force: true)
        return out
    }

    // MARK: 작업 폴더·저장

    private func prepareWork(_ work: URL, fingerprint fp: String) throws {
        let fm = FileManager.default
        try SGSStore.ensure()
        let fpURL = work.appendingPathComponent("fingerprint.txt")
        if let old = try? String(contentsOf: fpURL, encoding: .utf8), old != fp { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fp.write(to: fpURL, atomically: true, encoding: .utf8)
    }

    private func posesData(_ fs: SGSFrameSet) -> Data {
        SGSStore.encodeCameras(fs.frames.map { (id: $0.id, cam: $0.camera) })
    }

    private func restorePoses(_ d: Data, into fs: SGSFrameSet) -> Bool {
        guard let recs = GSOCameraFile.read(d), recs.count == fs.count else { return false }
        for (i, r) in recs.enumerated() {
            guard r.id == fs.frames[i].id else { return false }
            fs.setCamera(i, rcw: r.pose.rot.transpose, center: r.pose.center)
        }
        return true
    }

    private func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }

    /// 정렬된 값의 아래·가운데·위 분위(기본 10%·50%·90%).
    private func pick3(_ s: [Double], lo: Double = 0.1, hi: Double = 0.9) -> [Double] {
        if s.isEmpty { return [] }
        let n = s.count - 1
        return [s[Int(Double(n) * lo)], s[n / 2], s[Int(Double(n) * hi)]]
    }

    private func norm3(_ p: [Double], _ o: Int) -> Double {
        let a = p[o], b = p[o + 1], c = p[o + 2]
        return (a * a + b * b + c * c).squareRoot()
    }

    private func timingObject(fs: SGSFrameSet) -> [String: Any] {
        ["appVersion": GonggiBuildInfo.versionLine, "buildSHA": GonggiBuildInfo.buildSHA, "machine": ExpSys.machine,
         "source": source.url.lastPathComponent, "mode": settings.mode.rawValue,
         "totalSeconds": now(), "thermalPausedSeconds": pausedSeconds, "peakMemoryMB": peakMB, "thermalLog": thermalLog,
         "frames": fs.count, "train": "\(fs.trainW)x\(fs.trainH)", "hi": "\(fs.hiW)x\(fs.hiH)", "trainImagesInMemory": fs.cacheAll,
         "resumedStages": resumedStages, "stages": stageRecords, "notes": notes,
         "caution": "기기 실측 시간이다. 단계 사이 화면 꺼짐·앱 전환은 포함되지 않거나 시간을 늘릴 수 있다. 화질 지표는 재지 않았다."]
    }

    private func save(model m: SGSModel, exposure: [SGSExposure], lamTV: Float, fs: SGSFrameSet, to url: URL, surfaceStats: [String: Any]) throws {
        try SGSStore.ensure()
        let base = url.deletingPathExtension()
        let w = try SV2ContainerWriter(url: url)
        var mf: [String: Any] = [:]
        mf["format"] = "kmsgs 1: surfels.bin(SGS1: 원반마다 위치·log-scale(두께 축 고정)·쿼터니언·c0·불투명도 logit·방향별 색 3×3·시야 원뿔(중심, 반지름 rad))"
        mf["mode"] = settings.mode.rawValue
        mf["source"] = source.url.lastPathComponent
        mf["replay"] = source.replayURL?.lastPathComponent ?? NSNull()
        mf["appVersion"] = GonggiBuildInfo.versionLine; mf["buildSHA"] = GonggiBuildInfo.buildSHA; mf["machine"] = ExpSys.machine
        mf["surfels"] = m.count; mf["spacingMM"] = m.spacing * 1000; mf["lamTV"] = lamTV
        mf["train"] = "\(fs.trainW)x\(fs.trainH)"; mf["frames"] = fs.count
        if let d = try? JSONEncoder().encode(settings), let o = try? JSONSerialization.jsonObject(with: d) { mf["settings"] = o }
        mf["surface"] = surfaceStats
        mf["render"] = "색 = clip(c0 + C1·d), d = 원반을 향한 시선 방향을 시야 원뿔 안으로 제한. 노출은 항등. GSORaster 규칙 display."
        mf["pipeline"] = "posejoint(포즈 LM 320폭 ↔ 지도 맞춤, \(settings.jointRounds)라운드 × \(settings.jointIterations / max(1, settings.jointRounds))회) → TSDF \(settings.voxel * 1000) mm 표면 → 원반 \(settings.surfels)개 목표 → nc \(settings.ncIterations)회(λ \(settings.ncLambda), \(settings.ncIterations / 4)회부터) → 포즈 다시 맞춤 → shtvpc \(settings.appearIterations)회"
        mf["verified"] = "PC 검증은 제품(test_09·test_05), 학습 640×480에서만 했다. 공간·640 초과 해상도·이 앱 구현의 화질은 검증하지 않았다."
        mf["differencesFromPC"] = ["표면: Open3D 메시·Taubin·포아송 디스크 대신 TSDF 0 교차점·이웃 법선 평균·격자 균등 표본", "시작 원반 관측: 메시 광선 대신 시작 원반 렌더 깊이",
                                   "포즈 맞춤 라운드: 누적 보정량 대신 현재 포즈 기준 보정량(같은 목적 함수)", "학습 시점: 보류(held-out) 없이 모든 사진", "난수 순서: numpy와 다름"]
        mf["notes"] = notes
        do {
            try w.add("manifest.json", try JSONSerialization.data(withJSONObject: expJSONSafe(mf), options: [.sortedKeys, .prettyPrinted]))
            try w.add("surfels.bin", SGSStore.encode(m))
            try w.add("cameras.json", SGSStore.encodeCameras((0..<fs.count).map { (id: fs.frames[$0].id, cam: fs.trainCamera($0)) }))
            let ex: [[String: Any]] = exposure.map { ["gain": [$0.gain.x, $0.gain.y, $0.gain.z], "bias": [$0.bias.x, $0.bias.y, $0.bias.z]] }
            try w.add("exposure.json", try JSONSerialization.data(withJSONObject: expJSONSafe(ex), options: []))
            finish(6, timer: nil, iterations: 0)
            let tj = try JSONSerialization.data(withJSONObject: expJSONSafe(timingObject(fs: fs)), options: [.sortedKeys, .prettyPrinted])
            try w.add("timing.json", tj)
            try w.finish()
            try tj.write(to: URL(fileURLWithPath: base.path + ".timing.json"), options: .atomic)
        } catch { w.abort(); throw RunError.failed("저장 실패: \(error.localizedDescription)") }
        try? SGSStore.ply(m).write(to: URL(fileURLWithPath: base.path + ".ply"), options: .atomic)
        try? summaryText(fs: fs, model: m).write(to: URL(fileURLWithPath: base.path + ".summary.txt"), atomically: true, encoding: .utf8)
    }

    private func summaryText(fs: SGSFrameSet, model m: SGSModel) -> String {
        func fmt(_ s: Double) -> String { s >= 3600 ? String(format: "%.1f시간", s / 3600) : (s >= 60 ? String(format: "%.1f분", s / 60) : String(format: "%.1f초", s)) }
        var t = "매끈한 표면 3DGS (촬영 후 처리) — \(settings.mode.label)\n"
        t += "원본: \(source.url.lastPathComponent) · 사진 \(fs.count)장 · 원본 \(fs.hiW)×\(fs.hiH) · 학습 \(fs.trainW)×\(fs.trainH)" + (fs.cacheAll ? "" : " (학습 사진을 매번 JPEG에서 다시 풂)") + "\n"
        t += "기기 \(ExpSys.machine) · \(GonggiBuildInfo.versionLine)\n"
        t += "총 \(fmt(now())) (열 때문에 쉰 시간 \(fmt(pausedSeconds))) · 메모리 최고 \(Int(peakMB)) MB\n\n단계별\n"
        for r in stageRecords {
            let name = r["name"] as? String ?? "", sec = r["seconds"] as? Double ?? 0, it = r["iterations"] as? Int ?? 0
            var line = "  \(name): \(fmt(sec))"
            if it > 0 { line += " · 반복 \(it)회" }
            if let im = r["iterationMs"] as? [String: Any], let p50 = im["p50"] as? Double { line += String(format: " · 반복당 중앙값 %.0f ms", p50) }
            if (r["resumedFromCheckpoint"] as? Bool) == true { line += " (이전 실행 결과를 이어 씀)" }
            t += line + "\n"
            if let by = r["secondsBy"] as? [String: Double], !by.isEmpty {
                let top = by.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(fmt($0.value))" }.joined(separator: ", ")
                t += "    가장 오래 걸린 계산: \(top)\n"
            }
        }
        t += "\n결과: 원반 \(m.count)개 · 간격 \(String(format: "%.1f", m.spacing * 1000)) mm\n"
        t += "주의: PC 검증은 제품·학습 640×480에서만 했다. 공간·고해상도·이 구현의 화질은 검증 전이다. 시간은 이 기기에서 잰 값이다.\n"
        if !notes.isEmpty { t += "메모: " + notes.joined(separator: " ") + "\n" }
        return t
    }
}

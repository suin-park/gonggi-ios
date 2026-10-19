import Foundation
import ARKit
import simd

struct GSOOptions: Equatable {
    var showCamera = false          // 명시적 비교 옵션: 라이브 화면에 카메라 영상 배경(복원 품질 평가에 쓰지 않는다)
    var recordReplay = false        // 연구 기록: 재생용 입력(원본 영상 포함)을 용량 상한 안에서 저장
    var includeTemporary = true
    var optimize = true             // 촬영 중 가우시안 최적화(끄면 밀집 깊이 초기화만)
    var geometryOptimization = true // 끄면 색·불투명도만
    var useMono = true
}

/// 화면에 보여 줄 실시간 값(약 4Hz).
struct GSOLive {
    var elapsed: Double = 0
    var arHz: Double?
    var tracking = "—"
    var segment = 0
    var keyframes = 0
    var processed = 0
    var droppedBusy = 0
    var blurRejected = 0
    var queueLen = 0
    var keyframeHz: Double?
    var toMapP50: Double?, toMapP95: Double?
    var toPublishP50: Double?, toPublishP95: Double?
    var toDisplayP50: Double?, toDisplayP95: Double?
    var stageMs: [String: Double] = [:]
    var gaussians = 0
    var temporary = 0, candidate = 0, stable = 0
    var lastInserted = 0
    var lastAnchors = 0
    var lastFitInlier: Double?
    var lastFitConfidence: Double?
    var lastDenseSource = "—"
    var monoReady = false
    var monoStatus = ""
    var optIterations = 0
    var optPerSecond: Double?
    var lossStart: Double?, lossEnd: Double?
    var rollbacks = 0
    var coverage: Double?
    var optMs: [String: Double] = [:]
    var footprintMB: Double?
    var thermal = ""
    var governor = 0
    var hint = ""
    var depthStatus = "표면을 찾는 중"
    var firstInputS: Double?
    var firstAlignedS: Double?
    var firstCandidateS: Double?
    var firstStableS: Double?
    var firstDisplayS: Double?
    var replayFrames = 0
    var replayBytes = 0
    var paused = false
    var optimizing = true
}

/// 기기 내 가우시안 최적화 엔진. 하나의 ARSession → 같은 ARFrame의 영상·포즈·K·시각 → GSOPipeline(스테레오 앵커 + 단안 깊이 정렬 → 지속적인 가우시안 지도 → 렌더링 오차 최적화)
/// → 가우시안 렌더(V1 Metal 렌더러 재사용). 서버를 쓰지 않는다. 사전학습 깊이 모델은 기기 내 추론만 한다(재학습 없음). 촬영 중 가우시안을 반복 최적화한다(장면별 최적화).
final class GSOEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    let splats: RTSharedSplats
    let liveCam: RTLiveCameraStore
    let background: RTBackgroundStore
    var onLive: ((GSOLive) -> Void)?
    var onAutoStop: ((ExpEndReason) -> Void)?

    private(set) var options: GSOOptions
    let config: GSOConfig
    var log: ExperimentRunLog?
    private let arQueue = DispatchQueue(label: "gonggi.gso.ar", qos: .userInteractive)
    private let procQueue = DispatchQueue(label: "gonggi.gso.process", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "gonggi.gso.monitor", qos: .utility)
    private let loadQueue = DispatchQueue(label: "gonggi.gso.model", qos: .utility)

    // MARK: AR 쪽 상태 (arLock)
    private let arLock = NSLock()
    private var arTimes = ExpRateMeter()
    private var kfTimes = ExpRateMeter()
    private var received = 0
    private var keyframesAccepted = 0
    private var policyRejects: [String: Int] = [:]
    private var droppedBusy = 0
    private var trackingText = "—"
    private var segment = 0
    private var segmentsCreated = 1
    private var notNormalSince: Double?
    private var lastFrameTs: Double?
    private var lastFramePose: RTPose?
    private var policy = RTKeyframePolicy()
    private var lastKF: RTKeyframePolicy.Last?
    private var prev: RTKeyframePolicy.Last?
    private var lastBackgroundHost: Double = 0
    private var inFlight = false
    private var pending: SV2Engine.Job?
    private var kfCounter = 0
    private var clockDelta = 0.0
    private var running = false
    private var paused = false
    private var startedHost = 0.0
    private var firstInputHost: Double?
    private var pausedTotal = 0.0
    private var pauseStart: Double?
    private var segmentEvents: [(Double, String)] = []
    private var trackingTransitions = 0

    // MARK: 처리 쪽 상태 (procQueue에서만)
    let pipeline: GSOPipeline
    private let mono = RTMonoDepth()
    private var monoLoaded = false
    private var recorder: SV2ReplayRecorder?
    private var lastPublishHost: Double = 0
    private var pendingPublishCaptures: [Double] = []
    private var versionCapture: [Int: Double] = [:]
    private var optTickScheduled = false
    private var lastOptHost: Double = 0
    private var noBaselineStreak = 0

    // MARK: 통계 상자(statLock)
    private let statLock = NSLock()
    private var records: [GSOKFRecord] = []
    private var slices: [GSOSliceRecord] = []
    private var processed = 0
    private var blurRejected = 0
    private var toMap: [Double] = []
    private var toPublish: [Double] = []
    private var toDisplay: [Double] = []
    private var displaySources: [String: Int] = [:]
    private var stageSamples: [String: [Double]] = [:]
    private var optSamples: [String: [Double]] = [:]
    private var optIterTimes: [Double] = []
    private var counts = (n: 0, temp: 0, cand: 0, stable: 0)
    private var totals = (inserted: 0, stereoInserted: 0, monoInserted: 0, pruned: 0, monoRuns: 0, iterations: 0, moved: 0, nonFinite: 0, rejectedByCap: 0)
    private var lossStartLast: Double?, lossEndLast: Double?
    private var coverageLast: Double?
    private var firstAlignedHost: Double?
    private var firstCandidateHost: Double?
    private var firstStableHost: Double?
    private var firstDisplayHost: Double?
    private var hint = ""
    private var depthStatus = "표면을 찾는 중"
    private var governorLevel = 0
    private var governorChanges: [(Double, Int, String)] = []
    private var footprintPeak = 0.0
    private var thermalSeen = Set<String>()
    private var maxQueueLen = 0
    private var renderStatsLatest: RTRenderStats?
    private var timer: DispatchSourceTimer?
    private var autoStopSent = false

    init(options: GSOOptions, config: GSOConfig = GSOConfig(), log: ExperimentRunLog? = nil, splats: RTSharedSplats = RTSharedSplats(),
         liveCam: RTLiveCameraStore = RTLiveCameraStore(), background: RTBackgroundStore = RTBackgroundStore()) {
        self.options = options
        var cfg = config
        cfg.optimize = options.optimize
        cfg.geometryOptimization = options.geometryOptimization
        cfg.useMono = options.useMono
        self.config = cfg
        self.log = log
        self.splats = splats
        self.liveCam = liveCam
        self.background = background
        pipeline = GSOPipeline(config: cfg)
        super.init()
    }

    deinit { timer?.cancel() }

    func setOptions(_ o: GSOOptions) { statLock.lock(); options = o; statLock.unlock() }
    private var currentOptions: GSOOptions { statLock.lock(); defer { statLock.unlock() }; return options }

    func noteRenderStats(_ s: RTRenderStats) { statLock.lock(); renderStatsLatest = s; statLock.unlock() }

    /// 새 장면 버전이 처음 화면에 표시된 시각. 캡처 → 실제 표시 지연을 기록한다(게시 지연과 다르다).
    func notePresented(version: Int, uptime: Double, source: String) {
        let presentHost = uptime + clockDelta
        procQueue.async { [weak self] in
            guard let self, let cap = self.versionCapture[version] else { return }
            let ms = (presentHost - cap) * 1000
            self.statLock.lock()
            self.displaySources[source, default: 0] += 1
            self.toDisplay.append(ms); if self.toDisplay.count > 2000 { self.toDisplay.removeFirst() }
            if self.firstDisplayHost == nil, self.pipeline.map.count > 0 { self.firstDisplayHost = presentHost }
            self.statLock.unlock()
            self.versionCapture[version] = nil
            if version % 8 == 0 { self.log?.write("gso_display", ["version": version, "captureToDisplayMs": ms, "timeSource": source]) }
        }
    }

    // MARK: 시작·일시정지·재개·종료

    private func makeConfig() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = []
        c.isLightEstimationEnabled = false
        let fmts = ARWorldTrackingConfiguration.supportedVideoFormats.filter {
            $0.framesPerSecond <= 30 && abs($0.imageResolution.width / $0.imageResolution.height - 4.0 / 3.0) < 0.02
        }
        if let best = fmts.max(by: { $0.imageResolution.width < $1.imageResolution.width }) { c.videoFormat = best }
        return c
    }

    func start(runDirectoryForReplay: URL? = nil) {
        arLock.lock()
        running = true; paused = false
        startedHost = ExpSys.hostNow()
        clockDelta = ExpSys.clockDelta()
        arLock.unlock()
        let cfg = makeConfig()
        if currentOptions.recordReplay, let dir = runDirectoryForReplay { recorder = SV2ReplayRecorder(directory: dir) }
        // 모델은 백그라운드에서 읽는다. 준비되기 전 키프레임은 스테레오 전용 경로로 처리한다.
        if config.useMono {
            loadQueue.async { [weak self] in
                guard let self else { return }
                let ok = self.mono.load()
                self.statLock.lock(); self.monoLoaded = ok; self.statLock.unlock()
                self.log?.write("gso_model", ["ready": ok, "status": self.mono.status, "loadMs": self.mono.loadMs, "computeUnits": self.mono.computeUnits,
                                              "model": RTMonoDepth.modelResource])
            }
        }
        var info: [String: Any] = [:]
        info["videoFormat"] = ["w": cfg.videoFormat.imageResolution.width, "h": cfg.videoFormat.imageResolution.height, "fps": cfg.videoFormat.framesPerSecond]
        info["options"] = ["showCamera": options.showCamera, "recordReplay": options.recordReplay, "includeTemporary": options.includeTemporary,
                           "optimize": options.optimize, "geometryOptimization": options.geometryOptimization, "useMono": options.useMono]
        info["config"] = ["trainWidth": config.trainWidth, "smallWidth": config.smallWidth, "maxGaussians": config.maxGaussians, "winRecent": config.winRecent,
                          "insertBudget": config.insertBudget, "lrMu": config.opt.lrMu, "lrLogScale": config.opt.lrLogScale, "lrQuat": config.opt.lrQuat,
                          "lrColor": config.opt.lrColor, "lrOpacity": config.opt.lrOpacity, "lambdaDepth": config.opt.lambdaDepth]
        info["buildSHA"] = GonggiBuildInfo.buildSHA
        info["appVersion"] = GonggiBuildInfo.versionLine
        info["machine"] = ExpSys.machine
        info["server"] = false
        info["sceneOptimization"] = true
        info["pretrainedModelInference"] = "Depth Anything V2 Small (Core ML, 기기 내 추론만, 재학습 없음)"
        info["orientation"] = "capturedImage=sensorLandscapeRight, display=portrait(app locked)"
        info["algorithm"] = "ARKit pose + stereo anchors + monocular depth aligned to anchors -> persistent gaussians -> on-device photometric optimisation (sparse Adam, CPU forward/backward)"
        log?.write("gso_start", info)
        session.delegate = self
        session.delegateQueue = arQueue
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        startMonitor()
    }

    func pause() {
        arLock.lock()
        guard running, !paused else { arLock.unlock(); return }
        paused = true; pauseStart = ExpSys.hostNow()
        pending = nil
        arLock.unlock()
        session.pause()
        procQueue.sync {}
        procQueue.sync { self.publish(force: true) }
        log?.write("gso_pause", ["gaussians": pipeline.map.count])
    }

    func resume() {
        arLock.lock()
        guard running, paused else { arLock.unlock(); return }
        paused = false
        if let ps = pauseStart { pausedTotal += ExpSys.hostNow() - ps; pauseStart = nil }
        startNewSegmentLocked(reason: "resume", host: ExpSys.hostNow())
        arLock.unlock()
        session.run(makeConfig(), options: [])
        log?.write("gso_resume", ["segment": segment])
    }

    func stop() {
        timer?.cancel(); timer = nil
        arLock.lock(); let wasRunning = running; running = false; arLock.unlock()
        guard wasRunning else { return }
        session.pause()
        session.delegate = nil
        procQueue.sync {}
        procQueue.sync { self.publish(force: true) }
        log?.write("gso_stopped", ["gaussians": pipeline.map.count])
    }

    var isPaused: Bool { arLock.lock(); defer { arLock.unlock() }; return paused }

    // MARK: ARSessionDelegate (arQueue)

    private func startNewSegmentLocked(reason: String, host: Double) {
        segment += 1
        segmentsCreated += 1
        segmentEvents.append((host, reason))
        lastKF = nil; prev = nil
        log?.write("gso_segment", ["segment": segment, "reason": reason])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let host = ExpSys.hostNow()
        let showBG = currentOptions.showCamera
        let cam = frame.camera
        let pose = RTPose.fromARKit(cam.transform)
        var normal = false
        var text = "—"
        switch cam.trackingState {
        case .normal: normal = true; text = "normal"
        case .notAvailable: text = "notAvailable"
        case .limited(let r):
            switch r {
            case .initializing: text = "limited:initializing"
            case .excessiveMotion: text = "limited:excessiveMotion"
            case .insufficientFeatures: text = "limited:insufficientFeatures"
            case .relocalizing: text = "limited:relocalizing"
            @unknown default: text = "limited:unknown"
            }
        }
        let k = cam.intrinsics
        let imgW = Float(cam.imageResolution.width), imgH = Float(cam.imageResolution.height)
        liveCam.set(RTLiveCameraStore.Value(pose: pose, fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
                                            imgW: imgW, imgH: imgH, timestamp: frame.timestamp))
        arLock.lock()
        guard running, !paused else { arLock.unlock(); return }
        received += 1
        if firstInputHost == nil { firstInputHost = host }
        arTimes.add(host)
        if trackingText != text { trackingTransitions += 1; log?.write("gso_tracking", ["state": text]) }
        trackingText = text
        if normal {
            if let since = notNormalSince, host - since >= 1.0 { startNewSegmentLocked(reason: "tracking_recovered_after_\(Int(host - since))s", host: host) }
            notNormalSince = nil
        } else if notNormalSince == nil {
            notNormalSince = host
        }
        if let lt = lastFrameTs, frame.timestamp - lt > 1.5 { startNewSegmentLocked(reason: "frame_gap", host: host) }
        if let lp = lastFramePose, let lt = lastFrameTs, frame.timestamp - lt < 0.2, simd_length(pose.center - lp.center) > 0.6 {
            startNewSegmentLocked(reason: "pose_jump", host: host)
        }
        lastFrameTs = frame.timestamp
        lastFramePose = pose
        let seg = segment
        let wantBG = showBG && host - lastBackgroundHost > 0.1
        if wantBG { lastBackgroundHost = host }

        statLock.lock(); let level = governorLevel; statLock.unlock()
        var pol = policy
        if level >= 2 { pol.minInterval *= 2 }
        let decision = pol.evaluate(timestamp: frame.timestamp, pose: pose, trackingNormal: normal, last: lastKF, prev: prev)
        prev = RTKeyframePolicy.Last(timestamp: frame.timestamp, pose: pose)
        var job: SV2Engine.Job?
        switch decision {
        case .accept:
            lastKF = RTKeyframePolicy.Last(timestamp: frame.timestamp, pose: pose)
            keyframesAccepted += 1
            kfCounter += 1
            kfTimes.add(host)
            job = SV2Engine.Job(pb: frame.capturedImage, timestamp: frame.timestamp, pose: pose,
                                K: RTIntrinsics(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y, width: Int(imgW), height: Int(imgH)),
                                segment: seg, id: kfCounter, trackingText: text, trackingNormal: normal,
                                exposureDuration: cam.exposureDuration > 0 ? cam.exposureDuration : nil, exposureOffset: Double(cam.exposureOffset))
        case .reject(let why):
            policyRejects[why, default: 0] += 1
        }
        var dispatchNow: SV2Engine.Job?
        if let job {
            if inFlight {
                if pending != nil { droppedBusy += 1 }       // 오래된 대기 작업을 버리고 최신 것만 남긴다
                pending = job
            } else {
                inFlight = true
                dispatchNow = job
            }
        }
        arLock.unlock()
        if wantBG, let bg = RTFrameConverter.downscale(frame.capturedImage, outWidth: 160) {
            background.set(rgb: bg.rgb, width: bg.width, height: bg.height)
        }
        if let j = dispatchNow { procQueue.async { [weak self] in self?.process(j) } }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let e = error as NSError
        log?.write("gso_ar_error", ["domain": e.domain, "code": e.code, "description": e.localizedDescription])
        if !autoStopSent {
            autoStopSent = true
            log?.write("auto_stop", ["reason": "ar_error", "code": e.code])
            onAutoStop?(.failed)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) { log?.write("gso_ar_interrupted") }
    func sessionInterruptionEnded(_ session: ARSession) {
        arLock.lock(); startNewSegmentLocked(reason: "ar_interruption_ended", host: ExpSys.hostNow()); arLock.unlock()
        log?.write("gso_ar_interruption_ended")
    }

    // MARK: 처리 (procQueue)

    private func finishJob() {
        arLock.lock()
        if let next = pending {
            pending = nil
            arLock.unlock()
            procQueue.async { [weak self] in self?.process(next) }
        } else {
            inFlight = false
            arLock.unlock()
            scheduleOptimize()
        }
    }

    private func process(_ job: SV2Engine.Job) {
        defer { finishJob() }
        let captureHost = job.timestamp + clockDelta
        let tStart = ExpSys.hostNow()
        // 연구 기록을 켰을 때만 960폭으로 변환한다(재생용). 기본은 320폭(깊이·훈련 해상도의 원본).
        let width = currentOptions.recordReplay ? 960 : config.smallWidth
        guard let input = SV2Engine.makeInput(job: job, hiWidth: width, clockDelta: clockDelta) else { return }
        let tConv = ExpSys.hostNow()
        recorder?.record(input)
        statLock.lock(); let monoOK = monoLoaded; statLock.unlock()
        var rec = pipeline.process(input, mono: monoOK ? mono : nil)
        rec.convertMs += (tConv - tStart) * 1000
        let tDone = ExpSys.hostNow()
        rec.toMapMs = (tDone - captureHost) * 1000
        if rec.skipped != nil {
            statLock.lock(); blurRejected += 1; statLock.unlock()
            return
        }
        let sinceStart = tDone - startedHost
        statLock.lock()
        if firstAlignedHost == nil, rec.denseSource == "mono" { firstAlignedHost = tDone }
        if firstCandidateHost == nil, rec.states[1] + rec.states[2] > 0 { firstCandidateHost = tDone }
        if firstStableHost == nil, rec.states[2] > 0 { firstStableHost = tDone }
        statLock.unlock()
        _ = sinceStart
        noBaselineStreak = (rec.refs == 0) ? noBaselineStreak + 1 : 0
        pendingPublishCaptures.append(captureHost)
        statLock.lock()
        processed += 1
        records.append(rec); if records.count > 4000 { records.removeFirst(records.count - 4000) }
        toMap.append(rec.toMapMs); if toMap.count > 2000 { toMap.removeFirst() }
        func add(_ key: String, _ v: Double) { stageSamples[key, default: []].append(v); if stageSamples[key]!.count > 600 { stageSamples[key]!.removeFirst() } }
        add("convert", rec.convertMs); add("stereo", rec.stereoMs); add("mono", rec.monoMs); add("align", rec.alignMs)
        add("insert", rec.insertMs); add("evidence", rec.evidenceMs); add("total", rec.totalMs)
        totals.inserted += rec.inserted; totals.stereoInserted += rec.insertedStereo; totals.monoInserted += rec.insertedMono
        totals.rejectedByCap += rec.rejectedByCap
        if rec.monoRan { totals.monoRuns += 1 }
        counts = (rec.count, rec.states[0], rec.states[1], rec.states[2])
        if noBaselineStreak >= 3 {
            hint = "제자리 회전만으로는 깊이를 알 수 없어요. 옆으로 천천히 이동해 주세요"
            depthStatus = "시차 부족: 아직 검증된 깊이가 없어요"
        } else {
            hint = ""
            depthStatus = rec.count == 0 ? "표면을 찾는 중" : (rec.denseSource == "mono" ? "가우시안 생성·최적화 중" : "스테레오로 생성 중(단안 정렬 대기)")
        }
        statLock.unlock()
        log?.write("gso_kf", kfLog(rec))
        publish(force: false)
    }

    private func kfLog(_ r: GSOKFRecord) -> [String: Any] {
        var d: [String: Any] = [:]
        d["id"] = r.id
        d["toMapMs"] = r.toMapMs
        d["ms"] = ["convert": r.convertMs, "stereo": r.stereoMs, "mono": r.monoMs, "align": r.alignMs, "insert": r.insertMs, "evidence": r.evidenceMs, "total": r.totalMs]
        d["refs"] = r.refs; d["anchors"] = r.anchors; d["monoRan"] = r.monoRan; d["denseSource"] = r.denseSource
        if let f = r.fit {
            d["fit"] = ["a": Double(f.a), "b": Double(f.b), "inlierRatio": Double(f.inlierRatio), "anchors": f.anchorCount, "inliers": f.inlierCount,
                        "rmsRho": Double(f.rmsRho), "coverage": Double(f.spatialCoverage), "confidence": Double(f.confidence), "carried": f.carried,
                        "space": f.space.rawValue, "alternativeInlierRatio": Double(f.alternativeInlierRatio)]
        }
        d["rawMonoRange"] = [Double(r.rawMonoMin), Double(r.rawMonoMax)]
        d["inserted"] = ["total": r.inserted, "stereo": r.insertedStereo, "mono": r.insertedMono, "rejectedByCap": r.rejectedByCap]
        d["evidence"] = ["supportCounted": r.supportCounted, "toCandidate": r.promotedCandidate, "toStable": r.promotedStable]
        d["gain"] = Double(r.gain)
        d["gaussians"] = r.count
        d["states"] = ["temporary": r.states[0], "candidate": r.states[1], "stable": r.states[2]]
        return d
    }

    // MARK: 최적화 스케줄링

    /// 지도 큐가 비어 있을 때 최적화 묶음을 이어서 실행한다. 새 키프레임이 도착하면 다음 묶음 전에 그것을 먼저 처리한다.
    private func scheduleOptimize() {
        statLock.lock()
        let level = governorLevel
        let want = options.optimize && !autoStopSent
        statLock.unlock()
        arLock.lock(); let ok = running && !paused; arLock.unlock()
        guard want, ok, level < 2, !optTickScheduled else { return }
        optTickScheduled = true
        let gap = level >= 1 ? 0.06 : 0.0
        procQueue.asyncAfter(deadline: .now() + gap) { [weak self] in self?.optimizeTick() }
    }

    private func optimizeTick() {
        optTickScheduled = false
        arLock.lock(); let busy = inFlight || pending != nil; let ok = running && !paused; arLock.unlock()
        guard ok, !busy else { return }
        statLock.lock(); let level = governorLevel; statLock.unlock()
        let iters = level >= 1 ? 4 : 8
        let now = ExpSys.hostNow()
        let s = pipeline.optimizeSlice(maxIterations: iters, deadlineHost: now + 0.045)
        if s.iterations > 0 {
            statLock.lock()
            slices.append(s); if slices.count > 600 { slices.removeFirst(slices.count - 600) }
            func add(_ k: String, _ v: Double) { optSamples[k, default: []].append(v); if optSamples[k]!.count > 600 { optSamples[k]!.removeFirst() } }
            add("forward", s.forwardMs / Double(s.iterations)); add("backward", s.backwardMs / Double(s.iterations)); add("update", s.updateMs / Double(s.iterations))
            totals.iterations += s.iterations; totals.moved += s.moved; totals.nonFinite += s.nonFinite
            optIterTimes.append(ExpSys.hostNow()); if optIterTimes.count > 400 { optIterTimes.removeFirst() }
            if s.lossStart > 0 { lossStartLast = Double(s.lossStart); lossEndLast = Double(s.lossEnd) }
            coverageLast = Double(s.coverage)
            statLock.unlock()
            log?.write("gso_opt", ["iterations": s.iterations, "forwardMs": s.forwardMs, "backwardMs": s.backwardMs, "updateMs": s.updateMs,
                                   "lossStart": Double(s.lossStart), "lossEnd": Double(s.lossEnd), "depthLoss": Double(s.depthLossEnd),
                                   "rolledBack": s.rolledBack, "nonFinite": s.nonFinite, "moved": s.moved, "active": s.activeGaussians,
                                   "wallMs": s.wallMs, "geometry": s.geometry, "governor": level, "trainViewCoverage": Double(s.coverage)])
        }
        statLock.lock(); let procCount = processed; statLock.unlock()
        if procCount % 4 == 0 || s.iterations == 0 {
            let removed = pipeline.prune()
            if removed > 0 { statLock.lock(); totals.pruned += removed; statLock.unlock() }
        }
        let sc = pipeline.map.stateCounts()
        statLock.lock(); counts = (pipeline.map.count, sc.temporary, sc.candidate, sc.stable); statLock.unlock()
        publish(force: false)
        scheduleOptimize()
    }

    // MARK: 게시

    /// 지도 변경이 있으면 렌더용 스냅샷을 만들어 넘긴다(0.25초 이상 간격). procQueue에서만 부른다.
    private func publish(force: Bool) {
        let now = ExpSys.hostNow()
        if !force && now - lastPublishHost < 0.25 { return }
        if pipeline.map.count == 0 && !force { return }
        let includeTemp = currentOptions.includeTemporary
        let set = pipeline.map.splatSet(includeTemporary: includeTemp)
        splats.publish(packed: set.pack(), count: set.count)
        let version = splats.snapshot().version
        let latest = pendingPublishCaptures.last ?? 0
        if latest > 0 {
            versionCapture[version] = latest
            if versionCapture.count > 50 { for k in versionCapture.keys.sorted().prefix(versionCapture.count - 50) { versionCapture[k] = nil } }
        }
        let pubHost = ExpSys.hostNow()
        statLock.lock()
        for c in pendingPublishCaptures where c > 0 { toPublish.append((pubHost - c) * 1000) }
        if toPublish.count > 2000 { toPublish.removeFirst(toPublish.count - 2000) }
        statLock.unlock()
        pendingPublishCaptures.removeAll()
        lastPublishHost = now
        RTViewerBounds.shared.bounds = set.bounds()
    }

    // MARK: 모니터·거버너

    private func startMonitor() {
        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            if tick % 4 == 0 { self.governorTick() }
            let live = self.liveSnapshot()
            self.onLive?(live)
            if tick % 4 == 0 { self.logHeartbeat(live) }
        }
        t.resume()
        timer = t
    }

    private func governorTick() {
        let th = ProcessInfo.processInfo.thermalState
        let fp = ExpSys.footprintMB() ?? 0
        arLock.lock()
        let now = ExpSys.hostNow()
        let recent = arTimes.times.suffix(200).filter { now - $0 <= 2 }
        let hz = recent.count > 1 ? Double(recent.count - 1) / max(recent.last! - recent.first!, 0.001) : 30
        arLock.unlock()
        statLock.lock(); let rs = renderStatsLatest; statLock.unlock()
        var level = 0
        if th == .fair || hz < 24 || (rs?.gpuMsP95 ?? 0) > 24 { level = max(level, 1) }
        if th == .serious || fp > 1900 { level = max(level, 2) }
        if th == .critical || fp > 2400 { level = 3 }
        statLock.lock()
        footprintPeak = max(footprintPeak, fp)
        thermalSeen.insert(ExpSys.thermalName(th))
        let changed = level != governorLevel
        if changed { governorChanges.append((ExpSys.hostNow(), level, "thermal=\(ExpSys.thermalName(th)) footprintMB=\(Int(fp)) arHz=\(Int(hz))")) }
        governorLevel = level
        statLock.unlock()
        if changed {
            log?.write("gso_governor", ["level": level, "thermal": ExpSys.thermalName(th), "footprintMB": fp, "arHz": hz])
            if level < 2 { procQueue.async { [weak self] in self?.scheduleOptimize() } }
        }
        if level >= 3, !autoStopSent {
            autoStopSent = true
            log?.write("auto_stop", ["reason": "thermal_or_memory", "thermal": ExpSys.thermalName(th), "footprintMB": fp])
            onAutoStop?(th == .critical ? .thermal : .failed)
        }
    }

    func liveSnapshot() -> GSOLive {
        var l = GSOLive()
        let now = ExpSys.hostNow()
        arLock.lock()
        l.elapsed = running ? (now - startedHost - pausedTotal - (pauseStart.map { now - $0 } ?? 0)) : 0
        let recent = arTimes.times.suffix(200).filter { now - $0 <= 2 }
        l.arHz = recent.count > 1 ? Double(recent.count - 1) / max(recent.last! - recent.first!, 0.001) : nil
        let kr = kfTimes.times.suffix(60).filter { now - $0 <= 5 }
        l.keyframeHz = kr.count > 1 ? Double(kr.count - 1) / max(kr.last! - kr.first!, 0.001) : nil
        l.tracking = trackingText; l.segment = segment; l.keyframes = keyframesAccepted; l.droppedBusy = droppedBusy
        l.queueLen = (inFlight ? 1 : 0) + (pending != nil ? 1 : 0)
        l.paused = paused
        let fi = firstInputHost
        arLock.unlock()
        statLock.lock()
        l.processed = processed; l.blurRejected = blurRejected
        l.toMapP50 = RTStat.percentile(toMap, 0.5); l.toMapP95 = RTStat.percentile(toMap, 0.95)
        l.toPublishP50 = RTStat.percentile(toPublish, 0.5); l.toPublishP95 = RTStat.percentile(toPublish, 0.95)
        l.toDisplayP50 = RTStat.percentile(toDisplay, 0.5); l.toDisplayP95 = RTStat.percentile(toDisplay, 0.95)
        for (k, v) in stageSamples { if let p = RTStat.percentile(v, 0.5) { l.stageMs[k] = p } }
        for (k, v) in optSamples { if let p = RTStat.percentile(v, 0.5) { l.optMs[k] = p } }
        l.gaussians = counts.n; l.temporary = counts.temp; l.candidate = counts.cand; l.stable = counts.stable
        let last = records.last
        l.lastInserted = last?.inserted ?? 0
        l.lastAnchors = last?.anchors ?? 0
        l.lastDenseSource = last?.denseSource ?? "—"
        l.lastFitInlier = last?.fit.map { Double($0.inlierRatio) }
        l.lastFitConfidence = last?.fit.map { Double($0.confidence) }
        l.monoReady = monoLoaded
        l.monoStatus = mono.status
        l.optIterations = totals.iterations
        let recentIt = optIterTimes.filter { now - $0 <= 5 }
        l.optPerSecond = recentIt.count > 1 ? Double(recentIt.count - 1) / max(recentIt.last! - recentIt.first!, 0.001) : nil
        l.lossStart = lossStartLast; l.lossEnd = lossEndLast; l.coverage = coverageLast
        l.rollbacks = pipeline.rollbacks
        l.hint = hint; l.depthStatus = depthStatus; l.governor = governorLevel
        l.optimizing = options.optimize
        l.firstInputS = fi.map { $0 - startedHost }
        l.firstAlignedS = firstAlignedHost.map { $0 - startedHost }
        l.firstCandidateS = firstCandidateHost.map { $0 - startedHost }
        l.firstStableS = firstStableHost.map { $0 - startedHost }
        l.firstDisplayS = firstDisplayHost.map { $0 - startedHost }
        maxQueueLen = max(maxQueueLen, l.queueLen)
        statLock.unlock()
        l.replayFrames = recorder?.frames ?? 0
        l.replayBytes = recorder?.bytes ?? 0
        l.footprintMB = ExpSys.footprintMB(); l.thermal = ExpSys.thermal
        return l
    }

    private func logHeartbeat(_ l: GSOLive) {
        statLock.lock(); let rs = renderStatsLatest; statLock.unlock()
        var hb: [String: Any] = [:]
        hb["elapsed"] = l.elapsed
        hb["arHz"] = expNN(l.arHz); hb["keyframeHz"] = expNN(l.keyframeHz)
        hb["tracking"] = l.tracking; hb["segment"] = l.segment
        hb["keyframes"] = l.keyframes; hb["processed"] = l.processed; hb["droppedBusy"] = l.droppedBusy; hb["blurRejected"] = l.blurRejected
        hb["queueLen"] = l.queueLen
        hb["toMapMsP50"] = expNN(l.toMapP50); hb["toMapMsP95"] = expNN(l.toMapP95)
        hb["toPublishMsP50"] = expNN(l.toPublishP50); hb["toPublishMsP95"] = expNN(l.toPublishP95)
        hb["toDisplayMsP50"] = expNN(l.toDisplayP50); hb["toDisplayMsP95"] = expNN(l.toDisplayP95)
        hb["stageMsP50"] = l.stageMs; hb["optMsP50"] = l.optMs
        hb["gaussians"] = l.gaussians
        hb["states"] = ["temporary": l.temporary, "candidate": l.candidate, "stable": l.stable]
        hb["optIterations"] = l.optIterations; hb["optPerSecond"] = expNN(l.optPerSecond)
        hb["lossStart"] = expNN(l.lossStart); hb["lossEnd"] = expNN(l.lossEnd); hb["rollbacks"] = l.rollbacks
        hb["monoReady"] = l.monoReady
        hb["depthStatus"] = l.depthStatus
        if let r = rs {
            hb["render"] = ["fps": r.fps, "cpuMsP50": r.cpuMsP50, "cpuMsP95": r.cpuMsP95, "gpuMsP50": r.gpuMsP50, "gpuMsP95": r.gpuMsP95,
                            "drawn": r.drawn, "total": r.total, "visible": r.visible, "dropped": r.dropped, "sortMsP50": r.sortMsP50]
        }
        hb["footprintMB"] = expNN(l.footprintMB); hb["thermal"] = l.thermal; hb["governor"] = l.governor
        hb["replay"] = ["frames": l.replayFrames, "bytes": l.replayBytes]
        log?.write("gso_hb", hb)
    }

    // MARK: 저장

    /// 지도를 .kmogs(본체) + 호환 PLY/.state + 메타 + 요약(+재생 자료)으로 저장한다. 가우시안이 없으면 저장하지 않는다.
    func save(summaryText: String) -> GSOSaveResult {
        var out = GSOSaveResult(item: nil, error: nil, gaussians: 0, views: 0)
        procQueue.sync {
            let views = pipeline.views.map { GSOCameraRecord(id: $0.id, pose: $0.camera.pose, k: $0.camera.intrinsics, timestamp: $0.timestamp) }
            let req = GSOSaver.Request(map: pipeline.map, views: views, runId: log?.baseName, config: config, summaryText: summaryText, recorder: recorder)
            out = GSOSaver.save(req)
            if out.error == nil { recorder = nil }
        }
        return out
    }

    // MARK: 요약

    func summary(endReason: ExpEndReason, render: RTRenderStats?) -> (text: String, dict: [String: Any]) {
        let l = liveSnapshot()
        arLock.lock()
        let recv = received, kfs = keyframesAccepted, rejects = policyRejects, dropped = droppedBusy, segs = segmentsCreated
        let events = segmentEvents.map { "\($0.1)" }, trans = trackingTransitions
        arLock.unlock()
        statLock.lock()
        let recs = records, tm = toMap, tp = toPublish, td = toDisplay, sl = slices
        let fp = footprintPeak, th = Array(thermalSeen).sorted(), gov = governorChanges, proc = processed, blur = blurRejected, mq = maxQueueLen
        let tot = totals, dsrc = displaySources, cp = firstCandidateHost, st = firstStableHost
        var stage: [String: Double] = [:], stage95: [String: Double] = [:]
        for (k, v) in stageSamples { stage[k] = RTStat.percentile(v, 0.5) ?? 0; stage95[k] = RTStat.percentile(v, 0.95) ?? 0 }
        var opt: [String: Double] = [:], opt95: [String: Double] = [:]
        for (k, v) in optSamples { opt[k] = RTStat.percentile(v, 0.5) ?? 0; opt95[k] = RTStat.percentile(v, 0.95) ?? 0 }
        statLock.unlock()
        func f(_ v: Double?, _ d: Int = 0) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }
        let p50 = RTStat.percentile(tm, 0.5), p95 = RTStat.percentile(tm, 0.95)
        let q50 = RTStat.percentile(tp, 0.5), q95 = RTStat.percentile(tp, 0.95)
        let d50 = RTStat.percentile(td, 0.5), d95 = RTStat.percentile(td, 0.95)
        let lossA = sl.filter { $0.lossStart > 0 }
        let lossFirst = lossA.prefix(10).map { Double($0.lossStart) }, lossLast = lossA.suffix(10).map { Double($0.lossEnd) }
        let monoKFs = recs.filter { $0.denseSource == "mono" }.count, stereoOnly = recs.filter { $0.denseSource == "stereoOnly" }.count
        let fits = recs.compactMap { $0.fit }
        let fitRatio = RTStat.percentile(fits.map { Double($0.inlierRatio) }, 0.5)
        let rollbacks = pipeline.rollbacks
        let ms = { (c: Double?) -> String in c.map { String(format: "%.1f", $0) } ?? "—" }

        var t = "가우시안 최적화 실험 요약\n종료: \(endReason.label)\n\n"
        t += "[구분] 서버를 쓰지 않았다. 사전학습 깊이 모델은 기기 내 추론만 했다(재학습 없음). 촬영 중 가우시안 파라미터를 반복 최적화했다(장면별 최적화이며 '완전 무학습'이 아니다). 렌더 FPS는 생성 속도나 화질 지표가 아니다.\n\n"
        t += "입력\n  ARKit 프레임 \(recv)개, 키프레임 채택 \(kfs)개, 처리 \(proc)개, 대기 중 버려진 것 \(dropped)개, 흐림으로 거부 \(blur)개\n"
        t += "  키프레임 거부 사유: \(rejects.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        t += "  추적 상태 전환 \(trans)회, 세그먼트 \(segs)개 (\(events.joined(separator: ", ")))\n\n"
        t += "처음 도달 시각 (시작 후 초)\n  첫 입력 \(f(l.firstInputS, 2)) · 첫 정렬된 지도(단안 정렬) \(f(l.firstAlignedS, 2)) · 첫 후보 \(f(cp.map { $0 - startedHost }, 2)) · 첫 안정(독립 증거 3회) \(f(st.map { $0 - startedHost }, 2)) · 첫 표시 \(f(l.firstDisplayS, 2))\n\n"
        t += "지연 (캡처 시각 기준)\n  → 지도 반영 p50 \(f(p50)) / p95 \(f(p95)) ms (\(tm.count)개)\n  → 렌더용 게시 p50 \(f(q50)) / p95 \(f(q95)) ms (\(tp.count)개)\n  → 실제 화면 표시 p50 \(f(d50)) / p95 \(f(d95)) ms (\(td.count)개, 시각 출처: \(dsrc.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")); gpuEnd는 present 시각을 읽지 못해 GPU 완료 시각으로 근사한 값)\n"
        t += "  키프레임 단계 p50/p95(ms): " + stage.keys.sorted().map { "\($0) \(f(stage[$0]))/\(f(stage95[$0]))" }.joined(separator: ", ") + "\n  처리 대기열 최대 \(mq)\n\n"
        t += "깊이\n  단안 모델 실행 \(tot.monoRuns)회, 밀집 깊이로 처리한 키프레임 \(monoKFs), 스테레오만 \(stereoOnly), 정렬 내부점 비율 중앙값 \(f(fitRatio.map { $0 * 100 }))%\n\n"
        t += "가우시안 지도\n  \(l.gaussians)개 (임시 \(l.temporary) · 후보 \(l.candidate) · 안정 \(l.stable)); 누적 삽입 \(tot.inserted) (스테레오 확인 \(tot.stereoInserted) · 단안 \(tot.monoInserted)), 제거 \(tot.pruned), 상한으로 못 만든 \(tot.rejectedByCap)\n\n"
        t += "최적화\n  반복 \(tot.iterations)회(묶음 \(sl.count)개), 위치가 의미 있게 움직인 갱신 \(tot.moved), 비정상 gradient 건너뜀 \(tot.nonFinite), 롤백 \(rollbacks)회\n"
        t += "  반복당 p50/p95(ms): " + opt.keys.sorted().map { "\($0) \(f(opt[$0], 1))/\(f(opt95[$0], 1))" }.joined(separator: ", ") + "\n"
        t += "  훈련 시점의 광도 손실(Charbonnier): 처음 묶음 \(f(lossFirst.isEmpty ? nil : lossFirst.reduce(0, +) / Double(lossFirst.count), 4)) → 마지막 묶음 \(f(lossLast.isEmpty ? nil : lossLast.reduce(0, +) / Double(lossLast.count), 4)) (훈련에 쓴 사진의 손실이며 화질 증거가 아니다)\n\n"
        if let r = render {
            t += "렌더 (마지막 1초)\n  \(String(format: "%.1f", r.fps)) fps, CPU p50/p95 \(ms(r.cpuMsP50))/\(ms(r.cpuMsP95)) ms, GPU p50/p95 \(ms(r.gpuMsP50))/\(ms(r.gpuMsP95)) ms, 그린 가우시안 \(r.drawn)/\(r.total)\n\n"
        }
        t += "자원\n  메모리 피크 \(f(fp)) MB, 열 상태 \(th.joined(separator: ", ")), 거버너 변경 \(gov.count)회\n  재생 자료 \(l.replayFrames)장 \(l.replayBytes / 1_048_576) MB\n\n"
        t += "해석 주의\n  - 단일 장면·단일 실행의 측정이며 정확도(실제 거리 오차)나 화질(PSNR/SSIM)이 아니다. 다른 시점의 화질과 구멍 비율은 앱이 라이브로 측정하지 않는다(재생 비교 도구가 별도로 잰다).\n  - 포즈는 ARKit 값을 그대로 쓴다(최적화하지 않음). 세그먼트가 둘 이상이면 서로 다른 좌표계로 간주하고 병합하지 않았다.\n  - 지연 목표와 30fps는 목표이며 달성했다는 뜻이 아니다.\n"

        var d: [String: Any] = [:]
        d["endReason"] = endReason.rawValue
        d["received"] = recv; d["keyframes"] = kfs; d["processed"] = proc; d["droppedBusy"] = dropped; d["blurRejected"] = blur
        d["policyRejects"] = rejects; d["segments"] = segs; d["segmentEvents"] = events; d["trackingTransitions"] = trans
        d["first"] = ["inputS": expNN(l.firstInputS), "alignedS": expNN(l.firstAlignedS), "candidateS": expNN(cp.map { $0 - startedHost }),
                      "stableS": expNN(st.map { $0 - startedHost }), "displayS": expNN(l.firstDisplayS)]
        d["toMapMsP50"] = expNN(p50); d["toMapMsP95"] = expNN(p95)
        d["toPublishMsP50"] = expNN(q50); d["toPublishMsP95"] = expNN(q95)
        d["toDisplayMsP50"] = expNN(d50); d["toDisplayMsP95"] = expNN(d95); d["toDisplaySamples"] = td.count; d["displayTimeSources"] = dsrc
        d["stageMsP50"] = stage; d["stageMsP95"] = stage95; d["optMsP50"] = opt; d["optMsP95"] = opt95; d["maxQueueLen"] = mq
        d["gaussians"] = l.gaussians
        d["states"] = ["temporary": l.temporary, "candidate": l.candidate, "stable": l.stable]
        d["totals"] = ["inserted": tot.inserted, "stereoInserted": tot.stereoInserted, "monoInserted": tot.monoInserted, "pruned": tot.pruned,
                       "monoRuns": tot.monoRuns, "iterations": tot.iterations, "moved": tot.moved, "nonFinite": tot.nonFinite, "rejectedByCap": tot.rejectedByCap]
        d["rollbacks"] = rollbacks
        d["lossFirst10"] = expNN(lossFirst.isEmpty ? nil : lossFirst.reduce(0, +) / Double(lossFirst.count))
        d["lossLast10"] = expNN(lossLast.isEmpty ? nil : lossLast.reduce(0, +) / Double(lossLast.count))
        d["monoKeyframes"] = monoKFs; d["stereoOnlyKeyframes"] = stereoOnly
        d["footprintPeakMB"] = fp; d["thermalSeen"] = th; d["governorChanges"] = gov.count
        d["replay"] = ["frames": l.replayFrames, "bytes": l.replayBytes]
        if let r = render {
            d["render"] = ["fps": r.fps, "cpuMsP50": r.cpuMsP50, "cpuMsP95": r.cpuMsP95, "gpuMsP50": r.gpuMsP50, "gpuMsP95": r.gpuMsP95, "drawn": r.drawn, "total": r.total]
        }
        return (t, d)
    }
}

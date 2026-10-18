import Foundation
import ARKit
import simd

struct SV2Options: Equatable {
    var showCamera = false          // 명시적 비교 옵션: 라이브 화면에 카메라 영상 배경(복원 품질 평가에 쓰지 않는다)
    var recordReplay = false        // 연구 기록: 재생용 입력(원본 영상 포함)을 용량 상한 안에서 저장
    var includeTemporary = true
}

/// 화면에 보여 줄 실시간 값(약 4Hz).
struct SV2Live {
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
    var toMapP50: Double?
    var toMapP95: Double?
    var toPublishP50: Double?
    var toPublishP95: Double?
    var toDisplayP50: Double?
    var toDisplayP95: Double?
    var stageMs: [String: Double] = [:]
    var patches = 0
    var temporary = 0
    var candidate = 0
    var stable = 0
    var planeFill = 0
    var planes = 0
    var keyframesStored = 0
    var lastInserted = 0
    var lastUpdated = 0
    var lastReplaced = 0
    var lastValidDepth = 0
    var lastGridCells = 0
    var lastRefs = 0
    var backwardConsistentRatio: Double?
    var reuseRatio: Double?
    var lastReasons: [String: Int] = [:]
    var footprintMB: Double?
    var thermal = ""
    var governor = 0
    var hint = ""
    var depthStatus = "표면을 찾는 중"
    var firstInputS: Double?
    var firstParallaxS: Double?
    var firstSurfaceS: Double?
    var firstDisplayS: Double?
    var replayFrames = 0
    var replayBytes = 0
    var paused = false
}

/// 실시간 공간 생성 V2 엔진. 하나의 ARSession → 같은 ARFrame의 영상·포즈·K·시각을 묶은 입력 → SV2Pipeline(무모델 다중 시점 깊이 →
/// 영구 표면 지도) → 렌더용 스냅샷. 서버·장면별 학습·사전학습 모델을 쓰지 않는다.
final class SV2Engine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    let shared: SV2SharedScene
    let liveCam: RTLiveCameraStore
    let background: RTBackgroundStore
    var onLive: ((SV2Live) -> Void)?
    var onAutoStop: ((ExpEndReason) -> Void)?

    private(set) var options: SV2Options
    let config: SV2Config
    var log: ExperimentRunLog?
    private let arQueue = DispatchQueue(label: "gonggi.sv2.ar", qos: .userInteractive)
    private let procQueue = DispatchQueue(label: "gonggi.sv2.process", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "gonggi.sv2.monitor", qos: .utility)

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
    private var pending: Job?
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

    struct Job {
        var pb: CVPixelBuffer
        var timestamp: Double
        var pose: RTPose
        var K: RTIntrinsics
        var segment: Int
        var id: Int
        var trackingText: String
        var trackingNormal: Bool
        var exposureDuration: Double?
        var exposureOffset: Double?
    }

    // MARK: 처리 쪽 상태 (procQueue에서만)
    let pipeline: SV2Pipeline
    private var recorder: SV2ReplayRecorder?
    private var sceneVersion = 0
    private var lastPublishHost: Double = 0
    private var versionCapture: [Int: Double] = [:]      // 장면 버전 → 그 버전에 반영된 가장 최근 캡처 시각(host)
    private var pendingPublishCaptures: [Double] = []
    private var noBaselineStreak = 0
    private var runStamp = ""

    // MARK: 통계 상자(statLock)
    private let statLock = NSLock()
    private var records: [SV2KFRecord] = []
    private var processed = 0
    private var blurRejected = 0
    private var toMap: [Double] = []
    private var toPublish: [Double] = []
    private var toDisplay: [Double] = []
    private var displaySources: [String: Int] = [:]      // 표시 시각의 출처(present = drawable presentedTime, gpuEnd = GPU 완료 시각 근사)
    private var stageSamples: [String: [Double]] = [:]
    private var reasonTotals: [String: Int] = [:]
    private var rejectTotals: [String: Int] = [:]
    private var lastRecord: SV2KFRecord?
    private var counts = (patches: 0, temp: 0, cand: 0, stable: 0, fill: 0, planes: 0, kfs: 0)
    private var totalInserted = 0, totalUpdated = 0, totalReplaced = 0, totalSamplesMerged = 0
    private var totalWeakInserted = 0, totalFillInserted = 0, totalFillCovered = 0
    private var totalIndependent = 0, totalCorrelated = 0
    private var totalContradictionsRecorded = 0, totalContradictionsApplied = 0
    private var totalPromoCandidate = 0, totalPromoStable = 0, totalDemoted = 0, totalRevisions = 0
    private var totalRemovedViolation = 0, totalRemovedExpired = 0, totalRemovedCap = 0
    private var stableMoves: [Float] = []
    private var residuals: [Float] = []
    private var gainRaw: [Double] = []
    private var bwdChecked = 0, bwdOK = 0, bwdBad = 0
    private var firstParallaxHost: Double?
    private var firstSurfaceHost: Double?
    private var firstDisplayHost: Double?
    private var hint = ""
    private var depthStatus = "표면을 찾는 중"
    private var governorLevel = 0
    private var governorChanges: [(Double, Int, String)] = []
    private var footprintPeak = 0.0
    private var thermalSeen = Set<String>()
    private var maxQueueLen = 0
    private var renderStatsLatest: SV2RenderStats?
    private var renderStatsHistory: [SV2RenderStats] = []
    private var timer: DispatchSourceTimer?
    private var autoStopSent = false

    init(options: SV2Options, config: SV2Config = .default, log: ExperimentRunLog? = nil, shared: SV2SharedScene = SV2SharedScene(),
         liveCam: RTLiveCameraStore = RTLiveCameraStore(), background: RTBackgroundStore = RTBackgroundStore()) {
        self.options = options
        self.config = config
        self.log = log
        self.shared = shared
        self.liveCam = liveCam
        self.background = background
        pipeline = SV2Pipeline(config: config)
        super.init()
        shared.setProvider { [pipeline] id in pipeline.store.rgba(id) }
    }

    deinit { timer?.cancel() }

    func setOptions(_ o: SV2Options) { statLock.lock(); options = o; statLock.unlock() }

    private var currentOptions: SV2Options {
        statLock.lock(); defer { statLock.unlock() }
        return options
    }

    func noteRenderStats(_ s: SV2RenderStats) {
        statLock.lock()
        renderStatsLatest = s
        renderStatsHistory.append(s)
        if renderStatsHistory.count > 600 { renderStatsHistory.removeFirst() }
        statLock.unlock()
    }

    /// 새 장면 버전이 처음 화면에 표시된 시각. 캡처 → 실제 표시 지연을 기록한다(게시 지연과 다르다).
    func notePresented(version: Int, uptime: Double, source: String = "present") {
        let presentHost = uptime + clockDelta
        procQueue.async { [weak self] in
            guard let self, let cap = self.versionCapture[version] else { return }
            let ms = (presentHost - cap) * 1000
            self.statLock.lock()
            self.displaySources[source, default: 0] += 1
            self.toDisplay.append(ms); if self.toDisplay.count > 2000 { self.toDisplay.removeFirst() }
            if self.firstDisplayHost == nil, self.pipeline.map.aliveCount > 0 { self.firstDisplayHost = presentHost }
            self.statLock.unlock()
            self.versionCapture[version] = nil
            if version % 8 == 0 { self.log?.write("sv2_display", ["version": version, "captureToDisplayMs": ms, "timeSource": source]) }
        }
    }

    // MARK: 시작·일시정지·재개·종료

    private func makeConfig() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = []                 // ARPlaneAnchor는 쓰지 않는다(평면은 관측한 패치에서 직접 검증한다)
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
        if currentOptions.recordReplay, let dir = runDirectoryForReplay {
            recorder = SV2ReplayRecorder(directory: dir)
        }
        var info: [String: Any] = [:]
        info["videoFormat"] = ["w": cfg.videoFormat.imageResolution.width, "h": cfg.videoFormat.imageResolution.height, "fps": cfg.videoFormat.framesPerSecond]
        info["options"] = ["showCamera": options.showCamera, "recordReplay": options.recordReplay, "includeTemporary": options.includeTemporary]
        info["config"] = ["hiWidth": config.hiWidth, "smallWidth": config.smallWidth, "maxPatches": config.maxPatches, "maxKeyframes": config.maxKeyframes]
        info["policy"] = ["minInterval": policy.minInterval, "minTranslation": policy.minTranslation, "minRotationDeg": policy.minRotationDeg]
        info["buildSHA"] = GonggiBuildInfo.buildSHA
        info["appVersion"] = GonggiBuildInfo.versionLine
        info["machine"] = ExpSys.machine
        info["server"] = false
        info["sceneTraining"] = false
        info["pretrainedModels"] = false
        info["orientation"] = "capturedImage=sensorLandscapeRight, display=portrait(app locked)"
        info["replayRecording"] = recorder != nil
        info["algorithm"] = "ARKit pose + multi-ref plane-sweep ZNCC inverse-depth (no neural net) + backward consistency + persistent surface patches (inverse-variance fusion, independent-evidence accounting) + per-pixel source-keyframe projection with depth-visibility"
        log?.write("sv2_start", info)
        runStamp = log?.baseName ?? ""
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
        log?.write("sv2_pause", ["patches": pipeline.map.aliveCount])
    }

    func resume() {
        arLock.lock()
        guard running, paused else { arLock.unlock(); return }
        paused = false
        if let ps = pauseStart { pausedTotal += ExpSys.hostNow() - ps; pauseStart = nil }
        startNewSegmentLocked(reason: "resume", host: ExpSys.hostNow())
        arLock.unlock()
        session.run(makeConfig(), options: [])
        log?.write("sv2_resume", ["segment": segment])
    }

    func stop() {
        timer?.cancel(); timer = nil
        arLock.lock(); let wasRunning = running; running = false; arLock.unlock()
        guard wasRunning else { return }
        session.pause()
        session.delegate = nil
        procQueue.sync {}
        procQueue.sync { self.publish(force: true) }
        log?.write("sv2_stopped", ["patches": pipeline.map.aliveCount])
    }

    var isPaused: Bool { arLock.lock(); defer { arLock.unlock() }; return paused }

    // MARK: ARSessionDelegate (arQueue)

    private func startNewSegmentLocked(reason: String, host: Double) {
        segment += 1
        segmentsCreated += 1
        segmentEvents.append((host, reason))
        lastKF = nil; prev = nil
        log?.write("sv2_segment", ["segment": segment, "reason": reason])
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
        if trackingText != text { trackingTransitions += 1; log?.write("sv2_tracking", ["state": text]) }
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
        var job: Job?
        switch decision {
        case .accept:
            lastKF = RTKeyframePolicy.Last(timestamp: frame.timestamp, pose: pose)
            keyframesAccepted += 1
            kfCounter += 1
            kfTimes.add(host)
            job = Job(pb: frame.capturedImage, timestamp: frame.timestamp, pose: pose,
                      K: RTIntrinsics(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y, width: Int(imgW), height: Int(imgH)),
                      segment: seg, id: kfCounter, trackingText: text, trackingNormal: normal,
                      exposureDuration: cam.exposureDuration > 0 ? cam.exposureDuration : nil, exposureOffset: Double(cam.exposureOffset))
        case .reject(let why):
            policyRejects[why, default: 0] += 1
        }
        var dispatchNow: Job?
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
        log?.write("sv2_ar_error", ["domain": e.domain, "code": e.code, "description": e.localizedDescription])
        // 세션 오류는 복구하지 않고 정리한다(그때까지의 표면은 저장한다).
        if !autoStopSent {
            autoStopSent = true
            log?.write("auto_stop", ["reason": "ar_error", "code": e.code])
            onAutoStop?(.failed)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) { log?.write("sv2_ar_interrupted") }
    func sessionInterruptionEnded(_ session: ARSession) {
        arLock.lock(); startNewSegmentLocked(reason: "ar_interruption_ended", host: ExpSys.hostNow()); arLock.unlock()
        log?.write("sv2_ar_interruption_ended")
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
        }
    }

    private func process(_ job: Job) {
        defer { finishJob() }
        let captureHost = job.timestamp + clockDelta
        let tStart = ExpSys.hostNow()
        guard let hi = RTFrameConverter.downscale(job.pb, outWidth: config.hiWidth) else { return }
        let input = SV2Input(id: job.id, segment: job.segment, timestamp: job.timestamp, captureHost: captureHost, pose: job.pose,
                             kFull: job.K, rgbHi: hi.rgb, hiWidth: hi.width, hiHeight: hi.height, tracking: job.trackingText,
                             trackingNormal: job.trackingNormal, exposureDuration: job.exposureDuration, exposureOffset: job.exposureOffset)
        let tConv = ExpSys.hostNow()
        recorder?.record(input)
        var rec = pipeline.process(input)
        rec.convertMs += (tConv - tStart) * 1000
        let tDone = ExpSys.hostNow()
        rec.toMapMs = (tDone - captureHost) * 1000
        if rec.skipped != nil {
            statLock.lock(); blurRejected += 1; statLock.unlock()
            return
        }
        if rec.validDepth > 0, firstParallaxHostSet(tDone) { log?.write("sv2_first_parallax", ["kf": input.id, "sinceStartS": tDone - startedHost]) }
        if rec.alive > 0, firstSurfaceHostSet(tDone) { log?.write("sv2_first_surface", ["kf": input.id, "sinceStartS": tDone - startedHost]) }
        noBaselineStreak = (rec.refs == 0) ? noBaselineStreak + 1 : 0
        pendingPublishCaptures.append(captureHost)
        let st = rec.stats
        statLock.lock()
        processed += 1
        records.append(rec); if records.count > 4000 { records.removeFirst(records.count - 4000) }
        lastRecord = rec
        for (k, v) in rec.depthReasons { reasonTotals[k, default: 0] += v }
        for (k, v) in rec.rejected { rejectTotals[k, default: 0] += v }
        for (k, v) in st.rejected { rejectTotals[k, default: 0] += v }
        for (k, v) in rec.fill.rejected { rejectTotals["fill_" + k, default: 0] += v }
        toMap.append(rec.toMapMs); if toMap.count > 2000 { toMap.removeFirst() }
        func add(_ key: String, _ v: Double) { stageSamples[key, default: []].append(v); if stageSamples[key]!.count > 600 { stageSamples[key]!.removeFirst() } }
        add("convert", rec.convertMs); add("depth", rec.depthMs); add("build", rec.buildMs); add("plane", rec.planeMs)
        add("fuse", rec.fuseMs); add("cleanup", rec.cleanupMs); add("total", rec.totalMs)
        totalInserted += st.inserted; totalUpdated += st.updatedPatches; totalReplaced += st.replacedTemporary
        totalSamplesMerged += st.samplesMerged; totalWeakInserted += st.insertedWeak; totalFillInserted += st.insertedPlaneFill
        totalFillCovered += st.fillCovered
        totalIndependent += st.independentEvidence; totalCorrelated += st.correlatedEvidence
        totalContradictionsRecorded += st.contradictionsRecorded; totalContradictionsApplied += st.contradictionsApplied
        totalPromoCandidate += st.promotedCandidate; totalPromoStable += st.promotedStable; totalDemoted += st.demoted
        totalRevisions += st.revisionsBumped
        totalRemovedViolation += st.removedViolation; totalRemovedExpired += st.removedExpired; totalRemovedCap += st.removedCap
        stableMoves.append(contentsOf: st.stableMoveM.prefix(500)); if stableMoves.count > 20000 { stableMoves.removeFirst(stableMoves.count - 20000) }
        residuals.append(contentsOf: st.residualsSigma.prefix(2000)); if residuals.count > 20000 { residuals.removeFirst(residuals.count - 20000) }
        if let r = st.gainRaw { gainRaw.append(Double(r)); if gainRaw.count > 600 { gainRaw.removeFirst() } }
        bwdChecked += rec.backwardChecked; bwdOK += rec.backwardConsistent; bwdBad += rec.backwardInconsistent
        counts = (rec.alive, rec.states[0], rec.states[1], rec.states[2], rec.planeFillAlive, rec.planes, rec.keyframesStored)
        if noBaselineStreak >= 3 {
            hint = "제자리 회전만으로는 깊이를 알 수 없어요. 옆으로 천천히 이동해 주세요"
            depthStatus = "시차 부족: 아직 검증된 표면이 없어요"
        } else {
            hint = ""
            depthStatus = rec.alive == 0 ? "표면을 찾는 중" : "표면 생성 중"
        }
        statLock.unlock()
        log?.write("sv2_kf", kfLog(rec))
        publish(force: false)
    }

    private func firstParallaxHostSet(_ t: Double) -> Bool {
        statLock.lock(); defer { statLock.unlock() }
        if firstParallaxHost == nil { firstParallaxHost = t; return true }
        return false
    }

    private func firstSurfaceHostSet(_ t: Double) -> Bool {
        statLock.lock(); defer { statLock.unlock() }
        if firstSurfaceHost == nil { firstSurfaceHost = t; return true }
        return false
    }

    private func kfLog(_ r: SV2KFRecord) -> [String: Any] {
        let st = r.stats
        var d: [String: Any] = [:]
        d["id"] = r.id; d["segment"] = r.segment
        d["toMapMs"] = r.toMapMs
        d["ms"] = ["convert": r.convertMs, "depth": r.depthMs, "build": r.buildMs, "plane": r.planeMs, "fuse": r.fuseMs, "cleanup": r.cleanupMs, "total": r.totalMs]
        d["refs"] = r.refs; d["validDepth"] = r.validDepth; d["gridCells"] = r.gridCells
        d["samples"] = ["strong": r.strongSamples, "weak": r.weakSamples]
        d["backward"] = ["checked": r.backwardChecked, "consistent": r.backwardConsistent, "inconsistent": r.backwardInconsistent]
        d["maxBaselineM"] = Double(r.maxBaseline)
        d["inserted"] = ["total": st.inserted, "weak": st.insertedWeak, "planeFill": st.insertedPlaneFill]
        d["updatedPatches"] = st.updatedPatches; d["samplesMerged"] = st.samplesMerged; d["replacedTemporary"] = st.replacedTemporary
        d["evidence"] = ["independent": st.independentEvidence, "correlated": st.correlatedEvidence]
        d["contradiction"] = ["recorded": st.contradictionsRecorded, "applied": st.contradictionsApplied]
        d["transitions"] = ["toCandidate": st.promotedCandidate, "toStable": st.promotedStable, "demoted": st.demoted]
        d["revisionsBumped"] = st.revisionsBumped
        d["removed"] = ["freeSpace": st.removedViolation, "expired": st.removedExpired, "cap": st.removedCap]
        d["stableMoveM"] = ["max": Double(st.stableMoveM.max() ?? 0), "count": st.stableMoveM.count]
        d["gain"] = ["raw": expNN(st.gainRaw.map { Double($0) }), "used": Double(st.gainUsed), "pairs": st.gainPairs]
        d["fill"] = ["considered": r.fill.considered, "created": r.fill.created, "rejected": r.fill.rejected, "covered": st.fillCovered, "planes": r.planes]
        d["reasons"] = r.depthReasons
        d["rejected"] = r.rejected.merging(st.rejected) { $0 + $1 }
        d["patches"] = r.alive
        d["states"] = ["temporary": r.states[0], "candidate": r.states[1], "stable": r.states[2]]
        d["keyframesStored"] = r.keyframesStored
        d["sharpness"] = Double(r.sharpness)
        return d
    }

    /// 지도 변경이 있으면 렌더용 스냅샷을 만들어 넘긴다(0.25초 이상 간격). force이면 새 키프레임이 없어도 만든다. procQueue에서만 부른다.
    private func publish(force: Bool) {
        let now = ExpSys.hostNow()
        if pendingPublishCaptures.isEmpty && !force { return }
        if !force && now - lastPublishHost < 0.25 { return }
        doPublish(now: now)
    }

    private func doPublish(now: Double) {
        let latest = pendingPublishCaptures.last ?? 0
        let includeTemp = currentOptions.includeTemporary
        sceneVersion += 1
        let scene = pipeline.scene(version: sceneVersion, includeTemporary: includeTemp, latestCaptureHost: latest)
        shared.publish(scene)
        if latest > 0 {
            versionCapture[sceneVersion] = latest
            if versionCapture.count > 50 { for k in versionCapture.keys.sorted().prefix(versionCapture.count - 50) { versionCapture[k] = nil } }
        }
        let pubHost = ExpSys.hostNow()
        statLock.lock()
        for c in pendingPublishCaptures { toPublish.append((pubHost - c) * 1000) }
        if toPublish.count > 2000 { toPublish.removeFirst(toPublish.count - 2000) }
        statLock.unlock()
        pendingPublishCaptures.removeAll()
        lastPublishHost = now
        RTViewerBounds.shared.bounds = scene.bounds
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
        var level = 0
        if th == .fair { level = max(level, 1) }
        if th == .serious || fp > 1900 { level = max(level, 2) }
        if th == .critical || fp > 2400 { level = 3 }
        statLock.lock()
        footprintPeak = max(footprintPeak, fp)
        thermalSeen.insert(ExpSys.thermalName(th))
        let changed = level != governorLevel
        if changed { governorChanges.append((ExpSys.hostNow(), level, "thermal=\(ExpSys.thermalName(th)) footprintMB=\(Int(fp))")) }
        governorLevel = level
        statLock.unlock()
        if changed { log?.write("sv2_governor", ["level": level, "thermal": ExpSys.thermalName(th), "footprintMB": fp]) }
        if level >= 3, !autoStopSent {
            autoStopSent = true
            log?.write("auto_stop", ["reason": "thermal_or_memory", "thermal": ExpSys.thermalName(th), "footprintMB": fp])
            onAutoStop?(th == .critical ? .thermal : .failed)
        }
    }

    func liveSnapshot() -> SV2Live {
        var l = SV2Live()
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
        l.patches = counts.patches; l.temporary = counts.temp; l.candidate = counts.cand; l.stable = counts.stable
        l.planeFill = counts.fill; l.planes = counts.planes; l.keyframesStored = counts.kfs
        l.lastInserted = lastRecord?.stats.inserted ?? 0
        l.lastUpdated = lastRecord?.stats.updatedPatches ?? 0
        l.lastReplaced = lastRecord?.stats.replacedTemporary ?? 0
        l.lastValidDepth = lastRecord?.validDepth ?? 0
        l.lastGridCells = lastRecord?.gridCells ?? 0
        l.lastRefs = lastRecord?.refs ?? 0
        l.backwardConsistentRatio = (bwdOK + bwdBad) > 0 ? Double(bwdOK) / Double(bwdOK + bwdBad) : nil
        let tail = records.suffix(20)
        let upd = tail.reduce(0) { $0 + $1.stats.updatedPatches }, ins = tail.reduce(0) { $0 + $1.stats.inserted + $1.stats.replacedTemporary }
        l.reuseRatio = (upd + ins) > 0 ? Double(upd) / Double(upd + ins) : nil
        l.lastReasons = lastRecord?.depthReasons ?? [:]
        l.hint = hint; l.depthStatus = depthStatus; l.governor = governorLevel
        l.firstInputS = fi.map { $0 - startedHost }
        l.firstParallaxS = firstParallaxHost.map { $0 - startedHost }
        l.firstSurfaceS = firstSurfaceHost.map { $0 - startedHost }
        l.firstDisplayS = firstDisplayHost.map { $0 - startedHost }
        maxQueueLen = max(maxQueueLen, l.queueLen)
        statLock.unlock()
        l.replayFrames = recorder?.frames ?? 0
        l.replayBytes = recorder?.bytes ?? 0
        l.footprintMB = ExpSys.footprintMB(); l.thermal = ExpSys.thermal
        return l
    }

    private func logHeartbeat(_ l: SV2Live) {
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
        hb["stageMsP50"] = l.stageMs
        hb["patches"] = l.patches
        hb["states"] = ["temporary": l.temporary, "candidate": l.candidate, "stable": l.stable]
        hb["planeFill"] = l.planeFill; hb["keyframesStored"] = l.keyframesStored
        hb["reuse"] = expNN(l.reuseRatio)
        hb["depthStatus"] = l.depthStatus
        if let r = rs {
            var rd: [String: Any] = [:]
            rd["fps"] = r.fps; rd["cpuMsP50"] = r.cpuMsP50; rd["cpuMsP95"] = r.cpuMsP95; rd["gpuMsP50"] = r.gpuMsP50; rd["gpuMsP95"] = r.gpuMsP95
            rd["patchesDrawn"] = r.patchesDrawn; rd["activeSources"] = r.activeSources; rd["depthRebuilds"] = r.depthRebuilds
            rd["depthRefreshedWithoutRebuild"] = r.depthRefreshedWithoutRebuild
            rd["textureLoads"] = r.textureLoads; rd["textureMisses"] = r.textureMisses; rd["textureResident"] = r.textureResident
            rd["textureBytes"] = r.textureBytes
            rd["supportedRatio"] = expNN(r.supportedRatio); rd["noSourceRatio"] = expNN(r.noSourceRatio)
            rd["occludedAllRatio"] = expNN(r.occludedAllRatio); rd["disagreeRatio"] = expNN(r.disagreeRatio)
            hb["render"] = rd
        }
        hb["footprintMB"] = expNN(l.footprintMB); hb["thermal"] = l.thermal; hb["governor"] = l.governor
        hb["replay"] = ["frames": l.replayFrames, "bytes": l.replayBytes]
        log?.write("sv2_hb", hb)
    }

    // MARK: 저장

    typealias SaveResult = SV2SaveResult

    /// 지도를 .kmospace(본체) + 호환 PLY/.state + 메타 + 요약(+재생 자료)으로 저장한다. 패치가 없으면 저장하지 않는다.
    func save(summaryText: String) -> SaveResult {
        var out = SaveResult(item: nil, error: nil, patches: 0, keyframes: 0)
        procQueue.sync {
            let req = SV2Saver.Request(map: pipeline.map, store: pipeline.store, runId: log?.baseName, config: config, segments: segmentsCreated,
                                       recorder: recorder, summaryText: summaryText)
            out = SV2Saver.save(req)
            if out.error == nil { recorder = nil }
        }
        return out
    }

    // MARK: 요약

    func summary(endReason: ExpEndReason, render: SV2RenderStats?) -> (text: String, dict: [String: Any]) {
        let l = liveSnapshot()
        arLock.lock()
        let recv = received, kfs = keyframesAccepted, rejects = policyRejects, dropped = droppedBusy, segs = segmentsCreated
        let events = segmentEvents.map { "\($0.1)" }, trans = trackingTransitions
        arLock.unlock()
        statLock.lock()
        let recs = records, tm = toMap, tp = toPublish, td = toDisplay, rt = reasonTotals, rj = rejectTotals
        let mv = stableMoves, res = residuals, gr = gainRaw
        let fp = footprintPeak, th = Array(thermalSeen).sorted(), gov = governorChanges, proc = processed, blur = blurRejected, mq = maxQueueLen
        let ins = totalInserted, upd = totalUpdated, rep = totalReplaced, smg = totalSamplesMerged, wk = totalWeakInserted, fl = totalFillInserted
        let flc = totalFillCovered, ind = totalIndependent, cor = totalCorrelated
        let cr = totalContradictionsRecorded, ca = totalContradictionsApplied, pc = totalPromoCandidate, ps = totalPromoStable, dm = totalDemoted
        let rv = totalRevisions, rvv = totalRemovedViolation, rve = totalRemovedExpired, rvc = totalRemovedCap
        let bc = bwdChecked, bo = bwdOK, bb = bwdBad
        let hist = renderStatsHistory
        let dsrc = displaySources
        var stage: [String: Double] = [:], stage95: [String: Double] = [:]
        for (k, v) in stageSamples { stage[k] = RTStat.percentile(v, 0.5) ?? 0; stage95[k] = RTStat.percentile(v, 0.95) ?? 0 }
        statLock.unlock()
        func f(_ v: Double?, _ d: Int = 0) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }
        func pct(_ a: Double?, _ b: Double? = nil) -> String { a.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
        let p50 = RTStat.percentile(tm, 0.5), p95 = RTStat.percentile(tm, 0.95)
        let q50 = RTStat.percentile(tp, 0.5), q95 = RTStat.percentile(tp, 0.95)
        let d50 = RTStat.percentile(td, 0.5), d95 = RTStat.percentile(td, 0.95)
        let win = Array(recs.suffix(30))
        func sumI(_ a: [SV2KFRecord], _ k: (SV2KFRecord) -> Int) -> Int { a.reduce(0) { $0 + k($1) } }
        func reuse(_ a: [SV2KFRecord]) -> Double? {
            let u = sumI(a) { $0.stats.updatedPatches }, i = sumI(a) { $0.stats.inserted + $0.stats.replacedTemporary }
            return u + i > 0 ? Double(u) / Double(u + i) : nil
        }
        // 렌더러가 센 비율의 평균(1초마다 보고된 표본의 평균. 화소의 1/16 표본)
        func mean(_ k: (SV2RenderStats) -> Double?) -> Double? {
            let v = hist.compactMap(k)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let supportedM = mean { $0.supportedRatio }, noSrcM = mean { $0.noSourceRatio }, occM = mean { $0.occludedAllRatio }, disM = mean { $0.disagreeRatio }
        let firstIn = l.firstInputS, firstPar = l.firstParallaxS, firstSurf = l.firstSurfaceS, firstDisp = l.firstDisplayS
        let validRatio = recs.isEmpty ? nil : Double(recs.reduce(0) { $0 + $1.validDepth }) / Double(max(1, recs.reduce(0) { $0 + $1.gridCells }))

        var t = "실시간 공간 생성 V2 요약\n종료: \(endReason.label)\n\n"
        t += "[구분] 서버·장면별 학습·사전학습 모델을 쓰지 않았다. 아래 값은 모두 이 기기에서 이번 실행 중 측정한 값이다. 렌더 FPS는 생성 속도나 화질 지표가 아니다.\n\n"
        t += "입력\n  ARKit 프레임 \(recv)개, 키프레임 채택 \(kfs)개, 처리 \(proc)개, 대기 중 버려진 것 \(dropped)개, 흐림으로 거부 \(blur)개\n"
        t += "  키프레임 거부 사유: \(rejects.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        t += "  추적 상태 전환 \(trans)회, 세그먼트 \(segs)개 (\(events.joined(separator: ", ")))\n\n"
        t += "처음 도달 시각 (시작 후 초)\n  첫 입력 \(f(firstIn, 2)) · 첫 유효 시차(깊이 표본) \(f(firstPar, 2)) · 첫 표면 \(f(firstSurf, 2)) · 첫 표시 \(f(firstDisp, 2))\n\n"
        t += "지연 (캡처 시각 기준)\n  → 지도 반영 p50 \(f(p50)) / p95 \(f(p95)) ms\n  → 렌더용 게시 p50 \(f(q50)) / p95 \(f(q95)) ms (게시는 0.25초 이상 간격)\n  → 실제 화면 표시(present) p50 \(f(d50)) / p95 \(f(d95)) ms (\(td.count)개 장면 버전, 시각 출처: \(dsrc.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")); gpuEnd는 present 시각을 읽지 못해 GPU 완료 시각으로 근사한 값)\n"
        t += "  단계별 p50/p95(ms): " + stage.keys.sorted().map { "\($0) \(f(stage[$0]))/\(f(stage95[$0]))" }.joined(separator: ", ") + "\n  처리 대기열 최대 \(mq)\n\n"
        t += "지도\n  표면 패치 \(l.patches)개 (임시 \(l.temporary) · 후보 \(l.candidate) · 안정 \(l.stable)), 검증된 평면 채움 패치 \(l.planeFill)개, 보관 키프레임 \(l.keyframesStored)장\n"
        t += "  누적: 신규 \(ins) (약한 표본 \(wk), 평면 채움 \(fl)), 재사용(갱신된 패치) \(upd), 교체 \(rep), 병합된 표본 \(smg), 이미 표면이 있어 버린 채움 \(flc)\n"
        t += "  재사용 비율(갱신/(갱신+신규+교체)) 전체 \(pct(reuse(recs))) / 최근 30 키프레임 \(pct(reuse(win)))\n"
        t += "  증거: 독립 \(ind) · 상관(같은 참조·같은 위치) \(cor), 모순 기록 \(cr) → 적용 \(ca), 승격 후보 \(pc) / 안정 \(ps), 강등 \(dm), geometryRevision 증가 \(rv)\n"
        t += "  제거: 자유 공간 위반 \(rvv), 임시 만료 \(rve), 상한 \(rvc)\n"
        t += "  갱신 잔차 중앙값 \(f(RTStat.percentile(res.map { Double($0) }, 0.5), 2))σ / p95 \(f(RTStat.percentile(res.map { Double($0) }, 0.95), 2))σ (자기 일관성이며 실제 거리 오차가 아님)\n"
        t += "  안정 패치 이동 \(mv.count)건: 중앙값 \(f(RTStat.percentile(mv.map { Double($0 * 1000) }, 0.5), 2)) mm / p95 \(f(RTStat.percentile(mv.map { Double($0 * 1000) }, 0.95), 2)) mm / 최대 \(f(mv.max().map { Double($0 * 1000) }, 2)) mm\n"
        t += "  역방향 일치: 검사 \(bc), 일치 \(bo), 불일치(거부) \(bb) → 일치 \(pct(bc > 0 ? Double(bo) / Double(bc) : nil))\n"
        t += "  깊이 격자 중 유효 표본 비율 평균 \(pct(validRatio)), 거부/미확정 사유 누적: \(rt.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        t += "  표본 거부: \(rj.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        t += "  노출 보정: 키프레임별 추정 중앙값 \(f(RTStat.percentile(gr, 0.5), 2)) (한계 0.6~1.6, 기준 밝기는 처음 3번 관측으로 고정)\n\n"
        if let r = render {
            t += "렌더 (마지막 1초)\n  \(String(format: "%.1f", r.fps)) fps, CPU p50/p95 \(f(r.cpuMsP50, 1))/\(f(r.cpuMsP95, 1)) ms, GPU p50/p95 \(f(r.gpuMsP50, 1))/\(f(r.gpuMsP95, 1)) ms, 패치 \(r.patchesDrawn)개, 활성 source \(r.activeSources)장\n"
            t += "  가림 깊이 다시 만든 횟수 \(r.depthRebuilds), 시야 밖 변경이라 다시 만들지 않은 횟수 \(r.depthRefreshedWithoutRebuild), 텍스처 올림 \(r.textureLoads) / 놓침 \(r.textureMisses), 상주 \(r.textureResident)장 \(r.textureBytes / 1_048_576) MB\n"
        }
        t += "  표시 화소 중 질감 지원 \(pct(supportedM)) · source 없음(대체 평균 색) \(pct(noSrcM)) · 가림으로 전부 거절 \(pct(occM)) · 서로 다른 색이라 한 장만 선택 \(pct(disM)) (1초 보고 평균, 화소의 1/16 표본)\n\n"
        t += "자원\n  메모리 피크 \(f(fp)) MB, 열 상태 \(th.joined(separator: ", ")), 거버너 변경 \(gov.count)회\n  재생 자료 \(l.replayFrames)장 \(l.replayBytes / 1_048_576) MB\n\n"
        t += "해석 주의\n  - 단일 장면·단일 실행의 측정이며 정확도(실제 거리 오차)나 화질(PSNR/SSIM)이 아니다. 다른 시점의 화질과 구멍 비율은 이 앱이 측정하지 않았다.\n  - 포즈는 ARKit 값을 그대로 쓴다. 세그먼트가 둘 이상이면 서로 다른 좌표계로 간주하고 병합하지 않았다.\n  - 지연 목표(p95 250ms)와 30fps는 목표이며 달성했다는 뜻이 아니다.\n"

        var d: [String: Any] = [:]
        d["endReason"] = endReason.rawValue
        d["received"] = recv; d["keyframes"] = kfs; d["processed"] = proc; d["droppedBusy"] = dropped; d["blurRejected"] = blur
        d["policyRejects"] = rejects; d["segments"] = segs; d["segmentEvents"] = events; d["trackingTransitions"] = trans
        d["first"] = ["inputS": expNN(firstIn), "validParallaxS": expNN(firstPar), "surfaceS": expNN(firstSurf), "displayS": expNN(firstDisp)]
        d["toMapMsP50"] = expNN(p50); d["toMapMsP95"] = expNN(p95)
        d["toPublishMsP50"] = expNN(q50); d["toPublishMsP95"] = expNN(q95)
        d["toDisplayMsP50"] = expNN(d50); d["toDisplayMsP95"] = expNN(d95); d["toDisplaySamples"] = td.count; d["displayTimeSources"] = dsrc
        d["stageMsP50"] = stage; d["stageMsP95"] = stage95; d["maxQueueLen"] = mq
        d["patches"] = l.patches
        d["states"] = ["temporary": l.temporary, "candidate": l.candidate, "stable": l.stable]
        d["planeFillPatches"] = l.planeFill
        d["keyframesStored"] = l.keyframesStored
        d["inserted"] = ins; d["inserted_weak"] = wk; d["inserted_planeFill"] = fl; d["updatedPatches"] = upd; d["replacedTemporary"] = rep
        d["samplesMerged"] = smg; d["fillCovered"] = flc
        d["evidence"] = ["independent": ind, "correlated": cor]
        d["contradiction"] = ["recorded": cr, "applied": ca]
        d["transitions"] = ["toCandidate": pc, "toStable": ps, "demoted": dm]
        d["revisionsBumped"] = rv
        d["removed"] = ["freeSpace": rvv, "expired": rve, "cap": rvc]
        d["reuseAll"] = expNN(reuse(recs)); d["reuseRecent30"] = expNN(reuse(win))
        d["residualSigmaP50"] = expNN(RTStat.percentile(res.map { Double($0) }, 0.5))
        d["stableMoveMm"] = ["p50": expNN(RTStat.percentile(mv.map { Double($0 * 1000) }, 0.5)), "p95": expNN(RTStat.percentile(mv.map { Double($0 * 1000) }, 0.95)),
                             "max": expNN(mv.max().map { Double($0 * 1000) }), "samples": mv.count]
        d["backward"] = ["checked": bc, "consistent": bo, "inconsistent": bb]
        d["validDepthRatio"] = expNN(validRatio)
        d["reasonTotals"] = rt; d["rejectTotals"] = rj
        d["gainRawP50"] = expNN(RTStat.percentile(gr, 0.5))
        d["footprintPeakMB"] = fp; d["thermalSeen"] = th; d["governorChanges"] = gov.count
        d["replay"] = ["frames": l.replayFrames, "bytes": l.replayBytes]
        d["renderRatios"] = ["supported": expNN(supportedM), "noSource": expNN(noSrcM), "occludedAll": expNN(occM), "disagree": expNN(disM)]
        if let r = render {
            var rd: [String: Any] = [:]
            rd["fps"] = r.fps; rd["cpuMsP50"] = r.cpuMsP50; rd["cpuMsP95"] = r.cpuMsP95; rd["gpuMsP50"] = r.gpuMsP50; rd["gpuMsP95"] = r.gpuMsP95
            rd["patchesDrawn"] = r.patchesDrawn; rd["activeSources"] = r.activeSources; rd["depthRebuilds"] = r.depthRebuilds
            rd["textureLoads"] = r.textureLoads; rd["textureMisses"] = r.textureMisses; rd["textureResident"] = r.textureResident
            d["render"] = rd
        }
        return (t, d)
    }
}

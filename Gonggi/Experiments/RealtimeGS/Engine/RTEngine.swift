import Foundation
import ARKit
import simd

struct RTOptions: Equatable {
    var refine = true            // 정밀화(노출 보정, 고해상도 색, 법선 정리)
    var useMono = true           // 단안 깊이 사전값(모델이 있을 때)
    var showCamera = false       // 라이브 화면에 카메라 영상 배경
    var maxGaussians = 300_000
}

/// 화면에 보여 줄 실시간 값(약 4Hz).
struct RTLive {
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
    var latencyToMapP50: Double?
    var latencyToMapP95: Double?
    var latencyToPublishP50: Double?
    var latencyToPublishP95: Double?
    var stageMs: [String: Double] = [:]
    var gaussians = 0
    var verified = 0
    var provisional = 0
    var lastInserted = 0
    var lastMerged = 0
    var lastValidDepth = 0
    var lastReasons: [String: Int] = [:]
    var stereoFraction: Double?
    var reuseRatio: Double?
    var mergeResidualCm: Double?
    var monoStatus = ""
    var footprintMB: Double?
    var thermal = ""
    var governor = 0
    var hint = ""
    var paused = false
}

/// 키프레임 처리 결과 한 건(로그/요약용).
struct RTKFRecord {
    var id: Int32
    var segment: UInt16
    var captureHost: Double
    var toMapMs: Double
    var convertMs: Double
    var stereoMs: Double
    var monoMs: Double
    var fuseMs: Double
    var carveMs: Double
    var refineMs: Double
    var refs: Int
    var validDepth: Int
    var stereoValid: Int
    var inserted: Int
    var merged: Int
    var replaced: Int
    var carved: Int
    var reuse: Double
    var residualMedianCm: Double?
    var photoDiff: Double?
}

/// 실시간 가우시안 공간 생성 엔진. ARKit 단일 세션 → 키프레임 → 시간차 스테레오(+단안 사전값) → 가우시안 융합 → 정밀화 → 렌더용 포장.
final class RTEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    let splats = RTSharedSplats()
    let liveCam = RTLiveCameraStore()
    let background = RTBackgroundStore()
    var onLive: ((RTLive) -> Void)?
    var onAutoStop: ((ExpEndReason) -> Void)?

    private(set) var options: RTOptions
    var log: ExperimentRunLog?
    private let arQueue = DispatchQueue(label: "gonggi.rt.ar", qos: .userInteractive)
    private let procQueue = DispatchQueue(label: "gonggi.rt.process", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "gonggi.rt.monitor", qos: .utility)

    // MARK: AR 쪽 상태 (arLock)
    private let arLock = NSLock()
    private var arTimes = ExpRateMeter()
    private var kfTimes = ExpRateMeter()
    private var received = 0
    private var keyframesAccepted = 0
    private var policyRejects: [String: Int] = [:]
    private var droppedBusy = 0
    private var trackingText = "—"
    private var segment: UInt16 = 0
    private var segmentsCreated = 1
    private var lastNormalHost: Double = 0
    private var notNormalSince: Double?
    private var lastFrameTs: Double?
    private var lastFramePose: RTPose?
    private var policy = RTKeyframePolicy()
    private var lastKF: RTKeyframePolicy.Last?
    private var prev: RTKeyframePolicy.Last?
    private var lastBackgroundHost: Double = 0
    private var inFlight = false
    private var pending: RTJob?
    private var kfCounter: Int32 = 0
    private var clockDelta = 0.0
    private var running = false
    private var paused = false
    private var startedHost = 0.0
    private var pausedTotal = 0.0
    private var pauseStart: Double?
    private var segmentEvents: [(Double, String)] = []
    private var trackingTransitions = 0

    struct RTJob {
        var pb: CVPixelBuffer
        var timestamp: Double
        var pose: RTPose
        var K: RTIntrinsics
        var segment: UInt16
        var id: Int32
    }

    // MARK: 처리 쪽 상태 (procQueue에서만)
    private let map = RTGaussianMap()
    private var ring: [RTFrame] = []
    private var procSegment: UInt16 = 0
    private var gain: Float = 1
    private let mono = RTMonoDepth()
    private var monoLoadAttempted = false
    private var lastFit: RTAffineFit?
    private var lastFitHost: Double = 0
    private var lastFitSegment: UInt16 = 0
    private var lastMonoHost: Double = 0
    private var lastPublishedVersion = -1
    private var lastPublishHost: Double = 0
    private var pendingPublishCapture: [Double] = []
    private var noBaselineStreak = 0

    // 통계 상자(lock)
    private let statLock = NSLock()
    private var records: [RTKFRecord] = []
    private var processed = 0
    private var blurRejected = 0
    private var toMap: [Double] = []
    private var toPublish: [Double] = []
    private var stageSamples: [String: [Double]] = [:]
    private var reasonTotals: [String: Int] = [:]
    private var lastRecord: RTKFRecord?
    private var lastReasons: [String: Int] = [:]
    private var mapCounts = (alive: 0, verified: 0)
    private var totalInserted = 0, totalMerged = 0, totalReplaced = 0, totalCarved = 0, totalPruned = 0, totalDoubleRejected = 0
    private var reuseList: [Double] = []
    private var residuals: [Float] = []
    private var photoDiffs: [Double] = []
    private var refineColorDeltas: [Double] = []
    private var stereoFractions: [Double] = []
    private var monoFilled = 0, monoConflicts = 0, monoCarried = 0, monoRuns = 0
    private var hint = ""
    private var monoStatusText = "사용 안 함"
    private var governorLevel = 0
    private var governorChanges: [(Double, Int, String)] = []
    private var footprintPeak = 0.0
    private var thermalSeen = Set<String>()
    private var queueLenNow = 0
    private var maxQueueLen = 0
    private var cap = 300_000
    private var renderStatsLatest: RTRenderStats?

    private var timer: DispatchSourceTimer?
    private var autoStopSent = false

    init(options: RTOptions, log: ExperimentRunLog? = nil) {
        self.options = options
        self.log = log
        super.init()
        cap = options.maxGaussians
    }

    deinit { timer?.cancel() }

    func setOptions(_ o: RTOptions) {
        statLock.lock(); options = o; statLock.unlock()
    }

    private var currentOptions: RTOptions {
        statLock.lock(); defer { statLock.unlock() }
        return options
    }

    func updateRenderStats(_ s: RTRenderStats) {
        statLock.lock(); renderStatsLatest = s; statLock.unlock()
    }

    // MARK: 시작·일시정지·재개·종료

    private func makeConfig() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = []
        c.isLightEstimationEnabled = false
        // 4:3 영상 중 해상도가 가장 큰 30fps 포맷. 없으면 ARKit 기본값.
        let fmts = ARWorldTrackingConfiguration.supportedVideoFormats.filter {
            $0.framesPerSecond <= 30 && abs($0.imageResolution.width / $0.imageResolution.height - 4.0 / 3.0) < 0.02
        }
        if let best = fmts.max(by: { $0.imageResolution.width < $1.imageResolution.width }) { c.videoFormat = best }
        return c
    }

    func start() {
        arLock.lock()
        running = true; paused = false
        startedHost = ExpSys.hostNow()
        clockDelta = ExpSys.clockDelta()
        arLock.unlock()
        let cfg = makeConfig()
        var startInfo: [String: Any] = [:]
        startInfo["videoFormat"] = ["w": cfg.videoFormat.imageResolution.width, "h": cfg.videoFormat.imageResolution.height, "fps": cfg.videoFormat.framesPerSecond]
        startInfo["options"] = ["refine": options.refine, "useMono": options.useMono, "maxGaussians": options.maxGaussians, "showCamera": options.showCamera]
        startInfo["policy"] = ["minInterval": policy.minInterval, "minTranslation": policy.minTranslation, "minRotationDeg": policy.minRotationDeg]
        startInfo["buildSHA"] = GonggiBuildInfo.buildSHA
        startInfo["appVersion"] = GonggiBuildInfo.versionLine
        startInfo["machine"] = ExpSys.machine
        startInfo["model"] = RTMonoDepth.modelResource
        startInfo["algorithm"] = "ARKit pose + plane-sweep inverse-depth stereo (+affine-aligned mono prior) + surface gaussians + bounded refinement"
        log?.write("rt_start", startInfo)
        if currentOptions.useMono {
            procQueue.async { [weak self] in self?.loadMonoIfNeeded() }
        }
        session.delegate = self
        session.delegateQueue = arQueue
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        startMonitor()
    }

    private func loadMonoIfNeeded() {
        guard !monoLoadAttempted else { return }
        monoLoadAttempted = true
        let ok = mono.load()
        statLock.lock(); monoStatusText = mono.status; statLock.unlock()
        log?.write("rt_mono_load", ["ok": ok, "status": mono.status, "computeUnits": mono.computeUnits, "loadMs": mono.loadMs])
    }

    /// 입력을 멈춘다(카메라 해제). 처리 중인 작업은 끝까지 마친다.
    func pause() {
        arLock.lock()
        guard running, !paused else { arLock.unlock(); return }
        paused = true; pauseStart = ExpSys.hostNow()
        pending = nil
        arLock.unlock()
        session.pause()
        procQueue.sync {}            // 대기열 비우기
        procQueue.sync { self.publishIfNeeded(force: true) }
        log?.write("rt_pause", ["gaussians": map.aliveCount])
    }

    /// 새 세그먼트로 이어 간다(재개 직후에는 이전 좌표계와 일치한다고 가정하지 않는다).
    func resume() {
        arLock.lock()
        guard running, paused else { arLock.unlock(); return }
        paused = false
        if let ps = pauseStart { pausedTotal += ExpSys.hostNow() - ps; pauseStart = nil }
        startNewSegmentLocked(reason: "resume", host: ExpSys.hostNow())
        lastKF = nil; prev = nil
        arLock.unlock()
        session.run(makeConfig(), options: [])
        log?.write("rt_resume", ["segment": segment])
    }

    func stop() {
        timer?.cancel(); timer = nil
        arLock.lock(); let wasRunning = running; running = false; arLock.unlock()
        guard wasRunning else { return }
        session.pause()
        session.delegate = nil
        procQueue.sync {}
        procQueue.sync { self.publishIfNeeded(force: true) }
        log?.write("rt_stopped", ["gaussians": map.aliveCount])
    }

    var isPaused: Bool { arLock.lock(); defer { arLock.unlock() }; return paused }

    // MARK: ARSessionDelegate (arQueue)

    private func startNewSegmentLocked(reason: String, host: Double) {
        segment &+= 1
        segmentsCreated += 1
        segmentEvents.append((host, reason))
        lastKF = nil; prev = nil
        log?.write("rt_segment", ["segment": segment, "reason": reason])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let host = ExpSys.hostNow()
        let showCameraBG = currentOptions.showCamera
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
        arTimes.add(host)
        if trackingText != text { trackingTransitions += 1; log?.write("rt_tracking", ["state": text]) }
        trackingText = text
        // 세그먼트: 오래 정상이 아니었다가 돌아왔거나, 시간이 크게 벌어졌거나, 자세가 갑자기 튀었으면 새 세그먼트
        if normal {
            if let since = notNormalSince, host - since >= 1.0 { startNewSegmentLocked(reason: "tracking_recovered_after_\(Int(host - since))s", host: host) }
            notNormalSince = nil
            lastNormalHost = host
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

        // 라이브 배경 영상(작은 크기, 약 10Hz)
        let wantBG = showCameraBG && host - lastBackgroundHost > 0.1
        if wantBG { lastBackgroundHost = host }

        let decision = policy.evaluate(timestamp: frame.timestamp, pose: pose, trackingNormal: normal, last: lastKF,
                                       prev: prev)
        prev = RTKeyframePolicy.Last(timestamp: frame.timestamp, pose: pose)
        var job: RTJob?
        switch decision {
        case .accept:
            lastKF = RTKeyframePolicy.Last(timestamp: frame.timestamp, pose: pose)
            keyframesAccepted += 1
            kfCounter += 1
            kfTimes.add(host)
            job = RTJob(pb: frame.capturedImage, timestamp: frame.timestamp, pose: pose,
                        K: RTIntrinsics(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
                                        width: Int(imgW), height: Int(imgH)),
                        segment: seg, id: kfCounter)
        case .reject(let why):
            policyRejects[why, default: 0] += 1
        }
        var dispatchNow: RTJob?
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
        log?.write("rt_ar_error", ["domain": e.domain, "code": e.code, "description": e.localizedDescription])
    }

    func sessionWasInterrupted(_ session: ARSession) { log?.write("rt_ar_interrupted") }
    func sessionInterruptionEnded(_ session: ARSession) {
        arLock.lock(); startNewSegmentLocked(reason: "ar_interruption_ended", host: ExpSys.hostNow()); arLock.unlock()
        log?.write("rt_ar_interruption_ended")
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

    private func percentileMs(_ key: String) -> Double? {
        statLock.lock(); defer { statLock.unlock() }
        return RTStat.percentile(stageSamples[key] ?? [], 0.5)
    }

    private func process(_ job: RTJob) {
        defer { finishJob() }
        let tStart = ExpSys.hostNow()
        let captureHost = job.timestamp + clockDelta
        let opts = currentOptions
        statLock.lock()
        let level: Int = governorLevel
        statLock.unlock()
        if job.segment != procSegment { ring.removeAll(); procSegment = job.segment; gain = 1; lastFit = nil }

        // 1. 변환: 같은 ARFrame의 영상을 소유한 작은 복사본으로 (포즈·K·시각과 함께)
        guard let hi = RTFrameConverter.downscale(job.pb, outWidth: 640) else { return }
        let small = RTFrameConverter.halve(hi.rgb, width: hi.width, height: hi.height)
        let g = RTFrameConverter.gray(from: small.rgb, width: small.width, height: small.height)
        if g.sharpness < policy.minSharpness {
            statLock.lock(); blurRejected += 1; statLock.unlock()
            return
        }
        let frame = RTFrame(id: Int(job.id), segment: Int(job.segment), timestamp: job.timestamp, pose: job.pose,
                            kSmall: job.K.scaled(toWidth: small.width, height: small.height), grayS: g.gray, rgbS: small.rgb,
                            kHi: job.K.scaled(toWidth: hi.width, height: hi.height), rgbHi: hi.rgb, sharpness: g.sharpness, meanLuma: g.mean)
        let tConv = ExpSys.hostNow()

        // 2. 시간차 스테레오 (같은 세그먼트의 최근 키프레임을 참조)
        let refs = RTStereo.selectRefs(cur: frame, candidates: ring)
        var depth = RTStereo.estimate(cur: frame, refs: refs)
        let stereoValid = depth.validCount
        let tStereo = ExpSys.hostNow()

        // 3. 단안 사전값 (모델이 있고, 열/메모리 여유가 있고, 간격이 지났을 때만)
        var monoMs = 0.0
        var monoUsed = false
        if opts.useMono && level < 2 {
            loadMonoIfNeeded()
            let interval = level == 1 ? 1.6 : 0.8
            if mono.isReady && ExpSys.hostNow() - lastMonoHost >= interval {
                let tm = ExpSys.hostNow()
                lastMonoHost = tm
                if let m = mono.predict(rgb: hi.rgb, srcW: hi.width, srcH: hi.height, outW: depth.gw, outH: depth.gh) {
                    monoUsed = true
                    var fit = RTMonoAlign.fit(mono: m, depth: depth)
                    if let f = fit { lastFit = f; lastFitHost = tm; lastFitSegment = job.segment; statLock.lock(); monoRuns += 1; statLock.unlock() }
                    else if let lf = lastFit, lastFitSegment == job.segment, tm - lastFitHost < 2.0 {
                        var c = lf; c.carried = true; fit = c
                        statLock.lock(); monoCarried += 1; statLock.unlock()
                    }
                    if let fit {
                        let r = RTMonoAlign.apply(mono: m, fit: fit, to: &depth)
                        statLock.lock(); monoFilled += r.filled; monoConflicts += r.conflicts; statLock.unlock()
                    } else {
                        statLock.lock(); reasonTotals[RTReason.monoUnusable.label, default: 0] += 1; statLock.unlock()
                    }
                }
                monoMs = (ExpSys.hostNow() - tm) * 1000
            }
        }
        _ = monoUsed

        // 4. 표면 가우시안 생성 + 지도 융합
        let tFuse0 = ExpSys.hostNow()
        let built = RTSurfaceBuilder.build(frame: frame, depth: depth)
        let ctx = RTIntegrationContext(kf: job.id, segment: job.segment, camCenter: job.pose.center, colorGain: gain, maxGaussians: min(cap, opts.maxGaussians))
        let st = map.integrate(built.samples, ctx: ctx)
        let tFuse = ExpSys.hostNow()

        // 5. 가림 위반(떠다니는 가우시안) 제거, 가지치기, 상한
        let carved = map.carve(frame: frame, depth: depth, kf: job.id, segment: job.segment)
        let pruned = map.prune(currentKF: job.id)
        let capped = map.enforceCap(min(cap, opts.maxGaussians))
        let tCarve = ExpSys.hostNow()

        // 6. 정밀화 (끄거나 열/메모리 압박이면 건너뜀)
        var refineStats = RTRefiner.Stats()
        if opts.refine && level < 2 {
            if let ng = RTRefiner.estimateGain(frame: frame, map: map, hits: st.hits) { gain = 0.6 * gain + 0.4 * ng; refineStats.gain = gain }
            refineStats = RTRefiner.refine(frame: frame, map: map, hits: st.hits, gain: gain)
            refineStats.gain = gain
        }
        map.compactIfNeeded()
        let tRefine = ExpSys.hostNow()

        ring.append(frame)
        if ring.count > 8 { ring.removeFirst(ring.count - 8) }

        // 7. 기록·통계
        let reasons = depth.reasonCounts()
        var rejectedAll = reasons
        for (k, v) in built.rejected { rejectedAll[k.label, default: 0] += v }
        for (k, v) in st.rejected { rejectedAll[k.label, default: 0] += v }
        let total = st.inserted + st.merged + st.replaced
        let reuse = total > 0 ? Double(st.merged) / Double(total) : 0
        let resCm = RTStat.percentile(st.residuals.map { $0 * 100 }, 0.5).map { Double($0) }
        let photo = st.photoDiffs.isEmpty ? nil : Double(st.photoDiffs.reduce(0, +) / Float(st.photoDiffs.count))
        let toMapMs = (tRefine - captureHost) * 1000
        let nbFrac = depth.reason.isEmpty ? 0 : Double(depth.reason.filter { $0 == RTReason.noBaseline.rawValue }.count) / Double(depth.reason.count)
        noBaselineStreak = (nbFrac > 0.6 && refs.isEmpty) ? noBaselineStreak + 1 : 0
        let rec = RTKFRecord(id: job.id, segment: job.segment, captureHost: captureHost, toMapMs: toMapMs,
                             convertMs: (tConv - tStart) * 1000, stereoMs: (tStereo - tConv) * 1000, monoMs: monoMs,
                             fuseMs: (tFuse - tFuse0) * 1000, carveMs: (tCarve - tFuse) * 1000, refineMs: (tRefine - tCarve) * 1000,
                             refs: refs.count, validDepth: depth.validCount, stereoValid: stereoValid,
                             inserted: st.inserted, merged: st.merged, replaced: st.replaced, carved: carved + capped, reuse: reuse,
                             residualMedianCm: resCm, photoDiff: photo)
        statLock.lock()
        processed += 1
        records.append(rec); if records.count > 4000 { records.removeFirst(records.count - 4000) }
        lastRecord = rec
        lastReasons = rejectedAll
        for (k, v) in rejectedAll { reasonTotals[k, default: 0] += v }
        toMap.append(toMapMs); if toMap.count > 2000 { toMap.removeFirst() }
        func add(_ key: String, _ v: Double) { stageSamples[key, default: []].append(v); if stageSamples[key]!.count > 600 { stageSamples[key]!.removeFirst() } }
        add("convert", rec.convertMs); add("stereo", rec.stereoMs); add("fuse", rec.fuseMs); add("carve", rec.carveMs); add("refine", rec.refineMs)
        if monoMs > 0 { add("mono", monoMs) }
        totalInserted += st.inserted; totalMerged += st.merged; totalReplaced += st.replaced; totalCarved += carved + capped; totalPruned += pruned
        totalDoubleRejected += st.rejected[.doubleSurface] ?? 0
        if total > 0 { reuseList.append(reuse) }
        residuals.append(contentsOf: st.residuals.prefix(2000)); if residuals.count > 20000 { residuals.removeFirst(residuals.count - 20000) }
        if let photo { photoDiffs.append(photo) }
        if refineStats.colorUpdated > 0 { refineColorDeltas.append(Double(refineStats.colorDelta)) }
        let denom = Double(max(1, depth.reason.count))
        stereoFractions.append(Double(stereoValid) / denom)
        mapCounts = (map.aliveCount, map.verifiedCount)
        hint = noBaselineStreak >= 3 ? "제자리 회전만으로는 깊이를 알 수 없어요. 옆으로 천천히 이동해 주세요" : ""
        pendingPublishCapture.append(captureHost)
        statLock.unlock()

        var kfLog: [String: Any] = [:]
        kfLog["id"] = Int(job.id)
        kfLog["segment"] = Int(job.segment)
        kfLog["toMapMs"] = toMapMs
        kfLog["ms"] = ["convert": rec.convertMs, "stereo": rec.stereoMs, "mono": monoMs, "fuse": rec.fuseMs, "carve": rec.carveMs, "refine": rec.refineMs]
        kfLog["refs"] = refs.count
        kfLog["grid"] = [depth.gw, depth.gh]
        kfLog["validDepth"] = rec.validDepth
        kfLog["stereoValid"] = stereoValid
        kfLog["inserted"] = st.inserted
        kfLog["merged"] = st.merged
        kfLog["replaced"] = st.replaced
        kfLog["carved"] = carved
        kfLog["capped"] = capped
        kfLog["pruned"] = pruned
        kfLog["capReached"] = st.capReached
        kfLog["reuse"] = reuse
        kfLog["residualMedianCm"] = expNN(resCm)
        kfLog["photoDiff"] = expNN(photo)
        kfLog["gain"] = Double(gain)
        kfLog["refine"] = ["color": refineStats.colorUpdated, "normals": refineStats.normalsRefit, "colorDelta": Double(refineStats.colorDelta)]
        kfLog["reasons"] = rejectedAll
        kfLog["alive"] = map.aliveCount
        kfLog["verified"] = map.verifiedCount
        kfLog["sharpness"] = Double(g.sharpness)
        kfLog["governor"] = level
        log?.write("rt_kf", kfLog)
        publishIfNeeded(force: false)
    }

    /// 지도 변경이 있으면 렌더용 배열로 포장해 넘긴다(약 2.5Hz 이하).
    private func publishIfNeeded(force: Bool) {
        let now = ExpSys.hostNow()
        guard map.version != lastPublishedVersion else { return }
        guard force || now - lastPublishHost >= 0.4 else { return }
        let t0 = now
        var arr = [Float](repeating: 0, count: max(1, map.aliveCount) * RTGaussianMap.gpuStride)
        let n = arr.withUnsafeMutableBufferPointer { map.pack(into: $0.baseAddress!, capacity: max(1, map.aliveCount)) }
        splats.publish(packed: arr, count: n)
        RTViewerBounds.shared.bounds = map.bounds()
        lastPublishedVersion = map.version
        lastPublishHost = now
        let packMs = (ExpSys.hostNow() - t0) * 1000
        statLock.lock()
        for c in pendingPublishCapture { toPublish.append((ExpSys.hostNow() - c) * 1000) }
        if toPublish.count > 2000 { toPublish.removeFirst(toPublish.count - 2000) }
        pendingPublishCapture.removeAll()
        stageSamples["publish", default: []].append(packMs)
        statLock.unlock()
    }

    // MARK: 모니터 / 거버너 (monitorQueue)

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
        if level >= 2 { cap = Int(Double(options.maxGaussians) * 0.6) } else { cap = options.maxGaussians }
        statLock.unlock()
        if changed { log?.write("rt_governor", ["level": level, "thermal": ExpSys.thermalName(th), "footprintMB": fp]) }
        if level >= 3, !autoStopSent {
            autoStopSent = true
            log?.write("auto_stop", ["reason": level == 3 ? "thermal_or_memory" : "", "thermal": ExpSys.thermalName(th), "footprintMB": fp])
            onAutoStop?(th == .critical ? .thermal : .failed)
        }
    }

    func liveSnapshot() -> RTLive {
        var l = RTLive()
        let now = ExpSys.hostNow()
        arLock.lock()
        l.elapsed = running ? (now - startedHost - pausedTotal - (pauseStart.map { now - $0 } ?? 0)) : 0
        let recent = arTimes.times.suffix(200).filter { now - $0 <= 2 }
        l.arHz = recent.count > 1 ? Double(recent.count - 1) / max(recent.last! - recent.first!, 0.001) : nil
        let kr = kfTimes.times.suffix(60).filter { now - $0 <= 5 }
        l.keyframeHz = kr.count > 1 ? Double(kr.count - 1) / max(kr.last! - kr.first!, 0.001) : nil
        l.tracking = trackingText; l.segment = Int(segment); l.keyframes = keyframesAccepted; l.droppedBusy = droppedBusy
        l.queueLen = (inFlight ? 1 : 0) + (pending != nil ? 1 : 0)
        l.paused = paused
        arLock.unlock()
        statLock.lock()
        l.processed = processed; l.blurRejected = blurRejected
        l.latencyToMapP50 = RTStat.percentile(toMap, 0.5); l.latencyToMapP95 = RTStat.percentile(toMap, 0.95)
        l.latencyToPublishP50 = RTStat.percentile(toPublish, 0.5); l.latencyToPublishP95 = RTStat.percentile(toPublish, 0.95)
        for (k, v) in stageSamples { if let p = RTStat.percentile(v, 0.5) { l.stageMs[k] = p } }
        l.gaussians = mapCounts.alive; l.verified = mapCounts.verified; l.provisional = mapCounts.alive - mapCounts.verified
        l.lastInserted = lastRecord?.inserted ?? 0; l.lastMerged = lastRecord?.merged ?? 0; l.lastValidDepth = lastRecord?.validDepth ?? 0
        l.lastReasons = lastReasons
        l.stereoFraction = stereoFractions.last
        l.reuseRatio = reuseList.suffix(20).isEmpty ? nil : reuseList.suffix(20).reduce(0, +) / Double(reuseList.suffix(20).count)
        l.mergeResidualCm = RTStat.percentile(residuals.suffix(4000).map { $0 * 100 }, 0.5).map { Double($0) }
        l.monoStatus = monoStatusText; l.governor = governorLevel; l.hint = hint
        maxQueueLen = max(maxQueueLen, l.queueLen)
        statLock.unlock()
        l.footprintMB = ExpSys.footprintMB(); l.thermal = ExpSys.thermal
        return l
    }

    private func logHeartbeat(_ l: RTLive) {
        statLock.lock(); let rs = renderStatsLatest; statLock.unlock()
        var hb: [String: Any] = [:]
        hb["elapsed"] = l.elapsed
        hb["arHz"] = expNN(l.arHz)
        hb["keyframeHz"] = expNN(l.keyframeHz)
        hb["tracking"] = l.tracking
        hb["segment"] = l.segment
        hb["keyframes"] = l.keyframes
        hb["processed"] = l.processed
        hb["droppedBusy"] = l.droppedBusy
        hb["blurRejected"] = l.blurRejected
        hb["queueLen"] = l.queueLen
        hb["toMapMsP50"] = expNN(l.latencyToMapP50)
        hb["toMapMsP95"] = expNN(l.latencyToMapP95)
        hb["toPublishMsP50"] = expNN(l.latencyToPublishP50)
        hb["toPublishMsP95"] = expNN(l.latencyToPublishP95)
        hb["stageMsP50"] = l.stageMs
        hb["gaussians"] = l.gaussians
        hb["verified"] = l.verified
        hb["provisional"] = l.provisional
        hb["reuse"] = expNN(l.reuseRatio)
        hb["mergeResidualCm"] = expNN(l.mergeResidualCm)
        if let r = rs {
            var rd: [String: Any] = [:]
            rd["fps"] = r.fps; rd["cpuMsP50"] = r.cpuMsP50; rd["cpuMsP95"] = r.cpuMsP95; rd["gpuMsP50"] = r.gpuMsP50; rd["gpuMsP95"] = r.gpuMsP95
            rd["drawn"] = r.drawn; rd["visible"] = r.visible; rd["dropped"] = r.dropped; rd["sortMsP50"] = r.sortMsP50
            hb["render"] = rd
        }
        hb["footprintMB"] = expNN(l.footprintMB)
        hb["thermal"] = l.thermal
        hb["governor"] = l.governor
        hb["mono"] = l.monoStatus
        log?.write("rt_hb", hb)
    }

    // MARK: 저장

    struct SaveResult {
        var item: RTStore.Item?
        var error: String?
        var count: Int
    }

    /// 지도를 PLY(3DGS 표준 속성)와 메타 JSON으로 저장한다. 가우시안이 없으면 저장하지 않는다.
    func save(summaryText: String) -> SaveResult {
        var out = SaveResult(item: nil, error: nil, count: 0)
        procQueue.sync {
            let set = map.splatSet(includeProvisional: true)
            out.count = set.count
            guard set.count > 0 else { out.error = "저장할 가우시안이 없어요"; return }
            do {
                try RTStore.ensureDirectory()
                let base = RTStore.newBaseName()
                let url = RTStore.directory.appendingPathComponent(base + ".ply")
                try RTPLY.write(set, to: url)
                let meta: [String: Any] = [
                    "gaussians": set.count, "verified": map.verifiedCount, "provisional": map.provisionalCount,
                    "segments": segmentsCreated, "buildSHA": GonggiBuildInfo.buildSHA, "appVersion": GonggiBuildInfo.versionLine,
                    "machine": ExpSys.machine, "refine": options.refine, "useMono": options.useMono,
                    "format": "3DGS PLY (binary little endian): x y z nx ny nz f_dc_0..2 opacity(logit) scale_0..2(log) rot_0..3(wxyz). 구분 정보(확인됨/임시)는 포함하지 않음",
                    "coordinates": "ARKit 세계 좌표(중력 정렬, y 위), 세그먼트 구분 없이 합쳐 저장(세그먼트 간 정합은 검증하지 않음)"
                ]
                if let d = try? JSONSerialization.data(withJSONObject: expJSONSafe(meta), options: [.sortedKeys, .prettyPrinted]) {
                    try d.write(to: RTStore.directory.appendingPathComponent(base + ".meta.json"))
                }
                try summaryText.write(to: RTStore.directory.appendingPathComponent(base + ".summary.txt"), atomically: true, encoding: .utf8)
                out.item = RTStore.list().first { $0.url == url }
            } catch {
                out.error = "저장 실패: \(error.localizedDescription)"
            }
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
        let recs = records, tm = toMap, tp = toPublish, rt = reasonTotals, reuse = reuseList, res = residuals, photo = photoDiffs
        let ins = totalInserted, mer = totalMerged, rep = totalReplaced, car = totalCarved, pru = totalPruned, dbl = totalDoubleRejected
        let mf = monoFilled, mc = monoConflicts, mca = monoCarried, mr = monoRuns, ms = monoStatusText
        let fp = footprintPeak, th = Array(thermalSeen).sorted(), gov = governorChanges, rcd = refineColorDeltas, sf = stereoFractions
        let mq = maxQueueLen, proc = processed, blur = blurRejected
        var stage: [String: Double] = [:], stage95: [String: Double] = [:]
        for (k, v) in stageSamples { stage[k] = RTStat.percentile(v, 0.5) ?? 0; stage95[k] = RTStat.percentile(v, 0.95) ?? 0 }
        statLock.unlock()
        func f(_ v: Double?, _ d: Int = 0) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "—" }
        let p50 = RTStat.percentile(tm, 0.5), p95 = RTStat.percentile(tm, 0.95)
        let q50 = RTStat.percentile(tp, 0.5), q95 = RTStat.percentile(tp, 0.95)
        let reuseMean = reuse.isEmpty ? nil : reuse.reduce(0, +) / Double(reuse.count)
        let resMed = RTStat.percentile(res.map { Double($0 * 100) }, 0.5), res95 = RTStat.percentile(res.map { Double($0 * 100) }, 0.95)
        let photoMean = photo.isEmpty ? nil : photo.reduce(0, +) / Double(photo.count)
        let stereoMean = sf.isEmpty ? nil : sf.reduce(0, +) / Double(sf.count)

        var t = "실시간 공간 생성 요약\n종료: \(endReason.label)\n\n"
        t += "[구분] 아래 값은 모두 이 기기에서 이번 실행 중 측정한 값입니다. 목표값(30fps, p95 500ms)과 비교할 때 관측에 필요한 이동 시간은 포함되지 않습니다.\n\n"
        t += "입력\n  ARKit 프레임 \(recv)개, 키프레임 채택 \(kfs)개, 처리 \(proc)개, 대기 중 버려진 것 \(dropped)개, 흐림으로 거부 \(blur)개\n"
        t += "  키프레임 거부 사유: \(rejects.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        t += "  추적 상태 전환 \(trans)회, 세그먼트 \(segs)개 (\(events.joined(separator: ", ")))\n\n"
        t += "지연 (캡처 시각 → 지도 반영 / → 렌더용 배열 게시)\n  지도 반영 p50 \(f(p50)) ms, p95 \(f(p95)) ms\n  게시 p50 \(f(q50)) ms, p95 \(f(q95)) ms (게시는 0.4초 이상 간격)\n"
        t += "  단계별 p50/p95(ms): " + stage.keys.sorted().map { "\($0) \(f(stage[$0]))/\(f(stage95[$0]))" }.joined(separator: ", ") + "\n"
        t += "  처리 대기열 최대 \(mq)\n\n"
        t += "지도\n  가우시안 \(l.gaussians)개 (확인됨 \(l.verified), 임시 \(l.provisional))\n"
        t += "  누적: 추가 \(ins), 병합 \(mer), 교체 \(rep), 가림 위반/상한으로 제거 \(car), 가지치기 \(pru), 이중 표면 거부 \(dbl)\n"
        t += "  재사용 비율(병합/전체) 평균 \(f(reuseMean.map { $0 * 100 }))%, 병합 시 법선 방향 차이 중앙값 \(f(resMed, 2)) cm / p95 \(f(res95, 2)) cm\n"
        t += "  병합 전 저장 색과 관측 색의 평균 차이 \(f(photoMean.map { $0 * 100 }, 1))% (정밀화 켠/끈 실행끼리 비교)\n"
        t += "  깊이 격자 중 스테레오 확정 비율 평균 \(f(stereoMean.map { $0 * 100 }))%\n"
        t += "  거부/미확정 사유 누적: \(rt.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n\n"
        t += "단안 깊이\n  상태: \(ms)\n  정렬 성공 \(mr)회, 직전 정렬 이어쓰기 \(mca)회, 임시 채움 \(mf)점, 스테레오와 충돌해 제거 \(mc)점\n\n"
        t += "정밀화\n  \(currentOptions.refine ? "켜짐" : "꺼짐"); 색 갱신 평균 변화량 \(f(rcd.isEmpty ? nil : rcd.reduce(0, +) / Double(rcd.count) * 100, 2))%, 노출 보정 gain \(String(format: "%.2f", gain))\n\n"
        if let r = render {
            t += "렌더\n  \(String(format: "%.1f", r.fps)) fps, CPU p50/p95 \(f(r.cpuMsP50, 1))/\(f(r.cpuMsP95, 1)) ms, GPU p50/p95 \(f(r.gpuMsP50, 1))/\(f(r.gpuMsP95, 1)) ms, 그린 수 \(r.drawn)/\(r.total) (보이는 \(r.visible), 예산으로 버림 \(r.dropped)), 정렬 p50 \(f(r.sortMsP50, 1)) ms\n  (렌더 FPS는 생성 속도가 아닙니다)\n\n"
        }
        t += "자원\n  메모리 피크 \(f(fp)) MB, 열 상태 \(th.joined(separator: ", ")), 거버너 변경 \(gov.count)회\n\n"
        t += "해석 주의\n  - 이 값은 단일 장면·단일 실행의 측정이며 정확도(실제 거리 오차)가 아닙니다. 병합 차이는 지도와 새 관측 사이의 자기 일관성입니다.\n  - 다른 시점의 PSNR/SSIM과 구멍 비율은 이 앱이 측정하지 않았습니다.\n  - 세그먼트가 둘 이상이면 서로 다른 좌표계로 간주하며 병합하지 않았습니다.\n"

        var d: [String: Any] = [:]
        d["endReason"] = endReason.rawValue
        d["received"] = recv; d["keyframes"] = kfs; d["processed"] = proc; d["droppedBusy"] = dropped; d["blurRejected"] = blur
        d["policyRejects"] = rejects; d["segments"] = segs; d["segmentEvents"] = events; d["trackingTransitions"] = trans
        d["toMapMsP50"] = expNN(p50); d["toMapMsP95"] = expNN(p95); d["toPublishMsP50"] = expNN(q50); d["toPublishMsP95"] = expNN(q95)
        d["stageMsP50"] = stage; d["stageMsP95"] = stage95; d["maxQueueLen"] = mq
        d["gaussians"] = l.gaussians; d["verified"] = l.verified; d["provisional"] = l.provisional
        d["inserted"] = ins; d["merged"] = mer; d["replaced"] = rep; d["removedByCarveOrCap"] = car; d["pruned"] = pru; d["doubleSurfaceRejected"] = dbl
        d["reuseMean"] = expNN(reuseMean); d["mergeResidualCmMedian"] = expNN(resMed); d["mergeResidualCmP95"] = expNN(res95)
        d["photoDiffMean"] = expNN(photoMean); d["stereoFractionMean"] = expNN(stereoMean); d["reasonTotals"] = rt
        d["mono"] = ["status": ms, "fits": mr, "carried": mca, "filled": mf, "conflicts": mc] as [String: Any]
        d["refine"] = currentOptions.refine; d["footprintPeakMB"] = fp; d["thermalSeen"] = th; d["governorChanges"] = gov.count
        if let r = render {
            var rd: [String: Any] = [:]
            rd["fps"] = r.fps; rd["cpuMsP50"] = r.cpuMsP50; rd["cpuMsP95"] = r.cpuMsP95; rd["gpuMsP50"] = r.gpuMsP50; rd["gpuMsP95"] = r.gpuMsP95
            rd["drawn"] = r.drawn; rd["total"] = r.total; rd["visible"] = r.visible; rd["dropped"] = r.dropped
            d["render"] = rd
        }
        return (t, d)
    }
}

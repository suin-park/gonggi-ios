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
    var modelState = "대기"                // 준비 전 / 준비됨 / 사용 안 함
    var optimizerState = "대기"            // 실행 중 / 부하 낮춤(정밀화 중지) / 열·메모리 제한으로 중지 / 꺼짐
    var refineState = "대기"
    var splitsTotal = 0
    var refineIterations = 0
    var lastRollbackReason = ""
    var validationSkips = 0
    var hiCacheMB: Double?
    var gapTop = ""
    var resolutionText = ""
    var suspectTotal = 0
    // 제품 모드
    var isProduct = false
    var phase = ""                         // 대상 선택 / 촬영 / 일시정지
    var maskStatus = ""                    // 추적 중 / 불확실 / 놓침
    var maskTrusted = 0, maskUncertain = 0
    var maskMsP50: Double?
    var maskNote = ""
    var boundsText = ""
    var refineCellsPct: Double?, refineGaussiansPct: Double?
    var bgLeak: Double?
    var productPixels = 0
    var budgetText = ""
    var refineKind = ""
    var coverageText = ""
    var texText = ""
}

/// 엔진이 모으는 추가 통계(정밀화·검증·미생성 이유·중지 구간).
struct GSOExtraStats {
    var refineIterations = 0
    var refineMs = 0.0
    var refineSlices = 0
    var splits = 0
    var suspect = 0
    var validationMs = 0.0
    var validatedSlices = 0
    var validationSkipped = 0
    var rollbackReasons: [String: Int] = [:]
    var gapTotals: [String: Int] = [:]
    var candidatePixels = 0
    var thermalSkipMs = 0.0                 // 열·메모리 제한으로 최적화를 쉰 시간 합계(초)
    var pauseEvents: [(host: Double, event: String)] = []
    var optimizerPausedSince: Double?
    var resolutionLogged = false
    // 제품 모드 계산 예산
    var budgetSlices = 0
    var budgetWaits = 0
    var budgetPlannedMs = 0.0
    var budgetActualMs = 0.0
    var budgetOverMs = 0.0
    var splitsRolledBack = 0
    var refineKinds: [String: Int] = [:]
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
    /// 텍스처 스플랫 레이어 경로(config.textureLayers). 가우시안 경로의 pipeline은 이때 쓰이지 않는다.
    let texPipeline: TexLayerPipeline?
    let texStore = TexLayerStore()
    private let mono: RTMonoDepth
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
    private var extra = GSOExtraStats()
    private var lastRollbackReason = ""
    private var displaySizeText = ""
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
    // 제품 모드
    let maskProvider: GSOInstanceMaskProvider?
    let tracker: GSOProductMaskTracker?
    var onPreviewMask: ((GSOProductMask?, String) -> Void)?
    private var previewMode = false
    private var latestFrame: (pb: CVPixelBuffer, pose: RTPose, k: RTIntrinsics)?
    private var maskSamples: [Double] = []
    private var maskStats = (trusted: 0, uncertain: 0)
    private var maskNoteLast = ""
    private var progressLatest = GSORefineProgress()
    private var bgLeakLast: Double?
    private var productPixelsLast = 0
    private var refineKindLast = ""
    private var optWindow: [(end: Double, ms: Double)] = []
    private var budgetText = ""
    var isProduct: Bool { config.product != nil }

    init(options: GSOOptions, config: GSOConfig = GSOConfig(), log: ExperimentRunLog? = nil, splats: RTSharedSplats = RTSharedSplats(),
         liveCam: RTLiveCameraStore = RTLiveCameraStore(), background: RTBackgroundStore = RTBackgroundStore(), mono: RTMonoDepth = RTMonoDepth(),
         maskProvider: GSOInstanceMaskProvider? = nil, tracker: GSOProductMaskTracker? = nil) {
        self.options = options
        self.mono = mono
        self.maskProvider = maskProvider
        self.tracker = tracker
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
        texPipeline = cfg.textureLayers ? TexLayerPipeline() : nil
        super.init()
    }

    deinit { timer?.cancel() }

    func setOptions(_ o: GSOOptions) { statLock.lock(); options = o; statLock.unlock() }
    private var currentOptions: GSOOptions { statLock.lock(); defer { statLock.unlock() }; return options }

    func noteRenderStats(_ s: RTRenderStats) { statLock.lock(); renderStatsLatest = s; statLock.unlock() }
    func noteDisplaySize(_ w: Int, _ h: Int) { statLock.lock(); displaySizeText = "\(w)x\(h)"; statLock.unlock() }

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

    /// 제품 모드는 대상 선택 단계(preview)로 시작한다: 카메라와 ARKit 추적만 돌고 키프레임은 만들지 않는다. beginCapture()로 촬영을 시작한다.
    func start(runDirectoryForReplay: URL? = nil, preview: Bool = false) {
        statLock.lock(); previewMode = preview; statLock.unlock()
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
                // 화면을 열 때 미리 읽어 둔 모델이면 다시 읽지 않는다(첫 실행의 Neural Engine 컴파일에 약 50초가 걸렸다).
                let ok = self.mono.isReady ? true : self.mono.load()
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
        info["sceneOptimization"] = texPipeline == nil
        info["pretrainedModelInference"] = "Depth Anything V2 Small (Core ML, 기기 내 추론만, 재학습 없음)"
        info["orientation"] = "capturedImage=sensorLandscapeRight, display=portrait(app locked)"
        info["algorithm"] = texPipeline != nil
            ? "ARKit pose + stereo anchors + monocular depth (inverse-depth locked) aligned to anchors -> mask guard -> per-keyframe textured surfel layers (8x8 texels per 8x8-pixel cell) -> coverage-based layer selection + same-surface consensus blend. No gaussians, no per-scene optimisation."
            : "ARKit pose + stereo anchors + monocular depth aligned to anchors -> persistent gaussians -> on-device photometric optimisation (sparse Adam, CPU forward/backward)"
        info["representation"] = texPipeline != nil ? "texture-layers" : "gaussians"
        if let pc = config.product {
            info["product"] = ["enabled": true, "minKeyframeIntervalS": pc.minKeyframeInterval, "bgAlphaWeight": Double(pc.bgAlphaWeight), "bgFloorLogit": Double(pc.bgFloorLogit),
                               "optDuty": pc.optDuty, "hiValidation": pc.hiValidation, "maskGrid": "\(tracker?.config.gridWidth ?? 0)x\(tracker?.config.gridHeight ?? 0)",
                               "maskBandRadius": tracker?.config.bandRadius ?? 0, "maskSource": "Vision VNGenerateForegroundInstanceMaskRequest (기기 내)"]
            info["productMode"] = "고정된 제품 + 움직이는 휴대폰. 돌림판·손에 들고 돌리는 방식은 물체 포즈 추정이 없어 지원하지 않는다."
        }
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

    /// 저장하지 않고 끝낼 때 연구 기록 임시 폴더를 지운다.
    func discardReplay() { procQueue.sync { recorder?.discard(); recorder = nil } }

    // MARK: 제품 모드: 대상 선택·촬영 시작

    /// 대상 선택을 마치고 촬영(키프레임 생성)을 시작한다. 이미 돌고 있는 ARKit 추적은 그대로 이어진다.
    func beginCapture() {
        statLock.lock(); previewMode = false; statLock.unlock()
        arLock.lock(); startedHost = ExpSys.hostNow(); firstInputHost = nil; lastKF = nil; prev = nil; arLock.unlock()
        log?.write("product_capture_begin", ["targetID": tracker?.targetID ?? 0])
    }

    /// 화면(세로, 센서 영상을 맞춤으로 놓은 뷰)의 정규화 탭 위치에서 제품을 고른다. 마지막 카메라 프레임 한 장에 Vision 마스크를 돌린다(기기 내).
    /// completion은 백그라운드 큐에서 불린다.
    func selectTarget(viewTap: CGPoint, viewSize: CGSize, completion: @escaping (GSOProductMask?, String) -> Void) {
        statLock.lock(); let fr = latestFrame; statLock.unlock()
        guard let fr, let prov = maskProvider, let trk = tracker else { completion(nil, "카메라 영상이 아직 없어요"); return }
        let imgW = Float(fr.k.width), imgH = Float(fr.k.height)
        let m = RTViewMath.portraitMapping(imgW: imgW, imgH: imgH, viewW: Float(viewSize.width), viewH: Float(viewSize.height))
        let xp = Float(viewTap.x * viewSize.width), yp = Float(viewTap.y * viewSize.height)
        let u = (yp - m.ty) / m.m10, v = (m.tx - xp) / m.m10          // xp = tx − s·v, yp = ty + s·u
        let nu = u / imgW, nv = v / imgH
        guard nu >= 0, nu <= 1, nv >= 0, nv <= 1 else { completion(nil, "카메라 화면 안을 탭해 주세요"); return }
        loadQueue.async { [weak self] in
            guard let inst = prov.instanceMasks(pixelBuffer: fr.pb) else { completion(nil, "제품을 찾지 못했어요"); return }
            if let mk = trk.select(instances: inst, tap: SIMD2<Float>(nu, nv)) {
                self?.log?.write("product_select", ["targetID": trk.targetID, "areaFraction": Double(mk.areaFraction), "instances": inst.instanceCount, "tap": [Double(nu), Double(nv)]])
                completion(mk, "선택했어요. 초록 영역이 제품 전체를 덮는지 확인하세요")
            } else {
                completion(nil, "그 위치에서 제품을 찾지 못했어요. 제품을 직접 탭해 주세요")
            }
        }
    }

    /// 지금까지 모은 제품 3D 중심을 이 프레임에 투영한 센서 영상 정규화 좌표(마스크 추적에서 같은 대상을 고르는 단서).
    private func projectedProductCenter(_ job: SV2Engine.Job) -> SIMD2<Float>? {
        var centre = pipeline.productBounds.center
        if let tp = texPipeline, let b = TexLayerSelect.robustBounds(tp.layers) { centre = (b.min + b.max) * 0.5 }
        guard let c = centre else { return nil }
        let p = job.pose.worldToCam(c)
        guard p.z > 0.05 else { return nil }
        return SIMD2<Float>((job.K.fx * p.x / p.z + job.K.cx) / Float(job.K.width), (job.K.fy * p.y / p.z + job.K.cy) / Float(job.K.height))
    }

    /// 저장 메타: 제품 중심·좌표계·스케일의 의미·정밀화 진행·마스크 통계.
    private func productMeta() -> [String: Any] {
        let pb = pipeline.productBounds
        var d: [String: Any] = ["productMode": true, "targetID": tracker?.targetID ?? 1, "productBoundsValid": pb.isValid]
        func arr(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }
        if let tp = texPipeline, let tb = TexLayerSelect.robustBounds(tp.layers) {
            d["productBounds"] = ["min": arr(tb.min), "max": arr(tb.max)]
            d["productCenter"] = arr((tb.min + tb.max) * 0.5)
            d["productExtentMeters"] = arr(tb.max - tb.min)
            d["productBoundsValid"] = true
            d["representation"] = "texture-layers"
            d["textureLayers"] = texStatsDict(tp)
        } else if let b = pb.box {
            d["productBounds"] = ["min": arr(b.lo), "max": arr(b.hi)]
            d["productExtentMeters"] = arr(b.hi - b.lo)
        }
        if let c = pb.center { d["productCenter"] = arr(c) }
        d["coordinateSystem"] = "ARKit 세계 좌표(중력 정렬, y 위, 단위 m). 원점은 ARSession 시작 위치이며 제품 중심은 productCenter."
        d["scaleMeaning"] = "ARKit 포즈에 맞춘 스테레오 앵커 기준의 미터 추정치. 실제 치수 정확도는 검증되지 않았다."
        d["unobservedNote"] = "관측하지 않은 면(뒷면 등)은 복원하지 않는다. 비어 있는 부분은 복원 실패가 아니라 미관측일 수 있다."
        d["captureMode"] = "고정된 제품 + 움직이는 휴대폰(돌림판·손에 들고 돌리는 방식은 지원하지 않음)"
        statLock.lock()
        let prog = progressLatest
        d["refineProgress"] = ["cellsRefined": prog.cellsRefined, "cellsTotal": prog.cellsTotal, "gaussiansRefined": prog.gaussiansRefined, "gaussiansTotal": prog.gaussiansTotal]
        d["viewCoverage"] = ["azimuthObserved": prog.azimuthObserved, "azimuthBins": prog.azimuthBins, "directionCells": prog.directionCells, "directionBins": prog.directionBins,
                             "insufficientGaussianShare": Double(prog.insufficientShare), "note": "관측하지 않은 방향의 면은 복원하지 않는다. 관측했지만 복원이 부족한 가우시안(임시 또는 관측 3회 미만)은 따로 센다."]
        d["maskStats"] = ["trusted": maskStats.trusted, "uncertain": maskStats.uncertain]
        statLock.unlock()
        return d
    }

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
        statLock.lock(); let preview = previewMode; statLock.unlock()
        let showBG = currentOptions.showCamera || preview
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
        if preview {
            statLock.lock()
            latestFrame = (frame.capturedImage, pose, RTIntrinsics(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y, width: Int(imgW), height: Int(imgH)))
            statLock.unlock()
        }
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
        if let pc = config.product { pol.minInterval = max(pol.minInterval, pc.minKeyframeInterval) }      // 새 깊이·지도 추가 최대 초당 3회
        if level >= 2 { pol.minInterval *= 2 }
        var decision = pol.evaluate(timestamp: frame.timestamp, pose: pose, trackingNormal: normal, last: lastKF, prev: prev)
        if preview { decision = .reject("preview") }
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
        if wantBG, let bg = RTFrameConverter.downscale(frame.capturedImage, outWidth: preview ? 360 : 160) {
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
        // 원본(센서 1920×1440 등)에서 직접 960폭 영상을 만든다. 정밀화(고해상도 창)는 연구 기록 옵션과 무관하게 이 영상을 쓰고,
        // 연구 기록은 같은 영상을 디스크에 저장할지만 정한다.
        let width = 960
        guard let input = SV2Engine.makeInput(job: job, hiWidth: width, clockDelta: clockDelta) else { return }
        let tConv = ExpSys.hostNow()
        // 제품 모드: 같은 ARFrame의 원본 버퍼에서 기기 내 Vision 마스크를 만들고 대상 ID를 유지하며 갱신한다(RGB·포즈·K·시각·노출·마스크가 같은 프레임).
        var mask: GSOProductMask?
        var maskMs = 0.0
        if config.product != nil, let prov = maskProvider, let trk = tracker {
            let tm = ExpSys.hostNow()
            let inst = prov.instanceMasks(pixelBuffer: job.pb)
            mask = trk.track(instances: inst, projectedCenter: projectedProductCenter(job))
            maskMs = (ExpSys.hostNow() - tm) * 1000
            statLock.lock()
            maskSamples.append(maskMs); if maskSamples.count > 400 { maskSamples.removeFirst() }
            if mask?.trusted == true { maskStats.trusted += 1 } else { maskStats.uncertain += 1 }
            maskNoteLast = mask?.note ?? ""
            statLock.unlock()
            log?.write("product_mask", ["id": input.id, "trusted": mask?.trusted ?? false, "note": mask?.note ?? "", "iou": Double(mask?.iou ?? 0),
                                        "area": Double(mask?.areaFraction ?? 0), "ms": maskMs, "status": trk.status.rawValue, "targetID": trk.targetID])
        }
        recorder?.record(input, mask: mask)
        statLock.lock(); let monoOK = monoLoaded; statLock.unlock()
        var rec = texPipeline?.process(input, mono: monoOK ? mono : nil, mask: mask) ?? pipeline.process(input, mono: monoOK ? mono : nil, mask: mask)
        rec.convertMs += (tConv - tStart) * 1000
        let tDone = ExpSys.hostNow()
        rec.toMapMs = (tDone - captureHost) * 1000
        if rec.skipped != nil {
            statLock.lock()
            if rec.skipped == "maskUncertain" || rec.skipped == "maskContaminated" { for (k, v) in rec.gaps { extra.gapTotals[k, default: 0] += v } } else { blurRejected += 1 }
            statLock.unlock()
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
        for (k, v) in rec.gaps { extra.gapTotals[k, default: 0] += v }
        extra.candidatePixels += rec.candidatePixels
        extra.suspect += rec.suspectMarked
        add("hi", rec.hiMs)
        counts = (rec.count, rec.states[0], rec.states[1], rec.states[2])
        if noBaselineStreak >= 3 {
            hint = "제자리 회전만으로는 깊이를 알 수 없어요. 옆으로 천천히 이동해 주세요"
            depthStatus = "시차 부족: 아직 검증된 깊이가 없어요"
        } else {
            hint = ""
            depthStatus = rec.count == 0 ? "표면을 찾는 중" : (rec.denseSource == "mono" ? "가우시안 생성·최적화 중" : "스테레오로 생성 중(단안 정렬 대기)")
        }
        statLock.unlock()
        if !extra.resolutionLogged {
            extra.resolutionLogged = true
            var res = rec.resolutions.mapValues { $0 as Any }
            res["display"] = displaySizeText
            log?.write("gso_resolutions", res)
        }
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
        d["gaps"] = r.gaps; d["candidatePixels"] = r.candidatePixels
        d["insertedRecovery"] = r.insertedRecovery; d["suspectMarked"] = r.suspectMarked; d["hiMs"] = r.hiMs
        d["rotationOnlySkipped"] = r.rotationOnlySkipped; d["fitScaleRatio"] = Double(r.fitScaleRatio); d["alignFailed"] = r.alignFailed
        d["mask"] = ["trusted": r.maskTrusted, "note": r.maskNote, "iou": Double(r.maskIoU), "productPixels": r.productPixels, "boundsPoints": r.boundsPoints, "boundsValid": r.boundsValid, "outOfBounds": r.outOfBounds]
        d["gaussians"] = r.count
        d["states"] = ["temporary": r.states[0], "candidate": r.states[1], "stable": r.states[2]]
        return d
    }

    // MARK: 최적화 스케줄링

    /// 지도 큐가 비어 있을 때 최적화 묶음을 이어서 실행한다. 새 키프레임이 도착하면 다음 묶음 전에 그것을 먼저 처리한다.
    private func scheduleOptimize() {
        statLock.lock()
        let level = governorLevel
        let want = options.optimize && !autoStopSent && texPipeline == nil
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
        var iters = level >= 1 ? 4 : 8
        let now = ExpSys.hostNow()
        var window = 0.045
        var plannedMs = 45.0
        var usedMs = 0.0
        var allowedMs = 0.0
        if let pc = config.product {
            // 계산 예산: 키프레임을 줄여도 남는 시간을 무제한 최적화가 쓰지 않도록, 한 시계 초 안에서 최적화가 쓸 수 있는 시간 비율(optDuty, 부하가 있으면 절반)을 지킨다.
            // 반복 수 × 가우시안 수 상한도 둔다. 설정한 예산과 실제 실행 시간의 차이는 gso_opt 로그와 요약에 남긴다.
            statLock.lock()
            optWindow.removeAll { now - $0.end > 1.0 }
            usedMs = optWindow.reduce(0) { $0 + $1.ms }
            statLock.unlock()
            allowedMs = (level >= 1 ? pc.optDuty * 0.5 : pc.optDuty) * 1000
            if usedMs >= allowedMs {
                statLock.lock(); extra.budgetWaits += 1; statLock.unlock()
                optTickScheduled = true
                procQueue.asyncAfter(deadline: .now() + min(0.25, (usedMs - allowedMs) / 1000 + 0.03)) { [weak self] in self?.optimizeTick() }
                return
            }
            iters = pc.iterationCap(gaussians: pipeline.map.count, base: iters)
            plannedMs = min(45, allowedMs - usedMs)
            window = plannedMs / 1000
        }
        // 고해상도 정밀화는 부하가 없을 때만(열 fair·AR 프레임 저하 등으로 level ≥ 1이면 쉰다)
        let s = pipeline.optimizeSlice(maxIterations: iters, deadlineHost: now + window, allowRefine: level == 0)
        if config.product != nil {
            let prog = pipeline.refineProgress()
            statLock.lock()
            optWindow.append((ExpSys.hostNow(), s.wallMs))
            progressLatest = prog
            if s.productPixels > 0 { productPixelsLast = s.productPixels; bgLeakLast = Double(s.bgLeak) }
            if !s.refineCell.isEmpty, s.refineIterations > 0 { extra.refineKinds[s.refineCell, default: 0] += 1; refineKindLast = s.refineCell }
            extra.splitsRolledBack += s.splitsRolledBack
            extra.budgetSlices += 1; extra.budgetPlannedMs += plannedMs; extra.budgetActualMs += s.wallMs; extra.budgetOverMs += max(0, s.wallMs - plannedMs)
            budgetText = String(format: "예산 %.0f%% 중 최근 1초 사용 %.0f ms · 이번 묶음 계획 %.0f ms → 실제 %.0f ms · 반복 상한 %d · 대기 %d회", (level >= 1 ? 0.5 : 1) * (config.product?.optDuty ?? 0) * 100, usedMs, plannedMs, s.wallMs, iters, extra.budgetWaits)
            statLock.unlock()
        }
        if s.iterations > 0 {
            statLock.lock()
            slices.append(s); if slices.count > 600 { slices.removeFirst(slices.count - 600) }
            func add(_ k: String, _ v: Double) { optSamples[k, default: []].append(v); if optSamples[k]!.count > 600 { optSamples[k]!.removeFirst() } }
            add("forward", s.forwardMs / Double(s.iterations)); add("backward", s.backwardMs / Double(s.iterations)); add("update", s.updateMs / Double(s.iterations))
            totals.iterations += s.iterations; totals.moved += s.moved; totals.nonFinite += s.nonFinite
            optIterTimes.append(ExpSys.hostNow()); if optIterTimes.count > 400 { optIterTimes.removeFirst() }
            if s.lossStart > 0 { lossStartLast = Double(s.lossStart); lossEndLast = Double(s.lossEnd) }
            coverageLast = Double(s.coverage)
            extra.refineIterations += s.refineIterations; extra.refineMs += s.refineMs; extra.splits += s.splits
            if s.refineIterations > 0 { extra.refineSlices += 1 }
            extra.validationMs += s.validationMs
            if s.validationViews > 0 { extra.validatedSlices += 1 }
            if s.validationSkipped { extra.validationSkipped += 1 }
            if s.rolledBack { extra.rollbackReasons[String(s.rollbackReason.split(separator: " ").first ?? "?"), default: 0] += 1; lastRollbackReason = s.rollbackReason }
            if s.splitsRolledBack > 0 { extra.rollbackReasons["split", default: 0] += 1; lastRollbackReason = "분할 되돌림: " + s.splitRollbackReason }
            statLock.unlock()
            log?.write("gso_opt", ["iterations": s.iterations, "forwardMs": s.forwardMs, "backwardMs": s.backwardMs, "updateMs": s.updateMs,
                                   "lossStart": Double(s.lossStart), "lossEnd": Double(s.lossEnd), "depthLoss": Double(s.depthLossEnd),
                                   "rolledBack": s.rolledBack, "nonFinite": s.nonFinite, "moved": s.moved, "active": s.activeGaussians,
                                   "wallMs": s.wallMs, "geometry": s.geometry, "governor": level, "trainViewCoverage": Double(s.coverage),
                                   "budget": ["dutyAllowedMs": allowedMs, "usedLastSecondMs": usedMs, "plannedMs": plannedMs, "actualWallMs": s.wallMs, "itersCap": iters],
                                   "product": ["pixels": s.productPixels, "bgLeak": Double(s.bgLeak), "refineCell": s.refineCell, "splitsRolledBack": s.splitsRolledBack,
                                               "hiL1": [Double(s.valHiL1Before), Double(s.valHiL1After)], "edgeL1": [Double(s.valEdgeBefore), Double(s.valEdgeAfter)],
                                               "silhouette": [Double(s.valSilBefore), Double(s.valSilAfter)], "bgLeakVal": [Double(s.valLeakBefore), Double(s.valLeakAfter)]],
                                   "rollbackReason": s.rollbackReason, "validation": ["views": s.validationViews, "ms": s.validationMs, "skipped": s.validationSkipped,
                                                                                      "l1Before": Double(s.valL1Before), "l1After": Double(s.valL1After),
                                                                                      "alphaBefore": Double(s.valAlphaBefore), "alphaAfter": Double(s.valAlphaAfter)],
                                   "refine": ["iterations": s.refineIterations, "ms": s.refineMs, "decodeMs": s.refineDecodeMs, "cropPixels": s.refineCropPixels,
                                              "lossBefore": Double(s.refineLossBefore), "lossAfter": Double(s.refineLossAfter), "splits": s.splits, "skipped": s.refineSkipped,
                                              "crop": [s.refineCropW, s.refineCropH], "source": [s.refineSrcW, s.refineSrcH]]])
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
        if let tp = texPipeline {
            if tp.layers.isEmpty && !force { return }
            texStore.publish(tp.layers)
            splats.publish(packed: [], count: 0)        // 버전을 올려 표시 지연 측정(notePresented)을 같은 방식으로 쓴다
        } else if pipeline.map.count == 0 && !force {
            return
        }
        let includeTemp = currentOptions.includeTemporary
        let set = texPipeline == nil ? pipeline.map.splatSet(includeTemporary: includeTemp) : RTSplatSet()
        if texPipeline == nil { splats.publish(packed: set.pack(), count: set.count) }
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
        if let tp = texPipeline { RTViewerBounds.shared.bounds = TexLayerSelect.robustBounds(tp.layers) } else { RTViewerBounds.shared.bounds = set.bounds() }
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
        if changed {
            let nowH = ExpSys.hostNow()
            if level >= 2, extra.optimizerPausedSince == nil {
                extra.optimizerPausedSince = nowH
                extra.pauseEvents.append((nowH, "optimizer paused: thermal=\(ExpSys.thermalName(th)) footprintMB=\(Int(fp))"))
                log?.write("gso_optimizer_paused", ["thermal": ExpSys.thermalName(th), "footprintMB": fp, "level": level])
            } else if level < 2, let since = extra.optimizerPausedSince {
                extra.thermalSkipMs += (nowH - since)
                extra.optimizerPausedSince = nil
                extra.pauseEvents.append((nowH, "optimizer resumed: thermal=\(ExpSys.thermalName(th))"))
                log?.write("gso_optimizer_resumed", ["thermal": ExpSys.thermalName(th), "pausedSeconds": nowH - since])
            }
        }
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
        l.modelState = !config.useMono ? "사용 안 함" : (monoLoaded ? "준비됨" : "준비 중(첫 실행은 약 50초 걸릴 수 있어요. 그동안 스테레오 전용 결과만 나와요)")
        l.optimizerState = !options.optimize ? "꺼짐" : (governorLevel >= 2 ? "열·메모리 제한으로 중지됨(내려가면 자동 재개)" : (governorLevel == 1 ? "부하를 낮춤(고해상도 정밀화 쉼)" : "실행 중"))
        l.refineState = !config.hiRefine ? "꺼짐" : (governorLevel >= 1 || !options.optimize ? "쉼" : (extra.refineIterations > 0 ? "실행 중" : "대기"))
        l.splitsTotal = extra.splits; l.refineIterations = extra.refineIterations; l.lastRollbackReason = lastRollbackReason
        l.validationSkips = extra.validationSkipped; l.suspectTotal = extra.suspect
        l.hiCacheMB = Double(pipeline.hiStore.bytes) / 1_048_576
        l.gapTop = extra.gapTotals.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
        l.resolutionText = pipeline.resolutionInfo.isEmpty ? "" : "센서 \(pipeline.resolutionInfo["sensorW"] ?? 0)×\(pipeline.resolutionInfo["sensorH"] ?? 0) · 원본창 \(pipeline.resolutionInfo["hiW"] ?? 0)×\(pipeline.resolutionInfo["hiH"] ?? 0) · 깊이 \(pipeline.resolutionInfo["smallW"] ?? 0)×\(pipeline.resolutionInfo["smallH"] ?? 0) · 학습 \(pipeline.resolutionInfo["trainW"] ?? 0)×\(pipeline.resolutionInfo["trainH"] ?? 0) · 정밀화 창 \(pipeline.resolutionInfo["cropW"] ?? 0)×\(pipeline.resolutionInfo["cropH"] ?? 0)"
        if config.product != nil {
            l.isProduct = true
            l.phase = previewMode ? "대상 선택" : (l.paused ? "일시정지" : "촬영")
            l.maskStatus = { switch tracker?.status { case .tracking?: return "추적 중"; case .uncertain?: return "불확실(가림·흐림 등: 이 프레임은 쓰지 않음)"; case .lost?: return "놓침(제품을 다시 비춰 주세요)"; default: return "—" } }()
            l.maskTrusted = maskStats.trusted; l.maskUncertain = maskStats.uncertain
            l.maskMsP50 = RTStat.percentile(maskSamples, 0.5)
            l.maskNote = maskNoteLast
            let pb = pipeline.productBounds
            if let tp = texPipeline { l.texText = "텍스처 레이어 \(tp.layers.count)개 · 사각형 \(tp.quadCount)개 · 메모리 \(String(format: "%.1f", Double(tp.bytes) / 1_048_576)) MB · 건너뜀(마스크 \(tp.maskSkipped) · 마스크 오염 \(tp.maskContaminatedSkipped) · 깊이 없음 \(tp.depthSkipped)) · 마스크 점검으로 바꾼 화소 \(tp.guardRejectedPixels) · 예산으로 버린 레이어 \(tp.removedForBudget)" }
            l.boundsText = pb.isValid ? "확정(점 \(pb.points.count)개, 시점 \(pb.viewIDs.count)개)" : "모으는 중(점 \(pb.points.count)/\(pb.minPoints), 시점 \(pb.viewIDs.count)/\(pb.minViews))"
            l.coverageText = "관측한 방향 \(progressLatest.azimuthObserved)/\(progressLatest.azimuthBins) 방위 · \(progressLatest.directionCells)/\(progressLatest.directionBins) 칸 · 복원이 부족한 가우시안 \(Int(progressLatest.insufficientShare * 100))% (비추지 않은 방향은 복원하지 않아요)"
            l.refineCellsPct = progressLatest.cellsTotal > 0 ? Double(progressLatest.fractionCells) * 100 : nil
            l.refineGaussiansPct = progressLatest.gaussiansTotal > 0 ? Double(progressLatest.fractionGaussians) * 100 : nil
            l.bgLeak = bgLeakLast; l.productPixels = productPixelsLast
            l.budgetText = budgetText; l.refineKind = refineKindLast
        }
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
            if let tp = texPipeline {
                // 텍스처 스플랫 레이어: .kmots(일반 3DGS PLY가 아님). 결과 구조체는 재사용한다(gaussians = 사각형 수, views = 레이어 수).
                let r = TexLayerFiles.save(layers: tp.layers, runId: log?.baseName, config: tp.config, summaryText: summaryText, replay: recorder, extraMeta: productMeta())
                out = GSOSaveResult(item: r.item, error: r.error, gaussians: r.quads, views: r.layers)
                if r.error == nil { recorder = nil }
                return
            }
            let views = pipeline.views.map { GSOCameraRecord(id: $0.id, pose: $0.camera.pose, k: $0.camera.intrinsics, timestamp: $0.timestamp) }
            var req = GSOSaver.Request(map: pipeline.map, views: views, runId: log?.baseName, config: config, summaryText: summaryText, recorder: recorder)
            if config.product != nil {
                req.directory = ProductGSStore.directory; req.prefix = ProductGSStore.prefix; req.kind = "product"; req.extraMeta = productMeta()
            }
            out = GSOSaver.save(req)
            if out.error == nil { recorder = nil }
        }
        return out
    }

    // MARK: 텍스처 레이어 요약

    private func texStatsDict(_ tp: TexLayerPipeline) -> [String: Any] {
        ["layers": tp.layers.count, "quads": tp.quadCount, "bytes": tp.bytes, "removedForBudget": tp.removedForBudget, "maskSkipped": tp.maskSkipped,
         "maskContaminatedSkipped": tp.maskContaminatedSkipped, "depthSkipped": tp.depthSkipped, "blurSkipped": tp.blurSkipped,
         "maskGuardActiveFrames": tp.guardFramesActive, "maskGuardRejectedPixels": tp.guardRejectedPixels, "maskGuardFramesDropped": tp.maskGuard.framesDropped,
         "gainMin": [Double(tp.gainMin.x), Double(tp.gainMin.y), Double(tp.gainMin.z)], "gainMax": [Double(tp.gainMax.x), Double(tp.gainMax.y), Double(tp.gainMax.z)],
         "monoSpaceLocked": tp.config.lockMonoInverse ? "inverseDepth" : "auto", "monoInverseFits": tp.monoInverseFits, "monoDepthWouldHaveWon": tp.monoDepthWouldWin,
         "monoFromOriginalWindow": tp.config.monoFromOriginalWindow, "texLayersVersion": 2]
    }

    private func texSummaryText(_ tp: TexLayerPipeline) -> String {
        statLock.lock(); let ms = maskStats, msamples = maskSamples; let gt = (gaps: extra.gapTotals, candidates: extra.candidatePixels); statLock.unlock()
        var t = "텍스처 스플랫 레이어 (고정된 제품 + 움직이는 휴대폰)\n"
        t += "  표현: 키프레임마다 제품 영역 전체를 8×8 원본 화소 셀의 평면 사각형 + 8×8 RGBA 텍스처로 유지한다. 새 시점에서는 시야의 실제 표면을 덮는 레이어를 최대 \(TexLayerConst.blendMax)개(앞면만) 골라, 화소마다 가중치가 가장 큰 깊이를 표면으로 정하고 그 표면에 일치하는 관측만 혼합한다(색이 서로 다르면 대표 관측 하나). 같은 표면에 동의하는 레이어가 2개 미만인 화소는 가장자리 근처만 남긴다. 가우시안 지도·장면별 최적화(Adam)·분할을 쓰지 않았다. 일반 3DGS PLY가 아니다(.kmots).\n"
        t += "  레이어 \(tp.layers.count)개 · 사각형 \(tp.quadCount)개 · 메모리 \(String(format: "%.1f", Double(tp.bytes) / 1_048_576)) MB · 예산(최대 \(tp.config.maxLayers))으로 버린 레이어 \(tp.removedForBudget)\n"
        t += "  마스크: 신뢰 \(ms.trusted)장 · 불확실 \(ms.uncertain)장(이 프레임은 레이어를 만들지 않음), 마스크 시간 p50 \(String(format: "%.0f", RTStat.percentile(msamples, 0.5) ?? 0))ms\n"
        t += "  마스크 점검(연결성·3D 공간 일관성·색 보조): 점검이 작동한 프레임 \(tp.guardFramesActive)장, 불확실로 바꾼 화소 \(tp.guardRejectedPixels)개, 오염이 커서 쓰지 않은 프레임 \(tp.maskContaminatedSkipped)장\n"
        t += "  건너뜀: 마스크 \(tp.maskSkipped) · 마스크 오염 \(tp.maskContaminatedSkipped) · 깊이 없음 \(tp.depthSkipped) · 흐림 \(tp.blurSkipped)\n"
        t += "  노출 이득(겹치는 같은 표면 점의 직전 프레임 색 비율을 이어 곱함, 적용 범위 0.88~1.15, 밝은 화소는 덜 적용): 최소 \(String(format: "%.2f", tp.gainMin.x))/\(String(format: "%.2f", tp.gainMin.y))/\(String(format: "%.2f", tp.gainMin.z)) · 최대 \(String(format: "%.2f", tp.gainMax.x))/\(String(format: "%.2f", tp.gainMax.y))/\(String(format: "%.2f", tp.gainMax.z))\n"
        t += "  사용한 해상도: " + tp.resolutionInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ") + "\n"
        t += "  미생성·제외 이유(후보 셀 \(gt.candidates)개 중): " + gt.gaps.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + "\n"
        t += "  깊이: 스테레오 앵커에 맞춘 단안 모델 추정이며 독립 기준으로 검증하지 않았다(깊이 정확도 아님). 단안 출력 의미는 역깊이로 고정했고(역깊이 정렬 \(tp.monoInverseFits)회, 깊이 가정이 더 잘 맞았을 참고 횟수 \(tp.monoDepthWouldWin)회), 단안 입력은 " + (tp.config.monoFromOriginalWindow ? "원본 창(960×720)에서 상자 평균으로 줄여 만들었다" : "작은 영상(320 폭)을 늘려 만들었다") + ". 관측하지 않은 방향은 복원하지 않는다. 연구 기록: " + (recorder != nil ? "켜짐(자동 업로드 없음)" : "꺼짐 — 재생 자료 없음") + "\n\n"
        return t
    }

    // MARK: 제품 요약

    private func productSummaryText(ex: GSOExtraStats, f: (Double?, Int) -> String) -> String {
        statLock.lock()
        let prog = progressLatest, ms = maskStats, msamples = maskSamples
        let leak = bgLeakLast, pp = productPixelsLast
        statLock.unlock()
        let pb = pipeline.productBounds
        var t = "제품 모드 (고정된 제품 + 움직이는 휴대폰)\n"
        t += "  마스크: 기기 내 Vision, 신뢰 \(ms.trusted)장 · 불확실 \(ms.uncertain)장(이 프레임은 가우시안 생성·감독에 쓰지 않음), 마스크 시간 p50 \(f(RTStat.percentile(msamples, 0.5), 0))ms / p95 \(f(RTStat.percentile(msamples, 0.95), 0))ms, 대상 ID \(tracker?.targetID ?? 0)\n"
        t += "  3D 범위: " + (pb.isValid ? "확정(신뢰 깊이 점 \(pb.points.count)개, 서로 다른 시점 \(pb.viewIDs.count)개)" : "확정되지 않음(점 \(pb.points.count)/\(pb.minPoints), 시점 \(pb.viewIDs.count)/\(pb.minViews))") + "\n"
        t += "  정밀화 진행: 제품 칸 \(prog.cellsRefined)/\(prog.cellsTotal) (\(String(format: "%.0f", Double(prog.fractionCells) * 100))%) · 정밀화에서 갱신된 가우시안 \(prog.gaussiansRefined)/\(prog.gaussiansTotal) (\(String(format: "%.0f", Double(prog.fractionGaussians) * 100))%), 창 종류 \(ex.refineKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))\n"
        t += "  관측 범위: 방위 \(prog.azimuthObserved)/\(prog.azimuthBins), 방향 칸 \(prog.directionCells)/\(prog.directionBins) — 비추지 않은 방향의 면은 복원하지 않는다(미관측). 관측했지만 복원이 부족한 가우시안(임시 또는 관측 3회 미만) \(Int(prog.insufficientShare * 100))%\n"
        t += "  분할 \(ex.splits)개(검증 실패로 되돌린 분할 \(ex.splitsRolledBack)개), 롤백 \(pipeline.rollbacks)회, 마지막 제품 화소 \(pp)개, 배경 누출(확실한 배경 화소의 평균 알파) \(leak.map { String(format: "%.3f", $0) } ?? "—")\n"
        let planned = ex.budgetPlannedMs, actual = ex.budgetActualMs
        t += "  계산 예산: 최적화 시간 비율 상한 \(Int((config.product?.optDuty ?? 0) * 100))%, 묶음 \(ex.budgetSlices)개의 계획 \(String(format: "%.0f", planned))ms 대비 실제 \(String(format: "%.0f", actual))ms(초과 합계 \(String(format: "%.0f", ex.budgetOverMs))ms), 예산 때문에 기다린 횟수 \(ex.budgetWaits)\n"
        t += "  키프레임 간격 하한 \(String(format: "%.2f", config.product?.minKeyframeInterval ?? 0))초(초당 최대 \(String(format: "%.1f", 1 / max(0.001, config.product?.minKeyframeInterval ?? 1)))회)\n"
        t += "  연구 기록: " + (recorder != nil ? "켜짐(RGB·마스크·포즈·K·시각·노출 저장, 자동 업로드 없음)" : "꺼짐 — 재생 자료가 없어 같은 입력으로 다시 비교할 수 없음") + "\n\n"
        return t
    }

    private func productDict(ex: GSOExtraStats) -> [String: Any] {
        statLock.lock()
        let prog = progressLatest, ms = maskStats, msamples = maskSamples
        statLock.unlock()
        let pb = pipeline.productBounds
        return ["maskTrusted": ms.trusted, "maskUncertain": ms.uncertain, "maskMsP50": expNN(RTStat.percentile(msamples, 0.5)), "maskMsP95": expNN(RTStat.percentile(msamples, 0.95)),
                "boundsValid": pb.isValid, "boundsPoints": pb.points.count, "boundsViews": pb.viewIDs.count,
                "refine": ["cellsRefined": prog.cellsRefined, "cellsTotal": prog.cellsTotal, "gaussiansRefined": prog.gaussiansRefined, "gaussiansTotal": prog.gaussiansTotal, "kinds": ex.refineKinds],
                "splitsRolledBack": ex.splitsRolledBack,
                "budget": ["slices": ex.budgetSlices, "waits": ex.budgetWaits, "plannedMs": ex.budgetPlannedMs, "actualMs": ex.budgetActualMs, "overMs": ex.budgetOverMs,
                           "duty": config.product?.optDuty ?? 0, "minKeyframeIntervalS": config.product?.minKeyframeInterval ?? 0],
                "replayRecorded": recorder != nil]
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
        let spaceInv = fits.filter { $0.space == .inverseDepth && !$0.carried }.count, spaceDep = fits.filter { $0.space == .depth && !$0.carried }.count
        let rollbacks = pipeline.rollbacks
        let ms = { (c: Double?) -> String in c.map { String(format: "%.1f", $0) } ?? "—" }

        let isTex = texPipeline != nil
        var t = (isTex ? "텍스처 레이어(제품) 실행 요약\n종료: \(endReason.label)\n\n" : "가우시안 최적화 실험 요약\n종료: \(endReason.label)\n\n")
        t += isTex ? "[구분] 서버를 쓰지 않았다. 사전학습 깊이 모델은 기기 내 추론만 했다(재학습 없음). 이 실행은 가우시안을 만들지 않았고 장면별 최적화도 하지 않았다(텍스처 표면 레이어). 렌더 FPS는 생성 속도나 화질 지표가 아니다.\n\n" : "[구분] 서버를 쓰지 않았다. 사전학습 깊이 모델은 기기 내 추론만 했다(재학습 없음). 촬영 중 가우시안 파라미터를 반복 최적화했다(장면별 최적화이며 '완전 무학습'이 아니다). 렌더 FPS는 생성 속도나 화질 지표가 아니다.\n\n"
        t += "입력\n  ARKit 프레임 \(recv)개, 키프레임 채택 \(kfs)개, 처리 \(proc)개, 대기 중 버려진 것 \(dropped)개, 흐림으로 거부 \(blur)개\n"
        t += "  키프레임 거부 사유: \(rejects.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))\n"
        t += "  추적 상태 전환 \(trans)회, 세그먼트 \(segs)개 (\(events.joined(separator: ", ")))\n\n"
        t += "처음 도달 시각 (시작 후 초)\n  첫 입력 \(f(l.firstInputS, 2)) · 첫 정렬된 지도(단안 정렬) \(f(l.firstAlignedS, 2)) · 첫 후보 \(f(cp.map { $0 - startedHost }, 2)) · 첫 안정(독립 증거 3회) \(f(st.map { $0 - startedHost }, 2)) · 첫 표시 \(f(l.firstDisplayS, 2))\n\n"
        t += "지연 (캡처 시각 기준)\n  → 지도 반영 p50 \(f(p50)) / p95 \(f(p95)) ms (\(tm.count)개)\n  → 렌더용 게시 p50 \(f(q50)) / p95 \(f(q95)) ms (\(tp.count)개)\n  → 실제 화면 표시 p50 \(f(d50)) / p95 \(f(d95)) ms (\(td.count)개, 시각 출처: \(dsrc.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")); gpuEnd는 present 시각을 읽지 못해 GPU 완료 시각으로 근사한 값)\n"
        t += "  키프레임 단계 p50/p95(ms): " + stage.keys.sorted().map { "\($0) \(f(stage[$0]))/\(f(stage95[$0]))" }.joined(separator: ", ") + "\n  처리 대기열 최대 \(mq)\n\n"
        t += "깊이\n  단안 모델 실행 \(tot.monoRuns)회, 밀집 깊이로 처리한 키프레임 \(monoKFs), 스테레오만 \(stereoOnly), 정렬 내부점 비율 중앙값 \(f(fitRatio.map { $0 * 100 }))%\n  모델 출력 의미 판정(새로 맞춘 키프레임): 역깊이 가정 \(spaceInv) · 깊이 가정 \(spaceDep)" + (isTex ? " (텍스처 레이어 경로는 역깊이로 고정)" : "") + "\n\n"
        let ex = extra
        if !isTex {
            t += "정밀화·검증\n  원본 고해상도 창 정밀화 반복 \(ex.refineIterations)회(묶음 \(ex.refineSlices)개, \(f(ex.refineMs / 1000, 1))초), 선택적 분할 \(ex.splits)개, 앞쪽 오표면 의심 \(ex.suspect)개\n"
            t += "  갱신 전후 검증 \(ex.validatedSlices)묶음(공백 \(ex.validationSkipped), 검증 시간 합 \(f(ex.validationMs / 1000, 1))초), 롤백 \(pipeline.rollbacks)회: " + (ex.rollbackReasons.isEmpty ? "없음" : ex.rollbackReasons.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) + "\n"
            t += "  미생성 이유(삽입 후보 화소 \(ex.candidatePixels)개 중): " + ex.gapTotals.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + "\n"
            t += "  열·메모리 제한으로 최적화를 쉰 시간 \(f(ex.thermalSkipMs, 1))초, 중지·재개 기록 \(ex.pauseEvents.count)건 " + ex.pauseEvents.map { "[\($0.event)]" }.joined(separator: "") + "\n"
            t += "  사용한 해상도: \(l.resolutionText)\n  원본 고해상도 보관 \(f(l.hiCacheMB, 1)) MB\n\n"
            t += "가우시안 지도\n  \(l.gaussians)개 (임시 \(l.temporary) · 후보 \(l.candidate) · 안정 \(l.stable)); 누적 삽입 \(tot.inserted) (스테레오 확인 \(tot.stereoInserted) · 단안 \(tot.monoInserted)), 제거 \(tot.pruned), 상한으로 못 만든 \(tot.rejectedByCap)\n\n"
            t += "최적화\n  반복 \(tot.iterations)회(묶음 \(sl.count)개), 위치가 의미 있게 움직인 갱신 \(tot.moved), 비정상 gradient 건너뜀 \(tot.nonFinite), 롤백 \(rollbacks)회\n"
            t += "  반복당 p50/p95(ms): " + opt.keys.sorted().map { "\($0) \(f(opt[$0], 1))/\(f(opt95[$0], 1))" }.joined(separator: ", ") + "\n"
            t += "  훈련 시점의 광도 손실(Charbonnier): 처음 묶음 \(f(lossFirst.isEmpty ? nil : lossFirst.reduce(0, +) / Double(lossFirst.count), 4)) → 마지막 묶음 \(f(lossLast.isEmpty ? nil : lossLast.reduce(0, +) / Double(lossLast.count), 4)) (훈련에 쓴 사진의 손실이며 화질 증거가 아니다)\n\n"
        }
        if let r = render {
            t += "렌더 (마지막 1초)\n  \(String(format: "%.1f", r.fps)) fps, CPU p50/p95 \(ms(r.cpuMsP50))/\(ms(r.cpuMsP95)) ms, GPU p50/p95 \(ms(r.gpuMsP50))/\(ms(r.gpuMsP95)) ms, 그린 \(isTex ? "사각형" : "가우시안") \(r.drawn)/\(r.total)\n\n"
        }
        t += "자원\n  메모리 피크 \(f(fp)) MB, 열 상태 \(th.joined(separator: ", ")), 거버너 변경 \(gov.count)회\n  재생 자료 \(l.replayFrames)장 \(l.replayBytes / 1_048_576) MB\n\n"
        if let tp = texPipeline { t += texSummaryText(tp) } else if config.product != nil { t += productSummaryText(ex: ex, f: f) }
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
        d["extra"] = ["refineIterations": ex.refineIterations, "refineMs": ex.refineMs, "splits": ex.splits, "suspect": ex.suspect, "validatedSlices": ex.validatedSlices,
                       "validationSkipped": ex.validationSkipped, "rollbackReasons": ex.rollbackReasons, "gapTotals": ex.gapTotals, "candidatePixels": ex.candidatePixels,
                       "thermalPausedSeconds": ex.thermalSkipMs, "pauseEvents": ex.pauseEvents.map { "\($0.event)" }, "resolutions": pipeline.resolutionInfo]
        d["lossFirst10"] = expNN(lossFirst.isEmpty ? nil : lossFirst.reduce(0, +) / Double(lossFirst.count))
        d["lossLast10"] = expNN(lossLast.isEmpty ? nil : lossLast.reduce(0, +) / Double(lossLast.count))
        d["monoKeyframes"] = monoKFs; d["stereoOnlyKeyframes"] = stereoOnly
        d["monoSpace"] = ["inverseDepth": spaceInv, "depth": spaceDep, "inlierRatioP50": expNN(fitRatio)]
        d["footprintPeakMB"] = fp; d["thermalSeen"] = th; d["governorChanges"] = gov.count
        d["replay"] = ["frames": l.replayFrames, "bytes": l.replayBytes]
        if let r = render {
            d["render"] = ["fps": r.fps, "cpuMsP50": r.cpuMsP50, "cpuMsP95": r.cpuMsP95, "gpuMsP50": r.gpuMsP50, "gpuMsP95": r.gpuMsP95, "drawn": r.drawn, "total": r.total]
        }
        if let tp = texPipeline { d["textureLayers"] = texStatsDict(tp) } else if config.product != nil { d["product"] = productDict(ex: ex) }
        return (t, d)
    }
}

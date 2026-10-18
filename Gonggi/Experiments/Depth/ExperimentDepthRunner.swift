import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import UIKit
import simd

/// 깊이 검사 화면에 보여 줄 실시간 값 (약 4Hz로 갱신).
struct ExpDepthLive {
    var stages: [ExpDepthStage: ExpStageState] = [:]
    var message = ""
    var elapsed: Double = 0
    var videoSize: [Int]?
    var depthSize: [Int]?
    var videoHz: Double?
    var depthHz: Double?
    var videoFrames = 0
    var depthFrames = 0
    var videoDrops = 0
    var depthDrops = 0
    var validRatio: Double?
    var depthKind: String?
    var accuracy: String?
    var quality: String?
    var filtered: Bool?
    var calibrationPresent: Bool?
    var pairFraction: Double?
    var offsetP50Ms: Double?
    var offsetP95Ms: Double?
    var eventCount = 0
    var preview: CGImage?
    /// 화면 중앙 4칸(격자 8x6 중 가운데)의 중앙값. 줄자로 잰 표적과 비교할 때 쓴다. 정확도가 아니라 원값이다.
    var centerNative: Double?
    var centerConverted: Double?
    var centerValid: Double?
}

struct ExpTargetReading {
    var knownDistanceM: Double
    var native: Double?
    var converted: Double?
    var centerValid: Double?
    var accuracy: String
    var depthType: String
}

enum ExpDepthKind {
    static func describe(_ type: OSType) -> String {
        if type == kCVPixelFormatType_DisparityFloat16 || type == kCVPixelFormatType_DisparityFloat32 {
            return "disparity(단위 1/m, 상대 역깊이로 취급. 클수록 가까움)"
        }
        if type == kCVPixelFormatType_DepthFloat16 || type == kCVPixelFormatType_DepthFloat32 {
            return "depth(m 단위로 변환된 값. range인지 camera-Z인지는 문서로 확정되지 않았고, 정확도는 accuracy가 정함)"
        }
        return "알 수 없는 형식 \(ExpSys.fourCC(type))"
    }
}

/// 후면 듀얼 와이드의 영상 + 깊이를 `AVCaptureDataOutputSynchronizer`로 함께 받는다.
/// 파일은 만들지 않고 메모리에서 처리한다(샘플 저장 옵션을 켠 경우만 예외, 개수·용량 제한).
///
/// 스레드 규칙: 세션 시작·중지·구성은 `sessionQueue`, 콜백은 `cbQueue`, 픽셀 통계·색상화는 `statsQueue`.
/// 콜백 안에서는 파일 쓰기와 무거운 계산을 하지 않는다. 통계 작업이 밀려 있으면 그 프레임은 건너뛴다.
final class ExperimentDepthRunner: NSObject, @unchecked Sendable {
    struct Options {
        var filtering = false
        var fps: Double = 30
        var choice: ExpFormatChoice?          // nil = 자동
        var previewDepth = true
        var saveSamples = false
        var statsEvery = 6                    // 깊이 프레임 N장마다 통계(30fps면 5Hz)
    }

    struct SetupResult {
        var permissionDenied = false
        var deviceFound = false
        var formatsPresent = false
        var error: String?
        var outputConnected = false
        var chosen: ExpFormatChoice?
        var activeVideoFps: Double?
        var activeDepthFps: Double?
    }

    let events = ExpEvents()
    let session = AVCaptureSession()
    var onLive: ((ExpDepthLive) -> Void)?
    var onAutoStop: ((ExpEndReason) -> Void)?
    private(set) var setup = SetupResult()
    private(set) var photoDepth: ExpStageState = .notRun

    private let opts: Options
    private let log: ExperimentRunLog?
    private let sessionQueue = DispatchQueue(label: "gonggi.experiment.depth.session", qos: .userInitiated)
    private let cbQueue = DispatchQueue(label: "gonggi.experiment.depth.callbacks", qos: .userInitiated)
    private let statsQueue = DispatchQueue(label: "gonggi.experiment.depth.stats", qos: .utility)
    private let monitorQueue = DispatchQueue(label: "gonggi.experiment.depth.monitor", qos: .utility)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var startedHost: Double = 0
    private var stopped = true
    private var autoStopSent = false

    // 아래 값은 cbQueue에서만 바꾼다.
    private var videoPTS = ExpRateMeter()
    private var depthPTS = ExpRateMeter()
    private var videoArrival = ExpRateMeter()
    private var depthArrival = ExpRateMeter()
    private var videoDrops = 0
    private var depthDrops = 0
    private var collections = 0
    private var pairs = 0
    private var pairOffsets: [Double] = []
    private var videoSize: [Int]?
    private var depthSize: [Int]?
    private var depthTypeName: String?
    private var accuracyName: String?
    private var qualityName: String?
    private var filteredFlag: Bool?
    private var calibrationPresent: Bool?
    private var videoIntrinsics: [Float]?
    private var firstDepthHost: Double?
    private var depthCountForStats = 0

    // 통계 결과 (lock으로 보호)
    private let lock = NSLock()
    private var validRatios: [Double] = []
    private var lastValidRatio: Double?
    private var lastPreview: CGImage?
    private var statsMs: [Double] = []
    private var statsBusy = false
    private var clockDeltas: [Double] = []
    private var thermalSeen: Set<String> = []
    private var footprintMax: Double = 0
    private var savedSamples = 0
    private var savedBytes = 0
    private var lastSampleHost: Double = 0
    private var stages: [ExpDepthStage: ExpStageState] = [:]
    private var message = ""
    private var centerRing: [(host: Double, native: Double?, converted: Double?, valid: Double?)] = []
    private var targetReadings: [ExpTargetReading] = []

    init(options: Options, log: ExperimentRunLog?) {
        self.opts = options
        self.log = log
        super.init()
        for s in ExpDepthStage.allCases { stages[s] = .notRun }
    }

    deinit { timer?.cancel() }

    // MARK: 준비

    private func setStage(_ s: ExpDepthStage, _ v: ExpStageState) {
        lock.lock(); stages[s] = v; lock.unlock()
    }

    private func setMessage(_ m: String) {
        lock.lock(); message = m; lock.unlock()
    }

    /// 권한 확인, 장치·포맷 선택, 세션 구성. 카메라는 아직 실행하지 않는다.
    func prepare() async -> SetupResult {
        let granted = await Self.cameraAccessGranted()
        if !granted {
            setup.permissionDenied = true
            setMessage("카메라 권한이 없습니다. 설정 앱에서 허용해 주세요.")
            log?.write("C_config", ["stage": "auth", "ok": false])
            return setup
        }
        // A·B는 별도로 확인한다 (C와 구분)
        let disc = await ExperimentDiscovery.run(log: log)
        photoDepth = disc.photoDepth
        setStage(.deviceFound, disc.dualWideFound ? .yes : .no)
        setStage(.photoDepth, disc.photoDepth)
        setStage(.streamFormats, disc.dualWideFound ? (disc.formatsPresent ? .yes : .no) : .notRun)
        setup.deviceFound = disc.dualWideFound
        setup.formatsPresent = disc.formatsPresent
        guard disc.dualWideFound, disc.formatsPresent else {
            setMessage(disc.dualWideFound ? "이 기기의 듀얼 와이드는 영상과 함께 쓸 수 있는 깊이 포맷이 없습니다." : "이 기기에서는 후면 듀얼 와이드 카메라가 발견되지 않았습니다.")
            return setup
        }
        let result: SetupResult = await withCheckedContinuation { c in
            sessionQueue.async { c.resume(returning: self.configureSession(base: self.setup, discovery: disc)) }
        }
        setup = result
        setStage(.outputConnected, result.outputConnected ? .yes : .no)
        if let e = result.error { setMessage("설정 실패: \(e)") }
        return setup
    }

    private static func cameraAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configureSession(base: SetupResult, discovery: ExpDiscoveryResult) -> SetupResult {
        var r = base
        guard let dev = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) else {
            r.error = "장치를 다시 열 수 없음"; return r
        }
        device = dev
        // 포맷 선택: 지정이 있으면 그것, 없으면 영상 너비 1920 이하 중 가장 큰 것의 가장 큰 깊이 포맷
        let all = discovery.choices
        let pick: ExpFormatChoice? = {
            if let c = opts.choice, all.contains(c) { return c }
            let capped = all.filter { $0.videoW <= 1920 }
            let pool = capped.isEmpty ? all : capped
            return pool.max { ($0.videoW, $0.depthW) < ($1.videoW, $1.depthW) }
        }()
        guard let choice = pick, dev.formats.indices.contains(choice.videoIndex) else { r.error = "고를 수 있는 포맷이 없음"; return r }
        let vf = dev.formats[choice.videoIndex]
        guard vf.supportedDepthDataFormats.indices.contains(choice.depthIndex) else { r.error = "깊이 포맷 인덱스가 맞지 않음"; return r }
        let df = vf.supportedDepthDataFormats[choice.depthIndex]
        r.chosen = choice

        guard let input = try? AVCaptureDeviceInput(device: dev) else { r.error = "AVCaptureDeviceInput 생성 실패"; return r }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        if session.canAddInput(input) { session.addInput(input) } else { session.commitConfiguration(); r.error = "입력을 세션에 추가할 수 없음"; return r }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) } else { session.commitConfiguration(); r.error = "영상 출력을 추가할 수 없음"; return r }
        depthOutput.isFilteringEnabled = opts.filtering
        depthOutput.alwaysDiscardsLateDepthData = true
        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) } else { session.commitConfiguration(); r.error = "깊이 출력을 추가할 수 없음(canAddOutput=false)"; return r }
        session.commitConfiguration()

        do {
            try dev.lockForConfiguration()
            dev.activeFormat = vf
            dev.activeDepthDataFormat = df
            let vMax = vf.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            let vMin = vf.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1
            let fps = max(vMin, min(opts.fps, vMax))
            let dur = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            dev.activeVideoMinFrameDuration = dur
            dev.activeVideoMaxFrameDuration = dur
            dev.unlockForConfiguration()
        } catch {
            r.error = "카메라 설정 잠금/적용 실패: \(error.localizedDescription)"
            return r
        }
        r.activeVideoFps = dev.activeVideoMinFrameDuration.seconds > 0 ? 1 / dev.activeVideoMinFrameDuration.seconds : nil
        let depthDur = dev.activeDepthDataMinFrameDuration.seconds
        r.activeDepthFps = depthDur > 0 ? 1 / depthDur : nil

        if let vc = videoOutput.connection(with: .video), vc.isCameraIntrinsicMatrixDeliverySupported {
            vc.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        let dc = depthOutput.connection(with: .depthData)
        r.outputConnected = (dc != nil)
        let vRot = videoOutput.connection(with: .video)?.videoRotationAngle
        let dRot = dc?.videoRotationAngle
        log?.write("C_config", [
            "ok": r.outputConnected, "filtering": depthOutput.isFilteringEnabled,
            "videoFormatIndex": choice.videoIndex, "depthFormatIndex": choice.depthIndex,
            "video": [choice.videoW, choice.videoH], "depth": [choice.depthW, choice.depthH], "depthType": choice.depthType,
            "requestedFps": opts.fps, "activeVideoFps": expNN(r.activeVideoFps), "activeDepthFps": expNN(r.activeDepthFps),
            "depthConnectionExists": dc != nil, "depthConnectionEnabled": dc?.isEnabled ?? false, "depthConnectionActive": dc?.isActive ?? false,
            "videoRotationAngle": expNN(vRot), "depthRotationAngle": expNN(dRot),
            "note": "영상·깊이 버퍼는 센서 방향 그대로 전달된다. 화면 방향 회전은 앱이 해야 하며 이 검사는 회전·크롭·리사이즈를 하지 않는다."
        ])
        if !r.outputConnected { r.error = "depthData 연결이 만들어지지 않음" }
        return r
    }

    // MARK: 실행

    func start() async {
        guard setup.outputConnected, setup.error == nil else { return }
        stopped = false
        startedHost = ExpSys.hostNow()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
            let raw = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            self?.events.add(source: "av", kind: "interrupted", detail: "reason=\(raw) \(Self.interruptionName(raw))")
            self?.log?.write("av_interrupted", ["reason": raw, "name": Self.interruptionName(raw)])
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.log?.write("av_interruption_ended")
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let e = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)
            self?.events.add(source: "av", kind: "error", detail: "\(e?.domain ?? "?") \(e?.code ?? 0)")
            self?.log?.write("av_runtime_error", ["domain": expNN(e?.domain), "code": expNN(e?.code), "description": expNN(e?.localizedDescription)])
        })
        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: cbQueue)
        synchronizer = sync

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sessionQueue.async { self.session.startRunning(); c.resume() }
        }
        log?.write("av_started", ["isRunning": session.isRunning])
        if !session.isRunning { setMessage("세션이 실행되지 않았습니다."); events.add(source: "av", kind: "error", detail: "startRunning 후 isRunning=false") }
        setStage(.callbacks, .unknown)
        startMonitor()
    }

    /// 멈추고 연결을 모두 끊는다. 여러 번 불러도 안전하다.
    func stop() async {
        timer?.cancel(); timer = nil
        let wasStopped = stopped
        stopped = true
        if !wasStopped || session.isRunning {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                sessionQueue.async { self.session.stopRunning(); c.resume() }
            }
        }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        synchronizer?.setDelegate(nil, queue: nil)
        synchronizer = nil
        // 콜백 큐에 남은 작업이 끝날 때까지 기다린다.
        cbQueue.sync {}
        if !wasStopped { log?.write("av_stopped") }
    }

    private static func interruptionName(_ raw: Int) -> String {
        switch raw {
        case 1: return "videoDeviceNotAvailableInBackground"
        case 2: return "audioDeviceInUseByAnotherClient"
        case 3: return "videoDeviceInUseByAnotherClient"
        case 4: return "videoDeviceNotAvailableWithMultipleForegroundApps"
        case 5: return "videoDeviceNotAvailableDueToSystemPressure"
        default: return "unknown"
        }
    }

    // MARK: 모니터 (4Hz)

    private func startMonitor() {
        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            let live = self.liveSnapshot()
            self.onLive?(live)
            if tick % 4 == 0 {
                let th = ExpSys.thermal
                let fp = ExpSys.footprintMB() ?? 0
                self.lock.lock()
                self.thermalSeen.insert(th)
                self.footprintMax = max(self.footprintMax, fp)
                self.clockDeltas.append(ExpSys.clockDelta())
                self.lock.unlock()
                self.log?.write("hb", [
                    "src": "av", "elapsed": live.elapsed, "videoFrames": live.videoFrames, "depthFrames": live.depthFrames,
                    "videoDrops": live.videoDrops, "depthDrops": live.depthDrops, "videoHz": expNN(live.videoHz), "depthHz": expNN(live.depthHz),
                    "validRatio": expNN(live.validRatio), "thermal": th, "footprintMB": fp, "running": self.session.isRunning
                ])
                if ExpSys.thermalIsSevere, !self.autoStopSent {
                    self.autoStopSent = true
                    self.log?.write("auto_stop", ["reason": "thermal", "thermal": th])
                    self.onAutoStop?(.thermal)
                }
            }
        }
        t.resume()
        timer = t
    }

    func liveSnapshot() -> ExpDepthLive {
        var l = ExpDepthLive()
        cbQueue.sync {
            l.videoSize = videoSize; l.depthSize = depthSize
            l.videoHz = videoPTS.hz; l.depthHz = depthPTS.hz
            l.videoFrames = videoPTS.total; l.depthFrames = depthPTS.total
            l.videoDrops = videoDrops; l.depthDrops = depthDrops
            l.depthKind = depthTypeName; l.accuracy = accuracyName; l.quality = qualityName; l.filtered = filteredFlag
            l.calibrationPresent = calibrationPresent
            l.pairFraction = collections > 0 ? Double(pairs) / Double(collections) : nil
            let abs = pairOffsets.map { Swift.abs($0) * 1000 }
            l.offsetP50Ms = ExpMath.percentile(abs, 0.5); l.offsetP95Ms = ExpMath.percentile(abs, 0.95)
        }
        l.elapsed = ExpSys.hostNow() - startedHost
        l.eventCount = events.all.count
        lock.lock()
        l.stages = stages
        l.validRatio = lastValidRatio
        l.preview = lastPreview
        l.centerNative = centerRing.last?.native
        l.centerConverted = centerRing.last?.converted
        l.centerValid = centerRing.last?.valid
        l.message = message
        lock.unlock()
        if l.depthFrames > 0 { setStage(.callbacks, .yes); l.stages[.callbacks] = .yes }
        return l
    }

    /// 공존 검사에서 구간별 빈도·동기화를 계산하기 위한 PTS 목록(host clock).
    func timestampSnapshot() -> (video: [Double], depth: [Double]) {
        cbQueue.sync { (videoPTS.times, depthPTS.times) }
    }

    // MARK: 요약

    struct Summary {
        var outcome: ExpOutcome
        var endReason: ExpEndReason
        var text: String
        var dictionary: [String: Any]
    }

    func finalSummary(endReason: ExpEndReason) -> Summary {
        var live = liveSnapshot()
        if live.depthFrames == 0, setup.outputConnected { live.stages[.callbacks] = .no }
        var depthOffsetsNearest: [Double] = []
        var vTimes: [Double] = [], dTimes: [Double] = []
        var vArr: Double?, dArr: Double?
        cbQueue.sync {
            vTimes = videoPTS.times; dTimes = depthPTS.times
            depthOffsetsNearest = ExpMath.nearestOffsets(reference: vTimes, other: dTimes)
            vArr = videoArrival.hz; dArr = depthArrival.hz
        }
        lock.lock()
        let validRatiosCopy = validRatios, statsMsCopy = statsMs, deltas = clockDeltas, th = thermalSeen, fpMax = footprintMax
        let savedN = savedSamples, savedB = savedBytes
        let targets = targetReadings
        lock.unlock()

        let interruptions = events.count(source: "av", kinds: ["interrupted", "error"])
        let outcome = ExpDepthClassifier.outcome(
            permissionDenied: setup.permissionDenied, deviceFound: setup.deviceFound, formatsPresent: setup.formatsPresent,
            setupError: setup.error,
            outputConnected: setup.outputConnected, interruptions: interruptions, depthCallbacks: live.depthFrames)
        let sync = ExpSync.evaluate(offsets: depthOffsetsNearest, videoHz: live.videoHz,
                                    clockStable: true)   // 영상과 깊이 모두 같은 AV host clock PTS를 쓰므로 두 시계 비교가 필요 없다.
        let vrMedian = ExpMath.percentile(validRatiosCopy, 0.5), vrMin = validRatiosCopy.min()
        let statsP50 = ExpMath.percentile(statsMsCopy, 0.5), statsMax = statsMsCopy.max()

        var stageDict: [String: String] = [:]
        for st in ExpDepthStage.allCases { stageDict[st.rawValue] = (live.stages[st] ?? .notRun).rawValue }

        var d: [String: Any] = [
            "outcome": outcome.label, "outcomeOK": outcome.isOK, "endReason": endReason.rawValue,
            "stages": stageDict,
            "videoSize": expNN(live.videoSize), "depthSize": expNN(live.depthSize),
            "videoFrames": live.videoFrames, "depthFrames": live.depthFrames, "videoDrops": live.videoDrops, "depthDrops": live.depthDrops,
            "videoHzPTS": expNN(live.videoHz), "depthHzPTS": expNN(live.depthHz), "videoHzArrival": expNN(vArr), "depthHzArrival": expNN(dArr),
            "videoGapP95S": expNN(ExpMath.percentile(ExpMath.gaps(vTimes), 0.95)), "depthGapP95S": expNN(ExpMath.percentile(ExpMath.gaps(dTimes), 0.95)),
            "depthGapMaxS": expNN(ExpMath.gaps(dTimes).max())
        ]
        d.merge([
            "validRatioMedian": expNN(vrMedian), "validRatioMin": expNN(vrMin),
            "depthType": expNN(live.depthKind), "accuracy": expNN(live.accuracy), "quality": expNN(live.quality), "filtered": expNN(live.filtered),
            "calibrationPresent": expNN(live.calibrationPresent),
            "pairFraction": expNN(live.pairFraction), "depthMinusVideoNearestP50Ms": expNN(ExpMath.percentile(depthOffsetsNearest.map { abs($0) * 1000 }, 0.5)),
            "depthMinusVideoNearestP95Ms": expNN(ExpMath.percentile(depthOffsetsNearest.map { abs($0) * 1000 }, 0.95)),
            "syncVerdict": sync.label
        ]) { $1 }
        d.merge([
            "events": events.all.map { ["source": $0.source, "kind": $0.kind, "detail": $0.detail] },
            "thermalSeen": Array(th).sorted(), "footprintMaxMB": fpMax,
            "statsMsP50": expNN(statsP50), "statsMsMax": expNN(statsMax),
            "samplesSaved": savedN, "samplesBytes": savedB,
            "targetReadings": targets.map { ["knownDistanceM": $0.knownDistanceM, "native": expNN($0.native), "converted": expNN($0.converted),
                                              "centerValid": expNN($0.centerValid), "accuracy": $0.accuracy, "depthType": $0.depthType] },
            "setupError": expNN(setup.error), "activeVideoFps": expNN(setup.activeVideoFps), "activeDepthFps": expNN(setup.activeDepthFps)
        ]) { $1 }
        d["format"] = expNN(setup.chosen?.label)

        func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "없음" }
        var t = "후면 깊이 검사 요약\n"
        t += "결과: \(outcome.label)\n종료: \(endReason.label)\n\n"
        t += "단계별 상태 (앞 단계 성공은 뒤 단계의 증거가 아님)\n"
        for s in ExpDepthStage.allCases { t += "  - \(s.title): \((live.stages[s] ?? .notRun).label)\n" }
        t += "\n포맷: \(setup.chosen?.label ?? "선택 못함")\n"
        t += "수신 해상도: 영상 \(live.videoSize.map { "\($0[0])x\($0[1])" } ?? "없음"), 깊이 \(live.depthSize.map { "\($0[0])x\($0[1])" } ?? "없음")\n"
        t += "빈도(PTS 기준): 영상 \(f(live.videoHz)) Hz, 깊이 \(f(live.depthHz)) Hz  (도착 기준: 영상 \(f(vArr)) / 깊이 \(f(dArr)))\n"
        t += "프레임: 영상 \(live.videoFrames) (드롭 \(live.videoDrops)), 깊이 \(live.depthFrames) (드롭 \(live.depthDrops))\n"
        t += "깊이 간격 p95 \(f(ExpMath.percentile(ExpMath.gaps(dTimes), 0.95).map { $0 * 1000 })) ms, 최대 \(f(ExpMath.gaps(dTimes).max().map { $0 * 1000 })) ms\n"
        t += "유효 깊이 픽셀 비율(값이 채워진 비율, 정확도 아님): 중앙값 \(f(vrMedian.map { $0 * 100 }))%, 최저 \(f(vrMin.map { $0 * 100 }))%\n"
        t += "깊이 형식: \(live.depthKind ?? "없음")\n"
        t += "accuracy \(live.accuracy ?? "없음"), quality \(live.quality ?? "없음"), filtered \(live.filtered.map { String($0) } ?? "없음"), calibration \(live.calibrationPresent.map { $0 ? "제공됨" : "없음" } ?? "없음")\n"
        t += "RGB·깊이 동기화: 같은 묶음 비율 \(f(live.pairFraction.map { $0 * 100 }))%, 최근접 시간차 p50 \(f(ExpMath.percentile(depthOffsetsNearest.map { abs($0) * 1000 }, 0.5))) ms / p95 \(f(ExpMath.percentile(depthOffsetsNearest.map { abs($0) * 1000 }, 0.95))) ms → \(sync.label)\n"
        t += "중단·오류 이벤트: \(events.all.count)건" + (events.all.isEmpty ? "\n" : " (" + events.all.map { "\($0.source):\($0.kind) \($0.detail)" }.joined(separator: "; ") + ")\n")
        t += "열 상태: \(Array(th).sorted().joined(separator: ", ")), 메모리 최대 \(f(fpMax)) MB\n"
        t += "측정 부하: 통계 계산 p50 \(f(statsP50, 2)) ms, 최대 \(f(statsMax, 2)) ms (콜백 밖 별도 큐)\n"
        if opts.saveSamples { t += "샘플 저장: \(savedN)개, \(savedB / 1024) KB\n" }
        t += "\n해석 주의\n"
        t += "  - 유효 픽셀 비율이나 여러 프레임의 일치는 실제 거리 정확도가 아니다. 정확도는 거리를 아는 표적과 비교해야 한다.\n"
        t += "  - disparity는 상대 역깊이, depth 형식은 변환된 값이다. 변환 가능하다는 사실이 절대 정확도를 뜻하지 않는다.\n"
        t += "  - 깊이 버퍼는 왜곡이 반영된(nonrectilinear) 데이터이고 센서 방향 그대로다. 3D 점으로 쓰려면 calibration으로 정류해야 한다.\n"
        t += "  - 동기화 기준은 영상 프레임 주기의 절반(잠정)이다.\n"
        return Summary(outcome: outcome, endReason: endReason, text: t, dictionary: d)
    }

    // MARK: 콜백 처리 (cbQueue)

    private func handleVideo(pts: Double, size: [Int], intrinsics: [Float]?) {
        videoPTS.add(pts)
        videoArrival.add(ExpSys.hostNow())
        if videoSize == nil { log?.write("video_first", ["size": size, "intrinsics_fx_fy_cx_cy": expNN(intrinsics)]) }
        videoSize = size
        if let intrinsics { videoIntrinsics = intrinsics }
        log?.write("v", ["pts": pts, "w": size[0], "h": size[1]])
    }

    private func handleDepth(_ d: AVDepthData, pts: Double, video: CVPixelBuffer?) {
        depthPTS.add(pts)
        depthArrival.add(ExpSys.hostNow())
        depthCountForStats += 1
        let n = depthCountForStats
        let map = d.depthDataMap
        let type = CVPixelBufferGetPixelFormatType(map)
        depthSize = [CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(map)]
        depthTypeName = ExpDepthKind.describe(type)
        accuracyName = Self.accuracy(d.depthDataAccuracy)
        qualityName = Self.quality(d.depthDataQuality)
        filteredFlag = d.isDepthDataFiltered
        let cal = d.cameraCalibrationData
        calibrationPresent = (cal != nil)
        log?.write("d", ["pts": pts, "n": n, "w": depthSize![0], "h": depthSize![1], "type": ExpSys.fourCC(type),
                         "accuracy": accuracyName!, "quality": qualityName!, "filtered": d.isDepthDataFiltered])
        if n == 1 || n % 90 == 0, let cal {
            let k = cal.intrinsicMatrix
            let ref = cal.intrinsicMatrixReferenceDimensions
            var rec: [String: Any] = [
                "fx": k.columns.0.x, "fy": k.columns.1.y, "cx": k.columns.2.x, "cy": k.columns.2.y,
                "refW": ref.width, "refH": ref.height, "pixelSizeMM": cal.pixelSize,
                "distortionCenter": [cal.lensDistortionCenter.x, cal.lensDistortionCenter.y],
                "hasDistortionLUT": cal.lensDistortionLookupTable != nil,
                "hasInverseDistortionLUT": cal.inverseLensDistortionLookupTable != nil,
                "n": n
            ]
            let e = cal.extrinsicMatrix
            rec["extrinsic4x3"] = [e.columns.0, e.columns.1, e.columns.2, e.columns.3].flatMap { [$0.x, $0.y, $0.z] }
            if let vi = videoIntrinsics, let vs = videoSize, ref.width > 0 {
                // 영상 intrinsics와 깊이 calibration(기준 해상도)을 같은 해상도로 환산해 비교한다. 크롭 차이가 있으면 어긋날 수 있다.
                let s = Double(vs[0]) / Double(ref.width)
                rec["videoFxFromAttachment"] = vi[0]
                rec["calFxScaledToVideoWidth"] = Double(k.columns.0.x) * s
                rec["fxRelativeDiff"] = Double(vi[0]) > 0 ? (Double(k.columns.0.x) * s - Double(vi[0])) / Double(vi[0]) : 0
            }
            log?.write("cal", rec)
        }
        guard opts.statsEvery > 0, n % opts.statsEvery == 0 else { return }
        lock.lock()
        let busy = statsBusy
        if !busy { statsBusy = true }
        lock.unlock()
        if busy { return }   // 이전 통계가 아직 끝나지 않았으면 이 프레임은 건너뛴다.
        let wantPreview = opts.previewDepth
        let hostNow = ExpSys.hostNow()
        let wantSample: Bool = {
            guard opts.saveSamples, let video else { return false }
            lock.lock(); defer { lock.unlock() }
            return savedSamples < 10 && savedBytes < 12 * 1024 * 1024 && hostNow - lastSampleHost >= 3
        }()
        let videoRef: CVPixelBuffer? = wantSample ? video : nil
        statsQueue.async { [weak self] in
            guard let self else { return }
            let t0 = ExpSys.uptime()
            let nativeStats = ExpDepthPixels.stats(map)
            // meters-like 변환값의 중앙값 (accuracy가 relative이면 절대 거리가 아니다)
            let converted = d.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            let convStats = ExpDepthPixels.stats(converted.depthDataMap)
            let preview = wantPreview ? ExpDepthPixels.colorized(map) : nil
            if let videoRef { self.saveSample(video: videoRef, depth: d, pts: pts, hostNow: hostNow) }
            let ms = (ExpSys.uptime() - t0) * 1000
            self.lock.lock()
            if let s = nativeStats { self.lastValidRatio = s.validRatio; self.validRatios.append(s.validRatio) }
            self.centerRing.append((hostNow, Self.centerValue(nativeStats), Self.centerValue(convStats), Self.centerValid(nativeStats)))
            if self.centerRing.count > 12 { self.centerRing.removeFirst(self.centerRing.count - 12) }
            if wantPreview { self.lastPreview = preview }
            self.statsMs.append(ms)
            self.statsBusy = false
            self.lock.unlock()
            // 화면 갱신은 통계마다 하지만 로그에는 3번에 한 번만 남긴다 (5분 검사도 줄 한도 안에 들어가게).
            if (n / max(1, self.opts.statsEvery)) % 3 == 1 {
                self.log?.write("dstats", [
                    "pts": pts, "n": n, "native": expNN(nativeStats?.dictionary()),
                    "asDepthFloat32": expNN(convStats?.dictionary(includeGrid: false)),
                    "convertedAccuracy": Self.accuracy(converted.depthDataAccuracy), "statsMs": ms
                ])
            }
        }
    }

    private func saveSample(video: CVPixelBuffer, depth: AVDepthData, pts: Double, hostNow: Double) {
        let fm = FileManager.default
        guard let dir = log?.samplesDirectory else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock(); let idx = savedSamples + 1; lock.unlock()
        let stem = String(format: "sample-%02d", idx)
        var bytes = 0
        if let bin = ExpDepthPixels.float32Data(depth.depthDataMap) {
            try? bin.write(to: dir.appendingPathComponent(stem + ".depth.f32")); bytes += bin.count
        }
        let ci = CIImage(cvPixelBuffer: video)
        let scale = 640.0 / max(ci.extent.width, ci.extent.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cs = CGColorSpace(name: CGColorSpace.sRGB),
           let jpeg = Self.ciContext.jpegRepresentation(of: scaled, colorSpace: cs, options: [:]) {
            try? jpeg.write(to: dir.appendingPathComponent(stem + ".rgb.jpg")); bytes += jpeg.count
        }
        let map = depth.depthDataMap
        var side: [String: Any] = [
            "pts": pts, "depthW": CVPixelBufferGetWidth(map), "depthH": CVPixelBufferGetHeight(map),
            "depthNativeType": ExpSys.fourCC(CVPixelBufferGetPixelFormatType(map)),
            "depthFile": stem + ".depth.f32", "depthFileFormat": "float32 little-endian, row-major, 원본 타입 값을 float32로 펼침(변환 아님)",
            "accuracy": Self.accuracy(depth.depthDataAccuracy), "quality": Self.quality(depth.depthDataQuality),
            "filtered": depth.isDepthDataFiltered,
            "rgbMaxLongEdge": 640, "rgbOrientation": "센서 방향 그대로(회전 없음)"
        ]
        if let cal = depth.cameraCalibrationData {
            side["calFx"] = cal.intrinsicMatrix.columns.0.x
            side["calRefW"] = cal.intrinsicMatrixReferenceDimensions.width
            side["calRefH"] = cal.intrinsicMatrixReferenceDimensions.height
        }
        if let data = try? JSONSerialization.data(withJSONObject: expJSONSafe(side), options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent(stem + ".json")); bytes += data.count
        }
        lock.lock(); savedSamples = idx; savedBytes += bytes; lastSampleHost = hostNow; lock.unlock()
        log?.write("sample_saved", ["name": stem, "bytes": bytes])
    }

    /// 격자 8x6의 가운데 4칸(열 3,4 / 행 2,3)의 중앙값.
    static func centerValue(_ s: ExpDepthFrameStats?) -> Double? {
        guard let s, s.gridCols == 8, s.gridRows == 6 else { return nil }
        return ExpMath.percentile([19, 20, 27, 28].compactMap { s.gridMedian[$0] }, 0.5)
    }

    static func centerValid(_ s: ExpDepthFrameStats?) -> Double? {
        guard let s, s.gridCols == 8, s.gridRows == 6 else { return nil }
        let v = [19, 20, 27, 28].map { s.gridValid[$0] }
        return v.reduce(0, +) / Double(v.count)
    }

    /// 거리를 아는 표적을 화면 중앙에 두고 부른다. 최근 통계 몇 장의 중앙값을 기록한다.
    /// 기준 거리 = 후면 카메라 렌즈에서 표적 표면까지 광축 방향 거리(camera-Z). 중앙 영역에서는 range와 거의 같다.
    @discardableResult
    func recordTarget(knownDistanceM: Double) -> String {
        lock.lock()
        let recent = centerRing.suffix(5)
        let natives = recent.compactMap { $0.native }, convs = recent.compactMap { $0.converted }, valids = recent.compactMap { $0.valid }
        let type = depthTypeName ?? "?", acc = accuracyName ?? "?"
        lock.unlock()
        guard !natives.isEmpty || !convs.isEmpty else { return "아직 기록할 깊이 값이 없어요. 몇 초 뒤 다시 눌러 주세요." }
        let r = ExpTargetReading(knownDistanceM: knownDistanceM, native: ExpMath.percentile(natives, 0.5), converted: ExpMath.percentile(convs, 0.5),
                                 centerValid: valids.isEmpty ? nil : valids.reduce(0, +) / Double(valids.count), accuracy: acc, depthType: type)
        lock.lock(); targetReadings.append(r); lock.unlock()
        log?.write("target_reading", [
            "knownDistanceM": knownDistanceM, "nativeCenter": expNN(r.native), "convertedCenter": expNN(r.converted),
            "centerValidRatio": expNN(r.centerValid), "accuracy": acc, "depthType": type,
            "note": "기준 거리는 렌즈에서 표적 표면까지 광축 방향(camera-Z). 변환값은 accuracy가 relative이면 절대 거리가 아니다."
        ])
        return String(format: "%.1f m 표적 기록: 원값 %@ · 변환값 %@", knownDistanceM,
                      r.native.map { String(format: "%.3f", $0) } ?? "없음", r.converted.map { String(format: "%.3f", $0) } ?? "없음")
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private static func accuracy(_ a: AVDepthData.Accuracy) -> String {
        switch a { case .relative: return "relative"; case .absolute: return "absolute"; @unknown default: return "unknown" }
    }

    private static func quality(_ q: AVDepthData.Quality) -> String {
        switch q { case .low: return "low"; case .high: return "high"; @unknown default: return "unknown" }
    }

    private static func reasonName(_ r: AVCaptureOutput.DataDroppedReason) -> String {
        switch r {
        case .none: return "none"
        case .lateData: return "lateData"
        case .outOfBuffers: return "outOfBuffers"
        case .discontinuity: return "discontinuity"
        @unknown default: return "unknown"
        }
    }

    fileprivate func intrinsics(from sb: CMSampleBuffer) -> [Float]? {
        guard let att = CMGetAttachment(sb, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
              att.count == MemoryLayout<matrix_float3x3>.size else { return nil }
        var m = matrix_float3x3()
        att.withUnsafeBytes { src in
            withUnsafeMutableBytes(of: &m) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dst.count)))
            }
        }
        return [m.columns.0.x, m.columns.1.y, m.columns.2.x, m.columns.2.y]
    }
}

extension ExperimentDepthRunner: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        collections += 1
        let v = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData
        let d = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        var vPTS: Double?, dPTS: Double?
        var videoBuffer: CVPixelBuffer?
        if let v {
            if v.sampleBufferWasDropped {
                videoDrops += 1
                log?.write("v_drop", ["pts": v.timestamp.seconds, "reason": Self.reasonName(v.droppedReason)])
            } else {
                let pb = CMSampleBufferGetImageBuffer(v.sampleBuffer)
                videoBuffer = pb
                let size = [pb.map { CVPixelBufferGetWidth($0) } ?? 0, pb.map { CVPixelBufferGetHeight($0) } ?? 0]
                handleVideo(pts: v.timestamp.seconds, size: size, intrinsics: intrinsics(from: v.sampleBuffer))
                vPTS = v.timestamp.seconds
            }
        }
        if let d {
            if d.depthDataWasDropped {
                depthDrops += 1
                log?.write("d_drop", ["pts": d.timestamp.seconds, "reason": Self.reasonName(d.droppedReason)])
            } else {
                handleDepth(d.depthData, pts: d.timestamp.seconds, video: videoBuffer)
                dPTS = d.timestamp.seconds
            }
        }
        if let vPTS, let dPTS {
            pairs += 1
            if pairOffsets.count < 60_000 { pairOffsets.append(dPTS - vPTS) }
        }
    }
}

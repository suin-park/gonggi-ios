import Foundation
import ARKit
import AVFoundation
import CoreMotion
import simd

/// 렌즈 장치 상태 한 번의 읽기. 읽은 시각(readHost)은 영상 프레임의 촬영 시각이 아니다.
struct ExpLensState {
    var readHost: Double
    var lensPosition: Float
    var iso: Float
    var exposureDurationS: Double
    var isAdjustingFocus: Bool
    var isAdjustingExposure: Bool
    var deviceType: String
    var formatSize: [Int]
}

/// 기본 센서 검사 화면에 보여 줄 값.
struct ExpARLive {
    var phase = ""
    var elapsed: Double = 0
    var tracking = "—"
    var position: [Float]?
    var eulerDeg: [Float]?
    var imageSize: [Int]?
    var fps: Double?
    var frames = 0
    var rawPoints: Int?
    var planesHorizontal = 0
    var planesVertical = 0
    var exposureDurationS: Double?
    var exposureOffset: Float?
    var lightIntensity: Float?
    var lightTemperature: Float?
    var exifSummary: [String] = []
    var exifKeyCount = 0
    var motionHz: Double?
    var cbMsP50: Double?
    var thermal = ""
    var footprintMB: Double?
    var lens: ExpLensState?
    var lensAgeS: Double?
    var personDepthSeen = false
    var sceneDepthSeen = false
    var eventCount = 0
    var message = ""
}

struct ExpARPhaseResult {
    var name: String
    var optionsLabel: String
    var seconds: Double
    var frames: Int
    var fps: Double?
    var gapP95Ms: Double?
    var gapMaxMs: Double?
    var cbMsP50: Double?
    var cbMsP95: Double?
    var trackingNormalRatio: Double?
    var rawPointsMedian: Double?
    var planesMax: Int
    var motionHz: Double?
    var footprintMaxMB: Double
    var thermal: [String]

    var dictionary: [String: Any] {
        ["name": name, "options": optionsLabel, "seconds": seconds, "frames": frames, "fps": expNN(fps),
         "gapP95Ms": expNN(gapP95Ms), "gapMaxMs": expNN(gapMaxMs), "callbackMsP50": expNN(cbMsP50), "callbackMsP95": expNN(cbMsP95),
         "trackingNormalRatio": expNN(trackingNormalRatio), "rawPointsMedian": expNN(rawPointsMedian), "planesMax": planesMax,
         "motionHz": expNN(motionHz), "footprintMaxMB": footprintMaxMB, "thermal": thermal]
    }
}

/// ARKit 월드 트래킹을 돌리며 ARFrame이 실제로 담고 있는 값, 수신 빈도, 선택 기능의 부하를 기록한다.
/// 기능은 하나씩 켜고 끌 수 있고(구간 phase), 구간마다 같은 지표를 따로 모은다.
final class ExperimentARRunner: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Options: Equatable {
        var planes = false
        var personDepth = false
        var motion = false
        var lensPolling = false

        var label: String {
            var p: [String] = ["추적"]
            if planes { p.append("평면") }
            if personDepth { p.append("사람 마스크·깊이") }
            if motion { p.append("Core Motion") }
            if lensPolling { p.append("렌즈 상태 읽기") }
            return p.joined(separator: " + ")
        }
    }

    static var supportsPersonDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) }
    static var supportsSceneDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    let session = ARSession()
    let events = ExpEvents()
    var onLive: ((ExpARLive) -> Void)?
    var onAutoStop: ((ExpEndReason) -> Void)?

    private let log: ExperimentRunLog?
    private let queue = DispatchQueue(label: "gonggi.experiment.ar.delegate", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "gonggi.experiment.ar.monitor", qos: .utility)
    private let motionQueue = OperationQueue()
    private let motion = CMMotionManager()
    private let lock = NSLock()

    private var options = Options()
    private var running = false
    private var timer: DispatchSourceTimer?
    private var lensTimer: DispatchSourceTimer?
    private var lensDevice: AVCaptureDevice?
    private var startedHost = 0.0
    private var clockDeltaAtStart = 0.0
    private var autoStopSent = false

    // 구간 집계 (lock으로 보호)
    private var phaseName = "run"
    private var phaseOptions = Options()
    private var phaseStartHost = 0.0
    private var phaseFrames = ExpRateMeter()
    private var phaseCb: [Double] = []
    private var phaseTrackingNormal = 0
    private var phaseRawPoints: [Double] = []
    private var phasePlanesMax = 0
    private var phaseMotionCount = 0
    private var phaseFootprintMax = 0.0
    private var phaseThermal = Set<String>()
    private var phaseResults: [ExpARPhaseResult] = []

    // 전체 집계
    private var allFrames = ExpRateMeter()          // host clock 시각으로 환산한 도착 시각
    private var hostTimestamps: [Double] = []        // ARFrame.timestamp + clockDelta (공존 검사에서 영상 PTS와 비교)
    private var trackingCounts: [String: Int] = [:]
    private var live = ExpARLive()
    private var lastLens: ExpLensState?
    private var personDepthSeen = false
    private var sceneDepthSeen = false
    private var frameCount = 0
    private var lastTimestamp: Double?
    private var motionMeter = ExpRateMeter()
    private var motionMaxRot = 0.0
    private var clockDeltas: [Double] = []

    init(log: ExperimentRunLog?) {
        self.log = log
        super.init()
        motionQueue.maxConcurrentOperationCount = 1
    }

    deinit { timer?.cancel(); lensTimer?.cancel() }

    // MARK: 지원 현황

    static func logSupport(_ log: ExperimentRunLog?) -> [String: Any] {
        typealias C = ARWorldTrackingConfiguration
        var d: [String: Any] = [
            "isSupported": C.isSupported,
            "sceneDepth(LiDAR 필요)": C.supportsFrameSemantics(.sceneDepth),
            "smoothedSceneDepth": C.supportsFrameSemantics(.smoothedSceneDepth),
            "personSegmentation": C.supportsFrameSemantics(.personSegmentation),
            "personSegmentationWithDepth": C.supportsFrameSemantics(.personSegmentationWithDepth),
            "sceneReconstructionMesh(LiDAR 필요)": C.supportsSceneReconstruction(.mesh),
            "planeClassification": ARPlaneAnchor.isClassificationSupported,
            "deviceMotionAvailable": CMMotionManager().isDeviceMotionAvailable,
            "configurableCaptureDevice": C.configurableCaptureDeviceForPrimaryCamera != nil,
            "videoFormats": C.supportedVideoFormats.enumerated().map { (i, f) -> [String: Any] in
                ["index": i, "w": f.imageResolution.width, "h": f.imageResolution.height, "fps": f.framesPerSecond,
                 "deviceType": f.captureDeviceType.rawValue, "position": f.captureDevicePosition.rawValue]
            }
        ]
        func fmt(_ f: ARConfiguration.VideoFormat?) -> Any {
            guard let f else { return NSNull() }
            return ["w": f.imageResolution.width, "h": f.imageResolution.height, "fps": f.framesPerSecond, "deviceType": f.captureDeviceType.rawValue]
        }
        d["recommended4K"] = fmt(C.recommendedVideoFormatFor4KResolution)
        d["recommendedHighResFrameCapture"] = fmt(C.recommendedVideoFormatForHighResolutionFrameCapturing)
        log?.write("ar_support", d)
        return d
    }

    // MARK: 시작·구간·종료

    private func makeConfig(_ o: Options) -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = o.planes ? [.horizontal, .vertical] : []
        if o.personDepth, Self.supportsPersonDepth { c.frameSemantics.insert(.personSegmentationWithDepth) }
        return c
    }

    func start(options o: Options, phase: String) {
        lock.lock()
        options = o
        running = true
        startedHost = ExpSys.hostNow()
        clockDeltaAtStart = ExpSys.clockDelta()
        clockDeltas = [clockDeltaAtStart]
        resetPhaseLocked(name: phase, options: o)
        lock.unlock()
        log?.write("phase_begin", ["phase": phase, "options": o.label, "clockDelta": clockDeltaAtStart])
        session.delegate = self
        session.delegateQueue = queue
        session.run(makeConfig(o), options: [.resetTracking, .removeExistingAnchors])
        applySideSources(o)
        startMonitor()
    }

    /// 세션을 다시 만들지 않고 설정만 바꿔 다음 구간을 시작한다 (추적 상태는 유지).
    func beginPhase(_ name: String, options o: Options) {
        finishPhase()
        lock.lock()
        options = o
        resetPhaseLocked(name: name, options: o)
        lock.unlock()
        log?.write("phase_begin", ["phase": name, "options": o.label])
        session.run(makeConfig(o), options: [])
        applySideSources(o)
    }

    private func resetPhaseLocked(name: String, options o: Options) {
        phaseName = name; phaseOptions = o; phaseStartHost = ExpSys.hostNow()
        phaseFrames = ExpRateMeter(); phaseCb = []; phaseTrackingNormal = 0; phaseRawPoints = []
        phasePlanesMax = 0; phaseMotionCount = 0; phaseFootprintMax = 0; phaseThermal = []
    }

    private func finishPhase() {
        lock.lock()
        let secs = max(ExpSys.hostNow() - phaseStartHost, 0.001)
        let gaps = ExpMath.gaps(phaseFrames.times)
        let r = ExpARPhaseResult(
            name: phaseName, optionsLabel: phaseOptions.label, seconds: secs, frames: phaseFrames.total,
            fps: phaseFrames.hz, gapP95Ms: ExpMath.percentile(gaps, 0.95).map { $0 * 1000 }, gapMaxMs: gaps.max().map { $0 * 1000 },
            cbMsP50: ExpMath.percentile(phaseCb, 0.5), cbMsP95: ExpMath.percentile(phaseCb, 0.95),
            trackingNormalRatio: phaseFrames.total > 0 ? Double(phaseTrackingNormal) / Double(phaseFrames.total) : nil,
            rawPointsMedian: ExpMath.percentile(phaseRawPoints, 0.5), planesMax: phasePlanesMax,
            motionHz: phaseOptions.motion ? Double(phaseMotionCount) / secs : nil,
            footprintMaxMB: phaseFootprintMax, thermal: Array(phaseThermal).sorted())
        phaseResults.append(r)
        lock.unlock()
        log?.write("phase_end", r.dictionary)
    }

    private func applySideSources(_ o: Options) {
        // Core Motion
        if o.motion, motion.isDeviceMotionAvailable {
            if !motion.isDeviceMotionActive {
                motion.deviceMotionUpdateInterval = 1.0 / 100.0
                motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
                    guard let self, let m else { return }
                    let r = m.rotationRate
                    let mag = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
                    self.lock.lock()
                    self.motionMeter.add(m.timestamp)
                    self.phaseMotionCount += 1
                    self.motionMaxRot = max(self.motionMaxRot, mag)
                    self.lock.unlock()
                }
            }
        } else if motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
        // 렌즈 상태: ARKit이 쓰는 장치를 읽기만 한다 (설정은 바꾸지 않고 별도 캡처 세션도 만들지 않는다).
        if o.lensPolling {
            if lensTimer == nil {
                lensDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
                if lensDevice == nil { log?.write("lens_unavailable", ["reason": "configurableCaptureDeviceForPrimaryCamera == nil"]) }
                let t = DispatchSource.makeTimerSource(queue: monitorQueue)
                t.schedule(deadline: .now() + 0.2, repeating: 0.2)
                t.setEventHandler { [weak self] in self?.readLens() }
                t.resume()
                lensTimer = t
            }
        } else {
            lensTimer?.cancel(); lensTimer = nil
        }
    }

    private func readLens() {
        guard let dev = lensDevice else { return }
        let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        let s = ExpLensState(
            readHost: ExpSys.hostNow(), lensPosition: dev.lensPosition, iso: dev.iso, exposureDurationS: dev.exposureDuration.seconds,
            isAdjustingFocus: dev.isAdjustingFocus, isAdjustingExposure: dev.isAdjustingExposure,
            deviceType: dev.deviceType.rawValue, formatSize: [Int(d.width), Int(d.height)])
        lock.lock(); lastLens = s; lock.unlock()
        log?.write("lens", [
            "read_host_s": s.readHost, "lensPosition": s.lensPosition, "iso": s.iso, "exposureDurationS": s.exposureDurationS,
            "isAdjustingFocus": s.isAdjustingFocus, "isAdjustingExposure": s.isAdjustingExposure, "deviceType": s.deviceType,
            "formatSize": s.formatSize,
            "note": "장치 상태를 읽은 시각이다. 특정 영상 프레임의 촬영 시각과 같다고 가정하지 않는다."
        ])
    }

    /// 미리보기 뷰가 세션에 붙은 뒤에도 프레임이 이 러너로 들어오게 delegate를 다시 지정한다(실행 중일 때만).
    func reassertDelegate() {
        lock.lock(); let r = running; lock.unlock()
        guard r else { return }
        session.delegate = self
        session.delegateQueue = queue
    }

    /// 멈춘다. 여러 번 불러도 안전하다.
    func stop() {
        timer?.cancel(); timer = nil
        lensTimer?.cancel(); lensTimer = nil
        lock.lock(); let wasRunning = running; running = false; lock.unlock()
        guard wasRunning else { return }
        session.pause()
        session.delegate = nil
        motion.stopDeviceMotionUpdates()
        finishPhase()
        log?.write("ar_stopped", ["totalFrames": frameCount])
    }

    // MARK: 모니터 (4Hz 화면 갱신, 1Hz 로그)

    private func startMonitor() {
        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            let l = self.liveSnapshot()
            self.onLive?(l)
            if tick % 4 == 0 {
                self.lock.lock()
                self.phaseFootprintMax = max(self.phaseFootprintMax, l.footprintMB ?? 0)
                self.phaseThermal.insert(l.thermal)
                self.clockDeltas.append(ExpSys.clockDelta())
                self.lock.unlock()
                self.log?.write("hb", ["src": "ar", "phase": l.phase, "frames": l.frames, "fps": expNN(l.fps), "tracking": l.tracking,
                                       "rawPoints": expNN(l.rawPoints), "motionHz": expNN(l.motionHz), "cbMsP50": expNN(l.cbMsP50),
                                       "thermal": l.thermal, "footprintMB": expNN(l.footprintMB)])
                if ExpSys.thermalIsSevere, !self.autoStopSent {
                    self.autoStopSent = true
                    self.log?.write("auto_stop", ["reason": "thermal", "thermal": l.thermal])
                    self.onAutoStop?(.thermal)
                }
            }
        }
        t.resume()
        timer = t
    }

    func liveSnapshot() -> ExpARLive {
        lock.lock()
        var l = live
        l.phase = phaseName
        l.elapsed = ExpSys.hostNow() - startedHost
        // 최근 2초 안의 도착만 모아 현재 FPS로 본다.
        let now = ExpSys.hostNow()
        let recent = allFrames.times.suffix(400).filter { now - $0 <= 2.0 }
        l.fps = recent.count > 1 ? Double(recent.count - 1) / max(recent.last! - recent.first!, 0.001) : nil
        l.frames = allFrames.total
        let recentMotion = motionMeter.times.suffix(400).filter { ExpSys.uptime() - $0 <= 2.0 }
        l.motionHz = recentMotion.count > 1 ? Double(recentMotion.count - 1) / max(recentMotion.last! - recentMotion.first!, 0.001) : nil
        l.cbMsP50 = ExpMath.percentile(Array(phaseCb.suffix(120)), 0.5)
        l.lens = lastLens
        l.lensAgeS = lastLens.map { now - $0.readHost }
        l.personDepthSeen = personDepthSeen
        l.sceneDepthSeen = sceneDepthSeen
        lock.unlock()
        l.thermal = ExpSys.thermal
        l.footprintMB = ExpSys.footprintMB()
        l.eventCount = events.all.count
        return l
    }

    // MARK: ARSessionDelegate

    private func trackingName(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(let r):
            switch r {
            case .initializing: return "limited:initializing"
            case .excessiveMotion: return "limited:excessiveMotion"
            case .insufficientFeatures: return "limited:insufficientFeatures"
            case .relocalizing: return "limited:relocalizing"
            @unknown default: return "limited:unknown"
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = ExpSys.uptime()
        let cam = frame.camera
        let tracking = trackingName(cam.trackingState)
        let raw = frame.rawFeaturePoints?.points.count
        var ph = 0, pv = 0
        for a in frame.anchors {
            if let p = a as? ARPlaneAnchor { if p.alignment == .horizontal { ph += 1 } else { pv += 1 } }
        }
        let pb = frame.capturedImage
        let imageSize = [CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)]
        let arHost = frame.timestamp + clockDeltaAtStart
        let n: Int
        lock.lock()
        frameCount += 1; n = frameCount
        allFrames.add(ExpSys.hostNow())
        hostTimestamps.append(arHost)
        if hostTimestamps.count > ExpRateMeter.maxStored { hostTimestamps.removeFirst(hostTimestamps.count - ExpRateMeter.maxStored) }
        phaseFrames.add(arHost)
        trackingCounts[tracking, default: 0] += 1
        if tracking == "normal" { phaseTrackingNormal += 1 }
        if let raw { phaseRawPoints.append(Double(raw)) }
        phasePlanesMax = max(phasePlanesMax, ph + pv)
        if frame.estimatedDepthData != nil || frame.segmentationBuffer != nil { personDepthSeen = true }
        if frame.sceneDepth != nil { sceneDepthSeen = true }
        var l = live
        l.tracking = tracking
        l.position = [cam.transform.columns.3.x, cam.transform.columns.3.y, cam.transform.columns.3.z]
        l.eulerDeg = cam.eulerAngles.dividedByDegrees
        l.imageSize = imageSize
        l.rawPoints = raw
        l.planesHorizontal = ph; l.planesVertical = pv
        l.exposureDurationS = cam.exposureDuration
        l.exposureOffset = cam.exposureOffset
        l.lightIntensity = frame.lightEstimate?.ambientIntensity.floatValue
        l.lightTemperature = frame.lightEstimate?.ambientColorTemperature.floatValue
        live = l
        lock.unlock()

        var rec: [String: Any] = [
            "ts": frame.timestamp, "n": n, "tracking": tracking, "rawPoints": expNN(raw), "planes": ph + pv,
            "image": imageSize, "exposureDurationS": cam.exposureDuration, "exposureOffset": cam.exposureOffset
        ]
        if n == 1 || n % 30 == 0 {
            let k = cam.intrinsics
            let q = simd_quatf(cam.transform)
            rec["imageResolution"] = [cam.imageResolution.width, cam.imageResolution.height]
            rec["intrinsics_fx_fy_cx_cy"] = [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y]
            rec["pos"] = [cam.transform.columns.3.x, cam.transform.columns.3.y, cam.transform.columns.3.z]
            rec["quat_xyzw"] = [q.vector.x, q.vector.y, q.vector.z, q.vector.w]
            rec["rawPointIds"] = expNN(frame.rawFeaturePoints?.identifiers.count)
            rec["lightIntensity"] = expNN(frame.lightEstimate?.ambientIntensity)
            rec["lightTemperature"] = expNN(frame.lightEstimate?.ambientColorTemperature)
            rec["personDepthBuffer"] = expNN(frame.estimatedDepthData.map { [CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)] })
            rec["segmentationBuffer"] = expNN(frame.segmentationBuffer.map { [CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)] })
            rec["sceneDepth"] = frame.sceneDepth != nil
            rec["capturedDepthData(전면 전용)"] = frame.capturedDepthData != nil
            let exif = frame.exifData.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            rec["exif"] = exif
            lock.lock()
            live.exifKeyCount = exif.count
            live.exifSummary = ["ISOSpeedRatings", "ExposureTime", "FNumber", "FocalLength", "WhiteBalance", "BrightnessValue", "ExposureBiasValue"]
                .compactMap { key in exif[key].map { "\(key)=\($0)" } }
            lock.unlock()
            rec["planeDetails"] = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.prefix(12).map { p -> [String: Any] in
                ["alignment": p.alignment == .horizontal ? "H" : "V", "w": p.planeExtent.width, "h": p.planeExtent.height,
                 "center": [p.center.x, p.center.y, p.center.z], "classification": "\(p.classification)"]
            }
        }
        log?.write("ar", rec)
        lock.lock()
        live.frames = n
        phaseCb.append((ExpSys.uptime() - t0) * 1000)
        if phaseCb.count > 20_000 { phaseCb.removeFirst(phaseCb.count - 20_000) }
        lock.unlock()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let e = error as NSError
        events.add(source: "ar", kind: "error", detail: "\(e.domain) \(e.code)")
        log?.write("ar_error", ["domain": e.domain, "code": e.code, "description": e.localizedDescription])
    }

    func sessionWasInterrupted(_ session: ARSession) {
        events.add(source: "ar", kind: "interrupted", detail: "sessionWasInterrupted")
        log?.write("ar_interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) { log?.write("ar_interruption_ended") }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        log?.write("ar_tracking_change", ["state": trackingName(camera.trackingState)])
    }

    // MARK: 요약·공존 검사용 접근자

    /// 공존 검사에서 구간별 빈도를 구하기 위한 ARFrame 도착 시각(host clock 환산).
    var frameHostTimes: [Double] {
        lock.lock(); defer { lock.unlock() }
        return hostTimestamps
    }

    var clockDeltaSamples: [Double] {
        lock.lock(); defer { lock.unlock() }
        return clockDeltas
    }

    struct Summary {
        var text: String
        var dictionary: [String: Any]
    }

    func finalSummary(endReason: ExpEndReason, supports: [String: Any]) -> Summary {
        lock.lock()
        let phases = phaseResults
        let tc = trackingCounts, total = allFrames.total, pd = personDepthSeen, sd = sceneDepthSeen
        let motionHz = motionMeter.hz, motionMax = motionMaxRot
        let lens = lastLens, exifSummary = live.exifSummary, exifKeys = live.exifKeyCount
        let size = live.imageSize
        lock.unlock()

        func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "없음" }
        var t = "기본 센서 검사 요약\n종료: \(endReason.label)\n\n"
        t += "수신 프레임 \(total)개, 영상 해상도 \(size.map { "\($0[0])x\($0[1])" } ?? "없음")\n"
        t += "추적 상태 분포: " + (tc.isEmpty ? "없음" : tc.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) + "\n"
        t += "EXIF 항목 \(exifKeys)개 · " + (exifSummary.isEmpty ? "대표 항목 없음" : exifSummary.joined(separator: ", ")) + "\n"
        t += "Core Motion 평균 수신 \(f(motionHz)) Hz (최대 회전 \(f(motionMax, 2)) rad/s)\n"
        t += "사람 마스크/깊이 버퍼 수신: \(pd ? "예" : "아니오"), ARKit sceneDepth(LiDAR 필요) 수신: \(sd ? "예" : "아니오")\n"
        if let lens {
            t += String(format: "렌즈 상태(마지막 읽기): lensPosition %.3f, ISO %.0f, 노출 %.4f s, 초점 이동 %@, 노출 조정 %@ (읽은 시각 기준이며 프레임 촬영 시각이 아님)\n",
                        lens.lensPosition, lens.iso, lens.exposureDurationS, lens.isAdjustingFocus ? "예" : "아니오", lens.isAdjustingExposure ? "예" : "아니오")
        }
        t += "\n구간별 비교 (같은 지표, 선택 기능만 다름)\n"
        for p in phases {
            t += "■ \(p.name) — \(p.optionsLabel) (\(f(p.seconds, 0))초)\n"
            t += "   FPS \(f(p.fps)) · 프레임 간격 p95 \(f(p.gapP95Ms)) ms, 최대 \(f(p.gapMaxMs)) ms · 콜백 처리 p50 \(f(p.cbMsP50, 2)) / p95 \(f(p.cbMsP95, 2)) ms\n"
            t += "   추적 normal \(f(p.trackingNormalRatio.map { $0 * 100 }))% · 특징점 중앙값 \(f(p.rawPointsMedian, 0)) · 평면 최대 \(p.planesMax)개 · Core Motion \(f(p.motionHz)) Hz\n"
            t += "   메모리 최대 \(f(p.footprintMaxMB)) MB · 열 \(p.thermal.joined(separator: ","))\n"
        }
        t += "\n중단·오류 이벤트 \(events.all.count)건\n"
        t += "\n해석 주의\n  - 특징점 수와 평면 수는 ARKit 중간 결과이며 밀도·정확도를 보장하지 않는다.\n  - 구간 사이의 차이는 열 상태·장면에 따라서도 달라질 수 있다. 같은 장면에서 반복해 비교한다.\n  - ARKit sceneDepth는 LiDAR가 필요해 LiDAR 없는 기기에서는 쓸 수 없다. 후면 깊이(듀얼 와이드)와 별개다.\n"
        var d: [String: Any] = [
            "endReason": endReason.rawValue, "frames": total, "imageSize": expNN(size),
            "trackingCounts": tc, "exifKeyCount": exifKeys, "exifSummary": exifSummary, "motionHz": expNN(motionHz),
            "personDepthBufferSeen": pd, "sceneDepthSeen": sd, "phases": phases.map { $0.dictionary },
            "events": events.all.map { ["source": $0.source, "kind": $0.kind, "detail": $0.detail] }, "supports": supports
        ]
        if let lens {
            d["lastLens"] = ["lensPosition": lens.lensPosition, "iso": lens.iso, "exposureDurationS": lens.exposureDurationS,
                             "isAdjustingFocus": lens.isAdjustingFocus, "isAdjustingExposure": lens.isAdjustingExposure]
        }
        return Summary(text: t, dictionary: d)
    }
}

private extension simd_float3 {
    var dividedByDegrees: [Float] { [x, y, z].map { $0 * 180 / .pi } }
}

private extension Float {
    var floatValue: Float { self }
}

private extension CGFloat {
    var floatValue: Float { Float(self) }
}

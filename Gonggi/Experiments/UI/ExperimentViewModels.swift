import Foundation
import AVFoundation
import SwiftUI

enum ExpPermission {
    static func ensureCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

// MARK: - 기본 센서 검사

@MainActor
final class ExperimentSensorViewModel: ObservableObject {
    @Published var state: ExpRunState = .idle
    @Published var live = ExpARLive()
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var optPlanes = false
    @Published var optMotion = false
    @Published var optPersonDepth = false
    @Published var optLens = false
    @Published var compareMode = false
    @Published var duration: Double = 60
    @Published private(set) var session: ARSessionBox?

    /// 화면에 미리보기를 붙이기 위한 상자 (ARSession은 Runner가 소유한다).
    struct ARSessionBox: Identifiable {
        let id = UUID()
        let runner: ExperimentARRunner
    }

    private let gate = ExperimentCameraGate.shared
    private let gateName = "sensor"
    private var runner: ExperimentARRunner?
    private var controlTask: Task<Void, Never>?
    private var stopReason: ExpEndReason?

    static let comparePhaseSeconds: Double = 20

    var supportsPersonDepth: Bool { ExperimentARRunner.supportsPersonDepth }
    var sceneDepthSupported: Bool { ExperimentARRunner.supportsSceneDepth }
    var isBusy: Bool { state.isBusy }

    private func plan() -> [(name: String, options: ExperimentARRunner.Options)] {
        if compareMode {
            var p: [(String, ExperimentARRunner.Options)] = [
                ("1. 기본(추적만)", .init()),
                ("2. + 평면 검출", .init(planes: true)),
                ("3. + Core Motion", .init(planes: true, motion: true))
            ]
            if supportsPersonDepth { p.append(("4. + 사람 마스크·깊이", .init(planes: true, personDepth: true, motion: true))) }
            p.append(("5. + 렌즈 상태 읽기", .init(planes: true, personDepth: supportsPersonDepth, motion: true, lensPolling: true)))
            return p.map { (name: $0.0, options: $0.1) }
        }
        return [(name: "run", options: .init(planes: optPlanes, personDepth: optPersonDepth && supportsPersonDepth,
                                              motion: optMotion, lensPolling: optLens))]
    }

    func start() {
        guard state == .idle || state == .finished else { return }
        state = .starting
        summaryText = nil; shareItems = []; message = ""; stopReason = nil
        controlTask = Task { [weak self] in await self?.run() }
    }

    func requestStop(_ reason: ExpEndReason) {
        if stopReason == nil { stopReason = reason }
        if state == .starting || state == .running { state = .stopping }
    }

    private func run() async {
        guard await gate.acquire(gateName) else {
            message = "다른 검사가 카메라를 사용 중이에요. 잠시 뒤 다시 시도해 주세요."
            state = .idle
            return
        }
        guard await ExpPermission.ensureCamera() else {
            message = "카메라 권한이 필요해요. 설정 앱에서 허용해 주세요."
            gate.release(gateName); state = .idle
            return
        }
        let phases = plan()
        let kind: ExperimentKind = compareMode ? .sensorCompare : .sensorBasic
        let settings: [String: Any] = [
            "compareMode": compareMode, "durationS": compareMode ? Self.comparePhaseSeconds * Double(phases.count) : duration,
            "phases": phases.map { ["name": $0.name, "options": $0.options.label] },
            "personDepthSupported": supportsPersonDepth, "sceneDepthSupported(LiDAR)": sceneDepthSupported
        ]
        guard let log = ExperimentRunLog(kind: kind, settings: settings) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."
            gate.release(gateName); state = .idle
            return
        }
        let support = ExperimentARRunner.logSupport(log)
        let r = ExperimentARRunner(log: log)
        r.onLive = { [weak self] l in Task { @MainActor in self?.live = l } }
        r.onAutoStop = { [weak self] reason in Task { @MainActor in self?.requestStop(reason) } }
        runner = r
        session = ARSessionBox(runner: r)
        r.start(options: phases[0].options, phase: phases[0].name)
        state = .running

        let total = compareMode ? Self.comparePhaseSeconds * Double(phases.count) : duration
        let begin = Date()
        var phaseIndex = 0
        var reason: ExpEndReason = .completed
        while true {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let s = stopReason { reason = s; break }
            if Task.isCancelled { reason = .userStopped; break }
            let elapsed = Date().timeIntervalSince(begin)
            if elapsed >= total { reason = .completed; break }
            if compareMode {
                let idx = min(phases.count - 1, Int(elapsed / Self.comparePhaseSeconds))
                if idx != phaseIndex {
                    phaseIndex = idx
                    r.beginPhase(phases[idx].name, options: phases[idx].options)
                }
            }
        }
        state = .stopping
        r.stop()
        let summary = r.finalSummary(endReason: reason, supports: support)
        log.finish(summary: summary.dictionary, summaryText: summary.text)
        summaryText = summary.text
        shareItems = [log.url, log.summaryURL]
        runner = nil
        session = nil
        gate.release(gateName)
        state = .finished
    }
}

// MARK: - 후면 깊이 검사

@MainActor
final class ExperimentDepthViewModel: ObservableObject {
    @Published var state: ExpRunState = .idle
    @Published var live = ExpDepthLive()
    @Published var discovery: ExpDiscoveryResult?
    @Published var discovering = false
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var previewSession: AVCaptureSession?
    @Published var filtering = false
    @Published var previewDepth = true
    @Published var saveSamples = false
    @Published var duration: Double = 60
    @Published var choiceId = "auto"
    @Published var targetMessage = ""

    private let gate = ExperimentCameraGate.shared
    private let gateName = "depth"
    private var runner: ExperimentDepthRunner?
    private var controlTask: Task<Void, Never>?
    private var stopReason: ExpEndReason?

    var isBusy: Bool { state.isBusy }

    var selectedChoice: ExpFormatChoice? {
        discovery?.choices.first { $0.id == choiceId }
    }

    /// 카메라를 실행하지 않고 장치·포맷만 확인한다 (A, B).
    func discover() {
        guard !isBusy, !discovering else { return }
        discovering = true
        Task { [weak self] in
            let r = await ExperimentDiscovery.run(log: nil)
            self?.discovery = r
            self?.discovering = false
        }
    }

    func start() {
        guard state == .idle || state == .finished else { return }
        state = .starting
        summaryText = nil; shareItems = []; message = ""; stopReason = nil; targetMessage = ""
        live = ExpDepthLive()
        controlTask = Task { [weak self] in await self?.run() }
    }

    func requestStop(_ reason: ExpEndReason) {
        if stopReason == nil { stopReason = reason }
        if state == .starting || state == .running { state = .stopping }
    }

    func recordTarget(_ meters: Double) {
        targetMessage = runner?.recordTarget(knownDistanceM: meters) ?? "검사가 실행 중일 때만 기록할 수 있어요."
    }

    private func run() async {
        guard await gate.acquire(gateName) else {
            message = "다른 검사가 카메라를 사용 중이에요. 잠시 뒤 다시 시도해 주세요."
            state = .idle
            return
        }
        let choice = selectedChoice
        let settings: [String: Any] = [
            "durationS": duration, "filtering": filtering, "previewDepth": previewDepth, "saveSamples": saveSamples,
            "format": choice?.label ?? "자동", "sync": "AVCaptureDataOutputSynchronizer",
            "note": "320x240 같은 해상도는 가정하지 않는다. 실제 포맷은 C_config 줄에 기록된다."
        ]
        guard let log = ExperimentRunLog(kind: .depthStream, settings: settings) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."
            gate.release(gateName); state = .idle
            return
        }
        var o = ExperimentDepthRunner.Options()
        o.filtering = filtering; o.previewDepth = previewDepth; o.saveSamples = saveSamples; o.choice = choice
        let r = ExperimentDepthRunner(options: o, log: log)
        r.onLive = { [weak self] l in Task { @MainActor in self?.live = l } }
        r.onAutoStop = { [weak self] reason in Task { @MainActor in self?.requestStop(reason) } }
        runner = r

        let setup = await r.prepare()
        var reason: ExpEndReason = .completed
        if setup.outputConnected, setup.error == nil, stopReason == nil {
            await r.start()
            previewSession = r.session
            state = .running
            let begin = Date()
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let s = stopReason { reason = s; break }
                if Task.isCancelled { reason = .userStopped; break }
                if Date().timeIntervalSince(begin) >= duration { reason = .completed; break }
            }
        } else {
            reason = stopReason ?? .failed
        }
        state = .stopping
        previewSession = nil
        await r.stop()
        let summary = r.finalSummary(endReason: reason)
        log.finish(summary: summary.dictionary, summaryText: summary.text)
        summaryText = summary.text
        shareItems = ExperimentRunStore.shareItems(for: ExperimentRunInfo(
            baseName: log.baseName, experiment: log.kind.rawValue, title: log.kind.title, startedAt: nil, machine: "", appVersion: "",
            jsonlURL: log.url, summaryURL: log.summaryURL, samplesURL: log.samplesDirectory, sizeBytes: 0))
        runner = nil
        gate.release(gateName)
        state = .finished
        // 탐지 결과도 새로 고친다 (권한을 방금 허용했을 수 있음).
        discovery = await ExperimentDiscovery.run(log: nil)
    }
}

// MARK: - 공존 검사

@MainActor
final class ExperimentCoexistViewModel: ObservableObject {
    @Published var state: ExpRunState = .idle
    @Published var current: ExpCoexistTest?
    @Published var progress: ExpCoexistProgress?
    @Published var message = ""
    @Published var summaryText: String?
    @Published var shareItems: [URL] = []
    @Published var soloSeconds: Double = 30

    private let gate = ExperimentCameraGate.shared
    private let gateName = "coexist"
    private var runner: ExperimentCoexistRunner?
    private var controlTask: Task<Void, Never>?
    private var pendingStop: ExpEndReason?

    var isBusy: Bool { state.isBusy }

    func start(_ test: ExpCoexistTest) {
        guard state == .idle || state == .finished else { return }
        pendingStop = nil
        state = .starting
        current = test; summaryText = nil; shareItems = []; message = ""; progress = nil
        controlTask = Task { [weak self] in await self?.run(test) }
    }

    func requestStop(_ reason: ExpEndReason) {
        if pendingStop == nil { pendingStop = reason }
        runner?.cancel(reason)
        if state == .starting || state == .running { state = .stopping }
    }

    private func run(_ test: ExpCoexistTest) async {
        guard await gate.acquire(gateName) else {
            message = "다른 검사가 카메라를 사용 중이에요. 잠시 뒤 다시 시도해 주세요."
            state = .idle
            return
        }
        guard await ExpPermission.ensureCamera() else {
            message = "카메라 권한이 필요해요. 설정 앱에서 허용해 주세요."
            gate.release(gateName); state = .idle
            return
        }
        guard let log = ExperimentRunLog(kind: test.kind, settings: ["test": test.rawValue, "soloSeconds": soloSeconds,
                                                                      "note": "사용자가 명시적으로 시작한 검사. 의도적으로 두 소스를 같은 카메라에 동시에 연다."]) else {
            message = "로그 파일을 만들 수 없어요. 저장 공간을 확인해 주세요."
            gate.release(gateName); state = .idle
            return
        }
        let r = ExperimentCoexistRunner(test: test, log: log, seconds: soloSeconds)
        r.onProgress = { [weak self] p in Task { @MainActor in self?.progress = p } }
        runner = r
        if let p = pendingStop { r.cancel(p) }
        state = .running
        let result = await r.run()
        state = .stopping
        log.finish(summary: result.dictionary, summaryText: result.text)
        summaryText = result.text
        shareItems = [log.url, log.summaryURL]
        runner = nil
        gate.release(gateName)
        state = .finished
    }
}

// MARK: - 결과

@MainActor
final class ExperimentResultsViewModel: ObservableObject {
    @Published var runs: [ExperimentRunInfo] = []
    @Published var loading = false

    func reload() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) { ExperimentRunStore.list() }.value
            self?.runs = list
            self?.loading = false
        }
    }
}

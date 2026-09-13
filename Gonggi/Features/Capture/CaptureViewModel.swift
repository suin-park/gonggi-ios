import ARKit
import Combine
import SwiftUI

@MainActor
final class CaptureViewModel: ObservableObject {
    enum CameraPresentation: Equatable {
        case pending
        case mock
        case live
    }

    @Published private(set) var cameraPresentation: CameraPresentation = .pending
    @Published private(set) var useMockCamera = false
    @Published private(set) var hasReceivedFrame = false
    @Published private(set) var lastSummary: CaptureSessionSummary?
    @Published private(set) var isStopping = false
    @Published private(set) var isReconstructingTexturedMesh = false
    /// Active Astra guide segment index (0-based) when a guide plan is applied.
    @Published private(set) var guidedSegmentIndex: Int = 0

    let guidance = CaptureGuidanceEngine()
    let arSession = ARSession()
    let framePipeline = CaptureFramePipeline()

    private let texturedMeshCapture = TexturedMeshCaptureService()
    private var mockTimer: AnyCancellable?
    private var guidanceCancellable: AnyCancellable?
    private var startedAt = Date()
    private var guidePlan: AdvancedCaptureGuidePlan?
    /// Normalized Astra initial plan — live metrics remain completion authority.
    private(set) var capturePlan: CapturePlan = .empty
    private var configureGeneration = 0
    private var didStartLiveSession = false

    init() {
        guidanceCancellable = guidance.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        framePipeline.onQualityUpdate = { [weak self] quality, message in
            Task { @MainActor in
                self?.guidance.applySnapshot(quality: quality, message: message)
                self?.advanceGuidedSegmentIfNeeded()
            }
        }
    }

    func applyGuidePlan(_ plan: AdvancedCaptureGuidePlan) {
        let sanitized = AdvancedCaptureCopy.sanitize(plan)
        guidePlan = sanitized
        capturePlan = CapturePlan.normalize(from: sanitized)
        guidedSegmentIndex = 0
        // Initial hint only — during capture, live GuidanceAction owns the coach bubble.
        if let hint = capturePlan.startHint {
            guidance.applySnapshot(quality: guidance.quality, message: hint)
        }
    }

    func advanceGuidedSegment() {
        guard let plan = guidePlan, !plan.segments.isEmpty else { return }
        guidedSegmentIndex = min(guidedSegmentIndex + 1, plan.segments.count - 1)
        // Do not override live coach copy with Astra text.
    }

    private func advanceGuidedSegmentIfNeeded() {
        guard let plan = guidePlan, plan.segments.count > 1 else { return }
        let q = guidance.quality
        // Live qualityCoverage can skip Astra segments that are already satisfied.
        if q.qualityCoverage >= CaptureCompletionConfig.qualityCoverageReady {
            guidedSegmentIndex = plan.segments.count - 1
            return
        }
        let coverageDriven = Int(q.qualityCoverage * Double(plan.segments.count))
        let elapsed = Date().timeIntervalSince(startedAt)
        let timeDriven = Int(elapsed / 25.0)
        let expected = min(max(coverageDriven, timeDriven), plan.segments.count - 1)
        if expected > guidedSegmentIndex {
            guidedSegmentIndex = expected
        }
    }

    func configure(mockMode: Bool) {
        guidance.mockMode = mockMode
        useMockCamera = mockMode || !ARWorldTrackingConfiguration.isSupported
        CaptureSessionStore.pruneStaleSessions()
        configureGeneration += 1
        didStartLiveSession = false
        hasReceivedFrame = false

        if useMockCamera {
            cameraPresentation = .mock
            startMockTicks()
            arSession.pause()
            start()
        } else {
            mockTimer?.cancel()
            // Mount ARView first; `onARViewReady` starts the session once it has a window.
            cameraPresentation = .live
            let generation = configureGeneration
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard generation == configureGeneration, !didStartLiveSession else { return }
                onARViewReady()
            }
        }
    }

    /// Called from ARView when it is in the window with a real size.
    func onARViewReady() {
        guard cameraPresentation == .live, !useMockCamera, !didStartLiveSession else { return }
        didStartLiveSession = true
        startAR()
        start()
    }

    /// Re-run AR after returning to foreground (recovers black preview).
    func resumeCameraIfNeeded() {
        guard cameraPresentation == .live, !useMockCamera, !isStopping else { return }
        startAR()
    }

    func start() {
        lastSummary = nil
        startedAt = Date()
        guidance.start()
        framePipeline.start(mockMode: useMockCamera)
        guidance.isRecording = framePipeline.isRecording

        if !useMockCamera,
           CaptureDeviceCapabilities.supportsLiDARMeshReconstruction,
           let sessionId = framePipeline.activeSessionId {
            texturedMeshCapture.start(sessionId: sessionId)
        } else {
            texturedMeshCapture.reset()
        }
    }

    func cancelCapture() {
        mockTimer?.cancel()
        mockTimer = nil
        framePipeline.cancel()
        texturedMeshCapture.reset()
        guidance.cancelSession()
        guidance.isRecording = false
        arSession.pause()
    }

    func stop(finishedBy: CaptureFinishedBy = .manualEarlyFinish) async {
        guard !isStopping else { return }
        isStopping = true
        mockTimer?.cancel()
        mockTimer = nil
        arSession.pause()

        if useMockCamera {
            lastSummary = framePipeline.mockSummary(
                quality: guidance.quality,
                startedAt: startedAt,
                endedAt: Date()
            )
        } else if var summary = await framePipeline.finish(finishedBy: finishedBy) {
            if CaptureDeviceCapabilities.supportsLiDARMeshReconstruction {
                isReconstructingTexturedMesh = true
                summary = await enrichWithTexturedMesh(summary)
                isReconstructingTexturedMesh = false
            }
            lastSummary = summary
        } else {
            lastSummary = framePipeline.mockSummary(
                quality: guidance.quality,
                startedAt: startedAt,
                endedAt: Date()
            )
        }
        texturedMeshCapture.reset()
        guidance.isRecording = false
        isStopping = false
    }

    /// Called synchronously from ARSessionDelegate — do not dispatch before this returns.
    func ingestFrame(_ frame: ARFrame) {
        if !hasReceivedFrame {
            hasReceivedFrame = true
        }
        if CaptureDeviceCapabilities.supportsLiDARMeshReconstruction {
            texturedMeshCapture.ingest(frame: frame)
        }
        framePipeline.ingest(frame: frame)
    }

    private func enrichWithTexturedMesh(_ summary: CaptureSessionSummary) async -> CaptureSessionSummary {
        let meshSnapshots = texturedMeshCapture.snapshotMeshAnchors()
        let keyframes = texturedMeshCapture.snapshotKeyframes()
        let peakMemory = texturedMeshCapture.peakMemoryEstimateMB()

        guard !meshSnapshots.isEmpty, !keyframes.isEmpty else {
            return summary
        }

        return await Task.detached(priority: .userInitiated) {
            do {
                let output = try TexturedMeshReconstruction.reconstruct(
                    sessionId: summary.sessionId,
                    meshSnapshots: meshSnapshots,
                    keyframes: keyframes,
                    peakMemoryEstimateMB: peakMemory
                )
                var updated = summary
                updated.texturedSpaceURL = output.usdzURL
                updated.texturedMeshReport = output.report
                return updated
            } catch {
                return summary
            }
        }.value
    }

    private func startMockTicks() {
        mockTimer?.cancel()
        mockTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.framePipeline.ingestMockTick() }
    }

    private func startAR() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if type(of: config).supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.environmentTexturing = .automatic
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
}

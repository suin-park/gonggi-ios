import ARKit
import SwiftUI

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var useMockCamera = true
    @Published private(set) var lastSummary: CaptureSessionSummary?
    @Published private(set) var isStopping = false
    @Published private(set) var isReconstructingTexturedMesh = false

    let guidance = CaptureGuidanceEngine()
    let arSession = ARSession()
    let framePipeline = CaptureFramePipeline()

    private let texturedMeshCapture = TexturedMeshCaptureService()
    private var mockTimer: AnyCancellable?
    private var guidanceCancellable: AnyCancellable?
    private var startedAt = Date()

    init() {
        guidanceCancellable = guidance.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        framePipeline.onQualityUpdate = { [weak self] quality, message in
            Task { @MainActor in
                self?.guidance.applySnapshot(quality: quality, message: message)
            }
        }
    }

    func configure(mockMode: Bool) {
        guidance.mockMode = mockMode
        useMockCamera = mockMode || !ARWorldTrackingConfiguration.isSupported
        CaptureSessionStore.pruneStaleSessions()
        if useMockCamera {
            startMockTicks()
            arSession.pause()
        } else {
            mockTimer?.cancel()
            startAR()
        }
        start()
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

    func stop() async {
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
        } else if var summary = await framePipeline.finish() {
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

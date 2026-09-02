import ARKit
import Combine
import SwiftUI

@MainActor
final class Quick360ViewModel: ObservableObject {
    @Published private(set) var useMockCamera = true
    @Published private(set) var uiState = Quick360CaptureUIState.initial
    @Published private(set) var lastSummary: Quick360SessionSummary?
    @Published private(set) var isStopping = false
    @Published private(set) var isStitching = false

    let arSession = ARSession()
    private let engine: Quick360CaptureEngine
    private var mockTimer: AnyCancellable?
    private var mockStartedAt = Date()

    init(mockMode: Bool = true) {
        engine = Quick360CaptureEngine(mockMode: mockMode)
        useMockCamera = mockMode
    }

    func configure(mockMode: Bool) {
        useMockCamera = mockMode || !ARWorldTrackingConfiguration.isSupported
        if useMockCamera {
            arSession.pause()
        } else {
            startAR()
        }
        start()
    }

    func start() {
        lastSummary = nil
        let sessionId = UUID().uuidString
        let captureId = CaptureIdRegistry.nextCaptureId()
        engine.start(sessionId: sessionId, captureId: captureId)
        uiState = engine.uiState
        mockStartedAt = Date()

        if useMockCamera {
            startMockTicks()
        }
    }

    func cancelCapture() {
        mockTimer?.cancel()
        mockTimer = nil
        arSession.pause()
    }

    func ingestFrame(_ frame: ARFrame) {
        engine.ingest(frame: frame)
        uiState = engine.uiState
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        mockTimer?.cancel()
        arSession.pause()

        isStitching = true
        let result: Quick360Reconstruction.Result?
        do {
            result = try await Quick360Reconstruction.reconstruct(engine: engine, mockMode: useMockCamera)
        } catch {
            result = nil
        }
        isStitching = false

        let endedAt = Date()
        lastSummary = Quick360SessionSummary(
            id: UUID(),
            sessionId: engine.sessionId,
            captureId: engine.captureId,
            startedAt: engine.startedAt,
            endedAt: endedAt,
            progressPercent: engine.uiState.progressPercent,
            panoramaURL: result?.panoramaURL,
            coverageMaskURL: result?.coverageMaskURL,
            metadataURL: result?.metadataURL,
            report: result?.report,
            suggestedName: "Quick 360 \(formattedDate(endedAt))"
        )
        isStopping = false
    }

    private func startAR() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            // Do not enable depth for Quick 360 — LiDAR mesh not used
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func startMockTicks() {
        mockTimer?.cancel()
        mockTimer = Timer.publish(every: 0.4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.mockStartedAt)
                self.engine.ingestMockTick(elapsed: elapsed)
                self.uiState = self.engine.uiState
            }
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }
}

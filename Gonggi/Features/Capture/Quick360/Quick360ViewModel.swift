import ARKit
import AVFoundation
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
    let engine: Quick360CaptureEngine
    private var mockTimer: AnyCancellable?
    private var mockStartedAt = Date()
    private var didRunSession = false
    private var arViewReady = false

    init(mockMode: Bool = true) {
        Quick360Log.stage("Quick360 init start")
        engine = Quick360CaptureEngine(mockMode: mockMode)
        useMockCamera = mockMode
        Quick360Log.stage("Quick360 init done mockMode=\(mockMode)")
    }

    func configure(mockMode: Bool) {
        Quick360Log.stage("configure start mockMode=\(mockMode)")
        let permission = AVCaptureDevice.authorizationStatus(for: .video)
        Quick360Log.stage("camera permission = \(Self.permissionLabel(permission))")

        useMockCamera = mockMode || !ARWorldTrackingConfiguration.isSupported
        Quick360Log.stage(
            "useMockCamera=\(useMockCamera) worldTrackingSupported=\(ARWorldTrackingConfiguration.isSupported)"
        )

        if useMockCamera {
            arSession.pause()
            start()
        } else {
            // Do NOT call arSession.run here — wait until ARView is created with
            // automaticallyConfigureSession=false and has taken ownership of the session.
            start()
            requestCameraIfNeeded()
        }
        Quick360Log.stage("configure end")
    }

    /// Called once from Quick360ARViewRepresentable after ARView owns the session.
    func onARViewReady() {
        Quick360Log.stage("onARViewReady")
        arViewReady = true
        guard !useMockCamera else { return }
        runSessionIfNeeded()
    }

    func start() {
        lastSummary = nil
        didRunSession = false
        let sessionId = UUID().uuidString
        let captureId = CaptureIdRegistry.nextCaptureId()
        engine.start(sessionId: sessionId, captureId: captureId)
        uiState = engine.uiState
        mockStartedAt = Date()
        Quick360Log.stage("engine start sessionId=\(sessionId)")

        if useMockCamera {
            startMockTicks()
        } else if arViewReady {
            runSessionIfNeeded()
        }
    }

    func cancelCapture() {
        mockTimer?.cancel()
        mockTimer = nil
        didRunSession = false
        arSession.pause()
        Quick360Log.stage("cancelCapture")
    }

    func ingestPayload(_ payload: Quick360FramePayload) {
        engine.ingest(payload: payload)
        uiState = engine.uiState
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        mockTimer?.cancel()
        arSession.pause()
        didRunSession = false

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

    private func runSessionIfNeeded() {
        guard !didRunSession else {
            Quick360Log.stage("session run skipped (already running)")
            return
        }
        let config = Quick360ARConfiguration.makeWorldTracking()
        Quick360Log.stage(
            "configuration created nonLiDARSafe=\(Quick360ARConfiguration.isNonLiDARSafe(config))"
        )
        Quick360Log.stage("session run start")
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        didRunSession = true
        Quick360Log.stage("session run success")
    }

    private func requestCameraIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else { return }
        Quick360Log.stage("requesting camera access")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                Quick360Log.stage("camera access granted=\(granted)")
            }
        }
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

    private static func permissionLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}

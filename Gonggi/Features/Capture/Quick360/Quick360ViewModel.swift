import ARKit
import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class Quick360ViewModel: ObservableObject {
    @Published private(set) var useMockCamera = true
    @Published private(set) var uiState = Quick360CaptureUIState.initial
    @Published private(set) var lastSummary: Quick360SessionSummary?
    @Published private(set) var isStopping = false
    @Published private(set) var isStitching = false
    @Published private(set) var spherePreview: UIImage?
    @Published private(set) var floorPreview: UIImage?
    @Published private(set) var cameraSourcePreview: UIImage?
    @Published private(set) var brushDebug = Quick360BrushDebugState()
    @Published var showBrushDebug = Quick360Config.showBrushCoordinateDebug
    @Published private(set) var splitDebugSettings = Quick360SplitDebugSettings.default

    let arSession = ARSession()
    let engine: Quick360CaptureEngine
    private var mockTimer: AnyCancellable?
    private var previewTimer: AnyCancellable?
    private var mockStartedAt = Date()
    private var didRunSession = false
    private var arViewReady = false

    var isSplitDebugMode: Bool { Quick360Config.splitDebugCaptureMode }

    init(mockMode: Bool = true) {
        Quick360Log.stage("Quick360 init start")
        engine = Quick360CaptureEngine(mockMode: mockMode)
        useMockCamera = mockMode
        if Quick360Config.splitDebugCaptureMode {
            engine.updateSplitDebugSettings { settings in
                settings.enabled = true
                settings.showFloorRenderer = false
                settings.singleFrameMode = true
                settings.paintEnabled = true
            }
            splitDebugSettings = engine.splitDebugSettings
        }
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
            prepareSession()
        } else {
            prepareSession()
            requestCameraIfNeeded()
        }
        startPreviewTicks()
        Quick360Log.stage("configure end")
    }

    func onARViewReady() {
        Quick360Log.stage("onARViewReady")
        arViewReady = true
        guard !useMockCamera else { return }
        runSessionIfNeeded()
    }

    /// Reset session to align-front phase (does not auto-begin capture).
    func prepareSession() {
        lastSummary = nil
        didRunSession = false
        let sessionId = UUID().uuidString
        let captureId = CaptureIdRegistry.nextCaptureId()
        engine.start(sessionId: sessionId, captureId: captureId)
        uiState = engine.uiState
        mockStartedAt = Date()
        spherePreview = nil
        floorPreview = nil
        Quick360Log.stage("engine prepare sessionId=\(sessionId)")

        if useMockCamera {
            startMockTicks()
        } else if arViewReady {
            runSessionIfNeeded()
        }
    }

    /// Compatibility alias used by summary retry.
    func start() {
        prepareSession()
    }

    func beginCapture() {
        Quick360Log.stage("beginCapture")
        engine.beginCapture()
        uiState = engine.uiState
        mockStartedAt = Date()
    }

    func cancelCapture() {
        mockTimer?.cancel()
        mockTimer = nil
        previewTimer?.cancel()
        previewTimer = nil
        didRunSession = false
        arSession.pause()
        Quick360Log.stage("cancelCapture")
    }

    func ingestPayload(_ payload: Quick360FramePayload) {
        if engine.splitDebugSettings.frozen { return }
        engine.ingest(payload: payload)
        uiState = engine.uiState
        brushDebug = engine.brushDebug
        let snap = engine.debugPreviewSnapshot()
        if let cam = snap.cameraSource {
            cameraSourcePreview = cam
        }
        if let sphere = snap.sphere {
            spherePreview = sphere
        }
    }

    func toggleFreeze() {
        engine.updateSplitDebugSettings { $0.frozen.toggle() }
        splitDebugSettings = engine.splitDebugSettings
        Quick360Log.stage("splitDebug freeze=\(splitDebugSettings.frozen)")
    }

    func togglePaintEnabled() {
        engine.updateSplitDebugSettings { $0.paintEnabled.toggle() }
        splitDebugSettings = engine.splitDebugSettings
        Quick360Log.stage("splitDebug paint=\(splitDebugSettings.paintEnabled)")
    }

    func toggleSingleFrameMode() {
        engine.updateSplitDebugSettings { settings in
            settings.singleFrameMode.toggle()
            if settings.singleFrameMode {
                // Leave continuous; next Paint 1 / start queues a frame.
            }
        }
        splitDebugSettings = engine.splitDebugSettings
        Quick360Log.stage("splitDebug singleFrame=\(splitDebugSettings.singleFrameMode)")
    }

    func requestSingleFramePaint() {
        engine.requestSingleFramePaint()
        Quick360Log.stage("splitDebug requestSingleFramePaint")
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
            floorTextureURL: result?.floorTextureURL,
            report: result?.report,
            suggestedName: "공간 \(formattedDate(endedAt))"
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
            "configuration created nonLiDARSafe=\(Quick360ARConfiguration.isNonLiDARSafe(config)) plane=\(config.planeDetection.contains(.horizontal))"
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

    private func startPreviewTicks() {
        previewTimer?.cancel()
        previewTimer = Timer.publish(every: 0.35, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let images = self.engine.previewImages()
                self.spherePreview = images.sphere
                self.floorPreview = images.floor
                let snap = self.engine.debugPreviewSnapshot()
                if let cam = snap.cameraSource {
                    self.cameraSourcePreview = cam
                }
                self.brushDebug = snap.brushDebug
                self.splitDebugSettings = self.engine.splitDebugSettings
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

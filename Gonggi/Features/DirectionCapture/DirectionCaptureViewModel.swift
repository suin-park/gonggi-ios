import Combine
import Foundation
import SwiftUI

@MainActor
final class DirectionCaptureViewModel: ObservableObject {
    let engine = DirectionCaptureEngine()

    @Published var phase: DirectionCapturePhase = .idle
    @Published var progressText: String = "0 / 10"
    @Published var guideText: String = ""
    @Published var currentTarget: DirectionName?
    @Published var completed: Set<DirectionName> = []
    @Published var result: DirectionCaptureResult?
    @Published var didComplete = false
    @Published var useMockCamera = false
    @Published var yawDisplay: String = "yaw 0°"
    @Published var pitchDisplay: String = "pitch 0°"
    @Published var isPhotoPending = false
    @Published var pendingDirection: DirectionName?

    private var configured = false

    func configure(mockMode: Bool) {
        guard !configured else { return }
        configured = true
        useMockCamera = mockMode
        engine.onUIUpdate = { [weak self] in
            Task { @MainActor in self?.syncFromEngine() }
        }
        engine.onCaptured = { _ in
            GonggiHaptics.success()
        }
        engine.onCompleted = { [weak self] result in
            Task { @MainActor in
                self?.result = result
                self?.didComplete = true
                self?.syncFromEngine()
                GonggiHaptics.success()
            }
        }
        do {
            try engine.prepareCamera(mockMode: mockMode)
            engine.startSession()
            syncFromEngine()
        } catch {
            phase = .failed("카메라를 열 수 없습니다")
        }
    }

    func startCapture() {
        result = nil
        didComplete = false
        GonggiHaptics.medium()
        engine.beginCapture()
        syncFromEngine()
    }

    func retake() {
        result = nil
        didComplete = false
        GonggiHaptics.medium()
        engine.retake()
        syncFromEngine()
    }

    func close() {
        engine.stopSession()
    }

    private func syncFromEngine() {
        phase = engine.phase
        progressText = engine.progressText
        guideText = engine.guideText
        currentTarget = engine.currentTarget
        completed = Set(engine.captured.keys)
        isPhotoPending = engine.isPhotoPending
        pendingDirection = engine.pendingDirection
        let m = engine.lastMotion
        yawDisplay = String(format: "yaw %.0f°", m.yaw0to360)
        pitchDisplay = String(format: "elev %.0f°", m.elevationDeg)
    }
}

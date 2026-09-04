import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class PanoramaCaptureViewModel: ObservableObject {
    @Published var phase: PanoramaCapturePhase = .idle
    @Published var feedback: PanoramaGuideFeedback = .idle
    @Published var direction: PanoramaScanDirection = .right
    @Published var acceptedStripCount: Int = 0
    @Published var yawSpanDeg: Float = 0
    @Published var progress: Double = 0
    @Published var result: PanoramaCaptureResult?
    @Published var errorMessage: String?
    @Published var cameraAuthorized = false
    @Published var useMockCamera = false

    let engine = PanoramaCaptureEngine()
    private(set) var sessionId: String = ""
    private(set) var captureId: String = ""

    init() {
        engine.onUIUpdate = { [weak self] in
            Task { @MainActor in
                self?.syncFromEngine()
            }
        }
    }

    func configure(mockMode: Bool) {
        useMockCamera = mockMode
        sessionId = UUID().uuidString
        captureId = CaptureIdRegistry.nextCaptureId()
        if mockMode {
            cameraAuthorized = true
            phase = .ready
            feedback = .idle
            return
        }
        Task { await requestCameraAndStart() }
    }

    func requestCameraAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            cameraAuthorized = false
            errorMessage = PanoramaCaptureError.notAuthorized.localizedDescription
            phase = .failed(errorMessage ?? "")
            return
        }
        guard cameraAuthorized else { return }
        do {
            try engine.prepareCamera()
            engine.startSession()
            syncFromEngine()
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed(error.localizedDescription)
        }
    }

    func toggleCapture() {
        switch phase {
        case .ready, .idle:
            startCapture()
        case .capturing:
            Task { await finishCapture() }
        default:
            break
        }
    }

    func startCapture() {
        result = nil
        errorMessage = nil
        if useMockCamera {
            engine.beginMockCapture()
            Task {
                await runMockSweep()
                if engine.acceptedStripCount >= 8 {
                    await finishCapture()
                }
            }
        } else {
            engine.beginCapture()
        }
        syncFromEngine()
        GonggiHaptics.medium()
    }

    func finishCapture() async {
        do {
            let out = try await engine.finishCapture(sessionId: sessionId, captureId: captureId)
            result = out
            // Keep user-facing preview even if engine notify races.
            phase = .preview
            feedback = .enough
            acceptedStripCount = out.report.acceptedStripCount
            yawSpanDeg = out.report.yawSpanDeg
            progress = 1
            GonggiHaptics.success()
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed(error.localizedDescription)
            GonggiHaptics.error()
            syncFromEngine()
        }
    }

    func retake() {
        result = nil
        errorMessage = nil
        engine.cancelCapture()
        phase = .ready
        feedback = .idle
        acceptedStripCount = 0
        yawSpanDeg = 0
        progress = 0
        GonggiHaptics.light()
    }

    func close() {
        engine.stopSession()
        engine.cancelCapture()
    }

    var enoughForFinish: Bool {
        yawSpanDeg >= PanoramaCaptureConfig.enoughYawSpanDeg && acceptedStripCount >= 8
    }

    private func syncFromEngine() {
        phase = engine.phase
        feedback = engine.feedback
        direction = engine.direction
        acceptedStripCount = engine.acceptedStripCount
        yawSpanDeg = engine.yawSpanDeg
        progress = min(1, Double(yawSpanDeg / PanoramaCaptureConfig.autoEnoughYawSpanDeg))
    }

    private func runMockSweep() async {
        let w = 320
        let h = 480
        for i in 0..<80 {
            guard engine.phase == .capturing else { break }
            let yaw = Float(i) * 1.1
            var rgba = [UInt8](repeating: 40, count: w * h * 4)
            // Vertical feature that shifts with yaw for a visible panorama.
            let featureX = w / 2
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let band = abs(x - featureX) < 3 ? 220 : UInt8(60 + (x + Int(yaw)) % 40)
                    rgba[o] = band
                    rgba[o + 1] = UInt8(min(255, Int(band) + y % 20))
                    rgba[o + 2] = UInt8(80 + (y / 8) % 100)
                    rgba[o + 3] = 255
                }
            }
            engine.ingestMockFrame(
                rgba: rgba, width: w, height: h, yawDeg: yaw,
                uprightFrameWidth: w
            )
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

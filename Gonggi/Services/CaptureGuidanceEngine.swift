import ARKit
import Foundation
import simd

/// UI-facing capture guidance state (updated from `CaptureFramePipeline`).
@MainActor
final class CaptureGuidanceEngine: ObservableObject {
    @Published private(set) var quality = CaptureQualityState.zero
    @Published private(set) var coachMessage: String = "천천히 이동하세요"
    @Published var isFlashOn = false
    @Published var showGuideOverlay = true
    @Published var isRecording = false

    var mockMode: Bool = true

    func start() {
        quality = CaptureQualityState.zero
        coachMessage = "천천히 이동하세요"
    }

    func applySnapshot(quality: CaptureQualityState, message: String) {
        self.quality = quality
        self.coachMessage = message
    }

    func cancelSession() {
        isRecording = false
    }

    func toggleFlash() { isFlashOn.toggle() }
    func toggleGuide() { showGuideOverlay.toggle() }

    /// Legacy scalar ingest for unit-style testing.
    func ingestARFrame(
        trackingQuality: Float,
        motionSpeed: Float,
        angularVelocity: Float,
        meshVertexCount: Int
    ) {
        var q = quality
        q.trackingQuality = Double(trackingQuality)
        q.motionSpeed = Double(motionSpeed)
        q.angularVelocity = Double(angularVelocity)
        q.blurScore = max(0, 1 - Double(motionSpeed) * 1.4)
        q.overlapScore = min(1, Double(meshVertexCount) / 50_000)
        quality = q
    }
}

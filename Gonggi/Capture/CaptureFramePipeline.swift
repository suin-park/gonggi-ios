import ARKit
import Foundation
import QuartzCore

/// Processes AR frames on the session delegate queue (ARFrame is only valid during callback).
final class CaptureFramePipeline {
    var mockMode: Bool = true
    var onQualityUpdate: ((CaptureQualityState, String) -> Void)?

    let coverageSpatialIndex = CoverageSpatialIndex()

    private var sessionController: CaptureSessionController?
    private var guidanceRules = GuidanceRuleEngine()
    private var mockTick: UInt = 0
    private var mockAreas: [AreaCoverage] = []

    func start(mockMode: Bool) {
        self.mockMode = mockMode
        mockTick = 0
        guidanceRules.reset()
        mockAreas = []

        if mockMode {
            mockAreas = ["floor", "wall-n", "wall-s", "corner-ne", "ceiling", "sofa-zone", "shelf"]
                .map { AreaCoverage(id: $0) }
            coverageSpatialIndex.reset()
            sessionController = nil
        } else {
            let controller = CaptureSessionController(coverageSpatialIndex: coverageSpatialIndex)
            sessionController = controller
            try? controller.start()
        }
    }

    func cancel() {
        sessionController?.cancel()
        sessionController = nil
        coverageSpatialIndex.reset()
    }

    func finish() async -> CaptureSessionSummary? {
        if let controller = sessionController {
            return try? await controller.finish()
        }
        return nil
    }

    /// Must be called synchronously from `ARSessionDelegate`.
    func ingest(frame: ARFrame) {
        guard !mockMode else { return }
        sessionController?.ingest(frame: frame)
        publishUI(trackingLimited: frame.camera.trackingState != .normal)
    }

    func ingestMockTick() {
        guard mockMode else { return }
        mockTick &+= 1
        let t = Double(mockTick) * 0.04
        var q = CaptureQualityState.zero
        q.motionSpeed = 0.25 + 0.35 * abs(sin(t * 0.7))
        q.angularVelocity = 0.2 + 0.25 * abs(cos(t * 0.5))
        q.blurScore = max(0.3, 1 - q.motionSpeed * 1.2)
        q.trackingQuality = 0.92
        q.exposureScore = 0.88
        q.lowTextureScore = 0.3 + 0.1 * sin(t)
        q.overlapScore = min(1, 0.35 + t * 0.018)
        q.parallaxScore = min(1, 0.25 + t * 0.022)
        mockAreas = mockAreas.map { area in
            var a = area
            a.observationCount += 1
            a.uniqueViewCount += Int.random(in: 0...1)
            a.viewCount = a.uniqueViewCount
            a.angleDiversity = min(1, a.angleDiversity + 0.05)
            a.coverageScore = min(1, a.coverageScore + 0.04)
            a.state = a.coverageScore < 0.38 ? .insufficient : .acceptable
            return a
        }
        q.areas = mockAreas
        q.overallCoverage = min(0.92, 0.68 + t * 0.008)
        let msg = guidanceRules.evaluate(quality: q, trackingLimited: false)
        DispatchQueue.main.async { [weak self] in
            self?.onQualityUpdate?(q, msg)
        }
    }

    func mockSummary(quality: CaptureQualityState, startedAt: Date, endedAt: Date) -> CaptureSessionSummary {
        let revisit = quality.areas.filter { $0.state == .insufficient || $0.state == .unseen }.count
        return CaptureSessionSummary(
            startedAt: startedAt,
            endedAt: endedAt,
            quality: quality,
            fastMotionSegments: 3,
            lowTextureWarnings: quality.lowTextureScore > 0.5 ? 2 : 0,
            areasNeedingRevisit: max(revisit, 2),
            suggestedName: "새 공간 \(DateFormatter.captureName.string(from: endedAt))",
            avgAngularVelocity: quality.angularVelocity,
            maxAngularVelocity: quality.angularVelocity * 1.4,
            revisitScore: 0.4,
            angleDiversityScore: 0.5
        )
    }

    var isRecording: Bool { sessionController != nil }

    var activeSessionId: String? { sessionController?.sessionId }

    private var lastUIUpdate: TimeInterval = 0

    private func publishUI(trackingLimited: Bool) {
        let now = CACurrentMediaTime()
        guard now - lastUIUpdate >= 0.1 else { return }
        lastUIUpdate = now
        guard let controller = sessionController else { return }
        let q = controller.currentQuality(trackingLimited: trackingLimited)
        let msg = controller.currentCoachMessage(trackingLimited: trackingLimited)
        DispatchQueue.main.async { [weak self] in
            self?.onQualityUpdate?(q, msg)
        }
    }
}

private extension DateFormatter {
    static let captureName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()
}

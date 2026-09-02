import ARKit
import Foundation

/// Orchestrates video recording, telemetry, coverage, and manifest for one capture session.
final class CaptureSessionController {
    let sessionId: String
    let captureId: String
    private let videoRecorder = ARVideoRecorder()
    private let coverageSpatialIndex: CoverageSpatialIndex
    private var telemetry = CaptureTelemetryCollector()
    private var coverage = CoverageModelV1()
    private var guidanceRules = GuidanceRuleEngine()
    private var startedAt = Date()
    private var sessionStartTimestamp: TimeInterval = 0
    private(set) var isActive = false
    private var videoURL: URL?
    private var manifestURL: URL?

    init(
        captureId: String = CaptureIdRegistry.nextCaptureId(),
        sessionId: String? = nil,
        coverageSpatialIndex: CoverageSpatialIndex
    ) {
        self.captureId = captureId
        self.sessionId = sessionId ?? captureId
        self.coverageSpatialIndex = coverageSpatialIndex
    }

    func start() throws {
        startedAt = Date()
        sessionStartTimestamp = 0
        telemetry.reset(startTime: 0)
        coverage = CoverageModelV1()
        coverageSpatialIndex.reset()
        guidanceRules.reset()
        let url = try CaptureSessionStore.videoURL(sessionId: sessionId)
        videoURL = url
        manifestURL = try CaptureSessionStore.manifestURL(sessionId: sessionId)
        try videoRecorder.startRecording(to: url, prefer4K: true)
        isActive = true
    }

    func ingest(frame: ARFrame) {
        guard isActive else { return }
        if sessionStartTimestamp == 0 {
            sessionStartTimestamp = frame.timestamp
            telemetry.reset(startTime: frame.timestamp)
        }

        videoRecorder.append(frame: frame)
        telemetry.ingest(frame: frame)

        let motionQuality = telemetry.motionQuality
        coverage.observe(cameraTransform: frame.camera.transform, motionQuality: motionQuality, at: Date())
        coverageSpatialIndex.replace(cells: coverage.snapshotCells())

        let trackingLimited = frame.camera.trackingState != .normal
        _ = guidanceRules.evaluate(quality: qualityState(trackingLimited: trackingLimited), trackingLimited: trackingLimited)
    }

    func currentQuality(trackingLimited: Bool = false) -> CaptureQualityState {
        qualityState(trackingLimited: trackingLimited)
    }

    func currentCoachMessage(trackingLimited: Bool = false) -> String {
        guidanceRules.evaluate(quality: qualityState(trackingLimited: trackingLimited), trackingLimited: trackingLimited)
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        videoRecorder.cancel()
        CaptureSessionStore.deleteSession(sessionId: sessionId)
        videoURL = nil
        manifestURL = nil
    }

    func finish() async throws -> CaptureSessionSummary {
        guard isActive else {
            throw SessionError.notActive
        }
        isActive = false
        let endedAt = Date()

        var videoResult: ARVideoRecorder.Result?
        do {
            videoResult = try await videoRecorder.finish()
        } catch {
            CaptureSessionStore.deleteSession(sessionId: sessionId)
            throw error
        }

        let durationSec = endedAt.timeIntervalSince(startedAt)
        let manifest = CaptureManifestBuilder.build(
            captureId: captureId,
            sessionId: sessionId,
            startedAt: startedAt,
            durationSec: durationSec,
            video: videoResult,
            coverage: coverage,
            telemetry: telemetry,
            mockMode: false
        )

        guard let manifestURL else { throw SessionError.noManifestPath }
        do {
            try CaptureManifestBuilder.write(manifest, to: manifestURL)
        } catch {
            CaptureSessionStore.deleteSession(sessionId: sessionId)
            throw error
        }

        let counts = coverage.countsByState()
        let revisitAreas = coverage.areas.filter { $0.state == .insufficient || $0.state == .unseen }.count
        let lowTextureWarnings = telemetry.samples.filter { ($0.brightness ?? 1) < 0.25 }.count

        return CaptureSessionSummary(
            id: UUID(),
            captureId: captureId,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            quality: qualityState(trackingLimited: false),
            fastMotionSegments: telemetry.fastMotionSegmentCount,
            lowTextureWarnings: lowTextureWarnings,
            areasNeedingRevisit: revisitAreas,
            suggestedName: "새 공간 \(DateFormatter.captureName.string(from: endedAt))",
            videoURL: videoResult?.url,
            manifestURL: manifestURL,
            videoByteSize: videoResult?.byteSize,
            videoWidth: videoResult?.width,
            videoHeight: videoResult?.height,
            videoFPS: videoResult?.fps,
            avgAngularVelocity: telemetry.avgAngularVelocity,
            maxAngularVelocity: telemetry.maxAngularVelocity,
            trackingLimitedSec: telemetry.trackingLimitedDurationSec,
            goodAreaCount: counts.good,
            insufficientAreaCount: counts.insufficient,
            revisitScore: coverage.revisitScore,
            angleDiversityScore: coverage.angleDiversityScore
        )
    }

    // MARK: - Private

    private func qualityState(trackingLimited: Bool) -> CaptureQualityState {
        let areas = coverage.areas
        let overall = coverage.overallCoverage
        let lastSample = telemetry.samples.last
        return CaptureQualityState(
            overallCoverage: overall,
            motionSpeed: lastSample?.translationSpeedMps ?? telemetry.avgTranslationSpeed,
            angularVelocity: lastSample?.angularVelocityRadPerSec ?? telemetry.avgAngularVelocity,
            blurScore: telemetry.blurProxyMean,
            exposureScore: min(1, lastSample?.brightness ?? 0.85),
            trackingQuality: trackingLimited ? 0.35 : 0.95,
            lowTextureScore: estimateLowTexture(),
            overlapScore: min(1, Double(lastSample?.meshAnchorCount ?? 0) / 20.0),
            parallaxScore: min(1, coverage.angleDiversityScore),
            areas: areas
        )
    }

    private func estimateLowTexture() -> Double {
        let limited = telemetry.samples.filter { $0.trackingState.contains("insufficient_features") }.count
        guard !telemetry.samples.isEmpty else { return 0.2 }
        return min(1, Double(limited) / Double(telemetry.samples.count) * 2.0)
    }

    enum SessionError: LocalizedError {
        case notActive
        case noManifestPath

        var errorDescription: String? {
            switch self {
            case .notActive: return "Capture session not active"
            case .noManifestPath: return "Manifest path unavailable"
            }
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

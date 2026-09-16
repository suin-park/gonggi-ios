import Foundation

/// Thread-safe JPEG / AR-callback metrics for Spatial Capture packages.
final class SpatialCaptureRuntimeTelemetry: @unchecked Sendable {
    private let lock = NSLock()

    private(set) var receivedARFrameCount = 0
    private(set) var acceptedKeyframeCount = 0
    private(set) var rejectedKeyframeCount = 0
    private(set) var jpegSuccessCount = 0
    private(set) var jpegFailureCount = 0
    private(set) var jpegQueueDepth = 0
    private(set) var maxJPEGQueueDepth = 0
    private(set) var jpegEncodeMsSamples: [Double] = []
    private(set) var jpegWriteMsSamples: [Double] = []
    private(set) var captureCallbackMsSamples: [Double] = []
    private(set) var blurRejectedCount = 0
    private(set) var motionRejectedCount = 0
    private(set) var translationRejectedCount = 0
    private(set) var lowTextureRejectedCount = 0
    private(set) var jpegQueueFullRejectedCount = 0
    private(set) var trackingLimitedCount = 0
    private(set) var trackingNormalCount = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        receivedARFrameCount = 0
        acceptedKeyframeCount = 0
        rejectedKeyframeCount = 0
        jpegSuccessCount = 0
        jpegFailureCount = 0
        jpegQueueDepth = 0
        maxJPEGQueueDepth = 0
        jpegEncodeMsSamples = []
        jpegWriteMsSamples = []
        captureCallbackMsSamples = []
        blurRejectedCount = 0
        motionRejectedCount = 0
        translationRejectedCount = 0
        lowTextureRejectedCount = 0
        jpegQueueFullRejectedCount = 0
        trackingLimitedCount = 0
        trackingNormalCount = 0
    }

    func recordReceivedFrame(trackingNormal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        receivedARFrameCount += 1
        if trackingNormal {
            trackingNormalCount += 1
        } else {
            trackingLimitedCount += 1
        }
    }

    func recordCallbackDurationMs(_ ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        captureCallbackMsSamples.append(ms)
    }

    func updateQueueDepth(_ depth: Int) {
        lock.lock()
        defer { lock.unlock() }
        jpegQueueDepth = depth
        maxJPEGQueueDepth = max(maxJPEGQueueDepth, depth)
    }

    func recordReject(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        rejectedKeyframeCount += 1
        switch reason {
        case "blur":
            blurRejectedCount += 1
        case "motion_too_fast", "angular_too_fast":
            motionRejectedCount += 1
        case "translation_too_small":
            translationRejectedCount += 1
        case "low_texture":
            lowTextureRejectedCount += 1
        case "jpeg_queue_full":
            jpegQueueFullRejectedCount += 1
        default:
            break
        }
    }

    func recordJPEGSuccess(encodeMs: Double, writeMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        jpegSuccessCount += 1
        acceptedKeyframeCount += 1
        jpegEncodeMsSamples.append(encodeMs)
        jpegWriteMsSamples.append(writeMs)
    }

    func recordJPEGFailure() {
        lock.lock()
        defer { lock.unlock() }
        jpegFailureCount += 1
        rejectedKeyframeCount += 1
    }

    func snapshot(
        captureDurationSec: Double,
        totalTranslationDistanceM: Double,
        averageSharpness: Double?,
        averageParallax: Double?,
        observedCoverage: Double,
        packageBytes: Int?,
        averageJPEGBytes: Int?,
        averageTranslationBetweenKeyframesM: Double?
    ) -> SpatialCaptureTelemetryReport {
        lock.lock()
        defer { lock.unlock() }
        let trackingTotal = trackingNormalCount + trackingLimitedCount
        return SpatialCaptureTelemetryReport(
            captureDurationSec: captureDurationSec,
            receivedARFrameCount: receivedARFrameCount,
            acceptedKeyframeCount: acceptedKeyframeCount,
            rejectedKeyframeCount: rejectedKeyframeCount,
            JPEGSuccessCount: jpegSuccessCount,
            JPEGFailureCount: jpegFailureCount,
            averageJPEGSizeMB: averageJPEGBytes.map { Double($0) / 1_000_000.0 },
            capturePackageSizeMB: packageBytes.map { Double($0) / 1_000_000.0 },
            totalTranslationDistanceM: totalTranslationDistanceM,
            averageTranslationBetweenKeyframes: averageTranslationBetweenKeyframesM,
            trackingNormalRatio: trackingTotal > 0
                ? Double(trackingNormalCount) / Double(trackingTotal)
                : nil,
            trackingLimitedCount: trackingLimitedCount,
            blurRejectedCount: blurRejectedCount,
            motionRejectedCount: motionRejectedCount,
            translationRejectedCount: translationRejectedCount,
            lowTextureRejectedCount: lowTextureRejectedCount,
            jpegQueueFullRejectedCount: jpegQueueFullRejectedCount,
            averageSharpness: averageSharpness,
            averageParallax: averageParallax,
            coverage: observedCoverage,
            jpegEncodeAverageMs: Self.average(jpegEncodeMsSamples),
            jpegEncodeP95Ms: Self.percentile(jpegEncodeMsSamples, 0.95),
            jpegWriteAverageMs: Self.average(jpegWriteMsSamples),
            jpegWriteP95Ms: Self.percentile(jpegWriteMsSamples, 0.95),
            maxJPEGQueueDepth: maxJPEGQueueDepth,
            jpegQueueDepthAtFinish: jpegQueueDepth,
            ARCallbackAverageMs: Self.average(captureCallbackMsSamples),
            ARCallbackP95Ms: Self.percentile(captureCallbackMsSamples, 0.95),
            backpressurePolicy: "reject_when_pending_ge_\(SpatialCaptureConfig.jpegQueueMaxDepth)"
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }
}

struct SpatialCaptureTelemetryReport: Codable, Equatable, Sendable {
    var captureDurationSec: Double
    var receivedARFrameCount: Int
    var acceptedKeyframeCount: Int
    var rejectedKeyframeCount: Int
    var JPEGSuccessCount: Int
    var JPEGFailureCount: Int
    var averageJPEGSizeMB: Double?
    var capturePackageSizeMB: Double?
    var totalTranslationDistanceM: Double
    var averageTranslationBetweenKeyframes: Double?
    var trackingNormalRatio: Double?
    var trackingLimitedCount: Int
    var blurRejectedCount: Int
    var motionRejectedCount: Int
    var translationRejectedCount: Int
    var lowTextureRejectedCount: Int
    var jpegQueueFullRejectedCount: Int
    var averageSharpness: Double?
    var averageParallax: Double?
    var coverage: Double
    var jpegEncodeAverageMs: Double?
    var jpegEncodeP95Ms: Double?
    var jpegWriteAverageMs: Double?
    var jpegWriteP95Ms: Double?
    var maxJPEGQueueDepth: Int
    var jpegQueueDepthAtFinish: Int
    var ARCallbackAverageMs: Double?
    var ARCallbackP95Ms: Double?
    var backpressurePolicy: String
}

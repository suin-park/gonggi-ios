import Foundation
import simd
import QuartzCore

/// Frame-level live sphere brush accept / reject (coverage-hole triage).
enum Quick360LiveBrushRejectReason: String, CaseIterable, Sendable {
    case throttle
    case missingBrush = "missing_brush"
    case invalidProjection = "invalid_projection"
    case confidenceGate = "confidence_gate"
    case angularVelocity = "angular_velocity"
    case translation
    case fovOutside = "fov_outside"
    case paintDisabled = "paint_disabled"
    case singleFrameDone = "single_frame_done"
}

struct Quick360LiveBrushDecision: Equatable, Sendable {
    var accepted: Bool
    var rejectReason: Quick360LiveBrushRejectReason?
    var yawDeg: Float
    var pitchDeg: Float
    var angularSpeedDegPerSec: Float
    var note: String

    static func accepted(
        yawDeg: Float,
        pitchDeg: Float,
        angularSpeedDegPerSec: Float,
        note: String = ""
    ) -> Quick360LiveBrushDecision {
        Quick360LiveBrushDecision(
            accepted: true,
            rejectReason: nil,
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            angularSpeedDegPerSec: angularSpeedDegPerSec,
            note: note
        )
    }

    static func rejected(
        _ reason: Quick360LiveBrushRejectReason,
        yawDeg: Float,
        pitchDeg: Float,
        angularSpeedDegPerSec: Float,
        note: String = ""
    ) -> Quick360LiveBrushDecision {
        Quick360LiveBrushDecision(
            accepted: false,
            rejectReason: reason,
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            angularSpeedDegPerSec: angularSpeedDegPerSec,
            note: note
        )
    }
}

/// Running counters for coverage-hole reports (live brush only — not final stitch).
final class Quick360LiveBrushStats: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acceptedCount = 0
    private(set) var rejectedCounts: [Quick360LiveBrushRejectReason: Int] = [:]
    private(set) var firstFramePaintCount = 0
    private(set) var paintPixelSum = 0
    private(set) var paintMsSamples: [Double] = []
    private(set) var adaptiveIntervalSec: Double = Quick360Config.liveBrushMinIntervalSec

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        acceptedCount = 0
        rejectedCounts = [:]
        firstFramePaintCount = 0
        paintPixelSum = 0
        paintMsSamples = []
        adaptiveIntervalSec = Quick360Config.liveBrushMinIntervalSec
    }

    func record(_ decision: Quick360LiveBrushDecision, pixels: Int = 0, paintMs: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        if decision.accepted {
            acceptedCount += 1
            paintPixelSum += pixels
            if paintMs > 0 {
                paintMsSamples.append(paintMs)
                if paintMsSamples.count > 40 {
                    paintMsSamples.removeFirst(paintMsSamples.count - 40)
                }
            }
        } else if let reason = decision.rejectReason {
            rejectedCounts[reason, default: 0] += 1
        }
    }

    func recordFirstFramePaint() {
        lock.lock()
        defer { lock.unlock() }
        firstFramePaintCount += 1
    }

    func setAdaptiveInterval(_ sec: Double) {
        lock.lock()
        defer { lock.unlock() }
        adaptiveIntervalSec = sec
    }

    var averagePaintMs: Double {
        lock.lock()
        defer { lock.unlock() }
        guard !paintMsSamples.isEmpty else { return 0 }
        return paintMsSamples.reduce(0, +) / Double(paintMsSamples.count)
    }

    func summaryLine() -> String {
        lock.lock()
        defer { lock.unlock() }
        let rejects = Quick360LiveBrushRejectReason.allCases
            .compactMap { r -> String? in
                let n = rejectedCounts[r] ?? 0
                return n > 0 ? "\(r.rawValue)=\(n)" : nil
            }
            .joined(separator: " ")
        let avgMs = paintMsSamples.isEmpty
            ? 0
            : paintMsSamples.reduce(0, +) / Double(paintMsSamples.count)
        return String(
            format: "liveBrushStats accept=%d first=%d pxSum=%d avgPaintMs=%.1f interval=%.2fs rejects:[%@]",
            acceptedCount,
            firstFramePaintCount,
            paintPixelSum,
            avgMs,
            adaptiveIntervalSec,
            rejects.isEmpty ? "none" : rejects
        )
    }
}

enum Quick360LiveBrushPerf {
    /// Estimated live atlas footprint (RGBA + confidence + firstSeen).
    static func atlasMemoryBytes(width: Int, height: Int) -> Int {
        let pixels = width * height
        return pixels * 4 + pixels + pixels * MemoryLayout<Double>.size
    }

    static func logSnapshot(
        paintMs: Double,
        intervalSec: Double,
        atlasW: Int,
        atlasH: Int,
        brushW: Int,
        brushH: Int
    ) {
        let memMB = Double(atlasMemoryBytes(width: atlasW, height: atlasH)) / (1024 * 1024)
        Quick360Log.stage(
            String(
                format: "liveBrushPerf paintMs=%.1f interval=%.2fs(~%.1fHz) atlas=%dx%d(~%.2fMB) brush=%dx%d",
                paintMs,
                intervalSec,
                intervalSec > 0 ? 1 / intervalSec : 0,
                atlasW, atlasH,
                memMB,
                brushW, brushH
            )
        )
    }
}

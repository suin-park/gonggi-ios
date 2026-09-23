import CoreVideo
import Foundation
import UIKit
import simd

/// In-memory low-res thumbnail of the **continuityAnchor** camera image for REACQUIRE guidance.
/// Does **not** write a durable high-res duplicate to disk.
final class ContinuityAnchorThumbnailStore: @unchecked Sendable {
    private let lock = NSLock()
    private var jpegData: Data?
    private var anchorTimestamp: Double?
    private var reacquireSince: Double?
    private var lastSignedYawDeg: Double?
    private var lastProximity: Double = 0

    struct Snapshot: Equatable {
        var jpegData: Data?
        var visible: Bool
        var signedYawDeg: Double?
        /// 0…1 — higher means closer frustum/angular recovery toward continuityAnchor.
        var proximity: Double
        var title: String
        var guidance: String
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        jpegData = nil
        anchorTimestamp = nil
        reacquireSince = nil
        lastSignedYawDeg = nil
        lastProximity = 0
    }

    /// Call when continuityAnchor advances (recon KF or saved bridge obs) with the same ARFrame image.
    /// While REACQUIRE is active the stored target must stay frozen (do not chase live frames).
    func updateContinuityAnchorImage(pixelBuffer: CVPixelBuffer, timestamp: Double) {
        lock.lock()
        let frozen = reacquireSince != nil
        lock.unlock()
        if frozen { return }
        guard let data = Self.encodeThumbnailJPEG(pixelBuffer: pixelBuffer) else { return }
        lock.lock()
        // Re-check: REACQUIRE may have started while encoding.
        if reacquireSince != nil {
            lock.unlock()
            return
        }
        jpegData = data
        anchorTimestamp = timestamp
        lock.unlock()
    }

    func noteBridgeVerdict(_ verdict: CaptureBridgeVerdict?, at timestamp: Double) {
        lock.lock()
        defer { lock.unlock() }
        if verdict == .reacquire {
            if reacquireSince == nil { reacquireSince = timestamp }
        } else {
            reacquireSince = nil
        }
    }

    func updateLiveProximity(
        signedYawDeg: Double?,
        frustumOverlap: Double,
        at timestamp: Double,
        verdict: CaptureBridgeVerdict?,
        yawHintReliable: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }
        // Hide left/right arrows when yaw hint is unreliable (prefer no arrow over wrong direction).
        lastSignedYawDeg = yawHintReliable ? signedYawDeg : nil
        // Proximity: blend frustum toward reacquire floor and angular closeness.
        let yawAbs = abs(signedYawDeg ?? 90)
        let yawScore = max(0, 1 - yawAbs / CaptureBridgeConfig.unsupportedAngularJumpDeg)
        let frustScore = min(1, max(0, frustumOverlap))
        lastProximity = 0.55 * frustScore + 0.45 * yawScore
        if verdict == .reacquire {
            if reacquireSince == nil { reacquireSince = timestamp }
        } else if verdict != .bridgeRequired {
            reacquireSince = nil
        }
        _ = timestamp
    }

    func snapshot(now timestamp: Double) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = reacquireSince.map { timestamp - $0 } ?? 0
        let visible = jpegData != nil
            && reacquireSince != nil
            && elapsed >= CaptureBridgeConfig.reacquireThumbnailMinDurationSec
        return Snapshot(
            jpegData: visible ? jpegData : nil,
            visible: visible,
            signedYawDeg: visible ? lastSignedYawDeg : nil,
            proximity: lastProximity,
            title: "마지막 연결 화면",
            guidance: "이 장면이 다시 보이도록 천천히 움직여주세요"
        )
    }

    /// Thumbnail target must not change while REACQUIRE is ongoing (anchor image frozen).
    var frozenAnchorTimestamp: Double? {
        lock.lock()
        defer { lock.unlock() }
        return anchorTimestamp
    }

    private static func encodeThumbnailJPEG(pixelBuffer: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let maxEdge = CaptureBridgeConfig.reacquireThumbnailMaxEdgePx
        let scale = min(1, maxEdge / max(w, h))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        let ui = UIImage(cgImage: cg)
        return ui.jpegData(compressionQuality: 0.55)
    }
}

enum ContinuityYawHint {
    /// Signed shortest yaw from `from` → `to` (degrees). Positive = turn right (approx).
    /// Uses circular normalization (`atan2`-equivalent wrap via ±180 folding).
    static func signedYawDegrees(from: simd_float4x4, to: simd_float4x4) -> Double {
        let a = FrustumOverlapProxy.yawDegrees(from: from)
        let b = FrustumOverlapProxy.yawDegrees(from: to)
        return circularDeltaDegrees(Double(b - a))
    }

    /// Circular signed angle in (−180, 180].
    static func circularDeltaDegrees(_ delta: Double) -> Double {
        var d = delta
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// Frustum too weak → do not trust left/right arrow direction.
    static func isYawHintReliable(frustumOverlap: Double) -> Bool {
        frustumOverlap >= CaptureBridgeConfig.frustumOverlapLost
    }
}

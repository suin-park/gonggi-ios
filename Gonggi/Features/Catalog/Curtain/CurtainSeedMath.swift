import CoreGraphics
import Foundation
import simd

/// Client-side seed math mirroring cloud pole/seam warnings (design §5.2).
enum CurtainSeedMath {
    /// u within this distance of 0 or 1 triggers `near_seam`.
    static let nearSeamThresholdU: Double = 0.08
    /// |pitch| above this triggers `near_pole`.
    static let nearPolePitchThresholdDeg: Double = 75

    static func normalizedU(_ u: Double) -> Double {
        var x = u.truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        return x
    }

    static func clientWarnings(u: Double, pitchDeg: Double) -> [CurtainSeedWarning] {
        var out: [CurtainSeedWarning] = []
        let uNorm = normalizedU(u)
        if uNorm < nearSeamThresholdU || uNorm > (1 - nearSeamThresholdU) {
            out.append(.nearSeam)
        }
        if abs(pitchDeg) > nearPolePitchThresholdDeg {
            out.append(.nearPole)
        }
        return out
    }

    static func mergedWarnings(client: [CurtainSeedWarning], server: [String]?) -> [CurtainSeedWarning] {
        var set = Set(client)
        for raw in server ?? [] {
            if let w = CurtainSeedWarning(rawValue: raw) {
                set.insert(w)
            }
        }
        return CurtainSeedWarning.allCases.filter { set.contains($0) }
    }

    /// Build reproducible seed payload from a VR sphere tap.
    static func captureFromEquirectTap(
        yawDeg: Float,
        pitchDeg: Float,
        tapPoint: CGPoint?,
        viewSize: CGSize,
        latLongWidth: Int,
        latLongHeight: Int,
        spaceId: String,
        baseRevisionId: String
    ) -> CurtainSeedCapture {
        let uv = VRSphereEquirectBridge.textureUVFromEquirectDegrees(yawDeg: yawDeg, pitchDeg: pitchDeg)
        let dir = SpaceLinkMath.lookDirection(yawDeg: yawDeg, pitchDeg: pitchDeg)
        let u = Double(uv.u)
        let v = Double(uv.v)

        var screen: CurtainPlacementScreen?
        var pixel: CurtainPlacementPixel?
        if let tapPoint, viewSize.width > 1, viewSize.height > 1 {
            screen = CurtainPlacementScreen(
                x: Double(tapPoint.x),
                y: Double(tapPoint.y),
                width: Double(viewSize.width),
                height: Double(viewSize.height),
                interfaceOrientation: "portrait"
            )
            pixel = CurtainPlacementPixel(
                x: Int((Double(tapPoint.x) / Double(viewSize.width)) * Double(latLongWidth)),
                y: Int((Double(tapPoint.y) / Double(viewSize.height)) * Double(latLongHeight))
            )
        }

        let seed = CurtainPlacementSeedPayload(
            seedContractVersion: CurtainPlacementSeedPayload.contractVersion,
            spaceId: spaceId,
            baseRevisionId: baseRevisionId,
            latLongWidth: latLongWidth,
            latLongHeight: latLongHeight,
            u: u,
            v: v,
            yawDeg: Double(yawDeg),
            pitchDeg: Double(pitchDeg),
            direction: CurtainPlacementDirection(
                x: Double(dir.x),
                y: Double(dir.y),
                z: Double(dir.z)
            ),
            screen: screen,
            pixel: pixel,
            capturedAt: ISO8601DateFormatter().string(from: Date())
        )
        return CurtainSeedCapture(
            seed: seed,
            clientWarnings: clientWarnings(u: u, pitchDeg: Double(pitchDeg))
        )
    }
}

import Foundation
import simd

// MARK: - Sector / Ring structure (user-facing coverage grid)

/// Eye-height / upper / lower elevation bands for guided spatial capture.
enum CaptureElevationRing: String, Codable, CaseIterable, Sendable, Identifiable {
    case middle
    case upper
    case lower

    var id: String { rawValue }

    var userLabel: String {
        switch self {
        case .middle: return "중앙"
        case .upper: return "위쪽"
        case .lower: return "아래쪽"
        }
    }

    var coachVerb: String {
        switch self {
        case .middle: return "정면 높이"
        case .upper: return "위쪽"
        case .lower: return "아래쪽"
        }
    }
}

/// Four cardinal yaw sectors. Declaration order = **user coaching order**:
/// 왼쪽 → 정면 → 오른쪽 → 뒤쪽
enum CaptureYawSector: String, Codable, CaseIterable, Sendable, Identifiable {
    case left
    case front
    case right
    case back

    var id: String { rawValue }

    var userLabel: String {
        switch self {
        case .left: return "왼쪽"
        case .front: return "정면"
        case .right: return "오른쪽"
        case .back: return "뒤쪽"
        }
    }

    /// Explicit coaching sequence (must stay left → front → right → back).
    static let coachingOrder: [CaptureYawSector] = [.left, .front, .right, .back]
}

enum CaptureSectorFillState: String, Codable, Equatable, Sendable {
    case empty
    case capturing
    case insufficient
    case sufficient
}

/// High-level coach stage derived from sector/ring fill (not percent complete).
enum CaptureGuidanceStage: String, Codable, Equatable, Sendable {
    case eyeLevelSweep
    case upperSweep
    case lowerSweep
    case fillGaps
    case softComplete
    case reconstructionReady

    var statusLabel: String {
        switch self {
        case .eyeLevelSweep: return "정면 높이 촬영 중"
        case .upperSweep: return "위쪽 촬영 필요"
        case .lowerSweep: return "아래쪽 촬영 필요"
        case .fillGaps: return "조금 더 둘러봐 주세요"
        case .softComplete: return "거의 다 담았어요"
        case .reconstructionReady: return "촬영 완료"
        }
    }
}

struct CaptureSectorCellProgress: Equatable, Codable, Sendable, Identifiable {
    var ring: CaptureElevationRing
    var sector: CaptureYawSector
    var hitCount: Int
    var state: CaptureSectorFillState

    var id: String { "\(ring.rawValue)-\(sector.rawValue)" }
}

struct CaptureSectorRingProgress: Equatable, Codable, Sendable {
    var cells: [CaptureSectorCellProgress]
    var middleSufficientCount: Int
    var upperSufficientCount: Int
    var lowerSufficientCount: Int
    var totalSufficientCount: Int
    var fillRatio: Double
    var stage: CaptureGuidanceStage
    var currentRing: CaptureElevationRing?
    var currentSector: CaptureYawSector?

    static let empty = CaptureSectorRingProgress(
        cells: CaptureElevationRing.allCases.flatMap { ring in
            CaptureYawSector.allCases.map {
                CaptureSectorCellProgress(ring: ring, sector: $0, hitCount: 0, state: .empty)
            }
        },
        middleSufficientCount: 0,
        upperSufficientCount: 0,
        lowerSufficientCount: 0,
        totalSufficientCount: 0,
        fillRatio: 0,
        stage: .eyeLevelSweep,
        currentRing: nil,
        currentSector: nil
    )

    func cell(ring: CaptureElevationRing, sector: CaptureYawSector) -> CaptureSectorCellProgress? {
        cells.first { $0.ring == ring && $0.sector == sector }
    }

    /// Next sector the user should fill, in coaching order (left → front → right → back)
    /// within the active ring for `stage`.
    var nextCoachingFocus: (ring: CaptureElevationRing, sector: CaptureYawSector)? {
        let ring: CaptureElevationRing
        switch stage {
        case .eyeLevelSweep: ring = .middle
        case .upperSweep: ring = .upper
        case .lowerSweep: ring = .lower
        case .fillGaps:
            // Prefer first insufficient cell in ring order middle→upper→lower, coaching yaw order.
            for r in [CaptureElevationRing.middle, .upper, .lower] {
                if let s = firstInsufficient(in: r) { return (r, s) }
            }
            return nil
        case .softComplete, .reconstructionReady:
            return currentRing.flatMap { r in currentSector.map { (r, $0) } }
        }
        return firstInsufficient(in: ring).map { (ring, $0) }
    }

    private func firstInsufficient(in ring: CaptureElevationRing) -> CaptureYawSector? {
        for sector in CaptureYawSector.coachingOrder {
            let state = cell(ring: ring, sector: sector)?.state ?? .empty
            if state != .sufficient { return sector }
        }
        return nil
    }

    var focusUserLabel: String? {
        guard let focus = nextCoachingFocus else { return nil }
        switch focus.ring {
        case .middle: return focus.sector.userLabel
        case .upper: return "\(focus.sector.userLabel) 위"
        case .lower: return "\(focus.sector.userLabel) 아래"
        }
    }
}

// MARK: - Classification helpers

enum CaptureSectorRingClassifier {
    /// Pitch thresholds (radians) for middle vs upper/lower rings.
    /// Targets ~±25–35° bands with a stable middle band.
    static func ring(forPitchRadians pitch: Float) -> CaptureElevationRing {
        let deg = Double(pitch) * 180 / .pi
        if deg >= CaptureSectorRingConfig.upperPitchEnterDeg { return .upper }
        if deg <= CaptureSectorRingConfig.lowerPitchEnterDeg { return .lower }
        return .middle
    }

    /// Primary yaw sector from optical forward (world).
    /// Bucket 0 ≈ +Z forward maps to `.front`; coaching order is independent.
    static func sector(forYawRadians yaw: Float) -> CaptureYawSector {
        var a = Double(yaw)
        if a < 0 { a += 2 * .pi }
        let quarter = a / (.pi / 2)
        switch Int(floor(quarter)) % 4 {
        case 0: return .front
        case 1: return .right
        case 2: return .back
        default: return .left
        }
    }

    /// Sectors touched including ~35% boundary overlap (adjacent sector near edges).
    static func sectorsWithOverlap(forYawRadians yaw: Float) -> [CaptureYawSector] {
        let primary = sector(forYawRadians: yaw)
        var a = Double(yaw)
        if a < 0 { a += 2 * .pi }
        let withinQuarter = a.truncatingRemainder(dividingBy: .pi / 2) / (.pi / 2)
        let overlapFrac = CaptureSectorRingConfig.sectorOverlapFraction
        var out = [primary]
        if withinQuarter < overlapFrac {
            out.append(previous(primary))
        } else if withinQuarter > 1 - overlapFrac {
            out.append(next(primary))
        }
        return out
    }

    private static func next(_ s: CaptureYawSector) -> CaptureYawSector {
        switch s {
        case .left: return .front
        case .front: return .right
        case .right: return .back
        case .back: return .left
        }
    }

    private static func previous(_ s: CaptureYawSector) -> CaptureYawSector {
        switch s {
        case .left: return .back
        case .back: return .right
        case .right: return .front
        case .front: return .left
        }
    }

    static func yawPitch(from transform: simd_float4x4) -> (yaw: Float, pitch: Float) {
        let f = CaptureMath.forwardVector(from: transform)
        let yaw = atan2(f.x, f.z)
        let pitch = asin(simd_clamp(f.y, -1, 1))
        return (yaw, pitch)
    }
}

enum CaptureSectorRingConfig {
    /// Enter upper ring at / above this pitch (degrees). Target coaching band ~+25…+35°.
    static var upperPitchEnterDeg: Double = 18
    /// Enter lower ring at / below this pitch (degrees). Target coaching band ~−25…−35°.
    static var lowerPitchEnterDeg: Double = -18
    /// Fraction of each 90° sector treated as overlapping neighbor (~35%).
    static var sectorOverlapFraction: Double = 0.35
    /// Hits before a cell is "sufficient".
    static var hitsForSufficient: Int = 10
    /// Hits before a cell is "capturing" (vs empty).
    static var hitsForCapturing: Int = 2
    static var middleSectorsRequired: Int = 4
    static var upperSectorsRequired: Int = 3
    static var lowerSectorsRequired: Int = 3
}

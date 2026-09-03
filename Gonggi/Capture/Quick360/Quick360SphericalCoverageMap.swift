import Foundation
import simd

/// Spherical capture coverage — independent of live brush paint success.
enum Quick360CoverageCell: UInt8 {
    case unseen = 0
    case seenWeak = 1
    case captured = 2
}

enum Quick360CaptureGuidePhase: String, Equatable {
    case horizon
    case upper
    case lower
    case fillGaps
    case enough
}

/// Equirect bin map tracking what the camera actually viewed / keyframed.
final class Quick360SphericalCoverageMap {
    let width: Int
    let height: Int
    private var cells: [UInt8]

    init(
        width: Int = Quick360Config.coverageMapWidth,
        height: Int = Quick360Config.coverageMapHeight
    ) {
        self.width = max(8, width)
        self.height = max(4, height)
        self.cells = [UInt8](repeating: Quick360CoverageCell.unseen.rawValue, count: self.width * self.height)
    }

    func reset() {
        for i in cells.indices { cells[i] = Quick360CoverageCell.unseen.rawValue }
    }

    /// Stamp camera FOV footprint. Does **not** depend on live paint accepting pixels.
    func recordViewing(
        captureBasis: Quick360CaptureBasis,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        quality: Quick360CoverageCell
    ) {
        guard quality != .unseen else { return }
        let stride = max(1, Quick360Config.coverageStampStride)
        for y in stride(from: 0, to: height, by: stride) {
            for x in stride(from: 0, to: width, by: stride) {
                let (yaw, pitch) = yawPitch(atX: x, y: y)
                guard captureBasis.projectSphereDirectionToPixel(
                    yawRad: yaw,
                    pitchRad: pitch,
                    cameraTransform: cameraTransform,
                    thumbIntrinsics: intrinsics,
                    edgePad: 1.0
                ) != nil else { continue }
                upgrade(x: x, y: y, to: quality)
                // Soft neighborhood fill for stride > 1
                if stride > 1 {
                    for dy in 0..<stride where y + dy < height {
                        for dx in 0..<stride where x + dx < width {
                            upgrade(x: x + dx, y: y + dy, to: quality)
                        }
                    }
                }
            }
        }
    }

    /// Upgrade cells around a selected keyframe (stitch-quality).
    func markCapturedKeyframe(yawRad: Float, pitchRad: Float, halfAngleRad: Float) {
        let cosHalf = cos(halfAngleRad)
        for y in 0..<height {
            for x in 0..<width {
                let (cy, cp) = yawPitch(atX: x, y: y)
                let dirA = SphericalMath.directionVector(yawRad: yawRad, pitchRad: pitchRad)
                let dirB = SphericalMath.directionVector(yawRad: cy, pitchRad: cp)
                if simd_dot(dirA, dirB) >= cosHalf {
                    upgrade(x: x, y: y, to: .captured)
                }
            }
        }
    }

    func report() -> Quick360SphericalCoverageReport {
        var unseen = 0, weak = 0, captured = 0
        var hSeen = 0, hTotal = 0
        var uSeen = 0, uTotal = 0
        var lSeen = 0, lTotal = 0
        var zSeen = 0, zTotal = 0
        var nSeen = 0, nTotal = 0

        for y in 0..<height {
            let pitchDeg = pitchDeg(atY: y)
            for x in 0..<width {
                let cell = Quick360CoverageCell(rawValue: cells[y * width + x]) ?? .unseen
                switch cell {
                case .unseen: unseen += 1
                case .seenWeak: weak += 1
                case .captured: captured += 1
                }
                let seen = cell != .unseen
                let band = Quick360SphericalCoverageBands.band(forPitchDeg: pitchDeg)
                switch band {
                case .horizon:
                    hTotal += 1; if seen { hSeen += 1 }
                case .upper:
                    uTotal += 1; if seen { uSeen += 1 }
                case .lower:
                    lTotal += 1; if seen { lSeen += 1 }
                case .zenith:
                    zTotal += 1; if seen { zSeen += 1 }
                case .nadir:
                    nTotal += 1; if seen { nSeen += 1 }
                }
            }
        }

        let total = max(width * height, 1)
        let pct: (Int, Int) -> Float = { seen, tot in
            tot == 0 ? 0 : Float(seen) / Float(tot) * 100
        }
        let horizontal = pct(hSeen, hTotal)
        let upper = pct(uSeen, uTotal)
        let lower = pct(lSeen, lTotal)
        let zenith = pct(zSeen, zTotal)
        let nadir = pct(nSeen, nTotal)

        let w = Quick360Config.coverageBandWeights
        let overall =
            horizontal * w.horizon
            + upper * w.upper
            + lower * w.lower
            + zenith * w.zenith
            + nadir * w.nadir

        let weakPct = Float(weak) / Float(total) * 100
        let missingPct = Float(unseen) / Float(total) * 100
        let phase = Self.resolvePhase(
            horizontal: horizontal,
            upper: upper,
            lower: lower,
            zenith: zenith,
            nadir: nadir,
            overall: overall
        )
        let (sparseHint, missingYawHint) = Self.sparseGuidance(
            cells: cells,
            width: width,
            height: height,
            phase: phase
        )

        return Quick360SphericalCoverageReport(
            horizontalPercent: horizontal,
            upperPercent: upper,
            lowerPercent: lower,
            zenithPercent: zenith,
            nadirPercent: nadir,
            overallPercent: overall,
            weakPercent: weakPct,
            missingPercent: missingPct,
            guidePhase: phase,
            sparseHint: sparseHint,
            missingYawHintDeg: missingYawHint
        )
    }

    #if DEBUG
    /// Heatmap RGBA for DEBUG HUD (green=captured, amber=weak, dark=unseen).
    func debugHeatmapRGBA() -> (rgba: [UInt8], width: Int, height: Int) {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            switch Quick360CoverageCell(rawValue: cells[i]) ?? .unseen {
            case .unseen:
                out[o] = 40; out[o + 1] = 44; out[o + 2] = 52; out[o + 3] = 255
            case .seenWeak:
                out[o] = 180; out[o + 1] = 140; out[o + 2] = 60; out[o + 3] = 255
            case .captured:
                out[o] = 40; out[o + 1] = 180; out[o + 2] = 160; out[o + 3] = 255
            }
        }
        return (out, width, height)
    }
    #endif

    // MARK: - Private

    private func yawPitch(atX x: Int, y: Int) -> (Float, Float) {
        let u = (Float(x) + 0.5) / Float(width)
        let v = (Float(y) + 0.5) / Float(height)
        let yaw = u * 2 * .pi - .pi
        let pitch = .pi / 2 - v * .pi
        return (yaw, pitch)
    }

    private func pitchDeg(atY y: Int) -> Float {
        let v = (Float(y) + 0.5) / Float(height)
        return (.pi / 2 - v * .pi) * 180 / .pi
    }

    private func upgrade(x: Int, y: Int, to quality: Quick360CoverageCell) {
        let idx = y * width + x
        guard idx >= 0, idx < cells.count else { return }
        if quality.rawValue > cells[idx] {
            cells[idx] = quality.rawValue
        }
    }

    private static func resolvePhase(
        horizontal: Float,
        upper: Float,
        lower: Float,
        zenith: Float,
        nadir: Float,
        overall: Float
    ) -> Quick360CaptureGuidePhase {
        let thr = Quick360Config.coveragePhaseThresholds
        if overall >= thr.enoughOverall,
           horizontal >= thr.horizon,
           upper >= thr.upper,
           lower >= thr.lower,
           zenith >= thr.zenith,
           nadir >= thr.nadir {
            return .enough
        }
        if horizontal < thr.horizon { return .horizon }
        if upper < thr.upper || zenith < thr.zenith { return .upper }
        if lower < thr.lower || nadir < thr.nadir { return .lower }
        return .fillGaps
    }

    private static func sparseGuidance(
        cells: [UInt8],
        width: Int,
        height: Int,
        phase: Quick360CaptureGuidePhase
    ) -> (String?, Float?) {
        guard phase == .fillGaps || phase == .upper || phase == .lower else {
            return (nil, nil)
        }
        // Find largest unseen yaw sector in the active pitch band.
        let pitchRange: ClosedRange<Float>
        switch phase {
        case .upper: pitchRange = 25...90
        case .lower: pitchRange = -90...(-25)
        default: pitchRange = -90...90
        }

        var columnMiss = [Float](repeating: 0, count: width)
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            let pitch = (.pi / 2 - v * .pi) * 180 / .pi
            guard pitchRange.contains(pitch) else { continue }
            for x in 0..<width {
                if cells[y * width + x] == Quick360CoverageCell.unseen.rawValue {
                    columnMiss[x] += 1
                }
            }
        }
        guard let worst = columnMiss.enumerated().max(by: { $0.element < $1.element }),
              worst.element > 0 else {
            return (nil, nil)
        }
        let yawDeg = ((Float(worst.offset) + 0.5) / Float(width) * 360) - 180
        let compass = compassLabel(yawDeg: yawDeg)
        let vertical: String
        switch phase {
        case .upper: vertical = "위"
        case .lower: vertical = "아래"
        default: vertical = ""
        }
        if vertical.isEmpty {
            return ("\(compass)쪽이 조금 비어 있어요", yawDeg)
        }
        return ("\(compass)쪽 \(vertical)가 조금 비어 있어요", yawDeg)
    }

    private static func compassLabel(yawDeg: Float) -> String {
        var y = yawDeg
        while y > 180 { y -= 360 }
        while y < -180 { y += 360 }
        let a = abs(y)
        if a < 35 { return "앞" }
        if a > 145 { return "뒤" }
        return y > 0 ? "오른쪽" : "왼쪽"
    }
}

enum Quick360SphericalCoverageBands {
    enum Band { case horizon, upper, lower, zenith, nadir }

    static func band(forPitchDeg pitch: Float) -> Band {
        if pitch >= 70 { return .zenith }
        if pitch <= -70 { return .nadir }
        if pitch >= 25 { return .upper }
        if pitch <= -25 { return .lower }
        return .horizon
    }
}

struct Quick360SphericalCoverageReport: Equatable {
    var horizontalPercent: Float
    var upperPercent: Float
    var lowerPercent: Float
    var zenithPercent: Float
    var nadirPercent: Float
    var overallPercent: Float
    var weakPercent: Float
    var missingPercent: Float
    var guidePhase: Quick360CaptureGuidePhase
    var sparseHint: String?
    var missingYawHintDeg: Float?

    static let empty = Quick360SphericalCoverageReport(
        horizontalPercent: 0,
        upperPercent: 0,
        lowerPercent: 0,
        zenithPercent: 0,
        nadirPercent: 0,
        overallPercent: 0,
        weakPercent: 0,
        missingPercent: 100,
        guidePhase: .horizon,
        sparseHint: nil,
        missingYawHintDeg: nil
    )
}

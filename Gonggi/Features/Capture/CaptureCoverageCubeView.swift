import SwiftUI

/// Face fill levels for the quiet coverage cube (0…1).
struct CaptureCubeFaceFills: Equatable {
    var front: Double
    var left: Double
    var right: Double
    var back: Double
    var top: Double
    var bottom: Double

    static let empty = CaptureCubeFaceFills(
        front: 0, left: 0, right: 0, back: 0, top: 0, bottom: 0
    )

    static func from(progress: CaptureSectorRingProgress) -> CaptureCubeFaceFills {
        func level(_ ring: CaptureElevationRing, _ sector: CaptureYawSector) -> Double {
            switch progress.cell(ring: ring, sector: sector)?.state ?? .empty {
            case .empty: return 0
            case .insufficient: return 0.28
            case .capturing: return 0.58
            case .sufficient: return 1
            }
        }
        func ringMean(_ ring: CaptureElevationRing) -> Double {
            let vals = CaptureYawSector.coachingOrder.map { level(ring, $0) }
            guard !vals.isEmpty else { return 0 }
            return vals.reduce(0, +) / Double(vals.count)
        }
        return CaptureCubeFaceFills(
            front: level(.middle, .front),
            left: level(.middle, .left),
            right: level(.middle, .right),
            back: level(.middle, .back),
            top: ringMean(.upper),
            bottom: ringMean(.lower)
        )
    }
}

/// Compact isometric coverage cube — quiet, non-blocking.
struct CaptureCoverageCubeView: View {
    let fills: CaptureCubeFaceFills
    var isActive: Bool = true
    var size: CGFloat = 56

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let cx = canvasSize.width * 0.5
            let cy = canvasSize.height * 0.52
            let ux = s * 0.28
            let uy = s * 0.16
            let h = s * 0.32

            func p(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
                // x right, y up, z toward viewer-left for isometric
                CGPoint(
                    x: cx + (x - z) * ux,
                    y: cy + (x + z) * uy - y * h
                )
            }

            // Unit cube corners: x,y,z in {0,1}
            let fbl = p(0, 0, 1) // front-bottom-left
            let fbr = p(1, 0, 1)
            let ftl = p(0, 1, 1)
            let ftr = p(1, 1, 1)
            let bbl = p(0, 0, 0)
            let bbr = p(1, 0, 0)
            let btl = p(0, 1, 0)
            let btr = p(1, 1, 0)

            // Draw order: back-ish bottom, left, right, front, top
            drawFace(context, [bbl, bbr, fbr, fbl], fill: fills.bottom, shade: 0.75)
            drawFace(context, [bbl, fbl, ftl, btl], fill: fills.left, shade: 0.85)
            drawFace(context, [fbr, bbr, btr, ftr], fill: fills.right, shade: 0.9)
            // Front encodes front; back influence softly via mix into rim opacity already separate
            drawFace(context, [fbl, fbr, ftr, ftl], fill: max(fills.front, fills.back * 0.85), shade: 1.0)
            drawFace(context, [ftl, ftr, btr, btl], fill: fills.top, shade: 1.05)
        }
        .frame(width: size, height: size)
        .opacity(isActive ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func drawFace(
        _ context: GraphicsContext,
        _ points: [CGPoint],
        fill: Double,
        shade: Double
    ) {
        guard points.count >= 3 else { return }
        var path = Path()
        path.move(to: points[0])
        for pt in points.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        let color = Self.color(for: fill, shade: shade)
        context.fill(path, with: .color(color))
        context.stroke(
            path,
            with: .color(Color.white.opacity(isActive ? 0.22 : 0.12)),
            lineWidth: 1
        )
    }

    private static func color(for fill: Double, shade: Double) -> Color {
        let t = min(1, max(0, fill))
        // empty → cyan → green
        let r: Double
        let g: Double
        let b: Double
        let a: Double
        if t < 0.35 {
            let u = t / 0.35
            r = 0.75; g = 0.78; b = 0.82
            a = (0.14 + 0.16 * u) * shade
        } else if t < 0.75 {
            let u = (t - 0.35) / 0.4
            r = 0.2 + 0.1 * (1 - u)
            g = 0.75
            b = 0.85
            a = (0.4 + 0.35 * u) * shade
        } else {
            let u = (t - 0.75) / 0.25
            r = 0.25 * (1 - u)
            g = 0.78 + 0.12 * u
            b = 0.55 * (1 - u)
            a = (0.75 + 0.2 * u) * min(1, shade)
        }
        return Color(red: r, green: g, blue: b, opacity: min(1, a))
    }

    private var accessibilitySummary: String {
        let parts = [
            ("정면", fills.front), ("왼쪽", fills.left), ("오른쪽", fills.right),
            ("뒤", fills.back), ("위", fills.top), ("아래", fills.bottom),
        ]
        let filled = parts.filter { $0.1 >= 0.75 }.map(\.0)
        if filled.isEmpty { return "커버리지 큐브, 아직 부족한 면이 많아요" }
        return "커버리지 큐브, 충분: \(filled.joined(separator: ", "))"
    }
}

// MARK: - Quiet status / toast (UI only — gate logic unchanged)

enum CaptureQuietUIPhase: Equatable {
    case recognizing
    case capturing
    case nearlyReady
    case ready
}

enum CaptureQuietUIPresenter {
    /// Tracking + stabilizing must clear before coverage cube activates.
    static func isSpatialRecognitionReady(quality: CaptureQualityState) -> Bool {
        quality.capturePhase != .stabilizing
            && quality.trackingQuality >= 0.7
            && quality.guidanceAction != .trackingRecovery
    }

    static func phase(for quality: CaptureQualityState) -> CaptureQuietUIPhase {
        if !isSpatialRecognitionReady(quality: quality) { return .recognizing }
        if quality.completionState == .ready || quality.reconstructionReady { return .ready }
        if quality.completionState == .nearlyReady { return .nearlyReady }
        return .capturing
    }

    static func statusLine(for quality: CaptureQualityState) -> String {
        switch phase(for: quality) {
        case .recognizing:
            return "공간을 인식하고 있어요"
        case .capturing:
            return "공간 기록 중"
        case .nearlyReady:
            return "조금만 더 둘러봐 주세요"
        case .ready:
            // reconstructionReady ≠ session end (multi-room may continue).
            return "공간이 충분히 기록됐어요"
        }
    }

    static func finishTitle(isReady: Bool) -> String {
        isReady ? "촬영 완료" : "촬영 종료"
    }

    /// Short intervention toast — only when recognizing is done and something blocks progress.
    static func toastHint(for quality: CaptureQualityState) -> String? {
        guard isSpatialRecognitionReady(quality: quality) else { return nil }
        // Ready / latched: allow continue capture — no nag to finish, no overlap return.
        if quality.completionState == .ready || quality.reconstructionReady {
            return nil
        }

        if quality.trackingQuality < 0.45 || quality.guidanceAction == .trackingRecovery {
            return "조금 천천히 움직여 주세요"
        }
        if quality.guidanceAction == .improveBaseline
            || quality.guidanceAction == .moveLaterally
            || quality.translationBaselineGrade == .insufficient
        {
            return "조금 위치를 옮겨보세요"
        }
        if quality.guidanceAction == .needUpperCoverage
            || quality.guidanceStage == .upperSweep
        {
            return "위쪽도 함께 보여주세요"
        }
        if quality.guidanceAction == .needLowerCoverage
            || quality.guidanceStage == .lowerSweep
        {
            return "바닥 쪽도 함께 보여주세요"
        }
        if quality.guidanceAction == .reacquireView {
            return "이 장면이 다시 보이도록 천천히 움직여주세요"
        }
        if quality.guidanceAction == .returnToPreviousArea {
            return "방금 촬영한 곳이 다시 보이도록 이동해주세요"
        }
        if quality.guidanceAction == .slowDown || quality.motionSpeed > 0.7 {
            return "조금 천천히 움직여 주세요"
        }
        return nil
    }
}

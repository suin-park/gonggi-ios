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
            (L("Front"), fills.front), (L("Left"), fills.left), (L("Right"), fills.right),
            (L("Back"), fills.back), (L("Up"), fills.top), (L("Down"), fills.bottom),
        ]
        let filled = parts.filter { $0.1 >= 0.75 }.map(\.0)
        if filled.isEmpty { return L("Coverage cube, many sides still need photos") }
        return L("Coverage cube, enough: %@", "\(filled.joined(separator: ", "))")
    }
}

// MARK: - Quiet status / toast (UI only — gate logic unchanged)

enum CaptureQuietUIPhase: Equatable {
    case recognizing
    case capturing
    case nearlyReady
    case ready
    /// Enqueue safety cap reached — new keyframes will not be reserved.
    case storageCapReached
}

enum CaptureQuietUIPresenter {
    /// Tracking + stabilizing must clear before coverage cube activates.
    static func isSpatialRecognitionReady(quality: CaptureQualityState) -> Bool {
        quality.capturePhase != .stabilizing
            && quality.trackingQuality >= 0.7
            && quality.guidanceAction != .trackingRecovery
    }

    static func phase(for quality: CaptureQualityState) -> CaptureQuietUIPhase {
        // Cap takes priority over "recording / ready" copy so users never think saves continue.
        if quality.candidateSafetyCapReached { return .storageCapReached }
        if !isSpatialRecognitionReady(quality: quality) { return .recognizing }
        if quality.completionState == .ready || quality.reconstructionReady { return .ready }
        if quality.completionState == .nearlyReady { return .nearlyReady }
        return .capturing
    }

    static func statusLine(for quality: CaptureQualityState) -> String {
        switch phase(for: quality) {
        case .recognizing:
            return L("Recognizing the space")
        case .capturing:
            return L("Capturing the space")
        case .nearlyReady:
            return L("Look around a little more")
        case .ready:
            // reconstructionReady ≠ session end (multi-room may continue). Open items (not asked yet / asked and still
            // missing / photo limit) never read as enough.
            let open = !quality.captureRemaining.isEmpty || !quality.captureRecommendations.isEmpty
            return open ? L("You can finish the capture") : L("The space is fully captured")
        case .storageCapReached:
            // Enqueue cap — do not claim a durable on-disk JPEG count.
            return L("New photos are no longer being saved")
        }
    }

    static func finishTitle(isReady: Bool, candidateSafetyCapReached: Bool = false) -> String {
        if candidateSafetyCapReached {
            return isReady ? L("Capture complete") : L("End capture")
        }
        return isReady ? L("Capture complete") : L("End capture")
    }

    /// WHIK guide card (one card in every capture mode). Order: storage cap, recognizing, the guide v3/v4 prompt,
    /// a correction (warning), ready, then the free-capture tip that changes as photos are saved.
    static func guide(for quality: CaptureQualityState) -> WhikCaptureGuide {
        switch phase(for: quality) {
        case .storageCapReached:
            return WhikCaptureGuide(title: L("New photos are no longer being saved"),
                                    subtitle: L("You can end the capture now"), tone: .warning)
        case .recognizing:
            return WhikCaptureGuide(title: L("Recognizing the space"),
                                    subtitle: L("Hold the phone steady and slowly look around"))
        default:
            break
        }
        if let coach = quality.coachPrompt {
            let c = CaptureUIPresenter.coachCopy(coach)
            return WhikCaptureGuide(title: c.title, subtitle: c.subtitle)
        }
        if let gap = quality.gapPrompt {
            let c = CaptureUIPresenter.gapCopy(gap)
            return WhikCaptureGuide(title: c.title, subtitle: c.subtitle)
        }
        if let hint = toastHint(for: quality) {
            return WhikCaptureGuide(title: hint, subtitle: nil, tone: .warning)
        }
        if phase(for: quality) == .ready {
            return WhikCaptureGuide(title: statusLine(for: quality),
                                    subtitle: L("Tap Capture complete, or keep capturing"), tone: .done)
        }
        let tip = CaptureUIPresenter.captureTipCopy(savedPhotos: quality.spatialKeyframeEnqueueCount)
        if phase(for: quality) == .nearlyReady {
            return WhikCaptureGuide(title: L("Look around a little more"), subtitle: tip.subtitle)
        }
        return WhikCaptureGuide(title: tip.title, subtitle: tip.subtitle)
    }

    /// Bottom ring: the same fill the cube used (sector ring, or a share of quality coverage).
    static func ringFraction(for quality: CaptureQualityState) -> Double {
        min(1, max(0, max(quality.sectorRingProgress.fillRatio, quality.qualityCoverage * 0.35)))
    }

    /// Short intervention toast — only when recognizing is done and something blocks progress.
    static func toastHint(for quality: CaptureQualityState) -> String? {
        if quality.candidateSafetyCapReached {
            return L("New photos are no longer being saved")
        }
        guard isSpatialRecognitionReady(quality: quality) else { return nil }
        // Guide v3/v4 prompt on screen: one guidance line at a time (the cube hint must not contradict it).
        if quality.coachPrompt != nil || quality.gapPrompt != nil { return nil }
        // Ready / latched: allow continue capture — no nag to finish, no overlap return.
        if quality.completionState == .ready || quality.reconstructionReady {
            return nil
        }

        if quality.trackingQuality < 0.45 || quality.guidanceAction == .trackingRecovery {
            return L("Move a little more slowly")
        }
        if quality.guidanceAction == .improveBaseline
            || quality.guidanceAction == .moveLaterally
            || quality.translationBaselineGrade == .insufficient
        {
            return L("Try moving to a slightly different spot")
        }
        if quality.guidanceAction == .needUpperCoverage
            || quality.guidanceStage == .upperSweep
        {
            return L("Include where the wall meets the ceiling")
        }
        if quality.guidanceAction == .needLowerCoverage
            || quality.guidanceStage == .lowerSweep
        {
            return L("Include where the wall meets the floor")
        }
        if quality.guidanceAction == .reacquireView {
            return L("Move slowly until this view appears again")
        }
        if quality.guidanceAction == .returnToPreviousArea {
            return L("Move until the spot you just captured is visible again")
        }
        if quality.guidanceAction == .slowDown || quality.motionSpeed > 0.7 {
            return L("Move a little more slowly")
        }
        return nil
    }
}

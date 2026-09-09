import SwiftUI

/// Welcome decoration: light traces a small room’s edges, then fades (~8s loop).
/// Canvas-only — no ARSession, network, or file I/O. Fixed frame size so layout never jumps.
struct GonggiSpaceLightStoryView: View {
    var size: CGSize = CGSize(width: 280, height: 200)
    var isAnimating: Bool = true
    /// When non-nil, scrub to a fixed phase in [0, 1] (storyboard / Reduce Motion).
    var frozenPhase: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    static let loopDuration: TimeInterval = 8.0

    private var shouldAnimate: Bool {
        if frozenPhase != nil { return false }
        if debugForceStatic { return false }
        return isAnimating && !reduceMotion && scenePhase == .active
    }

    private var debugForceStatic: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-screenshot-reduce-motion") { return true }
        if let idx = args.firstIndex(of: "-screenshot-screen"),
           idx + 1 < args.count {
            let screen = args[idx + 1]
            if screen == "welcomeSpaceLightReduceMotion" || screen == "welcomeReduceMotion" {
                return true
            }
        }
        return false
        #else
        return false
        #endif
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: shouldAnimate ? 1.0 / 30.0 : 10.0, paused: !shouldAnimate)) { timeline in
            let phase = resolvedPhase(at: timeline.date)
            Canvas { context, canvasSize in
                GonggiSpaceLightStoryMath.draw(context: context, size: canvasSize, phase: phase)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func resolvedPhase(at date: Date) -> Double {
        if let frozenPhase { return min(1, max(0, frozenPhase)) }
        if !shouldAnimate {
            // Hold completed room silhouette for Reduce Motion / paused.
            return 0.70
        }
        let t = date.timeIntervalSinceReferenceDate
        let u = t.truncatingRemainder(dividingBy: Self.loopDuration) / Self.loopDuration
        return u < 0 ? u + 1 : u
    }
}

/// Pure geometry + timing for the space-light story (unit-testable without SwiftUI timeline).
enum GonggiSpaceLightStoryMath {
    /// Phase 0…1 over an 8s loop.
    static func draw(context: GraphicsContext, size: CGSize, phase: Double) {
        let p = min(1, max(0, phase))
        let room = RoomGeometry(size: size)

        // Soft ambient glow behind the room
        let glowRect = CGRect(
            x: room.origin.x - 20,
            y: room.origin.y - 16,
            width: room.width + 40,
            height: room.height + 36
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    GonggiColors.brandCyan.opacity(0.10 * Double(silhouetteOpacity(p))),
                    .clear,
                ]),
                center: CGPoint(x: glowRect.midX, y: glowRect.midY),
                startRadius: 8,
                endRadius: max(glowRect.width, glowRect.height) * 0.55
            )
        )

        let segments = room.drawOrder
        let drawEnd = lineRevealEnd(p)
        let trailOpacity = residualOpacity(p)
        let headOpacity = headOpacity(p)
        let fillOpacity = planeFillOpacity(p)

        // Subtle planes after structure is mostly drawn
        if fillOpacity > 0.01 {
            fillPlane(context: context, points: room.floorQuad, opacity: fillOpacity * 0.10)
            fillPlane(context: context, points: room.leftWallQuad, opacity: fillOpacity * 0.07)
            fillPlane(context: context, points: room.rightWallQuad, opacity: fillOpacity * 0.05)
        }

        var drawnLength: Double = 0
        let totalLength = segments.reduce(0.0) { $0 + $1.length }

        for segment in segments {
            let segStart = drawnLength / totalLength
            let segEnd = (drawnLength + segment.length) / totalLength
            drawnLength += segment.length

            if drawEnd <= segStart {
                continue
            }

            let localT = min(1, max(0, (drawEnd - segStart) / max(0.0001, segEnd - segStart)))
            let endPoint = lerp(segment.from, segment.to, localT)

            // Residual trail (full segment if already passed)
            if drawEnd >= segEnd {
                stroke(context: context, from: segment.from, to: segment.to, opacity: trailOpacity, width: 1.2)
            } else if localT > 0 {
                stroke(context: context, from: segment.from, to: endPoint, opacity: trailOpacity * 0.85, width: 1.15)
            }

            // Bright head near the drawing tip
            if drawEnd > segStart && drawEnd < segEnd + 0.02 && headOpacity > 0.01 {
                let headFromT = max(0, localT - 0.08)
                let headFrom = lerp(segment.from, segment.to, headFromT)
                stroke(context: context, from: headFrom, to: endPoint, opacity: headOpacity, width: 2.2)
                // Soft tip glow
                let tipRect = CGRect(x: endPoint.x - 5, y: endPoint.y - 5, width: 10, height: 10)
                context.fill(
                    Path(ellipseIn: tipRect),
                    with: .color(GonggiColors.brandCyan.opacity(0.55 * headOpacity))
                )
            }
        }

        // Intro spark before lines begin
        if p < 0.10 {
            let spark = room.sparkOrigin
            let sparkT = p / 0.10
            let r: CGFloat = 3 + CGFloat(sparkT) * 4
            let rect = CGRect(x: spark.x - r, y: spark.y - r, width: r * 2, height: r * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [
                        GonggiColors.brandCyan.opacity(0.7 * sparkT),
                        GonggiColors.brandCyan.opacity(0.15 * sparkT),
                        .clear,
                    ]),
                    center: spark,
                    startRadius: 0,
                    endRadius: r * 2.2
                )
            )
        }
    }

    // MARK: - Timing curves (start values; phase 0…1)

    /// 0.0–0.10 spark, 0.10–0.44 walls, 0.44–0.62 window/frame, hold, fade
    private static func lineRevealEnd(_ p: Double) -> Double {
        if p < 0.10 { return 0 }
        if p < 0.62 {
            return (p - 0.10) / 0.52
        }
        return 1
    }

    private static func residualOpacity(_ p: Double) -> Double {
        if p < 0.10 { return 0 }
        if p < 0.62 { return 0.35 + 0.35 * ((p - 0.10) / 0.52) }
        if p < 0.81 { return 0.72 }
        // fade 6.5–8.0s → 0.81–1.0
        let t = (p - 0.81) / 0.19
        return 0.72 * (1 - smoothstep(t))
    }

    private static func headOpacity(_ p: Double) -> Double {
        if p < 0.10 { return 0 }
        if p < 0.62 { return 0.95 }
        if p < 0.70 { return 0.95 * (1 - (p - 0.62) / 0.08) }
        return 0
    }

    private static func planeFillOpacity(_ p: Double) -> Double {
        if p < 0.44 { return 0 }
        if p < 0.62 { return (p - 0.44) / 0.18 }
        if p < 0.81 { return 1 }
        let t = (p - 0.81) / 0.19
        return 1 - smoothstep(t)
    }

    private static func silhouetteOpacity(_ p: Double) -> Double {
        residualOpacity(p)
    }

    private static func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t
        )
    }

    private static func stroke(
        context: GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        opacity: Double,
        width: CGFloat
    ) {
        guard opacity > 0.01 else { return }
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(
            path,
            with: .color(GonggiColors.brandCyan.opacity(opacity)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private static func fillPlane(context: GraphicsContext, points: [CGPoint], opacity: Double) {
        guard points.count >= 3, opacity > 0.01 else { return }
        var path = Path()
        path.move(to: points[0])
        for pt in points.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        context.fill(path, with: .color(GonggiColors.brandCyan.opacity(opacity)))
    }

    // MARK: - Room geometry (oblique fixed viewpoint)

    struct Segment {
        var from: CGPoint
        var to: CGPoint
        var length: Double {
            hypot(Double(to.x - from.x), Double(to.y - from.y))
        }
    }

    struct RoomGeometry {
        var origin: CGPoint
        var width: CGFloat
        var height: CGFloat

        // Key corners
        var fl: CGPoint // floor-left-front
        var fr: CGPoint
        var bl: CGPoint // floor-left-back
        var br: CGPoint
        var tl: CGPoint // ceiling-left-back-ish (room top left)
        var tr: CGPoint
        var tfl: CGPoint // top front left
        var tfr: CGPoint

        var sparkOrigin: CGPoint { fl }

        var floorQuad: [CGPoint] { [fl, fr, br, bl] }
        var leftWallQuad: [CGPoint] { [fl, bl, tl, tfl] }
        var rightWallQuad: [CGPoint] { [fr, br, tr, tfr] }

        /// Draw order: floor edges → walls → window → frame
        var drawOrder: [Segment] {
            var segs: [Segment] = [
                Segment(from: fl, to: fr),
                Segment(from: fr, to: br),
                Segment(from: br, to: bl),
                Segment(from: bl, to: fl),
                Segment(from: fl, to: tfl),
                Segment(from: fr, to: tfr),
                Segment(from: bl, to: tl),
                Segment(from: br, to: tr),
                Segment(from: tfl, to: tfr),
                Segment(from: tfl, to: tl),
                Segment(from: tfr, to: tr),
                Segment(from: tl, to: tr),
            ]
            // Window on back wall
            let wx0 = bl.x + (br.x - bl.x) * 0.28
            let wx1 = bl.x + (br.x - bl.x) * 0.55
            let wy0 = tl.y + (bl.y - tl.y) * 0.28
            let wy1 = tl.y + (bl.y - tl.y) * 0.62
            let wTL = CGPoint(x: wx0, y: wy0)
            let wTR = CGPoint(x: wx1, y: wy0)
            let wBR = CGPoint(x: wx1, y: wy1)
            let wBL = CGPoint(x: wx0, y: wy1)
            segs += [
                Segment(from: wTL, to: wTR),
                Segment(from: wTR, to: wBR),
                Segment(from: wBR, to: wBL),
                Segment(from: wBL, to: wTL),
            ]
            // Picture frame on right wall
            let fx0 = fr.x + (br.x - fr.x) * 0.35
            let fx1 = fr.x + (br.x - fr.x) * 0.62
            let fy0 = tfr.y + (fr.y - tfr.y) * 0.30
            let fy1 = tfr.y + (fr.y - tfr.y) * 0.58
            let fTL = CGPoint(x: fx0, y: fy0)
            let fTR = CGPoint(x: fx1, y: fy0)
            let fBR = CGPoint(x: fx1, y: fy1)
            let fBL = CGPoint(x: fx0, y: fy1)
            segs += [
                Segment(from: fTL, to: fTR),
                Segment(from: fTR, to: fBR),
                Segment(from: fBR, to: fBL),
                Segment(from: fBL, to: fTL),
            ]
            return segs
        }

        init(size: CGSize) {
            let marginX = size.width * 0.12
            let marginY = size.height * 0.10
            origin = CGPoint(x: marginX, y: marginY)
            width = size.width - marginX * 2
            height = size.height - marginY * 2

            // Oblique room: left wall recedes up-left, right wall up-right, floor trapezoid.
            fl = CGPoint(x: origin.x + width * 0.08, y: origin.y + height * 0.88)
            fr = CGPoint(x: origin.x + width * 0.78, y: origin.y + height * 0.90)
            bl = CGPoint(x: origin.x + width * 0.22, y: origin.y + height * 0.58)
            br = CGPoint(x: origin.x + width * 0.92, y: origin.y + height * 0.60)

            tfl = CGPoint(x: origin.x + width * 0.10, y: origin.y + height * 0.22)
            tfr = CGPoint(x: origin.x + width * 0.76, y: origin.y + height * 0.18)
            tl = CGPoint(x: origin.x + width * 0.24, y: origin.y + height * 0.08)
            tr = CGPoint(x: origin.x + width * 0.90, y: origin.y + height * 0.06)
        }
    }
}

#if DEBUG
/// Four storyboard frames for visual review contact sheets.
struct GonggiSpaceLightStoryboardView: View {
    private let phases: [(label: String, phase: Double)] = [
        ("시작", 0.06),
        ("선이 그려짐", 0.32),
        ("공간 완성", 0.70),
        ("잔상", 0.92),
    ]

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: GonggiSpacing.md) {
                Text("빛으로 그려지는 공간")
                    .font(GonggiTypography.headline(18))
                    .foregroundStyle(GonggiColors.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: GonggiSpacing.md) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: GonggiSpacing.xs) {
                            GonggiSpaceLightStoryView(
                                size: CGSize(width: 160, height: 120),
                                isAnimating: false,
                                frozenPhase: item.phase
                            )
                            .background(GonggiColors.surface.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
                            Text(item.label)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
            }
        }
    }
}
#endif

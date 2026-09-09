import SwiftUI

/// Decorative lat/long wireframe globe for welcome — no ARSession / camera permission.
struct GonggiWireframeSphereView: View {
    var diameter: CGFloat = 220
    var isAnimating: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var shouldAnimate: Bool {
        if debugForceStaticSphere { return false }
        return isAnimating && !reduceMotion && scenePhase == .active
    }

    /// DEBUG screenshot harness: `welcomeReduceMotion` cannot set Reduce Motion via environment on all SDKs.
    private var debugForceStaticSphere: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-screenshot-reduce-motion") { return true }
        if let idx = args.firstIndex(of: "-screenshot-screen"),
           idx + 1 < args.count,
           args[idx + 1] == "welcomeReduceMotion" {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: shouldAnimate ? 1.0 / 30.0 : 10.0, paused: !shouldAnimate)) { timeline in
            let angle = shouldAnimate ? rotationAngle(at: timeline.date) : 0.35
            Canvas { context, size in
                drawSphere(context: context, size: size, yaw: angle)
            }
            .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rotationAngle(at date: Date) -> Double {
        let period = GonggiMotion.welcomeSpherePeriod
        let t = date.timeIntervalSinceReferenceDate
        return (t / period) * (2 * .pi)
    }

    private func drawSphere(context: GraphicsContext, size: CGSize, yaw: Double) {
        let cx = size.width * 0.5
        let cy = size.height * 0.5
        let radius = min(size.width, size.height) * 0.42
        let tilt: Double = 0.38

        let glowRect = CGRect(
            x: cx - radius * 1.15,
            y: cy - radius * 1.15,
            width: radius * 2.3,
            height: radius * 2.3
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    GonggiColors.brandCyan.opacity(0.18),
                    GonggiColors.brandCyan.opacity(0.04),
                    .clear,
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: radius * 0.2,
                endRadius: radius * 1.2
            )
        )

        let meridians = 10
        let parallels = 7

        for m in 0 ..< meridians {
            let lon0 = (Double(m) / Double(meridians)) * 2 * .pi + yaw
            let samples = (0 ... 48).map { step -> Sample in
                let lat = -.pi / 2 + (.pi * Double(step) / 48.0)
                return project(lat: lat, lon: lon0, tilt: tilt, cx: cx, cy: cy, radius: radius)
            }
            drawDepthPath(context: context, samples: samples)
        }

        for pIdx in 1 ..< parallels {
            let lat = -.pi / 2 + (.pi * Double(pIdx) / Double(parallels))
            let samples = (0 ... 64).map { step -> Sample in
                let lon = (Double(step) / 64.0) * 2 * .pi + yaw
                return project(lat: lat, lon: lon, tilt: tilt, cx: cx, cy: cy, radius: radius)
            }
            drawDepthPath(context: context, samples: samples)
        }

        var rim = Path()
        rim.addEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        context.stroke(
            rim,
            with: .color(GonggiColors.brandCyan.opacity(0.35)),
            lineWidth: 1.0
        )
    }

    private struct Sample {
        var point: CGPoint
        var depth: Double
    }

    private func project(lat: Double, lon: Double, tilt: Double, cx: CGFloat, cy: CGFloat, radius: CGFloat) -> Sample {
        let x = cos(lat) * sin(lon)
        let y = sin(lat)
        let z = cos(lat) * cos(lon)
        let y2 = y * cos(tilt) - z * sin(tilt)
        let z2 = y * sin(tilt) + z * cos(tilt)
        let px = cx + CGFloat(x) * radius
        let py = cy - CGFloat(y2) * radius
        return Sample(point: CGPoint(x: px, y: py), depth: z2)
    }

    private func drawDepthPath(context: GraphicsContext, samples: [Sample]) {
        guard samples.count > 1 else { return }
        for i in 0 ..< (samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            let depth = (a.depth + b.depth) * 0.5
            var segment = Path()
            segment.move(to: a.point)
            segment.addLine(to: b.point)
            let t = max(0, min(1, (depth + 1) * 0.5))
            let opacity = 0.12 + 0.55 * t
            let width = 0.6 + 0.7 * t
            context.stroke(
                segment,
                with: .color(GonggiColors.brandCyan.opacity(opacity)),
                lineWidth: width
            )
        }
    }
}

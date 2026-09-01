import SwiftUI

/// Presentation-only coverage surface overlay — does not compute coverage.
struct CoverageSurfaceOverlay: View {
    let quality: CaptureQualityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private let patches = CoverageSurfaceLayout.patches

    var body: some View {
        let focusIndex = CoverageSurfaceLayout.focusPatchIndex(
            quality: quality,
            patchCount: patches.count
        )
        Canvas { context, size in
            for (index, patch) in patches.enumerated() {
                let state = CoverageSurfaceLayout.patchState(
                    index: index,
                    total: patches.count,
                    quality: quality
                )
                let path = patch.path(in: size)
                let style = CoverageSurfaceLayout.style(for: state, isFocus: index == focusIndex)
                context.fill(path, with: .color(style.fill))
                if style.strokeOpacity > 0 {
                    context.stroke(
                        path,
                        with: .color(style.stroke.opacity(style.strokeOpacity)),
                        lineWidth: style.lineWidth
                    )
                }
            }
            if let focusIndex, !reduceMotion {
                let focusPath = patches[focusIndex].path(in: size)
                let glow = CoverageSurfaceLayout.style(for: .insufficient, isFocus: true)
                context.stroke(
                    focusPath,
                    with: .color(glow.stroke.opacity(pulse ? 0.55 : 0.28)),
                    lineWidth: glow.lineWidth + 1.5
                )
            }
        }
        .opacity(1.0 - CaptureUIPresenter.overlayDimming(for: quality))
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion, focusPatchExists else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var focusPatchExists: Bool {
        CoverageSurfaceLayout.focusPatchIndex(quality: quality, patchCount: patches.count) != nil
    }
}

// MARK: - Layout (visual only)

private enum CoverageSurfaceLayout {
    struct PatchStyle {
        let fill: Color
        let stroke: Color
        let strokeOpacity: Double
        let lineWidth: CGFloat
    }

    struct Patch: Identifiable {
        let id: Int
        /// Normalized quad corners (0…1), slightly irregular for mesh-like feel.
        let corners: [CGPoint]
        let depth: Double

        func path(in size: CGSize) -> Path {
            var path = Path()
            guard corners.count >= 3 else { return path }
            let points = corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            return path
        }
    }

    static let patches: [Patch] = buildPatches()

    static func patchState(
        index: Int,
        total: Int,
        quality: CaptureQualityState
    ) -> CoverageState {
        if !quality.areas.isEmpty, index < quality.areas.count {
            return quality.areas[index].state
        }
        let coverage = quality.overallCoverage
        let t = Double(index) / Double(max(1, total - 1))
        let noise = sin(Double(index) * 1.73 + coverage * 3.1) * 0.08
        // Upper portion tends to be scanned first; global coverage lifts all cells.
        let bias = (1.0 - t) * 0.22
        let cellScore = coverage + bias + noise

        if cellScore < 0.18 { return .unseen }
        if cellScore < 0.38 { return .insufficient }
        if cellScore < 0.62 { return .acceptable }
        return .good
    }

    static func focusPatchIndex(quality: CaptureQualityState, patchCount: Int) -> Int? {
        var firstInsufficient: Int?
        for index in 0..<patchCount {
            let state = patchState(index: index, total: patchCount, quality: quality)
            if state == .insufficient {
                firstInsufficient = index
                break
            }
        }
        return firstInsufficient
    }

    static func style(for state: CoverageState, isFocus: Bool) -> PatchStyle {
        switch state {
        case .unseen:
            return PatchStyle(
                fill: Color.white.opacity(0.02),
                stroke: Color.white.opacity(0.04),
                strokeOpacity: 0.3,
                lineWidth: 0.5
            )
        case .insufficient:
            let fillOpacity = isFocus ? 0.22 : 0.14
            return PatchStyle(
                fill: GonggiColors.accentCyan.opacity(fillOpacity),
                stroke: GonggiColors.accentCyan,
                strokeOpacity: isFocus ? 0.75 : 0.48,
                lineWidth: isFocus ? 2.0 : 1.2
            )
        case .acceptable:
            return PatchStyle(
                fill: GonggiColors.accentTeal.opacity(0.06),
                stroke: GonggiColors.accentTeal.opacity(0.35),
                strokeOpacity: 0.35,
                lineWidth: 0.8
            )
        case .good:
            return PatchStyle(
                fill: GonggiColors.successGreen.opacity(0.04),
                stroke: GonggiColors.successGreen.opacity(0.28),
                strokeOpacity: 0.28,
                lineWidth: 0.6
            )
        }
    }

    private static func buildPatches() -> [Patch] {
        // Irregular surface quads — not a uniform grid.
        let seeds: [(CGFloat, CGFloat, CGFloat, CGFloat, Double)] = [
            (0.05, 0.12, 0.28, 0.22, 0.9), (0.22, 0.08, 0.48, 0.20, 0.7),
            (0.44, 0.06, 0.72, 0.18, 0.85), (0.68, 0.10, 0.95, 0.24, 0.75),
            (0.04, 0.22, 0.26, 0.38, 0.6), (0.24, 0.20, 0.50, 0.36, 0.8),
            (0.48, 0.18, 0.70, 0.34, 0.65), (0.70, 0.22, 0.96, 0.40, 0.9),
            (0.06, 0.38, 0.30, 0.54, 0.7), (0.28, 0.36, 0.52, 0.52, 0.55),
            (0.50, 0.34, 0.74, 0.50, 0.8), (0.72, 0.38, 0.94, 0.56, 0.6),
            (0.08, 0.54, 0.32, 0.70, 0.85), (0.30, 0.52, 0.54, 0.68, 0.7),
            (0.52, 0.50, 0.76, 0.66, 0.75), (0.74, 0.54, 0.92, 0.72, 0.9),
            (0.10, 0.70, 0.34, 0.86, 0.65), (0.32, 0.68, 0.56, 0.84, 0.8),
            (0.54, 0.66, 0.78, 0.82, 0.7), (0.76, 0.70, 0.90, 0.88, 0.55),
            (0.14, 0.84, 0.38, 0.96, 0.9), (0.36, 0.82, 0.58, 0.94, 0.6),
            (0.58, 0.80, 0.80, 0.92, 0.75), (0.78, 0.84, 0.88, 0.96, 0.85),
        ]
        return seeds.enumerated().map { index, seed in
            let (x0, y0, x1, y1, depth) = seed
            let jitter: CGFloat = 0.03
            let j = CGFloat(index % 5) * 0.008
            return Patch(
                id: index,
                corners: [
                    CGPoint(x: x0 + j, y: y0),
                    CGPoint(x: x1 - jitter, y: y0 + jitter + j),
                    CGPoint(x: x1, y: y1),
                    CGPoint(x: x0 + jitter, y: y1 - jitter),
                ],
                depth: depth
            )
        }
    }
}

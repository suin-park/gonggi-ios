import SwiftUI
import UIKit

/// Temporary Hybrid Split Debug Capture — Test A observation UI.
/// Layout keeps controls above the system tab bar (or full-screen cover with no tab bar).
struct Quick360SplitDebugView: View {
    let testPhase: Quick360SplitDebugTestPhase
    let sphereImage: UIImage?
    let cameraSourceImage: UIImage?
    let brushDebug: Quick360BrushDebugState
    let hasCachedFrame: Bool
    let onClose: () -> Void
    let onStartTest: () -> Void
    let onReset: () -> Void
    let onPaintOne: () -> Void

    private var isFrozen: Bool { testPhase == .testAFrozen }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            spherePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.white.opacity(0.35))
            cameraPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controlBar
        }
        .background(Color.black)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isFrozen ? "TEST A — FROZEN" : "SPLIT DEBUG · TEST A")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(isFrozen ? .orange : .white)

                Text(brushDebug.overlayText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(8)
                    .background(.black.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.92))
    }

    private var spherePane: some View {
        ZStack {
            Color(white: 0.22)
            if let sphereImage {
                Image(uiImage: sphereImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .overlay {
                        FOVOutlineOverlay(corners: brushDebug.fovCorners)
                    }
            } else {
                Text("neutral gray — paint 전")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            CrosshairOverlay(color: .cyan)
            paneLabel("SPHERE OUTPUT")
        }
        .clipped()
    }

    private var cameraPane: some View {
        ZStack {
            Color.black
            if let cameraSourceImage {
                Image(uiImage: cameraSourceImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text("waiting for brush source…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            CrosshairOverlay(color: .yellow)
            paneLabel("CAMERA SOURCE")
            if !isFrozen {
                VStack {
                    Spacer()
                    Text("정면의 기준 물체를 중앙에 맞춰주세요")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .padding(.bottom, 10)
                }
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            if isFrozen {
                controlButton("RESET", fill: Color.white.opacity(0.18), action: onReset)
                controlButton("PAINT 1", fill: Color.orange.opacity(0.75), action: onPaintOne)
            } else {
                controlButton(
                    hasCachedFrame ? "START TEST" : "WAITING FRAME…",
                    fill: hasCachedFrame ? GonggiColors.accentTeal : Color.gray.opacity(0.5),
                    action: onStartTest
                )
                .disabled(!hasCachedFrame)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    private func controlButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func paneLabel(_ title: String) -> some View {
        VStack {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55))
                Spacer()
            }
            .padding(8)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

private struct CrosshairOverlay: View {
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width * 0.5
            let cy = geo.size.height * 0.5
            Path { path in
                path.move(to: CGPoint(x: cx - 18, y: cy))
                path.addLine(to: CGPoint(x: cx + 18, y: cy))
                path.move(to: CGPoint(x: cx, y: cy - 18))
                path.addLine(to: CGPoint(x: cx, y: cy + 18))
            }
            .stroke(color.opacity(0.95), lineWidth: 1.2)
            Circle()
                .stroke(color.opacity(0.9), lineWidth: 1)
                .frame(width: 10, height: 10)
                .position(x: cx, y: cy)
        }
        .allowsHitTesting(false)
    }
}

private struct FOVOutlineOverlay: View {
    let corners: [Quick360FOVDiagnostics.Corner]

    var body: some View {
        GeometryReader { geo in
            if corners.count == 4 {
                Path { path in
                    let pts = corners.map { c in
                        CGPoint(x: CGFloat(c.u) * geo.size.width, y: CGFloat(c.v) * geo.size.height)
                    }
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    path.closeSubpath()
                }
                .stroke(Color.green.opacity(0.9), lineWidth: 1.5)

                let cu = corners.map(\.u).reduce(0, +) / Float(corners.count)
                let cv = corners.map(\.v).reduce(0, +) / Float(corners.count)
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                    .position(x: CGFloat(cu) * geo.size.width, y: CGFloat(cv) * geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

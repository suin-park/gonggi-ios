import SwiftUI
import UIKit

/// Temporary Hybrid Split Debug Capture — compare camera source vs sphere brush on device.
/// Does not invent ±90°/UV offsets; observation-only coordinate gate.
struct Quick360SplitDebugView: View {
    let uiState: Quick360CaptureUIState
    let sphereImage: UIImage?
    let cameraSourceImage: UIImage?
    let brushDebug: Quick360BrushDebugState
    let settings: Quick360SplitDebugSettings
    let onClose: () -> Void
    let onStart: () -> Void
    let onFinish: () -> Void
    let onToggleFreeze: () -> Void
    let onTogglePaint: () -> Void
    let onToggleSingleFrame: () -> Void
    let onPaintOneFrame: () -> Void

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.height * 0.5
            VStack(spacing: 0) {
                spherePane
                    .frame(width: geo.size.width, height: half)
                Divider().overlay(Color.white.opacity(0.35))
                cameraPane
                    .frame(width: geo.size.width, height: half)
            }
            .overlay(alignment: .topLeading) {
                debugHUD
                    .padding(.top, 52)
                    .padding(.leading, 10)
            }
            .overlay(alignment: .top) {
                topChrome
            }
            .overlay(alignment: .bottom) {
                bottomChrome
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
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
        }
        .clipped()
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

    private var debugHUD: some View {
        Text(brushDebug.overlayText)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.92))
            .padding(8)
            .background(.black.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(false)
    }

    private var topChrome: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.5))
                    .clipShape(Circle())
            }
            Spacer()
            Text("SPLIT DEBUG")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5))
                .clipShape(Capsule())
            Spacer()
            if uiState.canFinish {
                Button(action: onFinish) {
                    Text("완료")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(GonggiColors.accentTeal)
                        .clipShape(Capsule())
                }
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var bottomChrome: some View {
        VStack(spacing: 8) {
            if uiState.phase == .alignFront || uiState.phase == .readyToStart {
                Text("정면의 기준 물체를 맞춰주세요")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }

            HStack(spacing: 8) {
                debugChip(
                    settings.frozen ? "Resume" : "Freeze",
                    active: settings.frozen,
                    action: onToggleFreeze
                )
                debugChip(
                    settings.paintEnabled ? "Paint: ON" : "Paint: OFF",
                    active: settings.paintEnabled,
                    action: onTogglePaint
                )
                debugChip(
                    settings.singleFrameMode ? "Single: ON" : "Single: OFF",
                    active: settings.singleFrameMode,
                    action: onToggleSingleFrame
                )
                if settings.singleFrameMode, uiState.phase == .capturing || uiState.phase == .complete {
                    debugChip("Paint 1", active: false, action: onPaintOneFrame)
                }
            }

            if uiState.canStart {
                Button(action: onStart) {
                    Text("촬영 시작")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(GonggiColors.accentTeal)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 18)
    }

    private func debugChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(active ? Color.orange.opacity(0.75) : Color.black.opacity(0.55))
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                )
        }
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

/// Draws current FOV footprint on the equirect sphere preview (UV space).
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

                // Center of FOV footprint
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

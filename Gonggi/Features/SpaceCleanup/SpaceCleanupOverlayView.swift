import SwiftUI

/// Bottom chrome for multi-point furniture selection inside VR.
struct SpaceCleanupSelectionBanner: View {
    @ObservedObject var session: SpaceCleanupSession
    var poleWarning: Bool
    var onAddCenter: () -> Void
    var onSubmit: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: GonggiSpacing.sm) {
            if poleWarning {
                Text(L("You're near the top or bottom. Tilt the view down a little so the furniture is visible."))
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }

            Text(bannerMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if !session.points.isEmpty, session.job?.isAwaitingConfirmation != true {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(session.points.enumerated()), id: \.element.id) { index, point in
                            Button {
                                GonggiHaptics.light()
                                session.removePoint(id: point.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.bold))
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(0.2)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Delete selection %@", "\(index + 1)"))
                        }
                    }
                }
            }

            if session.job?.isAwaitingConfirmation == true {
                TextField(L("What do you want to remove? (e.g. sofa, mirror)"), text: $session.removalTargetText)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .submitLabel(.done)
                    .accessibilityLabel(L("To remove"))

                HStack(spacing: GonggiSpacing.sm) {
                    Button(L("Choose again")) {
                        GonggiHaptics.light()
                        session.resetForReselect()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button(L("Clear this furniture")) {
                        GonggiHaptics.medium()
                        onConfirm()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    .disabled(!session.canConfirm)
                }
            } else if session.job?.isInFlight == true {
                ProgressView()
                    .tint(.white)
            } else {
                HStack(spacing: GonggiSpacing.sm) {
                    Button(L("Add selection")) {
                        GonggiHaptics.light()
                        onAddCenter()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    .disabled(session.isSubmitting)

                    Button(L("Undo last selection")) {
                        GonggiHaptics.light()
                        session.undoLast()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(session.points.isEmpty || session.isSubmitting)
                }

                HStack(spacing: GonggiSpacing.sm) {
                    Button(L("Choose again")) {
                        GonggiHaptics.light()
                        session.resetForReselect()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(session.points.isEmpty || session.isSubmitting)

                    Button(L("Clear this furniture")) {
                        GonggiHaptics.medium()
                        onSubmit()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    .disabled(!session.canSubmitSelected || !session.consentAccepted || session.isSubmitting)
                }
            }

            if let error = session.errorMessage {
                Text(error)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Button(L("Close")) { onCancel() }
                .font(GonggiTypography.caption(12))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, GonggiSpacing.md)
    }

    private var bannerMessage: String {
        if session.job?.isAwaitingConfirmation == true {
            return session.canConfirm
                ? L("Check what will be removed, then tap “Clear this furniture”")
                : L("Check the pin, then type the name of the furniture to remove below")
        }
        if session.job?.isInFlight == true {
            return L("Finding the selected furniture…")
        }
        if session.points.isEmpty {
            return L("Center the screen on the furniture, then tap “Add selection” or tap it")
        }
        return L("%@ selected, keep adding or tap “Clear this furniture”", "\(session.points.count)")
    }
}

/// Numbered markers + detected polygon overlays projected into the current VR view.
/// Uses equirect UV projection only — never a screen-fixed latlong mask image (that drifts when panning).
struct SpaceCleanupVROverlay: View {
    let points: [SpaceCleanupSelectionPoint]
    let polygons: [[SpaceCleanupUvPoint]]
    let projectEquirectDegrees: (Float, Float) -> CGPoint?
    var onMaskPreviewLoaded: ((Bool) -> Void)? = nil
    /// Bumped when camera look changes so markers re-project.
    var refreshEpoch: UInt64 = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(polygons.enumerated()), id: \.offset) { _, poly in
                    polygonPath(poly, in: geo.size)
                        .fill(GonggiColors.accentCyan.opacity(0.28))
                        .overlay(
                            polygonPath(poly, in: geo.size)
                                .stroke(GonggiColors.accentCyan.opacity(0.85), lineWidth: 2)
                        )
                        .allowsHitTesting(false)
                        .onAppear { onMaskPreviewLoaded?(true) }
                }

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let yawDeg = Float(point.yaw * 180 / .pi)
                    let pitchDeg = Float(point.pitch * 180 / .pi)
                    if let screen = projectEquirectDegrees(yawDeg, pitchDeg) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(GonggiColors.accentCyan))
                            .position(clamped(screen, in: geo.size))
                            .accessibilityLabel(L("Selection %@", "\(index + 1)"))
                    }
                }
            }
            .id(refreshEpoch)
        }
        .allowsHitTesting(false)
    }

    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 8), size.width - 8),
            y: min(max(point.y, 8), size.height - 8)
        )
    }

    private func polygonPath(_ poly: [SpaceCleanupUvPoint], in size: CGSize) -> Path {
        var path = Path()
        let screens: [CGPoint] = poly.compactMap { uv in
            let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(
                u: Float(uv.u),
                v: Float(uv.v)
            )
            return projectEquirectDegrees(yaw, pitch)
        }
        guard let first = screens.first else { return path }
        path.move(to: first)
        for pt in screens.dropFirst() {
            path.addLine(to: pt)
        }
        path.closeSubpath()
        _ = size
        return path
    }
}

import SwiftUI

/// Compact 3×4 sector/ring fill indicator (middle / upper / lower × 4 yaw sectors).
struct CaptureSectorRingStrip: View {
    let progress: CaptureSectorRingProgress

    private let rings: [CaptureElevationRing] = [.upper, .middle, .lower]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rings) { ring in
                HStack(spacing: 6) {
                    Text(ring.userLabel)
                        .font(GonggiTypography.label(10))
                        .foregroundStyle(GonggiColors.textTertiary)
                        .frame(width: 28, alignment: .leading)
                    ForEach(CaptureYawSector.coachingOrder) { sector in
                        let cell = progress.cell(ring: ring, sector: sector)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(fillColor(for: cell?.state ?? .empty))
                            .frame(height: 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(GonggiColors.border.opacity(0.5), lineWidth: 0.5)
                            )
                            .accessibilityLabel("\(ring.userLabel) \(sector.userLabel) \(cell?.state.rawValue ?? "empty")")
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(GonggiColors.surfaceElevated.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("촬영 구간 진행")
    }

    private func fillColor(for state: CaptureSectorFillState) -> Color {
        switch state {
        case .empty:
            return GonggiColors.border.opacity(0.25)
        case .capturing:
            return GonggiColors.brandCyan.opacity(0.45)
        case .insufficient:
            return GonggiColors.brandCyan.opacity(0.7)
        case .sufficient:
            return GonggiColors.successGreen.opacity(0.9)
        }
    }
}

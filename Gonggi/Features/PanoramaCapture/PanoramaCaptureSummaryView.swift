import SwiftUI

struct PanoramaCaptureSummaryView: View {
    let result: PanoramaCaptureResult
    let onRetake: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                        Text(L("Panorama preview"))
                            .font(GonggiTypography.title(24))
                            .foregroundStyle(GonggiColors.textPrimary)

                        previewCard

                        statsCard

                        VStack(spacing: GonggiSpacing.sm) {
                            PrimaryButton(title: L("Keep in Library"), icon: "checkmark") {
                                onDone()
                            }
                            SecondaryButton(title: L("Capture again"), icon: "arrow.counterclockwise") {
                                onRetake()
                            }
                        }
                    }
                    .padding(GonggiSpacing.lg)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Close")) { onDone() }
                        .foregroundStyle(GonggiColors.accentTeal)
                }
            }
        }
    }

    private var previewCard: some View {
        Group {
            if let img = result.previewImage ?? result.finalImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: GonggiRadius.md)
                            .strokeBorder(GonggiColors.border, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: GonggiRadius.md)
                    .fill(GonggiColors.surface)
                    .frame(height: 160)
                    .overlay(Text(L("No preview")).foregroundStyle(GonggiColors.textTertiary))
            }
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            labelRow(L("Rotation angle"), String(format: "%.0f°", result.report.yawSpanDeg))
            labelRow(L("Strips"), "\(result.report.acceptedStripCount)")
            labelRow(
                L("Resolution"),
                "\(result.report.outputWidth)×\(result.report.outputHeight)"
            )
            labelRow(
                L("Processing time"),
                String(format: L("%.1f s"), result.report.processingTimeSec)
            )
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md))
    }

    private func labelRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)
            Spacer()
            Text(value)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
        }
    }
}

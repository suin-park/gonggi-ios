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
                        Text("파노라마 미리보기")
                            .font(GonggiTypography.title(24))
                            .foregroundStyle(GonggiColors.textPrimary)

                        previewCard

                        statsCard

                        VStack(spacing: GonggiSpacing.sm) {
                            PrimaryButton(title: "보관함에 두기", icon: "checkmark") {
                                onDone()
                            }
                            SecondaryButton(title: "다시 촬영", icon: "arrow.counterclockwise") {
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
                    Button("닫기") { onDone() }
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
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: GonggiRadius.md)
                            .strokeBorder(GonggiColors.border, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: GonggiRadius.md)
                    .fill(GonggiColors.surface)
                    .frame(height: 160)
                    .overlay(Text("미리보기 없음").foregroundStyle(GonggiColors.textTertiary))
            }
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            labelRow("회전 각도", String(format: "%.0f°", result.report.yawSpanDeg))
            labelRow("스트립", "\(result.report.acceptedStripCount)")
            labelRow(
                "해상도",
                "\(result.report.outputWidth)×\(result.report.outputHeight)"
            )
            labelRow(
                "처리 시간",
                String(format: "%.1f초", result.report.processingTimeSec)
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

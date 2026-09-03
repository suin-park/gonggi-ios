import SwiftUI

struct Quick360SummaryView: View {
    let summary: Quick360SessionSummary
    let onRetry: () -> Void
    let onPreview360: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    GonggiSummaryHero(
                        coveragePercent: summary.report.map { Int($0.coveragePercent.rounded()) } ?? summary.progressPercent,
                        qualityLabel: qualityLabel,
                        duration: formattedDuration(summary.duration)
                    )

                    Text("공간 촬영 결과")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)

                    if let report = summary.report {
                        reportGrid(report)
                    }

                    Text("파노라마·바닥 데이터는 기기에만 저장됩니다.")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textTertiary)

                    VStack(spacing: GonggiSpacing.sm) {
                        if summary.panoramaURL != nil, onPreview360 != nil {
                            PrimaryButton(title: "360° 공간 미리보기 (Experimental)", icon: "globe") {
                                onPreview360?()
                            }
                        }
                        SecondaryButton(title: "다시 촬영", icon: "arrow.counterclockwise") {
                            onRetry()
                        }
                    }
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("공간 촬영 요약")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var qualityLabel: String {
        guard let report = summary.report else { return "Prototype" }
        if report.sphereCoveragePercent >= 55 || report.coveragePercent >= 75 { return "양호" }
        if report.sphereCoveragePercent >= 35 || report.coveragePercent >= 50 { return "보통" }
        return "보강 필요"
    }

    private func reportGrid(_ report: Quick360PanoramaReport) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: GonggiSpacing.sm) {
            metric("공간 커버", String(format: "%.0f%%", report.sphereCoveragePercent))
            metric("바닥", report.floorDetected
                   ? String(format: "%.0f%%", report.floorCoveragePercent)
                   : "미검출")
            metric("파노라마", String(format: "%.1f%%", report.coveragePercent))
            metric("키프레임", "\(report.acceptedKeyframeCount)/\(report.selectedKeyframeCount)")
            metric("정렬 보정", "\(report.successfulRefinements)/\(report.visualRefinementAttempts)")
            metric("최대 이동", String(format: "%.0f cm", report.maxTranslationM * 100))
            metric("촬영 시간", String(format: "%.0fs", report.captureDurationSec))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(GonggiTypography.caption(11))
                .foregroundStyle(GonggiColors.textTertiary)
            Text(value)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GonggiSpacing.sm)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return m > 0 ? "\(m)분 \(s)초" : "\(s)초"
    }
}

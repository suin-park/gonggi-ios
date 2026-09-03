import SwiftUI

struct Quick360SummaryView: View {
    let summary: Quick360SessionSummary
    let onRetry: () -> Void

    @State private var showPanoramaViewer = false
    @State private var viewerURL: URL?
    @State private var previewError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    GonggiSummaryHero(
                        coveragePercent: summary.report.map {
                            Int($0.overallSphericalCoveragePercent.rounded())
                        } ?? summary.progressPercent,
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
                        PrimaryButton(title: "360° 공간 미리보기", icon: "globe") {
                            openPanoramaPreview()
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
            .fullScreenCover(isPresented: $showPanoramaViewer) {
                if let viewerURL {
                    Panorama360ViewerView(imageURL: viewerURL)
                }
            }
            .alert("미리보기를 열 수 없어요", isPresented: Binding(
                get: { previewError != nil },
                set: { if !$0 { previewError = nil } }
            )) {
                Button("확인", role: .cancel) { previewError = nil }
            } message: {
                Text(previewError ?? "")
            }
        }
    }

    private func openPanoramaPreview() {
        GonggiHaptics.light()
        guard let url = summary.panoramaURL else {
            previewError = "파노라마 파일이 없어요. 다시 촬영해 주세요."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            previewError = "파노라마 파일을 찾을 수 없어요."
            return
        }
        guard UIImage(contentsOfFile: url.path) != nil else {
            previewError = "파노라마 이미지를 불러오지 못했어요."
            return
        }
        viewerURL = url
        // Present from Summary itself (Method B) — avoids sheet + parent fullScreenCover conflict.
        showPanoramaViewer = true
    }

    private var qualityLabel: String {
        guard let report = summary.report else { return "기록됨" }
        if report.overallSphericalCoveragePercent >= 62
            || report.sphereCoveragePercent >= 55
            || report.coveragePercent >= 75 {
            return "양호"
        }
        if report.overallSphericalCoveragePercent >= 40
            || report.sphereCoveragePercent >= 35
            || report.coveragePercent >= 50 {
            return "보통"
        }
        return "보강 필요"
    }

    private func reportGrid(_ report: Quick360PanoramaReport) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: GonggiSpacing.sm) {
            metric("전체 커버", String(format: "%.0f%%", report.overallSphericalCoveragePercent))
            metric("수평", String(format: "%.0f%%", report.horizontalCoveragePercent))
            metric("위쪽", String(format: "%.0f%%", report.upperCoveragePercent))
            metric("아래쪽", String(format: "%.0f%%", report.lowerCoveragePercent))
            metric("천장", String(format: "%.0f%%", report.zenithCoveragePercent))
            metric("바닥(구체)", String(format: "%.0f%%", report.nadirCoveragePercent))
            metric("파노라마", String(format: "%.1f%%", report.coveragePercent))
            metric("해상도", "\(report.outputWidth)×\(report.outputHeight)")
            metric("키프레임", "\(report.acceptedKeyframeCount)/\(report.selectedKeyframeCount)")
            metric("정렬 보정", "\(report.successfulRefinements)/\(report.visualRefinementAttempts)")
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

import SwiftUI

struct Quick360SummaryView: View {
    let summary: Quick360SessionSummary
    let onRetry: () -> Void

    @State private var showPanoramaViewer = false
    @State private var viewerURL: URL?
    @State private var previewError: String?
    @State private var showABShare = false
    @State private var abShareItems: [URL] = []
    @State private var abShareError: String?

    private var hasOpenCVPanorama: Bool {
        PanoramaABPaths.openCVPanoramaURL(sessionId: summary.sessionId) != nil
    }

    private var hasABArtifacts: Bool {
        !PanoramaABPaths.shareableArtifactURLs(sessionId: summary.sessionId).isEmpty
    }

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

                    if Quick360Config.testFlightABCompareEnabled || hasABArtifacts {
                        Text("이 빌드는 Legacy 결과를 표시하고, 동일 세션 OpenCV A/B 산출물을 함께 저장합니다.")
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }

                    VStack(spacing: GonggiSpacing.sm) {
                        PrimaryButton(title: "360° 공간 미리보기 (Legacy)", icon: "globe") {
                            openPanoramaPreview(url: summary.panoramaURL)
                        }
                        if hasOpenCVPanorama {
                            SecondaryButton(title: "OpenCV 파노라마 미리보기", icon: "eye") {
                                openPanoramaPreview(
                                    url: PanoramaABPaths.openCVPanoramaURL(sessionId: summary.sessionId)
                                )
                            }
                        }
                        if hasABArtifacts {
                            SecondaryButton(title: "A/B 결과 공유", icon: "square.and.arrow.up") {
                                shareABArtifacts()
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
            .fullScreenCover(isPresented: $showPanoramaViewer) {
                if let viewerURL {
                    Panorama360ViewerView(imageURL: viewerURL)
                }
            }
            .sheet(isPresented: $showABShare) {
                CaptureExportShareSheet(items: abShareItems) {
                    showABShare = false
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
            .alert("A/B 공유", isPresented: Binding(
                get: { abShareError != nil },
                set: { if !$0 { abShareError = nil } }
            )) {
                Button("확인", role: .cancel) { abShareError = nil }
            } message: {
                Text(abShareError ?? "")
            }
        }
    }

    private func openPanoramaPreview(url: URL?) {
        GonggiHaptics.light()
        guard let url else {
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
        showPanoramaViewer = true
    }

    private func shareABArtifacts() {
        GonggiHaptics.light()
        let urls = PanoramaABPaths.shareableArtifactURLs(sessionId: summary.sessionId)
        guard !urls.isEmpty else {
            abShareError = "A/B 산출물이 아직 없어요. 촬영을 완료한 뒤 다시 시도해 주세요."
            return
        }
        abShareItems = urls
        showABShare = true
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

import SwiftUI

struct CaptureSummaryView: View {
    let summary: CaptureSessionSummary
    let onContinueCapture: () -> Void
    let onCreateSpace: () -> Void

    #if DEBUG
    @State private var showExportShare = false
    @State private var exportShareItems: [URL] = []
    @State private var exportError: String?
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    Text("촬영 요약")
                        .font(GonggiTypography.title(24))
                        .foregroundStyle(GonggiColors.textPrimary)

                    summaryRow(title: "촬영 품질", value: summary.qualityLabel, icon: "sparkles")
                    if !summary.captureId.isEmpty {
                        summaryRow(title: "Capture ID", value: summary.captureId, icon: "number")
                    }
                    summaryRow(
                        title: "공간 커버리지",
                        value: "\(summary.coveragePercent)%",
                        icon: "square.grid.3x3.fill"
                    )
                    summaryRow(
                        title: "촬영 시간",
                        value: formattedDuration(summary.duration),
                        icon: "clock"
                    )

                    if let w = summary.videoWidth, let h = summary.videoHeight, w > 0 {
                        summaryRow(
                            title: "영상 해상도",
                            value: "\(w)×\(h)",
                            icon: "video.fill"
                        )
                    }

                    summaryRow(
                        title: "평균 회전 속도",
                        value: String(format: "%.2f rad/s", summary.avgAngularVelocity),
                        icon: "rotate.3d"
                    )
                    summaryRow(
                        title: "최대 회전 속도",
                        value: String(format: "%.2f rad/s", summary.maxAngularVelocity),
                        icon: "gyroscope",
                        warning: summary.maxAngularVelocity > 1.2
                    )
                    summaryRow(
                        title: "빠른 이동 구간",
                        value: "\(summary.fastMotionSegments)개",
                        icon: "hare.fill",
                        warning: summary.fastMotionSegments > 0
                    )
                    summaryRow(
                        title: "추적 제한 시간",
                        value: formattedDuration(summary.trackingLimitedSec),
                        icon: "location.slash",
                        warning: summary.trackingLimitedSec > 3
                    )
                    summaryRow(
                        title: "충분 촬영 영역",
                        value: "\(summary.goodAreaCount)개",
                        icon: "checkmark.circle.fill"
                    )
                    summaryRow(
                        title: "보강 필요 영역",
                        value: "\(summary.insufficientAreaCount)개",
                        icon: "arrow.triangle.2.circlepath",
                        warning: summary.insufficientAreaCount > 0
                    )
                    summaryRow(
                        title: "재방문 점수",
                        value: percentString(summary.revisitScore),
                        icon: "arrow.2.squarepath"
                    )
                    summaryRow(
                        title: "각도 다양성",
                        value: percentString(summary.angleDiversityScore),
                        icon: "camera.metering.multispot"
                    )

                    if summary.lowTextureWarnings > 0 {
                        warningBanner
                    }

                    if summary.manifestURL != nil {
                        Text("촬영 데이터가 기기에 저장되었습니다. 업로드 전 외부로 전송되지 않습니다.")
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }

                    VStack(spacing: GonggiSpacing.sm) {
                        PrimaryButton(title: "이대로 공간 생성", icon: "cube.transparent") {
                            onCreateSpace()
                        }
                        SecondaryButton(title: "추가 촬영") {
                            onContinueCapture()
                        }
                        #if DEBUG
                        if summary.manifestURL != nil, !summary.captureId.isEmpty {
                            SecondaryButton(title: "촬영 데이터보내기 (Debug)", icon: "square.and.arrow.up") {
                                prepareExport()
                            }
                        }
                        if let exportError {
                            Text(exportError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
                        }
                        #endif
                    }
                    .padding(.top, GonggiSpacing.md)
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiColors.backgroundPrimary.ignoresSafeArea())
            #if DEBUG
            .sheet(isPresented: $showExportShare) {
                CaptureExportShareSheet(items: exportShareItems) {
                    showExportShare = false
                }
            }
            #endif
        }
    }

    #if DEBUG
    private func prepareExport() {
        exportError = nil
        do {
            let result = try CaptureSessionExporter.exportToDocuments(
                sessionId: summary.sessionId,
                captureId: summary.captureId
            )
            exportShareItems = CaptureSessionExporter.shareItems(from: result)
            showExportShare = true
        } catch {
            exportError = "보내기 실패: \(error.localizedDescription)"
        }
    }
    #endif

    private func summaryRow(
        title: String,
        value: String,
        icon: String,
        warning: Bool = false
    ) -> some View {
        GlassCard {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(warning ? GonggiColors.warning : GonggiColors.accentCyan)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textSecondary)
                    Text(value)
                        .font(GonggiTypography.headline(18))
                        .foregroundStyle(GonggiColors.textPrimary)
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: GonggiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GonggiColors.warning)
            Text("저텍스처 구간이 감지되었습니다. 생성 후 품질이 낮을 수 있습니다.")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        return m > 0 ? "\(m)분 \(s)초" : "\(s)초"
    }

    private func percentString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

#Preview {
    CaptureSummaryView(
        summary: CaptureSessionSummary(
            startedAt: Date().addingTimeInterval(-180),
            endedAt: Date(),
            quality: CaptureQualityState(
                overallCoverage: 0.86,
                motionSpeed: 0.3,
                angularVelocity: 0.25,
                blurScore: 0.8,
                exposureScore: 0.9,
                trackingQuality: 0.95,
                lowTextureScore: 0.2,
                overlapScore: 0.7,
                parallaxScore: 0.65,
                areas: []
            ),
            fastMotionSegments: 3,
            lowTextureWarnings: 0,
            areasNeedingRevisit: 2,
            suggestedName: "새 공간",
            avgAngularVelocity: 0.42,
            maxAngularVelocity: 1.1,
            trackingLimitedSec: 2.5,
            goodAreaCount: 5,
            insufficientAreaCount: 2,
            revisitScore: 0.55,
            angleDiversityScore: 0.62
        ),
        onContinueCapture: {},
        onCreateSpace: {}
    )
}

import SwiftUI

struct CaptureSummaryView: View {
    let summary: CaptureSessionSummary
    let onContinueCapture: () -> Void
    let onCreateSpace: () -> Void
    let onPreviewSpace: (() -> Void)?

    #if DEBUG
    @State private var showExportShare = false
    @State private var exportShareItems: [URL] = []
    @State private var exportError: String?
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    GonggiSummaryHero(
                        coveragePercent: summary.coveragePercent,
                        qualityLabel: summary.qualityLabel,
                        duration: formattedDuration(summary.duration)
                    )

                    Text("촬영 결과")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)

                    metricsGrid

                    if let report = summary.texturedMeshReport {
                        texturedMeshReportSection(report)
                    }

                    if summary.lowTextureWarnings > 0 {
                        warningBanner
                    }

                    if summary.manifestURL != nil {
                        Text("촬영 데이터는 기기에만 저장됩니다.")
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }

                    VStack(spacing: GonggiSpacing.sm) {
                        if summary.texturedSpaceURL != nil, onPreviewSpace != nil {
                            SecondaryButton(title: "공간 미리보기 (Experimental)", icon: "cube") {
                                onPreviewSpace?()
                            }
                        }
                        PrimaryButton(title: "이대로 공간 생성", icon: "cube.transparent") {
                            GonggiHaptics.success()
                            onCreateSpace()
                        }
                        SecondaryButton(title: "추가 촬영", icon: "camera") {
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
                    .padding(.top, GonggiSpacing.sm)
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("촬영 요약")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .sheet(isPresented: $showExportShare) {
                CaptureExportShareSheet(items: exportShareItems) {
                    showExportShare = false
                }
            }
            #endif
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: GonggiSpacing.sm
        ) {
            GonggiMetricTile(
                icon: "checkmark.circle.fill",
                title: "충분 촬영",
                value: "\(summary.goodAreaCount)개",
                accent: GonggiColors.successGreen
            )
            GonggiMetricTile(
                icon: "arrow.triangle.2.circlepath",
                title: "보강 필요",
                value: "\(summary.insufficientAreaCount)개",
                accent: GonggiColors.accentCyan,
                warning: summary.insufficientAreaCount > 0
            )
            GonggiMetricTile(
                icon: "hare.fill",
                title: "빠른 이동",
                value: "\(summary.fastMotionSegments)구간",
                warning: summary.fastMotionSegments > 0
            )
            GonggiMetricTile(
                icon: "location.slash",
                title: "추적 제한",
                value: formattedDuration(summary.trackingLimitedSec),
                warning: summary.trackingLimitedSec > 3
            )
            GonggiMetricTile(
                icon: "arrow.2.squarepath",
                title: "재방문",
                value: percentString(summary.revisitScore)
            )
            GonggiMetricTile(
                icon: "camera.metering.multispot",
                title: "각도 다양성",
                value: percentString(summary.angleDiversityScore)
            )
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

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: GonggiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GonggiColors.warning)
            Text("저텍스처 구간이 감지되었습니다. 생성 후 품질이 낮을 수 있습니다.")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.warning.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                .stroke(GonggiColors.warning.opacity(0.25), lineWidth: 1)
        )
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

    private func texturedMeshReportSection(_ report: TexturedMeshReport) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("Textured Mesh (Experimental)")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: GonggiSpacing.sm
            ) {
                GonggiMetricTile(icon: "point.3.connected.trianglepath.dotted", title: "Vertices", value: formatCount(report.vertexCount))
                GonggiMetricTile(icon: "triangle", title: "Triangles", value: formatCount(report.triangleCount))
                GonggiMetricTile(icon: "photo.on.rectangle", title: "Keyframes", value: "\(report.keyframeCount)")
                GonggiMetricTile(icon: "paintbrush.pointed", title: "Texture", value: "\(Int(report.texturedCoveragePercent.rounded()))%")
                GonggiMetricTile(icon: "clock", title: "Rebuild", value: String(format: "%.1fs", report.reconstructionTimeSec))
                GonggiMetricTile(icon: "doc", title: "Output", value: formatBytes(report.outputByteSize))
            }
        }
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

#Preview {
    CaptureSummaryView(
        summary: GonggiPreviewSamples.sampleSummary,
        onContinueCapture: {},
        onCreateSpace: {},
        onPreviewSpace: nil
    )
}

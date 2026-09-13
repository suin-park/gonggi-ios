import SwiftUI

struct CaptureSummaryView: View {
    let summary: CaptureSessionSummary
    let onContinueCapture: () -> Void
    let onCreateSpace: () -> Void
    let onPreviewSpace: (() -> Void)?

    @State private var showDiagShare = false
    @State private var diagShareItems: [URL] = []
    @State private var diagShareError: String?

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

                    #if DEBUG
                    if let df = summary.dataFoundation {
                        dataFoundationDebugSection(df)
                    }
                    #endif

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
                        if !summary.sessionId.isEmpty {
                            SecondaryButton(title: "촬영 진단 공유", icon: "square.and.arrow.up") {
                                prepareDiagnosticsShare()
                            }
                        }
                        if let diagShareError {
                            Text(diagShareError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
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
            .sheet(isPresented: $showDiagShare) {
                CaptureExportShareSheet(items: diagShareItems) {
                    showDiagShare = false
                }
            }
            #if DEBUG
            .sheet(isPresented: $showExportShare) {
                CaptureExportShareSheet(items: exportShareItems) {
                    showExportShare = false
                }
            }
            #endif
        }
    }

    private func prepareDiagnosticsShare() {
        diagShareError = nil
        do {
            let folder = try CaptureDiagnosticsStore.buildSharePackage(
                sessionId: summary.sessionId,
                captureId: summary.captureId.isEmpty ? summary.sessionId : summary.captureId,
                includeVideo: false
            )
            diagShareItems = [folder]
            showDiagShare = true
        } catch {
            diagShareError = "진단 공유 준비에 실패했어요."
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: GonggiSpacing.sm
        ) {
            GonggiMetricTile(
                icon: "square.3.layers.3d",
                title: "촬영 범위",
                value: CaptureUIPresenter.userGradeLabel("coverage", quality: summary.quality),
                accent: GonggiColors.successGreen
            )
            GonggiMetricTile(
                icon: "move.3d",
                title: "입체 정보",
                value: CaptureUIPresenter.userGradeLabel("baseline", quality: summary.quality),
                warning: summary.quality.translationBaselineGrade == .insufficient
            )
            GonggiMetricTile(
                icon: "link",
                title: "카메라 연결",
                value: CaptureUIPresenter.userGradeLabel("overlap", quality: summary.quality),
                warning: summary.quality.overlapState == .lost || summary.quality.overlapState == .weak
            )
            GonggiMetricTile(
                icon: "eye",
                title: "화면 선명도",
                value: CaptureUIPresenter.userGradeLabel("sharpness", quality: summary.quality),
                warning: summary.quality.sharpnessState == .blurry
            )
            GonggiMetricTile(
                icon: "location",
                title: "카메라 추적",
                value: CaptureUIPresenter.userGradeLabel("tracking", quality: summary.quality),
                warning: summary.quality.trackingQuality < 0.7
            )
            GonggiMetricTile(
                icon: "hare.fill",
                title: "빠른 이동",
                value: "\(summary.fastMotionSegments)구간",
                warning: summary.fastMotionSegments > 0
            )
        }
    }

    #if DEBUG
    private func dataFoundationDebugSection(_ df: CaptureDataFoundationSummary) -> some View {
        let duration = max(summary.duration, 0.001)
        let limitedFrac = min(1, summary.trackingLimitedSec / duration)
        let normalFrac = max(0, 1 - limitedFrac)
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("3DGS Data Foundation (DEBUG)")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            Group {
                Text(String(format: "duration %.1fs · schema v%d", duration, df.schemaVersion))
                Text("written \(df.videoFramesWritten) · poses \(df.poseSamples) · dropped \(df.droppedVideoFrames)")
                if let integ = df.integrity {
                    Text("MOV samples \(integ.movSamples) · PTS matched \(integ.ptsMatched) · mismatched \(integ.ptsMismatched)")
                    Text(String(format: "max PTS Δ %.6fs · integrity %@", integ.maxPTSDeltaSec, integ.passed ? "PASS" : "FAIL"))
                } else {
                    Text("MOV integrity: (release build skips reader)")
                }
                Text("keyframes \(df.keyframe3DGSCount) · depth \(df.depthSamples)")
                Text(String(format: "path %.2fm · max baseline %.2fm · grade %@", df.totalPathLengthM, df.maxBaselineM, df.translationBaselineGrade.rawValue))
                Text(String(format: "viewAngleDiv %.2f · tracking N %.0f%% L %.0f%%", df.viewAngleDiversity, normalFrac * 100, limitedFrac * 100))
                if let d = df.discontinuity {
                    Text(String(
                        format: "jumps %d · maxΔt %.2fm · maxΔr %.2frad · track transitions %d",
                        d.possiblePoseJumpCount,
                        d.maxFrameTranslationDeltaM,
                        d.maxFrameRotationDeltaRad,
                        d.trackingStateTransitions
                    ))
                }
                Text("overlap: \(df.overlapAvailable ? "yes" : "notAvailable") · sync SoT: videoPTS")
                Text(String(
                    format: "obsCov %.0f%% / qualCov %.0f%% / overlap %.2f (%@)",
                    df.observedCoverage * 100,
                    df.qualityCoverage * 100,
                    df.overlapScore,
                    df.overlapState.rawValue
                ))
                Text(String(
                    format: "sharp %@ / score %.2f / blurSamples %.0f%%",
                    df.sharpnessState.rawValue,
                    df.sharpnessScore,
                    df.sharpnessBlurryFraction * 100
                ))
                Text("action \(df.guidanceAction.rawValue) / phase \(df.capturePhase.rawValue) / completion \(df.completionState.rawValue)")
                if let note = df.orientationNote {
                    Text(note).lineLimit(3)
                }
            }
            .font(GonggiTypography.caption(12))
            .foregroundStyle(GonggiColors.textSecondary)

            if !df.cameraPathTopDown.isEmpty {
                cameraPathDebugView(df.cameraPathTopDown)
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func cameraPathDebugView(_ points: [CaptureVec3]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera path (top-down XZ)")
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textTertiary)
            Canvas { context, size in
                guard points.count >= 1 else { return }
                let xs = points.map(\.x)
                let zs = points.map(\.z)
                let minX = xs.min() ?? 0
                let maxX = xs.max() ?? 0
                let minZ = zs.min() ?? 0
                let maxZ = zs.max() ?? 0
                let spanX = max(0.05, maxX - minX)
                let spanZ = max(0.05, maxZ - minZ)
                let pad: CGFloat = 8
                func map(_ p: CaptureVec3) -> CGPoint {
                    let nx = CGFloat((p.x - minX) / spanX)
                    let nz = CGFloat((p.z - minZ) / spanZ)
                    return CGPoint(
                        x: pad + nx * (size.width - 2 * pad),
                        y: pad + nz * (size.height - 2 * pad)
                    )
                }
                var path = Path()
                for (i, p) in points.enumerated() {
                    let pt = map(p)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                context.stroke(path, with: .color(GonggiColors.accentCyan), lineWidth: 1.5)
                if let first = points.first {
                    let pt = map(first)
                    context.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)), with: .color(.green))
                }
                if let last = points.last, points.count > 1 {
                    let pt = map(last)
                    context.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)), with: .color(.orange))
                }
            }
            .frame(height: 120)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("START ● green → END ● orange · axes X horizontal, Z vertical")
                .font(GonggiTypography.caption(11))
                .foregroundStyle(GonggiColors.textTertiary)
        }
    }
    #endif

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

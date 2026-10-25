import SwiftUI

struct CaptureSummaryView: View {
    let summary: CaptureSessionSummary
    let onContinueCapture: () -> Void
    let onCreateSpace: () -> Void
    let onPreviewSpace: (() -> Void)?

    @State private var showDiagShare = false
    @State private var diagShareItems: [URL] = []
    @State private var diagShareError: String?
    @State private var showOriginalShare = false
    @State private var originalShareItems: [URL] = []
    @State private var originalShareError: String?
    @State private var isExportingOriginal = false

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
                        duration: formattedDuration(summary.duration),
                        captureFullyReady: summary.quality.completionState == .ready
                            && summary.quality.terminalContinuityOK,
                        candidateSafetyCapReached: summary.quality.candidateSafetyCapReached
                    )

                    Text(L("Capture result"))
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)

                    metricsGrid

                    if !summary.quality.captureRemaining.isEmpty {
                        remainingSection(summary.quality.captureRemaining)
                    }

                    // Engine diagnostics: internal testers only (TestFlight/DEBUG unlock), never general users.
                    if GonggiFeatureFlags.isInternalToolsUnlocked, let report = summary.texturedMeshReport {
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

                    if summary.manifestURL != nil, GonggiFeatureFlags.isInternalToolsUnlocked {
                        Text(L("Capture data is saved only on this device. Diagnostic sharing doesn't include original photos."))
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }

                    VStack(spacing: GonggiSpacing.sm) {
                        if summary.texturedSpaceURL != nil, onPreviewSpace != nil, GonggiFeatureFlags.isInternalToolsUnlocked {
                            SecondaryButton(title: L("Space preview (Experimental)"), icon: "cube") {
                                onPreviewSpace?()
                            }
                        }
                        let weakTerminal = !summary.quality.terminalContinuityOK
                            || summary.quality.completionState != .ready
                        PrimaryButton(
                            title: CaptureSummaryPresentation.createButtonTitle(weakTerminal: weakTerminal),
                            icon: "cube.transparent"
                        ) {
                            GonggiHaptics.success()
                            onCreateSpace()
                        }
                        if CaptureSummaryPresentation.shouldOfferContinueCapture(
                            candidateSafetyCapReached: summary.quality.candidateSafetyCapReached
                        ) {
                            SecondaryButton(
                                title: CaptureSummaryPresentation.continueButtonTitle(weakTerminal: weakTerminal),
                                icon: "camera"
                            ) {
                                onContinueCapture()
                            }
                        }
                        if !summary.sessionId.isEmpty, GonggiFeatureFlags.isInternalToolsUnlocked {
                            SecondaryButton(title: L("Share capture diagnostics (no photos)"), icon: "doc.text") {
                                prepareDiagnosticsShare()
                            }
                            SecondaryButton(
                                title: isExportingOriginal ? L("Preparing original package…") : L("Export original package"),
                                icon: "square.and.arrow.up"
                            ) {
                                prepareOriginalPackageShare()
                            }
                            .disabled(isExportingOriginal)
                        }
                        if let diagShareError {
                            Text(diagShareError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
                        }
                        if let originalShareError {
                            Text(originalShareError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
                        }
                        #if DEBUG
                        if summary.manifestURL != nil, !summary.captureId.isEmpty {
                            SecondaryButton(title: L("Export capture data (Debug)"), icon: "square.and.arrow.up") {
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
            .navigationTitle(L("Capture summary"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDiagShare) {
                CaptureExportShareSheet(items: diagShareItems) {
                    showDiagShare = false
                }
            }
            .sheet(isPresented: $showOriginalShare) {
                CaptureExportShareSheet(items: originalShareItems) {
                    showOriginalShare = false
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
            diagShareError = L("Couldn't prepare diagnostic sharing. (Original photos aren't included.)")
        }
    }

    private func prepareOriginalPackageShare() {
        originalShareError = nil
        isExportingOriginal = true
        let sessionId = summary.sessionId
        let captureId = summary.captureId.isEmpty ? summary.sessionId : summary.captureId
        Task {
            defer { isExportingOriginal = false }
            do {
                let folder = try await Task.detached(priority: .userInitiated) {
                    try CaptureDiagnosticsStore.buildFullSpatialPackageShare(
                        sessionId: sessionId,
                        captureId: captureId
                    )
                }.value
                originalShareItems = [folder]
                showOriginalShare = true
            } catch {
                originalShareError = L("Couldn't export the original package. Check that it's complete.")
            }
        }
    }

    /// Open items with their status (남음 / 미해결 / 사진 한도). Informational: finishing and creating are not blocked.
    private func remainingSection(_ items: [CaptureRemainingItem]) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text(CaptureSummaryPresentation.remainingHeader)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            ForEach(Array(CaptureSummaryPresentation.remainingRows(items).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: GonggiSpacing.sm) {
                    Text(row.status)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().stroke(GonggiColors.border, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(GonggiTypography.caption(14))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text(row.detail)
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(CaptureSummaryPresentation.remainingFootnote)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: GonggiSpacing.sm
        ) {
            GonggiMetricTile(
                icon: "square.3.layers.3d",
                title: L("Coverage"),
                value: CaptureUIPresenter.userGradeLabel("coverage", quality: summary.quality),
                accent: GonggiColors.successGreen
            )
            GonggiMetricTile(
                icon: "move.3d",
                title: L("Depth information"),
                value: CaptureUIPresenter.userGradeLabel("baseline", quality: summary.quality),
                warning: summary.quality.translationBaselineGrade == .insufficient
            )
            GonggiMetricTile(
                icon: "link",
                title: L("Camera connection"),
                value: CaptureUIPresenter.userGradeLabel("overlap", quality: summary.quality),
                warning: summary.quality.overlapState == .lost || summary.quality.overlapState == .weak
            )
            GonggiMetricTile(
                icon: "eye",
                title: L("Sharpness"),
                value: CaptureUIPresenter.userGradeLabel("sharpness", quality: summary.quality),
                warning: summary.quality.sharpnessState == .blurry
            )
            GonggiMetricTile(
                icon: "location",
                title: L("Camera tracking"),
                value: CaptureUIPresenter.userGradeLabel("tracking", quality: summary.quality),
                warning: summary.quality.trackingQuality < 0.7
            )
            GonggiMetricTile(
                icon: "hare.fill",
                title: L("Fast movement"),
                value: L("%@ sections", "\(summary.fastMotionSegments)"),
                warning: summary.fastMotionSegments > 0
            )
        }
    }

    #if DEBUG
    private func dataFoundationDebugSection(_ df: CaptureDataFoundationSummary) -> some View {
        let duration = max(summary.duration, 0.001)
        let limitedFrac = min(1, summary.trackingLimitedSec / duration)
        let normalFrac = max(0, 1 - limitedFrac)
        return VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("Capture Data Foundation (DEBUG)")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            Group {
                Text(String(format: "duration %.1fs, schema v%d", duration, df.schemaVersion))
                Text("written \(df.videoFramesWritten), poses \(df.poseSamples), dropped \(df.droppedVideoFrames)")
                if let integ = df.integrity {
                    Text("MOV samples \(integ.movSamples), PTS matched \(integ.ptsMatched), mismatched \(integ.ptsMismatched)")
                    Text(String(format: "max PTS Δ %.6fs, integrity %@", integ.maxPTSDeltaSec, integ.passed ? "PASS" : "FAIL"))
                } else {
                    Text("MOV integrity: (release build skips reader)")
                }
                Text("selected frames \(df.keyframe3DGSCount), depth \(df.depthSamples)")
                if let pkg = df.spatialCapturePackageURL {
                    Text("package \(pkg.lastPathComponent), valid \(df.spatialCapturePackageValid == true ? "yes" : "no")")
                }
                Text(String(format: "path %.2fm, max baseline %.2fm, grade %@", df.totalPathLengthM, df.maxBaselineM, df.translationBaselineGrade.rawValue))
                Text(String(format: "viewAngleDiv %.2f, tracking N %.0f%% L %.0f%%", df.viewAngleDiversity, normalFrac * 100, limitedFrac * 100))
                if let d = df.discontinuity {
                    Text(String(
                        format: "jumps %d, maxΔt %.2fm, maxΔr %.2frad, track transitions %d",
                        d.possiblePoseJumpCount,
                        d.maxFrameTranslationDeltaM,
                        d.maxFrameRotationDeltaRad,
                        d.trackingStateTransitions
                    ))
                }
                Text("overlap: \(df.overlapAvailable ? "yes" : "notAvailable"), sync SoT: videoPTS")
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
            Text("START ● green → END ● orange, axes X horizontal, Z vertical")
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
            exportError = L("Export failed: %@", "\(error.localizedDescription)")
        }
    }
    #endif

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: GonggiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GonggiColors.warning)
            Text(L("Low-texture areas were detected. The result may be lower quality."))
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
        return m > 0 ? L("%1$@ min %2$@ s", "\(m)", "\(s)") : L("%@ s", "\(s)")
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

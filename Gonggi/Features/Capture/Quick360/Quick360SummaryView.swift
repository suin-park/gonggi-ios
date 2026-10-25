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

                    Text(L("Space capture result"))
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)

                    if let report = summary.report {
                        reportGrid(report)
                    }

                    Text(L("Panorama and floor data are saved only on this device."))
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textTertiary)

                    if Quick360Config.testFlightABCompareEnabled || hasABArtifacts {
                        Text(L("This build shows the Legacy result and also saves OpenCV A/B output from the same session."))
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }

                    VStack(spacing: GonggiSpacing.sm) {
                        PrimaryButton(title: L("360° space preview (Legacy)"), icon: "globe") {
                            openPanoramaPreview(url: summary.panoramaURL)
                        }
                        if hasOpenCVPanorama {
                            SecondaryButton(title: L("OpenCV panorama preview"), icon: "eye") {
                                openPanoramaPreview(
                                    url: PanoramaABPaths.openCVPanoramaURL(sessionId: summary.sessionId)
                                )
                            }
                        } else if Quick360Config.testFlightABCompareEnabled || hasABArtifacts {
                            Text(L("OpenCV reconstruction failed — the Legacy preview is kept."))
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if hasABArtifacts {
                            SecondaryButton(title: L("Share A/B results"), icon: "square.and.arrow.up") {
                                shareABArtifacts()
                            }
                        }
                        SecondaryButton(title: L("Capture again"), icon: "arrow.counterclockwise") {
                            onRetry()
                        }
                    }
                }
                .padding(GonggiSpacing.lg)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle(L("Space capture summary"))
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
            .alert(L("Can't open the preview"), isPresented: Binding(
                get: { previewError != nil },
                set: { if !$0 { previewError = nil } }
            )) {
                Button(L("OK"), role: .cancel) { previewError = nil }
            } message: {
                Text(previewError ?? "")
            }
            .alert(L("Share A/B"), isPresented: Binding(
                get: { abShareError != nil },
                set: { if !$0 { abShareError = nil } }
            )) {
                Button(L("OK"), role: .cancel) { abShareError = nil }
            } message: {
                Text(abShareError ?? "")
            }
        }
    }

    private func openPanoramaPreview(url: URL?) {
        GonggiHaptics.light()
        guard let url else {
            previewError = L("The panorama file is missing. Please capture again.")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            previewError = L("Couldn't find the panorama file.")
            return
        }
        guard UIImage(contentsOfFile: url.path) != nil else {
            previewError = L("Couldn't load the panorama image.")
            return
        }
        viewerURL = url
        showPanoramaViewer = true
    }

    private func shareABArtifacts() {
        GonggiHaptics.light()
        let urls = PanoramaABPaths.shareableArtifactURLs(sessionId: summary.sessionId)
        guard !urls.isEmpty else {
            abShareError = L("No A/B output yet. Finish the capture and try again.")
            return
        }
        abShareItems = urls
        showABShare = true
    }

    private var qualityLabel: String {
        guard let report = summary.report else { return L("Captured") }
        if report.overallSphericalCoveragePercent >= 62
            || report.sphereCoveragePercent >= 55
            || report.coveragePercent >= 75 {
            return L("Good")
        }
        if report.overallSphericalCoveragePercent >= 40
            || report.sphereCoveragePercent >= 35
            || report.coveragePercent >= 50 {
            return L("Fair")
        }
        return L("Needs more")
    }

    private func reportGrid(_ report: Quick360PanoramaReport) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: GonggiSpacing.sm) {
            metric(L("Full coverage"), String(format: "%.0f%%", report.overallSphericalCoveragePercent))
            metric(L("Horizontal"), String(format: "%.0f%%", report.horizontalCoveragePercent))
            metric(L("Up"), String(format: "%.0f%%", report.upperCoveragePercent))
            metric(L("Down"), String(format: "%.0f%%", report.lowerCoveragePercent))
            metric(L("Ceiling"), String(format: "%.0f%%", report.zenithCoveragePercent))
            metric(L("Floor (sphere)"), String(format: "%.0f%%", report.nadirCoveragePercent))
            metric(L("Panorama"), String(format: "%.1f%%", report.coveragePercent))
            metric(L("Resolution"), "\(report.outputWidth)×\(report.outputHeight)")
            metric(L("Keyframes"), "\(report.acceptedKeyframeCount)/\(report.selectedKeyframeCount)")
            metric(L("Alignment correction"), "\(report.successfulRefinements)/\(report.visualRefinementAttempts)")
            metric(L("Capture time"), String(format: "%.0fs", report.captureDurationSec))
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
        return m > 0 ? L("%1$@ min %2$@ s", "\(m)", "\(s)") : L("%@ s", "\(s)")
    }
}

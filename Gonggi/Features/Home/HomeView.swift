import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSpace: SpaceRecord?
    @State private var viewerSession: SpaceViewerSession?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?

    private var recentSpace: SpaceRecord? {
        appState.spaces.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                    GonggiBrandMark()
                    heroSection
                    if let recent = recentSpace {
                        recentSection(recent)
                    }
                    actions
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedSpace) { space in
                SpaceDetailView(space: space)
            }
            .fullScreenCover(item: $viewerSession) { session in
                VRSphereSpaceView(
                    imageURL: session.fileURL,
                    sessionId: session.id,
                    onClose: { viewerSession = nil }
                )
            }
            .overlay {
                if isPreparingViewer {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                    }
                }
            }
            .alert("공간을 불러오지 못했어요", isPresented: Binding(
                get: { viewerError != nil || appState.pendingViewerError != nil },
                set: {
                    if !$0 {
                        viewerError = nil
                        appState.pendingViewerError = nil
                    }
                }
            )) {
                Button("다시 불러오기") {
                    if let id = appState.pendingViewerJobId ?? selectedSpace?.id ?? recentSpace?.id {
                        Task { await openViewer(jobId: id) }
                    }
                }
                Button("닫기", role: .cancel) {
                    viewerError = nil
                    appState.pendingViewerError = nil
                }
            } message: {
                Text(viewerError ?? appState.pendingViewerError ?? "")
            }
            .onChange(of: appState.pendingViewerJobId) { _, jobId in
                guard let jobId else { return }
                Task {
                    await openViewer(jobId: jobId)
                    appState.pendingViewerJobId = nil
                }
            }
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(GonggiColors.heroGradient)
                .frame(height: 200)
            PortalIllustration()
                .padding(GonggiSpacing.lg)
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            Text("소중한 공간을\n오래도록 기억하세요")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.92))
                .padding(GonggiSpacing.lg)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("공간을 기록하는 일러스트")
    }

    private func recentSection(_ space: SpaceRecord) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("최근 기록한 공간")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            Button {
                handleSpaceTap(space)
            } label: {
                HStack(spacing: GonggiSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                            .fill(GonggiColors.surface)
                            .frame(width: 56, height: 56)
                        if space.showsActivityIndicator {
                            ProgressView()
                                .tint(GonggiColors.accentTeal)
                        } else {
                            Image(systemName: space.thumbnailSystemImage)
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(GonggiColors.accentTeal)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name)
                            .font(GonggiTypography.headline(16))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text(space.note ?? space.statusBadgeLabel)
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(
                                space.repairBadge == .repairFailed || space.status == .failed
                                    ? GonggiColors.error
                                    : GonggiColors.textTertiary
                            )
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
                .padding(GonggiSpacing.md)
                .background(GonggiColors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                        .stroke(GonggiColors.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            }
            .buttonStyle(GonggiPressableStyle())
        }
    }

    private func handleSpaceTap(_ space: SpaceRecord) {
        switch SpaceCardTapPolicy.action(for: space.status) {
        case .openViewer:
            // Includes repairing / repaired / repairFailed overlays — open latest successful revision.
            Task { await openViewer(jobId: space.id) }
        case .openDetail:
            // Failed: detail only — never auto-regenerate (explicit “다시 시도” only).
            selectedSpace = space
        case .ignore:
            selectedSpace = space
        }
    }

    private func openViewer(jobId: String) async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        let result = await appState.prepareSpaceViewer(jobId: jobId)
        switch result {
        case .success(let url):
            viewerSession = SpaceViewerSession(id: jobId, fileURL: url)
        case .failure(let error):
            viewerError = error.userMessage
        }
    }

    private var actions: some View {
        VStack(spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "새 공간 기록하기", icon: "camera.aperture") {
                appState.selectTab(.record)
            }
            SecondaryButton(title: "보관함 보기", icon: "archivebox") {
                appState.selectTab(.library)
            }
        }
    }
}

private struct PortalIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GonggiColors.accentCyan.opacity(glow ? 0.32 : 0.22),
                                GonggiColors.accentTeal.opacity(0.06),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: min(w, h) * 0.48
                        )
                    )
                    .frame(width: w * 0.75, height: w * 0.75)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(GonggiColors.accentCyan.opacity(0.4), lineWidth: 1.5)
                    .frame(width: w * 0.38, height: h * 0.52)
                    .rotationEffect(.degrees(-6))
                Image(systemName: "cube.transparent")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(GonggiColors.textPrimary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState(isMockMode: true))
}

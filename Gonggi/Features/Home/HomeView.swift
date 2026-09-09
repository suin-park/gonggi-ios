import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSpace: SpaceRecord?
    @State private var viewerLaunch: SpaceViewerLaunch?
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
            .fullScreenCover(item: $viewerLaunch) { launch in
                SpaceVRNavigationHost(
                    sessions: launch.sessions,
                    onClose: { viewerLaunch = nil }
                )
            }
            .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
                viewerLaunch = nil
                selectedSpace = nil
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
            .onChange(of: appState.pendingViewerLaunch) { _, launch in
                guard let launch else { return }
                viewerLaunch = launch
                appState.pendingViewerLaunch = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
                let sessionId = note.userInfo?["sessionId"] as? String
                let jobId = note.userInfo?["jobId"] as? String
                guard let launch = viewerLaunch else { return }
                let hit = launch.sessions.contains {
                    $0.id == sessionId || $0.id == jobId
                }
                if hit {
                    viewerLaunch = nil
                }
                if selectedSpace?.id == jobId || selectedSpace?.sessionId == sessionId {
                    selectedSpace = nil
                }
            }
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(GonggiColors.heroGradient)
                .frame(height: 220)
            HStack {
                Spacer(minLength: 0)
                GonggiWireframeSphereView(diameter: 148, isAnimating: true)
                    .opacity(0.9)
                    .padding(.trailing, GonggiSpacing.md)
            }
            .padding(.top, GonggiSpacing.sm)
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            Text(GonggiBrandCopy.welcomeHeadline)
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.94))
                .padding(GonggiSpacing.lg)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("공간을 다시 둘러보는 소개")
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
                    SpaceThumbnailView(
                        space: space,
                        height: 56,
                        width: 56,
                        cornerRadius: GonggiRadius.sm,
                        showsActivityOverlay: true
                    )
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
        // Build 79: home recent card → Detail (manage). Viewer via Library “공간 보기”.
        selectedSpace = space
    }

    private func openViewer(jobId: String) async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        let result = await appState.prepareSpaceViewer(jobId: jobId)
        switch result {
        case .success(let url):
            viewerLaunch = SpaceViewerLaunch(
                single: SpaceViewerSession(
                    id: jobId,
                    fileURL: url,
                    audioURL: AppState.preferredAudioURL(for: jobId)
                )
            )
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

#Preview {
    HomeView()
        .environmentObject(AppState(isMockMode: true))
}

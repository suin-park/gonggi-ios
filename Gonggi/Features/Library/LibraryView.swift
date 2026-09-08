import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var assetStore = AssetLibraryStore.shared
    @State private var category: LibraryCategory = .spaces
    @State private var selectedSpace: SpaceRecord?
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?
    @State private var retryJobId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    categoryPicker
                    if category == .spaces {
                        spacesHeader
                        LazyVStack(spacing: GonggiSpacing.md) {
                            ForEach(appState.spaces) { space in
                                MemoryArchiveCard(
                                    space: space,
                                    onOpenDetail: {
                                        selectedSpace = space
                                    },
                                    onViewSpace: {
                                        Task { await openViewer(jobId: space.id) }
                                    }
                                )
                            }
                        }
                    } else {
                        AssetLibraryView(store: assetStore)
                    }
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("보관함")
            .navigationBarTitleDisplayMode(.large)
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
                        ProgressView().tint(.white).scaleEffect(1.2)
                    }
                }
            }
            .alert("공간을 불러오지 못했어요", isPresented: Binding(
                get: { viewerError != nil },
                set: { if !$0 { viewerError = nil } }
            )) {
                Button("다시 불러오기") {
                    if let id = retryJobId {
                        Task { await openViewer(jobId: id) }
                    }
                }
                Button("닫기", role: .cancel) { viewerError = nil }
            } message: {
                Text(viewerError ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
                let sessionId = note.userInfo?["sessionId"] as? String
                let jobId = note.userInfo?["jobId"] as? String
                if let launch = viewerLaunch,
                   launch.sessions.contains(where: { $0.id == sessionId || $0.id == jobId }) {
                    viewerLaunch = nil
                }
                if selectedSpace?.id == jobId || selectedSpace?.sessionId == sessionId {
                    selectedSpace = nil
                }
            }
            .onAppear {
                appState.ensureSpaceGenerationPolling()
            }
        }
    }

    private var categoryPicker: some View {
        Picker("보관함 분류", selection: $category) {
            ForEach(LibraryCategory.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
    }

    private func handleOpen(_ space: SpaceRecord) {
        selectedSpace = space
    }

    private func openViewer(jobId: String) async {
        retryJobId = jobId
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        switch await appState.prepareSpaceViewer(jobId: jobId) {
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

    private var spacesHeader: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("기억의 아카이브")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentTeal)
            Text("기록한 공간을\n다시 방문해보세요")
                .font(GonggiTypography.headline(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .lineSpacing(2)
        }
        .padding(.bottom, GonggiSpacing.xs)
    }
}

#Preview {
    LibraryView()
        .environmentObject(AppState(isMockMode: true))
}

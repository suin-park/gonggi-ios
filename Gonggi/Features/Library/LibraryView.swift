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
    @State private var showImportSheet = false
    @State private var gaussianViewerSpaceId: String?
    @State private var showGaussianViewer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    categoryPicker
                    if category == .spaces {
                        if appState.spaces.isEmpty {
                            Text("아직 만든 공간이 없어요.")
                                .font(GonggiTypography.body(15))
                                .foregroundStyle(GonggiColors.textSecondary)
                                .padding(.top, GonggiSpacing.sm)
                            Button {
                                showImportSheet = true
                            } label: {
                                Label("외부에서 가져오기", systemImage: "square.and.arrow.down")
                            }
                            .padding(.top, GonggiSpacing.sm)
                        } else {
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
                        }
                    } else {
                        AssetLibraryView(store: assetStore)
                    }
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground())
            .navigationTitle("공간 관리")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if category == .spaces {
                        Button {
                            showImportSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("외부에서 가져오기")
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                SpaceImportSheet(
                    onImported: { jobId in
                        Task { await openViewer(jobId: jobId) }
                    },
                    onGaussianImported: { spaceId in
                        gaussianViewerSpaceId = spaceId
                        showGaussianViewer = true
                    }
                )
                .environmentObject(appState)
            }
            .fullScreenCover(isPresented: $showGaussianViewer) {
                if let spaceId = gaussianViewerSpaceId {
                    GaussianSplatWebViewer(spaceId: spaceId) {
                        showGaussianViewer = false
                        gaussianViewerSpaceId = nil
                    }
                }
            }
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
            .onChange(of: appState.preferredLibraryCategory) { _, category in
                guard let category else { return }
                self.category = category
                appState.preferredLibraryCategory = nil
            }
            .onChange(of: appState.libraryRefreshEpoch) { _, _ in
                category = .spaces
                appState.ensureSpaceGenerationPolling()
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
        Picker("분류", selection: $category) {
            ForEach(LibraryCategory.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
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
                    audioURL: AppState.preferredAudioURL(for: jobId),
                    videoURL: AppState.preferredVideoURL(for: jobId)
                )
            )
        case .failure(let error):
            viewerError = error.userMessage
        }
    }

}

#Preview {
    LibraryView()
        .environmentObject(AppState(isMockMode: true))
}

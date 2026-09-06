import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSpace: SpaceRecord?
    @State private var viewerSession: SpaceViewerSession?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?
    @State private var retryJobId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    header
                    LazyVStack(spacing: GonggiSpacing.md) {
                        ForEach(appState.spaces) { space in
                            MemoryArchiveCard(space: space) {
                                handleOpen(space)
                            }
                        }
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
            .fullScreenCover(item: $viewerSession) { session in
                VRSphereSpaceView(imageURL: session.fileURL, onClose: { viewerSession = nil })
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
        }
    }

    private func handleOpen(_ space: SpaceRecord) {
        switch space.status {
        case .failed:
            appState.retrySpaceGeneration(jobId: space.id)
        case .ready:
            Task { await openViewer(jobId: space.id) }
        default:
            selectedSpace = space
        }
    }

    private func openViewer(jobId: String) async {
        retryJobId = jobId
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        switch await appState.prepareSpaceViewer(jobId: jobId) {
        case .success(let url):
            viewerSession = SpaceViewerSession(id: jobId, fileURL: url)
        case .failure(let error):
            viewerError = error.userMessage
        }
    }

    private var header: some View {
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

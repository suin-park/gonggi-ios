import SwiftUI
import WebKit

struct SpaceDetailView: View {
    @EnvironmentObject private var appState: AppState
    let space: SpaceRecord
    @State private var showViewer = false
    @State private var showDeleteConfirm = false
    @State private var viewerSession: SpaceViewerSession?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?
    @State private var showAddObjectSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                heroSection
                metaSection
                if let note = space.note {
                    memoryNoteSection(note)
                }
                actionsSection
            }
            .padding(GonggiSpacing.lg)
            .padding(.bottom, GonggiSpacing.xxl)
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showViewer) {
            ViewerPlaceholderView(space: space)
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
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
            }
        }
        .alert("공간을 불러오지 못했어요", isPresented: Binding(
            get: { viewerError != nil },
            set: { if !$0 { viewerError = nil } }
        )) {
            Button("다시 불러오기") {
                Task { await openViewer() }
            }
            Button("닫기", role: .cancel) { viewerError = nil }
        } message: {
            Text(viewerError ?? "")
        }
        .alert("공간을 삭제할까요?", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {}
            Button("취소", role: .cancel) {}
        } message: {
            Text("삭제된 공간은 복구할 수 없습니다.")
        }
        .sheet(isPresented: $showAddObjectSheet) {
            AddObjectToSpaceSheet(onClose: { showAddObjectSheet = false })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            GonggiColors.backgroundElevated,
                            GonggiColors.surface,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 240)
            RadialGradient(
                colors: [GonggiColors.accentTeal.opacity(0.25), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 200
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            Image(systemName: space.thumbnailSystemImage)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            statusBadge
                .padding(GonggiSpacing.md)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("\(space.name) 미리보기")
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text(space.name)
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Label(
                space.capturedAt.formatted(date: .long, time: .shortened),
                systemImage: "calendar"
            )
            .font(GonggiTypography.caption(14))
            .foregroundStyle(GonggiColors.textSecondary)
        }
    }

    private func memoryNoteSection(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("기억 메모")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            GonggiElevatedCard {
                Text(note)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: GonggiSpacing.sm) {
            switch space.status {
            case .ready:
                PrimaryButton(title: "다시 들어가기", icon: "cube.transparent") {
                    GonggiHaptics.light()
                    Task { await openViewer() }
                }
                SecondaryButton(title: "3D 오브젝트 추가", icon: "square.stack.3d.up") {
                    GonggiHaptics.light()
                    showAddObjectSheet = true
                }
            case .failed:
                PrimaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                    GonggiHaptics.medium()
                    appState.retrySpaceGeneration(jobId: space.id)
                }
            case .processing, .uploading:
                GonggiElevatedCard {
                    HStack(spacing: GonggiSpacing.md) {
                        ProgressView()
                            .tint(GonggiColors.accentTeal)
                        Text(space.note ?? "공간을 만들고 있어요")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .draft:
                PrimaryButton(title: "이어서 보기", icon: "cube.transparent") {
                    showViewer = true
                }
            }
            HStack(spacing: GonggiSpacing.sm) {
                SecondaryButton(title: "공유", icon: "square.and.arrow.up") {}
                SecondaryButton(title: "삭제", icon: "trash") {
                    showDeleteConfirm = true
                }
            }
        }
        .padding(.top, GonggiSpacing.xs)
    }

    private func openViewer() async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        switch await appState.prepareSpaceViewer(jobId: space.id) {
        case .success(let url):
            viewerSession = SpaceViewerSession(id: space.id, fileURL: url)
        case .failure(let error):
            viewerError = error.userMessage
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(GonggiColors.statusColor(forBadge: space.repairBadge, fallback: space.status))
                .frame(width: 7, height: 7)
            Text(space.statusBadgeLabel)
        }
        .font(GonggiTypography.caption(13))
        .foregroundStyle(GonggiColors.statusColor(forBadge: space.repairBadge, fallback: space.status))
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, GonggiSpacing.xs)
        .background(GonggiColors.backgroundPrimary.opacity(0.65))
        .clipShape(Capsule())
    }
}

/// Space → place 3D object navigation shell (picker / create wired in later phases).
struct AddObjectToSpaceSheet: View {
    var onClose: () -> Void
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                Text("3D 오브젝트 추가")
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("이 공간에 배치할 어셋을 고르거나 새로 만들 수 있어요.")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)

                optionRow(
                    title: "내 3D 어셋",
                    subtitle: "3D Locker에 있는 어셋에서 선택",
                    icon: "square.grid.2x2"
                ) {
                    // Phase D: asset picker linked to Locker library.
                }
                optionRow(
                    title: "새로 만들기",
                    subtitle: "사진으로 3D 어셋 생성 후 배치",
                    icon: "plus.circle"
                ) {
                    showCreate = true
                }
                Spacer()
            }
            .padding(GonggiSpacing.lg)
            .background(GonggiAmbientBackground(showGlow: false))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateAssetFlowView(onClose: { showCreate = false })
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func optionRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            HStack(spacing: GonggiSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(GonggiColors.accentTeal)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(subtitle)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(GonggiSpacing.md)
            .background(GonggiColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ViewerPlaceholderView: View {
    let space: SpaceRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = space.viewerURL {
                    WebView(url: url)
                } else {
                    VStack(spacing: GonggiSpacing.lg) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 56, weight: .ultraLight))
                            .foregroundStyle(GonggiColors.accentTeal)
                        Text("3D 공간 뷰어")
                            .font(GonggiTypography.headline(20))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text("곧 이곳에서 기록한 공간을\n다시 걸어 다닐 수 있어요.")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                    .padding(GonggiSpacing.xl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    NavigationStack {
        SpaceDetailView(space: SpaceRecord.sampleArchive[0])
            .environmentObject(AppState(isMockMode: true))
    }
}

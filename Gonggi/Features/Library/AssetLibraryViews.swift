import SceneKit
import SwiftUI

/// Library tab: canonical 3D Locker assets via `GET /api/mobile/assets` (Phase 1).
struct AssetLibraryView: View {
    @ObservedObject var store: AssetLibraryStore
    @State private var selectedAsset: MobileAssetDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            header
            content
        }
        .navigationDestination(item: $selectedAsset) { asset in
            AssetDetailView(listSnapshot: asset)
        }
        .task {
            if store.phase == .idle || store.phase == .failed {
                store.refresh()
            }
        }
        .refreshable {
            await store.performRefresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("3D 어셋")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentTeal)
            Text("3D Locker의 3D 어셋을\n한곳에서 관리해요")
                .font(GonggiTypography.headline(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .lineSpacing(2)
            if store.mayBeTruncated {
                Text("최근 \(AssetLibraryStore.knownServerTakeLimit)개까지 표시돼요")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            loadingState
        case .failed:
            errorState
        case .loaded:
            if store.isTrueEmpty {
                emptyState
            } else {
                assetList
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: GonggiSpacing.md) {
            ProgressView()
                .tint(GonggiColors.accentTeal)
            Text("3D 어셋을 불러오는 중…")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, GonggiSpacing.xxl)
    }

    private var emptyState: some View {
        VStack(spacing: GonggiSpacing.lg) {
            Spacer(minLength: 40)
            Image(systemName: "cube.transparent")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(GonggiColors.accentTeal.opacity(0.8))
                .accessibilityHidden(true)
            Text("아직 3D 어셋이 없어요")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("3D Locker에서 만든 어셋이 여기에 표시됩니다.")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: GonggiSpacing.lg) {
            Spacer(minLength: 40)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityHidden(true)
            Text(store.errorMessage ?? "3D 어셋을 불러오지 못했어요")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
            Button {
                GonggiHaptics.light()
                store.refresh(force: true)
            } label: {
                Text("다시 시도")
                    .font(GonggiTypography.body(16))
                    .fontWeight(.semibold)
                    .foregroundStyle(GonggiColors.accentTeal)
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var assetList: some View {
        LazyVStack(spacing: GonggiSpacing.md) {
            ForEach(store.assets) { asset in
                Button {
                    GonggiHaptics.light()
                    selectedAsset = asset
                } label: {
                    assetCard(asset)
                }
                .buttonStyle(GonggiPressableStyle())
                .accessibilityLabel("\(asset.name), 3D 어셋 상세 보기")
                .accessibilityHint(asset.libraryStatus.label)
            }
        }
    }

    private func assetCard(_ asset: MobileAssetDTO) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            AssetThumbnailView(urlString: asset.thumbUrl, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name)
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .lineLimit(2)
                Text(asset.libraryStatus.label)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textSecondary)
                if let date = asset.parsedCreatedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(GonggiTypography.caption(11))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(GonggiColors.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

// MARK: - Detail

struct AssetDetailView: View {
    let listSnapshot: MobileAssetDTO

    @EnvironmentObject private var appState: AppState
    @State private var detail: MobileAssetDTO?
    @State private var loadError: String?
    @State private var isLoadingDetail = false
    @State private var showSpacePicker = false
    @State private var isLaunchingPlacement = false
    @State private var placementMessage: String?
    @State private var viewerLaunch: SpaceViewerLaunch?

    private var asset: MobileAssetDTO { detail ?? listSnapshot }
    private var canPlace: Bool {
        asset.availableForPlacement && !(asset.usdzUrl ?? "").isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                previewBlock
                Text(asset.name)
                    .font(GonggiTypography.title(24))
                    .foregroundStyle(GonggiColors.textPrimary)
                metaRows
                placeSection
                if let loadError {
                    Text(loadError)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.error)
                }
            }
            .padding(GonggiSpacing.lg)
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("3D 어셋")
        .task { await loadDetail() }
        .sheet(isPresented: $showSpacePicker) {
            PlaceAssetSpacePickerView(
                spaces: appState.spaces,
                onSelect: { space in
                    showSpacePicker = false
                    Task { await placeIntoSpace(space) }
                },
                onClose: { showSpacePicker = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $viewerLaunch) { launch in
            SpaceVRNavigationHost(
                sessions: launch.sessions,
                onClose: { viewerLaunch = nil }
            )
            .environmentObject(appState)
        }
        .overlay {
            if isLaunchingPlacement {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
            }
        }
        .alert("배치할 수 없어요", isPresented: Binding(
            get: { placementMessage != nil },
            set: { if !$0 { placementMessage = nil } }
        )) {
            Button("확인", role: .cancel) { placementMessage = nil }
        } message: {
            Text(placementMessage ?? "")
        }
    }

    @ViewBuilder
    private var previewBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(GonggiColors.surface)
                .frame(height: 260)
            if asset.canPreviewUSDZ, let urlString = asset.usdzUrl, let url = URL(string: urlString) {
                AssetUSDZPreviewHost(assetId: asset.id, remoteURL: url)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
                    .frame(height: 260)
            } else {
                AssetThumbnailView(urlString: asset.thumbUrl, size: 120)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }

    private var metaRows: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            metaRow(title: "상태", value: asset.libraryStatus.label)
            if let date = asset.parsedCreatedAt {
                metaRow(
                    title: "생성일",
                    value: date.formatted(date: .long, time: .shortened)
                )
            }
            metaRow(
                title: "3D (GLB)",
                value: !(asset.glbKey ?? "").isEmpty ? "준비됨" : "없음"
            )
            metaRow(
                title: "AR (USDZ)",
                value: usdzStatusLabel(asset.usdzStatus)
            )
            metaRow(
                title: "공간 배치",
                value: canPlace ? "가능" : (asset.placementUnavailableReason ?? "USDZ 준비 후 가능")
            )
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private var placeSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "공간에 배치", icon: "square.stack.3d.up") {
                GonggiHaptics.light()
                showSpacePicker = true
            }
            .disabled(!canPlace || isLaunchingPlacement)
            .opacity(canPlace ? 1 : 0.45)
            .accessibilityLabel("공간에 배치")
            .accessibilityHint(canPlace ? "배치할 공간을 선택합니다" : (asset.placementUnavailableReason ?? ""))

            if let reason = asset.placementUnavailableReason {
                Text(reason)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            } else {
                Text("AR/배치 준비가 완료된 어셋만 사용할 수 있어요")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
        }
    }

    private func metaRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func usdzStatusLabel(_ raw: String?) -> String {
        switch (raw ?? "NONE").uppercased() {
        case "READY": return "READY"
        case "PROCESSING": return "PROCESSING"
        case "FAILED": return "FAILED"
        default: return "NONE"
        }
    }

    private func placeIntoSpace(_ space: SpaceRecord) async {
        isLaunchingPlacement = true
        defer { isLaunchingPlacement = false }
        if let block = await AssetPlacementLaunch.open(
            space: space,
            asset: asset,
            source: .assetDetail,
            appState: appState,
            present: { launch in
                viewerLaunch = launch
            }
        ) {
            placementMessage = block.userMessage
        }
    }

    private func loadDetail() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let fresh = try await MobileAssetsAPIClient().fetchAsset(id: listSnapshot.id)
            detail = fresh
            loadError = nil
        } catch let error as MobileAssetsAPIError {
            if case .server(let status) = error, status == 401 {
                loadError = "로그인이 필요해요"
            } else if case .server(let status) = error, status == 404 {
                loadError = "3D 어셋 정보를 불러오지 못했어요"
            } else {
                loadError = "3D 어셋 정보를 불러오지 못했어요"
            }
        } catch {
            loadError = "3D 어셋 정보를 불러오지 못했어요"
        }
    }
}

// MARK: - Thumbnail

struct AssetThumbnailView: View {
    let urlString: String?
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                .fill(GonggiColors.surface)
                .frame(width: size, height: size)
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholderIcon
                    case .empty:
                        ProgressView()
                            .scaleEffect(0.8)
                    @unknown default:
                        placeholderIcon
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
                .accessibilityHidden(true)
            } else {
                placeholderIcon
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }

    private var placeholderIcon: some View {
        Image(systemName: "cube.transparent")
            .font(.system(size: size * 0.35, weight: .light))
            .foregroundStyle(GonggiColors.accentTeal)
    }
}

// MARK: - USDZ SceneKit preview (reuses VRUsdzCache)

struct AssetUSDZPreviewHost: View {
    let assetId: String
    let remoteURL: URL

    @State private var localURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let localURL {
                AssetSceneKitPreviewRepresentable(modelURL: localURL)
            } else if failed {
                AssetThumbnailView(urlString: nil, size: 80)
            } else {
                ProgressView()
                    .tint(GonggiColors.accentTeal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let cached = await VRUsdzCache().localURL(assetId: assetId, remoteURL: remoteURL)
            if let cached {
                localURL = cached
            } else {
                failed = true
            }
        }
    }
}

struct AssetSceneKitPreviewRepresentable: UIViewRepresentable {
    let modelURL: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        if let scene = try? SCNScene(url: modelURL, options: nil) {
            view.scene = scene
            view.pointOfView = makeCamera(for: scene)
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func makeCamera(for scene: SCNScene) -> SCNNode {
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        let (minVec, maxVec) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (minVec.x + maxVec.x) * 0.5,
            (minVec.y + maxVec.y) * 0.5,
            (minVec.z + maxVec.z) * 0.5
        )
        let extent = max(maxVec.x - minVec.x, max(maxVec.y - minVec.y, maxVec.z - minVec.z))
        camera.position = SCNVector3(center.x, center.y + extent * 0.15, center.z + max(extent * 1.8, 0.4))
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        return camera
    }
}

/// Kept for Space Detail sheet entry points that still open create (Phase 3 will wire).
/// Library Phase 1 does not present this flow.
struct CreateAssetFlowView: View {
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                Text("새 3D 어셋 만들기")
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("사진으로 3D를 만드는 기능은 곧 연결될 예정이에요.")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)
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
        }
    }
}

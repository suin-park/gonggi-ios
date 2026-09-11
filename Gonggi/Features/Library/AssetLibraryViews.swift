import SceneKit
import SwiftUI
import UIKit

/// Library tab: canonical 3D Locker assets + GenerationJob cards (Phase 1 + 3B).
struct AssetLibraryView: View {
    @ObservedObject var store: AssetLibraryStore
    @ObservedObject private var generationStore = AssetGenerationStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedAsset: MobileAssetDTO?
    @State private var showCreate = false
    @State private var toastMessage: String?
    @State private var retryJob: MobileGenerationJobDTO?
    @State private var pendingRetryImage: UIImage?
    @State private var pendingRetryJPEG: Data?

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
            } else {
                await generationStore.refreshActiveJobs()
            }
        }
        .refreshable {
            await store.performRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            generationStore.setForeground(phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetGenerationDidComplete)) { _ in
            store.refresh(force: true)
        }
        .sheet(isPresented: $showCreate) {
            CreateAssetFlowView(
                onClose: { showCreate = false },
                onAccepted: {
                    toastMessage = "3D 생성을 시작했어요"
                    store.refresh(force: true)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.vertical, GonggiSpacing.sm)
                    .background(GonggiColors.accentTeal.opacity(0.95))
                    .clipShape(Capsule())
                    .padding(.bottom, GonggiSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                            withAnimation { self.toastMessage = nil }
                        }
                    }
            }
        }
        .sheet(item: $retryJob) { job in
            CreateAssetFlowView(
                onClose: {
                    retryJob = nil
                    pendingRetryImage = nil
                    pendingRetryJPEG = nil
                    generationStore.removeJob(id: job.jobId)
                },
                onAccepted: {
                    generationStore.removeJob(id: job.jobId)
                    retryJob = nil
                    pendingRetryImage = nil
                    pendingRetryJPEG = nil
                    toastMessage = "3D 생성을 시작했어요"
                    store.refresh(force: true)
                },
                retrySourceImage: pendingRetryImage,
                retryJPEG: pendingRetryJPEG
            )
            .presentationDetents([.large])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    GonggiHaptics.light()
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(GonggiColors.accentTeal)
                        .frame(width: 36, height: 36)
                        .background(GonggiColors.surfaceElevated.opacity(0.8))
                        .clipShape(Circle())
                }
                .accessibilityLabel("새 3D 자산 만들기")
            }
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
                entryList
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: GonggiSpacing.md) {
            ProgressView()
                .tint(GonggiColors.accentTeal)
            Text("3D 자산을 불러오는 중…")
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
            Text("아직 3D 자산이 없어요")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("사진으로 새 3D 자산을 만들어 보세요.")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            PrimaryButton(title: "새 3D 자산 만들기", icon: "plus") {
                GonggiHaptics.medium()
                showCreate = true
            }
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
            Text(store.errorMessage ?? "3D 자산을 불러오지 못했어요")
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

    private var entryList: some View {
        LazyVStack(spacing: GonggiSpacing.md) {
            ForEach(store.libraryEntries) { entry in
                switch entry {
                case .asset(let asset):
                    Button {
                        GonggiHaptics.light()
                        selectedAsset = asset
                    } label: {
                        assetCard(asset)
                    }
                    .buttonStyle(GonggiPressableStyle())
                    .accessibilityLabel("\(asset.name), 3D 어셋 상세 보기")
                    .accessibilityHint(asset.libraryStatus.label)
                case .generation(let job):
                    generationCard(job)
                }
            }
        }
    }

    private func generationCard(_ job: MobileGenerationJobDTO) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            generationThumb(job)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.statusLabel)
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(GonggiColors.textPrimary)
                if job.isActive {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(GonggiColors.accentTeal)
                        if let stage = job.stage, !stage.isEmpty {
                            Text(stage)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.textSecondary)
                        }
                        // Real server progress only — never invent %.
                        if let progress = job.progress, progress > 0, progress <= 100 {
                            Text("\(progress)%")
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.textTertiary)
                        }
                    }
                } else if job.isFailed {
                    Button {
                        GonggiHaptics.light()
                        if let data = generationStore.localThumb(for: job.jobId),
                           let image = UIImage(data: data) {
                            retryJob = job
                            // Sheet uses retrySource below via identified sheet content
                            pendingRetryImage = image
                            pendingRetryJPEG = data
                        } else {
                            pendingRetryImage = nil
                            pendingRetryJPEG = nil
                            retryJob = job
                        }
                    } label: {
                        Text("다시 시도")
                            .font(GonggiTypography.caption(13))
                            .fontWeight(.semibold)
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .accessibilityLabel(job.statusLabel)
    }

    @ViewBuilder
    private func generationThumb(_ job: MobileGenerationJobDTO) -> some View {
        let size: CGFloat = 64
        if let data = generationStore.localThumb(for: job.jobId),
           let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
        } else if let urlString = job.sourceThumbUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                        .fill(GonggiColors.surface)
                        .overlay {
                            Image(systemName: "cube.transparent")
                                .foregroundStyle(GonggiColors.textTertiary)
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                .fill(GonggiColors.surface)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(GonggiColors.textTertiary)
                }
        }
    }

    private func assetCard(_ asset: MobileAssetDTO) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            AssetThumbnailView(
                urlString: asset.thumbUrl,
                size: 64,
                showsMissingCaption: false,
                debugAssetId: asset.id
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name)
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if asset.isUsdzProcessing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(GonggiColors.accentTeal)
                    }
                    Text(asset.libraryStatus.label)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
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
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var libraryStore = AssetLibraryStore.shared
    @State private var detail: MobileAssetDTO?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isLoadingDetail = false
    @State private var isPreparingAR = false
    @State private var isDownloadingAR = false
    @State private var showSpacePicker = false
    @State private var isLaunchingPlacement = false
    @State private var placementMessage: String?
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var quickLookURL: IdentifiedURL?
    @State private var pollTask: Task<Void, Never>?
    @State private var isForeground = true
    @State private var exploreListed = false
    @State private var exploreCanList = false
    @State private var exploreBusy = false
    @State private var exploreMessage: String?

    private var asset: MobileAssetDTO { detail ?? listSnapshot }
    private var canPlace: Bool {
        asset.availableForPlacement && !(asset.usdzUrl ?? "").isEmpty
    }
    private var canOpenAR: Bool {
        asset.isUsdzReady && !isDownloadingAR && !isPreparingAR
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                previewBlock
                Text(asset.name)
                    .font(GonggiTypography.title(24))
                    .foregroundStyle(GonggiColors.textPrimary)
                statusBanner
                exploreVisibilitySection
                metaRows
                actionSection
                if let actionError {
                    Text(actionError)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.error)
                }
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
        .navigationTitle("3D 자산")
        .task {
            await loadDetail()
            await loadExploreVisibility()
            syncPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            isForeground = phase == .active
            syncPolling()
        }
        .onDisappear {
            stopPolling()
        }
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
        .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
            viewerLaunch = nil
            quickLookURL = nil
            showSpacePicker = false
        }
        .fullScreenCover(item: $quickLookURL) { item in
            AssetARQuickLookView(localUsdzURL: item.url)
        }
        .overlay {
            if isLaunchingPlacement || isDownloadingAR {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: GonggiSpacing.md) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                        if isDownloadingAR {
                            Text("AR을 준비하는 중…")
                                .font(GonggiTypography.caption(14))
                                .foregroundStyle(.white)
                        }
                    }
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
    private var statusBanner: some View {
        HStack(spacing: GonggiSpacing.sm) {
            if asset.isUsdzProcessing || isPreparingAR {
                ProgressView()
                    .controlSize(.small)
                    .tint(GonggiColors.accentTeal)
            }
            Text(asset.libraryStatus.label)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(asset.libraryStatus.label)
    }

    @ViewBuilder
    private var previewBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(GonggiColors.surface)
                .frame(height: 260)
            if asset.canPreviewUSDZ, let urlString = asset.usdzUrl, let url = URL(string: urlString) {
                AssetUSDZPreviewHost(assetId: asset.id, remoteURL: url, thumbUrl: asset.thumbUrl)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
                    .frame(height: 260)
            } else {
                AssetThumbnailView(
                    urlString: asset.thumbUrl,
                    size: 120,
                    showsMissingCaption: true,
                    debugAssetId: asset.id
                )
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
                title: "3D",
                value: !(asset.glbKey ?? "").isEmpty ? "준비됨" : "없음"
            )
            metaRow(
                title: "AR",
                value: userFacingARMeta(asset.usdzStatus)
            )
            metaRow(
                title: "공간 배치",
                value: canPlace ? "가능" : (asset.placementUnavailableReason ?? "준비 후 가능")
            )
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private var exploreVisibilitySection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Toggle(isOn: Binding(
                get: { exploreListed },
                set: { next in
                    Task { await setExploreListed(next) }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("둘러보기에 공개")
                        .font(GonggiTypography.headline(16))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(
                        exploreCanList
                            ? "다른 사용자가 홈 둘러보기에서 이 자산을 볼 수 있어요."
                            : "AR 준비가 끝난 뒤에 공개할 수 있어요."
                    )
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                }
            }
            .disabled(!exploreCanList || exploreBusy)
            .tint(GonggiColors.brandCyan)

            if let exploreMessage {
                Text(exploreMessage)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.error)
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    @ViewBuilder
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            if asset.isUsdzReady {
                PrimaryButton(title: "AR로 보기", icon: "arkit") {
                    GonggiHaptics.medium()
                    Task { await openAR() }
                }
                .disabled(!canOpenAR)
                .opacity(canOpenAR ? 1 : 0.45)
                .accessibilityLabel("AR로 보기")
                .accessibilityHint("카메라로 실제 공간에 3D 어셋을 배치합니다")

                SecondaryButton(title: "공간에 배치", icon: "square.stack.3d.up") {
                    GonggiHaptics.light()
                    showSpacePicker = true
                }
                .disabled(!canPlace || isLaunchingPlacement)
                .opacity(canPlace ? 1 : 0.45)
                .accessibilityLabel("공간에 배치")
            } else if asset.isUsdzProcessing || isPreparingAR {
                Text("AR/공간 배치 준비 중…")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .accessibilityLabel("AR과 공간 배치를 준비하는 중")
            } else if asset.isUsdzFailed {
                PrimaryButton(title: "AR 다시 준비하기", icon: "arrow.clockwise") {
                    GonggiHaptics.light()
                    Task { await prepareAR(invalidateCache: true) }
                }
                .disabled(isPreparingAR)
                .accessibilityLabel("AR과 공간 배치를 다시 준비하기")
            } else {
                // NONE / legacy
                PrimaryButton(title: "AR/공간 배치 준비하기", icon: "sparkles") {
                    GonggiHaptics.light()
                    Task { await prepareAR(invalidateCache: false) }
                }
                .disabled(isPreparingAR)
                .accessibilityLabel("AR과 공간 배치를 준비하기")
            }

            if !asset.isUsdzReady, let reason = asset.placementUnavailableReason {
                Text(reason)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
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

    private func userFacingARMeta(_ raw: String?) -> String {
        switch (raw ?? "NONE").uppercased() {
        case "READY": return "준비됨"
        case "PROCESSING": return "준비 중"
        case "FAILED": return "준비되지 않음"
        default: return "준비되지 않음"
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
            applyDetail(fresh)
            loadError = nil
        } catch let error as MobileAssetsAPIError {
            if case .server(let status) = error, status == 401 {
                loadError = "로그인이 필요해요"
            } else {
                loadError = "3D 어셋 정보를 불러오지 못했어요"
            }
        } catch {
            loadError = "3D 어셋 정보를 불러오지 못했어요"
        }
    }

    private func applyDetail(_ fresh: MobileAssetDTO) {
        detail = fresh
        libraryStore.upsertAsset(fresh)
        syncPolling()
        exploreCanList = fresh.isUsdzReady
    }

    private func loadExploreVisibility() async {
        do {
            let state = try await MobileAssetsAPIClient().getExploreVisibility(assetId: asset.id)
            exploreListed = state.exploreListed
            exploreCanList = state.canList
            exploreMessage = nil
        } catch {
            // Non-fatal — toggle stays off until reload.
            exploreCanList = asset.isUsdzReady
        }
    }

    private func setExploreListed(_ next: Bool) async {
        guard !exploreBusy else { return }
        let previous = exploreListed
        exploreListed = next
        exploreBusy = true
        exploreMessage = nil
        defer { exploreBusy = false }
        do {
            let state = try await MobileAssetsAPIClient().setExploreVisibility(
                assetId: asset.id,
                exploreListed: next
            )
            exploreListed = state.exploreListed
            exploreCanList = state.canList
        } catch {
            exploreListed = previous
            exploreMessage = "공개 설정을 저장하지 못했어요. 다시 시도해주세요."
        }
    }

    private func prepareAR(invalidateCache: Bool) async {
        guard !isPreparingAR else { return }
        isPreparingAR = true
        actionError = nil
        defer { isPreparingAR = false }
        if invalidateCache {
            await VRUsdzCache().invalidate(assetId: asset.id)
        }
        do {
            let response = try await MobileAssetsAPIClient().prepareAR(assetId: asset.id)
            if response.alreadyReady || response.status.uppercased() == "READY" {
                await loadDetail()
                return
            }
            // Optimistic PROCESSING until GET confirms.
            if var snapshot = detail ?? Optional(listSnapshot) {
                snapshot.usdzStatus = "PROCESSING"
                snapshot.availability = "processing"
                snapshot.availableForPlacement = false
                applyDetail(snapshot)
            }
            syncPolling()
        } catch let error as MobilePrepareARError {
            actionError = "AR 파일을 준비하지 못했어요. 다시 시도해주세요."
            _ = error
        } catch {
            actionError = "AR 파일을 준비하지 못했어요. 다시 시도해주세요."
        }
    }

    private func openAR() async {
        guard let urlString = asset.usdzUrl, let remote = URL(string: urlString) else {
            actionError = "AR 파일을 불러오지 못했어요"
            return
        }
        isDownloadingAR = true
        actionError = nil
        defer { isDownloadingAR = false }
        guard let local = await VRUsdzCache().localURL(assetId: asset.id, remoteURL: remote) else {
            actionError = "AR 파일을 불러오지 못했어요"
            return
        }
        quickLookURL = IdentifiedURL(url: local)
    }

    private func syncPolling() {
        if asset.isUsdzProcessing, isForeground {
            startPollingIfNeeded()
        } else {
            stopPolling()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task {
            var delays: [UInt64] = [2, 3, 5, 8]
            var delayIndex = 0
            while !Task.isCancelled {
                let delay = delays[min(delayIndex, delays.count - 1)]
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delayIndex = min(delayIndex + 1, delays.count - 1)
                guard !Task.isCancelled else { return }
                guard isForeground else { continue }
                do {
                    let fresh = try await MobileAssetsAPIClient().fetchAsset(id: listSnapshot.id)
                    await MainActor.run {
                        applyDetail(fresh)
                    }
                    if !fresh.isUsdzProcessing {
                        await MainActor.run { stopPolling() }
                        return
                    }
                } catch {
                    // Keep polling; server is canonical.
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

private struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Thumbnail

enum AssetThumbnailLoadPhase: Equatable {
    case noURL
    case loading
    case success
    case networkFailure(status: Int?)
    case decodeFailure
}

struct AssetThumbnailView: View {
    let urlString: String?
    var size: CGFloat = 64
    /// When true and there is no result thumb, show a small "미리보기 없음" caption under the icon.
    var showsMissingCaption: Bool = false
    /// Optional asset id prefix for DEBUG diagnostics only (never shown in UI).
    var debugAssetId: String? = nil
    /// Explicitly labeled input-photo fallback (not a result thumb). Nil = do not use input photo.
    var inputPhotoURLString: String? = nil
    var inputPhotoCaption: String = "입력 사진"

    @State private var phase: AssetThumbnailLoadPhase = .noURL
    @State private var image: UIImage?
    @State private var showingInputPhoto = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                    .fill(GonggiColors.surface)
                    .frame(width: size, height: size)
                switch phase {
                case .success:
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
                            .accessibilityHidden(true)
                    } else {
                        placeholderIcon
                    }
                case .loading:
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(GonggiColors.accentTeal)
                case .noURL, .networkFailure, .decodeFailure:
                    placeholderIcon
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)

            if showingInputPhoto, phase == .success {
                Text(inputPhotoCaption)
                    .font(GonggiTypography.caption(10))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(1)
            } else if showsMissingCaption, phase == .noURL || isFailurePhase {
                Text("미리보기 없음")
                    .font(GonggiTypography.caption(10))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .task(id: "\(urlString ?? "")|\(inputPhotoURLString ?? "")") {
            await load()
        }
    }

    private var isFailurePhase: Bool {
        switch phase {
        case .networkFailure, .decodeFailure: return true
        default: return false
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "cube.transparent")
            .font(.system(size: size * 0.35, weight: .light))
            .foregroundStyle(GonggiColors.accentTeal)
    }

    @MainActor
    private func load() async {
        image = nil
        showingInputPhoto = false
        let authGen = AuthSessionGeneration.current

        if let urlString, let url = URL(string: urlString), !urlString.isEmpty {
            phase = .loading
            let result = await AssetThumbnailFetcher.fetch(url: url)
            guard AuthSessionGeneration.isCurrent(authGen) else { return }
            apply(result, asInputPhoto: false)
            #if DEBUG
            logDebug(preferredURL: urlString, result: result)
            #endif
            if phase == .success { return }
        }

        // Result thumb missing/failed — optional labeled input photo only (never silent backfill).
        if let input = inputPhotoURLString, let url = URL(string: input), !input.isEmpty {
            phase = .loading
            let result = await AssetThumbnailFetcher.fetch(url: url)
            guard AuthSessionGeneration.isCurrent(authGen) else { return }
            apply(result, asInputPhoto: true)
            #if DEBUG
            logDebug(preferredURL: input, result: result)
            #endif
            return
        }

        if urlString == nil || urlString?.isEmpty == true {
            phase = .noURL
        }
    }

    private func apply(_ result: AssetThumbnailFetcher.Result, asInputPhoto: Bool) {
        switch result {
        case .success(let img):
            image = img
            phase = .success
            showingInputPhoto = asInputPhoto
        case .networkFailure(let status):
            phase = .networkFailure(status: status)
            showingInputPhoto = false
        case .decodeFailure:
            phase = .decodeFailure
            showingInputPhoto = false
        }
    }

    #if DEBUG
    private func logDebug(preferredURL: String, result: AssetThumbnailFetcher.Result) {
        let idPart: String
        if let debugAssetId, debugAssetId.count >= 8 {
            idPart = String(debugAssetId.prefix(8))
        } else {
            idPart = debugAssetId ?? "-"
        }
        let hasURL = !(urlString ?? "").isEmpty
        let status: String
        switch result {
        case .success:
            status = "success"
        case .networkFailure(let code):
            status = "networkFailure status=\(code.map(String.init) ?? "nil")"
        case .decodeFailure:
            status = "decodeFailure"
        }
        // Never log full signed URLs / tokens — host + path prefix only.
        let hostPath: String
        if let u = URL(string: preferredURL) {
            hostPath = "\(u.host ?? "?")\(String(u.path.prefix(48)))"
        } else {
            hostPath = "unparseable"
        }
        print(
            "[AssetThumbDBG] id=\(idPart) hasResultThumb=\(hasURL) phase=\(status) url=\(hostPath) inputPhoto=\(showingInputPhoto)"
        )
    }
    #endif
}

enum AssetThumbnailFetcher {
    enum Result: Sendable {
        case success(UIImage)
        case networkFailure(status: Int?)
        case decodeFailure
    }

    static func fetch(url: URL) async -> Result {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode
            if let status, !(200 ... 299).contains(status) {
                return .networkFailure(status: status)
            }
            if let head = String(data: data.prefix(64), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               head.hasPrefix("<") || head.hasPrefix("{") || head.hasPrefix("[") {
                return .decodeFailure
            }
            guard let image = UIImage(data: data) else {
                return .decodeFailure
            }
            return .success(image)
        } catch {
            #if DEBUG
            let ns = error as NSError
            print("[AssetThumbDBG] fetchError domain=\(ns.domain) code=\(ns.code)")
            #endif
            return .networkFailure(status: nil)
        }
    }
}

// MARK: - USDZ SceneKit preview (reuses VRUsdzCache)

struct AssetUSDZPreviewHost: View {
    let assetId: String
    let remoteURL: URL
    var thumbUrl: String? = nil

    @State private var localURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let localURL {
                AssetSceneKitPreviewRepresentable(modelURL: localURL)
            } else if failed {
                AssetThumbnailView(
                    urlString: thumbUrl,
                    size: 80,
                    showsMissingCaption: true,
                    debugAssetId: assetId
                )
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


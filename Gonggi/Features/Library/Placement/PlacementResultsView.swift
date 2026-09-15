import SwiftUI

@MainActor
final class PlacementResultsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var results: [ProductPlacementResultDTO] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRefreshing = false
    @Published var actionError: String?
    @Published var highlightId: String?

    private let client: any PlacementResultsServing
    private var pollTask: Task<Void, Never>?
    private var isVisible = false
    private let pollIntervalNanoseconds: UInt64 = 3_000_000_000

    init(client: any PlacementResultsServing, highlightId: String? = nil) {
        self.client = client
        self.highlightId = highlightId
    }

    var hasInFlight: Bool {
        results.contains { $0.status.isInFlight }
    }

    func onAppear() {
        isVisible = true
        Task { await refresh(forceLoading: results.isEmpty) }
        startPollingIfNeeded()
    }

    func onDisappear() {
        isVisible = false
        cancelPolling()
    }

    func onScenePhaseActive() {
        guard isVisible else { return }
        Task { await refresh(forceLoading: false) }
        startPollingIfNeeded()
    }

    func pullToRefresh() async {
        await refresh(forceLoading: false)
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Exposed for unit tests — true while a poll loop task is scheduled.
    var isPolling: Bool { pollTask != nil }

    func refresh(forceLoading: Bool) async {
        if forceLoading {
            phase = .loading
        } else if !results.isEmpty {
            isRefreshing = true
        }
        do {
            let list = try await client.listResults()
            results = list
            phase = .loaded
            startPollingIfNeeded()
        } catch let error as MobilePlacementResultsAPIError {
            if results.isEmpty {
                phase = .failed(error.userMessage)
            }
            // Keep stale list on transient failures when we already have content.
        } catch {
            if results.isEmpty {
                phase = .failed(MobilePlacementResultsAPIError.invalidResponse.userMessage)
            }
        }
        isRefreshing = false
    }

    func retryFailed(_ result: ProductPlacementResultDTO) async {
        do {
            let updated = try await client.retryCurtain(placementResultId: result.id)
            upsert(updated)
            startPollingIfNeeded()
        } catch let error as MobilePlacementResultsAPIError {
            actionError = error.userMessage
        } catch {
            actionError = MobilePlacementResultsAPIError.invalidResponse.userMessage
        }
    }

    func confirmNeedsConfirmation(_ result: ProductPlacementResultDTO) async {
        guard let jobId = result.curtainCompositeJobId, !jobId.isEmpty else {
            actionError = "확인에 필요한 작업 정보가 없어요"
            return
        }
        do {
            try await client.confirmCurtainJob(jobId: jobId)
            await refresh(forceLoading: false)
        } catch let error as MobilePlacementResultsAPIError {
            actionError = error.userMessage
        } catch {
            actionError = "확인 요청에 실패했어요"
        }
    }

    /// Fresh detail (signed preview URL) for opening a completed curtain composite.
    func fetchDetail(id: String) async throws -> ProductPlacementResultDTO {
        let detailed = try await client.fetchResult(id: id)
        upsert(detailed)
        return detailed
    }

    private func upsert(_ result: ProductPlacementResultDTO) {
        if let idx = results.firstIndex(where: { $0.id == result.id }) {
            results[idx] = result
        } else {
            results.insert(result, at: 0)
        }
        phase = .loaded
    }

    private func startPollingIfNeeded() {
        guard isVisible, hasInFlight else {
            cancelPolling()
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard self.isVisible, self.hasInFlight else {
                    self.cancelPolling()
                    return
                }
                await self.refresh(forceLoading: false)
            }
        }
    }
}

struct PlacementResultsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: PlacementResultsViewModel
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?

    init(isMockMode: Bool, highlightId: String? = nil) {
        let client: any PlacementResultsServing = isMockMode
            ? PlacementResultsMockClient()
            : MobilePlacementResultsAPIClient()
        _viewModel = StateObject(
            wrappedValue: PlacementResultsViewModel(client: client, highlightId: highlightId)
        )
    }

    /// Test / preview injection.
    init(viewModel: PlacementResultsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            content
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.onScenePhaseActive()
            }
        }
        .refreshable {
            await viewModel.pullToRefresh()
        }
        .alert("배치 결과", isPresented: Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button("확인", role: .cancel) { viewModel.actionError = nil }
        } message: {
            Text(viewModel.actionError ?? "")
        }
        .fullScreenCover(item: $viewerLaunch) { launch in
            SpaceVRNavigationHost(
                sessions: launch.sessions,
                onClose: { viewerLaunch = nil }
            )
            .environmentObject(appState)
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
            Button("닫기", role: .cancel) { viewerError = nil }
        } message: {
            Text(viewerError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView("배치 결과 불러오는 중…")
                .tint(GonggiColors.accentCyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, GonggiSpacing.xl)
        case .failed(let message):
            VStack(spacing: GonggiSpacing.sm) {
                Text(message)
                    .font(GonggiTypography.body(14))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .multilineTextAlignment(.center)
                Button("다시 시도") {
                    GonggiHaptics.light()
                    Task { await viewModel.refresh(forceLoading: true) }
                }
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textOnAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(GonggiColors.accentCyan))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, GonggiSpacing.lg)
        case .loaded:
            if viewModel.results.isEmpty {
                Text("아직 배치 결과가 없어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .padding(.top, GonggiSpacing.sm)
            } else {
                LazyVStack(spacing: GonggiSpacing.md) {
                    ForEach(viewModel.results) { result in
                        PlacementResultCardView(
                            result: result,
                            isHighlighted: result.id == viewModel.highlightId,
                            onTap: { handleTap(result) },
                            onRetry: {
                                Task { await viewModel.retryFailed(result) }
                            },
                            onReselect: {
                                openSpaceForReselect(result)
                            },
                            onConfirm: {
                                Task { await viewModel.confirmNeedsConfirmation(result) }
                            }
                        )
                    }
                }
            }
        }
    }

    private func handleTap(_ result: ProductPlacementResultDTO) {
        switch result.status {
        case .completed:
            openCompleted(result)
        case .needsConfirmation:
            Task { await viewModel.confirmNeedsConfirmation(result) }
        case .failed:
            break
        case .queued, .inProgress, .unsupported:
            break
        }
    }

    private func openCompleted(_ result: ProductPlacementResultDTO) {
        Task {
            if result.type == .curtain2D {
                await openCompletedCurtain(result)
            } else {
                await openSourceSpaceViewer(result)
            }
        }
    }

    private func openSpaceForReselect(_ result: ProductPlacementResultDTO) {
        Task {
            let jobId = await resolveViewerJobId(from: result)
            guard !jobId.isEmpty else {
                viewModel.actionError = "연결된 공간을 찾을 수 없어요"
                return
            }
            if result.type == .curtain2D,
               let productId = result.catalogProductId {
                appState.pendingCurtainPlacement = PendingCurtainPlacement(
                    productId: productId,
                    variantId: result.catalogVariantId ?? "",
                    catalog2DAssetId: nil,
                    catalogRevision: nil,
                    productRevision: nil,
                    displayName: result.displayProductName,
                    partnerName: result.displayPartnerName,
                    thumbnailUrl: result.cardPreviewURLString,
                    targetSpaceId: jobId,
                    targetSessionId: jobId,
                    projectionKey: nil,
                    baseRevisionId: result.sourceRevisionId ?? "rev-0-base"
                )
            }
            await openViewer(jobId: jobId)
        }
    }

    /// Completed curtain → download signed composite lat-long and open VR.
    private func openCompletedCurtain(_ result: ProductPlacementResultDTO) async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }

        do {
            var detailed = result
            if PlacementResultOpenPolicy.compositePreviewURLString(for: detailed) == nil {
                detailed = try await viewModel.fetchDetail(id: result.id)
            }
            guard let urlString = PlacementResultOpenPolicy.compositePreviewURLString(for: detailed),
                  let remote = URL(string: urlString) else {
                // No composite URL — fall back to source space (session-resolved).
                isPreparingViewer = false
                await openSourceSpaceViewer(result)
                return
            }

            let dest = try PlacementResultOpenPolicy.compositeCacheURL(resultId: result.id)
            if !SpaceLatLongStore.isValidLocalFile(at: dest.path) {
                try await downloadComposite(from: remote, to: dest)
            }
            guard SpaceLatLongStore.isValidLocalFile(at: dest.path) else {
                viewerError = SpaceViewerError.downloadFailed.userMessage
                return
            }

            let audioKey = await resolveViewerJobId(from: result)
            viewerLaunch = SpaceViewerLaunch(
                single: SpaceViewerSession(
                    id: result.id,
                    fileURL: dest,
                    audioURL: AppState.preferredAudioURL(for: audioKey),
                    videoURL: AppState.preferredVideoURL(for: audioKey)
                )
            )
        } catch {
            // Composite download failed — try opening the source space instead.
            await openSourceSpaceViewer(result)
            if viewerLaunch == nil, viewerError == nil {
                viewerError = SpaceViewerError.downloadFailed.userMessage
            }
        }
    }

    private func openSourceSpaceViewer(_ result: ProductPlacementResultDTO) async {
        let jobId = await resolveViewerJobId(from: result)
        guard !jobId.isEmpty else {
            viewModel.actionError = "연결된 공간을 찾을 수 없어요"
            return
        }
        await openViewer(jobId: jobId)
    }

    private func resolveViewerJobId(from result: ProductPlacementResultDTO) async -> String {
        let sessionHint = result.sourceSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spaceKey = result.sourceSpaceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let preferredKey: String
        if let sessionHint, !sessionHint.isEmpty {
            preferredKey = sessionHint
        } else if let spaceKey, !spaceKey.isEmpty {
            preferredKey = spaceKey
        } else {
            return ""
        }

        let localJobs = appState.jobStore.jobs
        let resolvedLocal = PlacementResultOpenPolicy.resolveViewerJobId(
            spaceKey: preferredKey,
            jobs: localJobs
        )
        if localJobs.contains(where: { $0.jobId == resolvedLocal || $0.sessionId == resolvedLocal }) {
            return resolvedLocal
        }

        // `sourceSpaceId` is often GonggiSpace.id — map via owner catalog.
        guard let spaceKey, !spaceKey.isEmpty else {
            return resolvedLocal
        }
        var catalogRows: [[String: Any]] = []
        if let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty {
            catalogRows = (try? await MobileAuthAPIClient().listSpaces(accessToken: token)) ?? []
        }
        return PlacementResultOpenPolicy.resolveViewerJobId(
            spaceKey: spaceKey,
            jobs: localJobs,
            catalogRows: catalogRows
        )
    }

    private func downloadComposite(from remote: URL, to destination: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpaceViewerError.downloadFailed
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    private func openViewer(jobId: String) async {
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

private struct PlacementResultCardView: View {
    let result: ProductPlacementResultDTO
    var isHighlighted: Bool
    var onTap: () -> Void
    var onRetry: () -> Void
    var onReselect: () -> Void
    var onConfirm: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            HStack(alignment: .top, spacing: GonggiSpacing.md) {
                preview
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        badge(result.type.badgeTitle)
                        badge(result.status.statusTitle, emphasized: true)
                    }
                    Text(result.displayProductName)
                        .font(GonggiTypography.body(15))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .lineLimit(2)
                    if !result.displayPartnerName.isEmpty {
                        Text(result.displayPartnerName)
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.accentCyan)
                            .lineLimit(1)
                    }
                    if let date = result.createdAtDate {
                        Text(Self.dateFormatter.string(from: date))
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                    if result.status.isInFlight {
                        ProgressView(value: min(max(result.progress ?? 0.15, 0.05), 1))
                            .tint(GonggiColors.accentCyan)
                            .accessibilityLabel("배치 진행 중")
                    }
                }
                Spacer(minLength: 0)
            }

            if result.status == .failed {
                HStack(spacing: GonggiSpacing.sm) {
                    Button("다시 시도") {
                        GonggiHaptics.light()
                        onRetry()
                    }
                    .font(GonggiTypography.caption(13))
                    .buttonStyle(.borderedProminent)
                    .tint(GonggiColors.accentCyan)
                    Button("창문 위치 다시 선택") {
                        GonggiHaptics.light()
                        onReselect()
                    }
                    .font(GonggiTypography.caption(13))
                    .buttonStyle(.bordered)
                }
            } else if result.status == .needsConfirmation {
                Button("창문 위치 확인") {
                    GonggiHaptics.medium()
                    onConfirm()
                }
                .font(GonggiTypography.caption(13))
                .buttonStyle(.borderedProminent)
                .tint(GonggiColors.accentCyan)
            }
        }
        .padding(GonggiSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .fill(GonggiColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(
                    isHighlighted ? GonggiColors.accentCyan : GonggiColors.borderSubtle.opacity(0.6),
                    lineWidth: isHighlighted ? 2 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
        .onTapGesture {
            GonggiHaptics.light()
            onTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        "\(result.type.badgeTitle), \(result.status.statusTitle), \(result.displayProductName)"
    }

    private func badge(_ title: String, emphasized: Bool = false) -> some View {
        Text(title)
            .font(GonggiTypography.caption(11))
            .foregroundStyle(emphasized ? GonggiColors.textOnAccent : GonggiColors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    emphasized ? GonggiColors.accentCyan : GonggiColors.surfaceElevated
                )
            )
    }

    @ViewBuilder
    private var preview: some View {
        let url = result.cardPreviewURLString.flatMap(URL.init(string:))
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView().tint(GonggiColors.accentCyan)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            GonggiColors.surfaceElevated
            Image(systemName: result.type == .curtain2D ? "window.vertical.closed" : "sofa.fill")
                .foregroundStyle(GonggiColors.textTertiary)
        }
    }
}

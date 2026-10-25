import SwiftUI

/// One library entry: a capture result (space / 360° / object) or a 3D asset made earlier from a photo.
/// Only real records of the signed-in account; never design photos.
enum WhikLibraryItem: Identifiable, Equatable {
    case record(SpaceRecord)
    case asset(MobileAssetDTO)

    enum Kind: Equatable { case space3D, space360, object3D }

    var id: String {
        switch self {
        case .record(let r): return "r:" + r.id
        case .asset(let a): return "a:" + a.id
        }
    }

    var kind: Kind {
        switch self {
        case .record(let r):
            if r.isProductResult { return .object3D }
            // Same rule as GaussianGenerationStore.spaceId(fromLibraryId:) (3DGS records are "gaussian:<spaceId>").
            return r.id.hasPrefix("gaussian:") ? .space3D : .space360
        case .asset:
            return .object3D
        }
    }

    var title: String {
        switch self {
        case .record(let r): return r.name
        case .asset(let a): return a.name.isEmpty ? "Untitled" : a.name
        }
    }

    var date: Date {
        switch self {
        case .record(let r): return r.capturedAt
        case .asset(let a): return a.createdAt.flatMap(WhikLibraryItem.parseDate) ?? .distantPast
        }
    }

    var kindLabel: String {
        switch kind {
        case .space3D: return "3D Space"
        case .space360: return "360° Space"
        case .object3D: return "3D Object"
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

enum WhikLibraryFilter: Hashable, CaseIterable {
    case all, spaces, objects

    func includes(_ kind: WhikLibraryItem.Kind) -> Bool {
        switch self {
        case .all: return true
        case .spaces: return kind != .object3D
        case .objects: return kind == .object3D
        }
    }

    /// Newest first; filter applied.
    static func items(records: [SpaceRecord], assets: [MobileAssetDTO], filter: WhikLibraryFilter) -> [WhikLibraryItem] {
        let all = records.map(WhikLibraryItem.record) + assets.map(WhikLibraryItem.asset)
        return all.filter { filter.includes($0.kind) }.sorted { $0.date > $1.date }
    }
}

/// Status line for a record that is not ready yet. Progress comes from the server job only (no estimate).
enum WhikRecordStatus {
    static func label(_ r: SpaceRecord) -> String? {
        if r.repairBadge != .none, r.status == .ready { return nil }
        switch r.status {
        case .ready: return nil
        case .draft: return "Not sent"
        case .uploading: return "Uploading"
        case .processing: return "Processing"
        case .failed: return "Failed"
        }
    }

    /// Server-reported 0…1 for a 3D generation job, when the server has reported a stage.
    @MainActor
    static func progress(_ r: SpaceRecord) -> Double? {
        guard r.status == .processing,
              let gid = GaussianGenerationStore.shared.spaceId(fromLibraryId: r.id),
              let job = GaussianGenerationStore.shared.record(spaceId: gid),
              job.stage != nil, job.progress > 0, job.progress < 1
        else { return nil }
        return job.progress
    }
}

struct WhikLibraryView: View {
    let onProfile: () -> Void
    let onCapture: () -> Void
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var gate: WhikAuthGate
    @EnvironmentObject private var viewers: WhikViewerPresenter
    @ObservedObject private var auth = AuthSessionController.shared
    @ObservedObject private var assets = AssetLibraryStore.shared
    @State private var filter: WhikLibraryFilter = .all
    @State private var detail: SpaceRecord?
    @State private var assetDetail: MobileAssetDTO?

    private var signedIn: Bool {
        if case .signedIn = auth.phase { return true }
        return false
    }

    private var items: [WhikLibraryItem] {
        WhikLibraryFilter.items(records: appState.spaces, assets: assets.assets, filter: filter)
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        Text("Library")
                            .font(WhikFont.largeTitle())
                            .foregroundStyle(WhikColors.textPrimary)
                        Spacer()
                        WhikCircleButton(systemImage: "person", label: "Profile", action: onProfile)
                    }
                    .padding(.top, 8)
                    WhikChips(items: [(.all, "All"), (.spaces, "Spaces"), (.objects, "Objects")], selection: $filter)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    if signedIn {
                        // Captures that never finished uploading stay resumable (original package on device).
                        if filter != .objects { UnsentCapturesSection(products: false) }
                        if filter != .spaces { UnsentCapturesSection(products: true) }
                        if items.isEmpty {
                            emptyState
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(items) { item in
                                    WhikLibraryTile(item: item)
                                        .onTapGesture { open(item) }
                                        .contextMenu { menu(for: item) }
                                }
                            }
                        }
                    } else {
                        guestState
                    }
                }
                .padding(.horizontal, WhikLayout.sideInset)
                .padding(.bottom, WhikLayout.tabBarClearance)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh(force: true) }
            .background(WhikColors.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $detail) { space in
                SpaceDetailView(space: space)
            }
            .navigationDestination(item: $assetDetail) { asset in
                AssetDetailView(listSnapshot: asset)
            }
            .task(id: signedIn) { await refresh(force: false) }
            .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
                let jobId = note.userInfo?["jobId"] as? String
                if detail?.id == jobId { detail = nil }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No captures yet")
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(WhikColors.textPrimary)
            Button(action: onCapture) {
                Text("Capture")
                    .font(.system(.body).weight(.semibold))
                    .foregroundStyle(WhikColors.onMint)
                    .padding(.horizontal, 28)
                    .frame(minHeight: 48)
                    .background(Capsule().fill(WhikColors.mint))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var guestState: some View {
        VStack(spacing: 20) {
            emptyState
            Divider().overlay(WhikColors.border)
            Button {
                gate.signIn(reason: "Sign in to see your captures.")
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text("Sign in to see your captures")
                    Spacer()
                    Text("Sign in").foregroundStyle(WhikColors.mint)
                    Image(systemName: "chevron.right").foregroundStyle(WhikColors.mint)
                }
                .font(.system(.subheadline))
                .foregroundStyle(WhikColors.textSecondary)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func menu(for item: WhikLibraryItem) -> some View {
        switch item {
        case .record(let r):
            if r.status == .ready {
                Button { open(item) } label: { Label("Open", systemImage: "play.circle") }
            }
            Button { detail = r } label: { Label("Details, rename or delete", systemImage: "info.circle") }
        case .asset(let a):
            Button { assetDetail = a } label: { Label("Details", systemImage: "info.circle") }
        }
    }

    /// Ready results open the viewer; anything still in progress, failed or not sent opens its detail page
    /// (status, retry, rename, delete).
    private func open(_ item: WhikLibraryItem) {
        GonggiHaptics.light()
        switch item {
        case .record(let r):
            guard r.status == .ready else { detail = r; return }
            if let gid = GaussianGenerationStore.shared.spaceId(fromLibraryId: r.id) {
                viewers.openGaussian(spaceId: gid)
            } else {
                viewers.openSpace(jobId: r.id)
            }
        case .asset(let a):
            assetDetail = a
        }
    }

    private func refresh(force: Bool) async {
        guard signedIn else { return }
        appState.ensureSpaceGenerationPolling()
        if force || assets.phase == .idle || assets.phase == .failed { assets.refresh(force: force) }
        if force {
            await GaussianLibraryReconciler.shared.reconcileIfStale(minInterval: 0)
        } else {
            await GaussianLibraryReconciler.shared.reconcileIfStale()
        }
    }
}

private struct WhikLibraryTile: View {
    let item: WhikLibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    thumbnail(width: geo.size.width, height: geo.size.height)
                    if case .record(let r) = item, let status = WhikRecordStatus.label(r) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(status)
                                .font(.system(.caption).weight(.semibold))
                                .foregroundStyle(r.status == .failed ? WhikColors.danger : WhikColors.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                            if let p = WhikRecordStatus.progress(r) {
                                ProgressView(value: p)
                                    .tint(WhikColors.mint)
                                    .accessibilityLabel("Server progress")
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .aspectRatio(0.92, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(WhikColors.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.body).weight(.semibold))
                    .foregroundStyle(WhikColors.textPrimary)
                    .lineLimit(1)
                Text(item.kindLabel)
                    .font(.system(.subheadline))
                    .foregroundStyle(WhikColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func thumbnail(width: CGFloat, height: CGFloat) -> some View {
        switch item {
        case .record(let r):
            SpaceThumbnailView(space: r, height: height, width: width, cornerRadius: 0, showsActivityOverlay: false)
        case .asset(let a):
            ZStack {
                WhikColors.surface
                AssetThumbnailView(urlString: a.thumbUrl, size: min(width, height))
            }
            .frame(width: width, height: height)
        }
    }
}

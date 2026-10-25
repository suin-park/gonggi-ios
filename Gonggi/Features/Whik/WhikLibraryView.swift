import Observation
import SwiftUI

/// One library entry: a capture result (space / 360° / object) or a 3D asset made earlier from a photo.
/// Only real records of the signed-in account; never design photos.
enum WhikLibraryItem: Identifiable, Equatable {
    case record(SpaceRecord)
    case asset(MobileAssetDTO)

    enum Kind: Hashable, CaseIterable {
        case space3D, space360, object3D

        var label: String {
            switch self {
            case .space3D: return L("3D Space")
            case .space360: return L("360° Space")
            case .object3D: return L("3D Object")
            }
        }
    }

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

    /// The stored name, exactly as saved (user-typed or created earlier). Never translated.
    var title: String {
        switch self {
        case .record(let r): return r.name
        case .asset(let a): return a.name
        }
    }

    var displayTitle: String { title.isEmpty ? L("Untitled") : title }

    var date: Date {
        switch self {
        case .record(let r): return r.capturedAt
        case .asset(let a): return a.createdAt.flatMap(WhikLibraryItem.parseDate) ?? .distantPast
        }
    }

    var status: WhikItemStatus {
        switch self {
        case .record(let r): return WhikItemStatus(r.status)
        case .asset: return .ready // listed photo-made assets already exist; AR preparation is not a generation state
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

/// Library status filter, mapped from `SpaceGenerationStatus`.
enum WhikItemStatus: Hashable, CaseIterable {
    case ready, processing, failed

    init(_ status: SpaceGenerationStatus) {
        switch status {
        case .ready: self = .ready
        case .failed: self = .failed
        case .draft, .uploading, .processing: self = .processing
        }
    }

    var label: String {
        switch self {
        case .ready: return L("Ready")
        case .processing: return L("Processing")
        case .failed: return L("Failed")
        }
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

    /// Newest first; category applied (kept for callers that only need the tabs).
    static func items(records: [SpaceRecord], assets: [MobileAssetDTO], filter: WhikLibraryFilter) -> [WhikLibraryItem] {
        var q = WhikLibraryQuery()
        q.category = filter
        return q.apply(records.map(WhikLibraryItem.record) + assets.map(WhikLibraryItem.asset), locale: Locale(identifier: "en"))
    }
}

enum WhikLibrarySort: Hashable, CaseIterable {
    case newest, oldest, nameAZ

    var label: String {
        switch self {
        case .newest: return L("Newest first")
        case .oldest: return L("Oldest first")
        case .nameAZ: return L("Name A–Z")
        }
    }
}

/// Library search / sort / filters. One shared instance, so the query survives opening a detail screen and
/// coming back (and tab switches).
struct WhikLibraryQuery: Equatable {
    var category: WhikLibraryFilter = .all
    var search = ""
    var sort: WhikLibrarySort = .newest
    var kinds: Set<WhikLibraryItem.Kind> = []
    var statuses: Set<WhikItemStatus> = []

    var extraFilterCount: Int { kinds.count + statuses.count }
    var isFiltering: Bool {
        category != .all || !search.trimmingCharacters(in: .whitespaces).isEmpty || extraFilterCount > 0
    }

    mutating func clearAll() {
        category = .all
        search = ""
        kinds = []
        statuses = []
    }

    /// Category, type, status and name search together, then the chosen order. Name order and matching use the
    /// selected language's rules.
    func apply(_ all: [WhikLibraryItem], locale: Locale) -> [WhikLibraryItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = all.filter { item in
            guard category.includes(item.kind) else { return false }
            if !kinds.isEmpty, !kinds.contains(item.kind) { return false }
            if !statuses.isEmpty, !statuses.contains(item.status) { return false }
            if !needle.isEmpty {
                return item.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                        locale: locale) != nil
            }
            return true
        }
        switch sort {
        case .newest: return filtered.sorted { $0.date > $1.date }
        case .oldest: return filtered.sorted { $0.date < $1.date }
        case .nameAZ:
            return filtered.sorted {
                let r = $0.displayTitle.compare($1.displayTitle, options: [.caseInsensitive, .numeric], range: nil, locale: locale)
                return r == .orderedSame ? $0.date > $1.date : r == .orderedAscending
            }
        }
    }
}

@Observable
final class WhikLibraryState {
    static let shared = WhikLibraryState()
    var query = WhikLibraryQuery()
}

/// Status line for a record that is not ready yet. Progress comes from the server job only (no estimate).
enum WhikRecordStatus {
    static func label(_ r: SpaceRecord) -> String? {
        if r.repairBadge != .none, r.status == .ready { return nil }
        switch r.status {
        case .ready: return nil
        case .draft: return L("Not sent")
        case .uploading: return L("Uploading")
        case .processing: return L("Processing")
        case .failed: return L("Failed")
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
    @Bindable private var state = WhikLibraryState.shared
    @State private var detail: SpaceRecord?
    /// Photo-made 3D Object opened full screen (the AR detail page is unused for now).
    @State private var openedAsset: MobileAssetDTO?
    @State private var assetToDelete: MobileAssetDTO?
    @State private var deleteFailed = false
    @State private var showFilters = false

    private var signedIn: Bool {
        if case .signedIn = auth.phase { return true }
        return false
    }

    private var allItems: [WhikLibraryItem] {
        appState.spaces.map(WhikLibraryItem.record) + assets.assets.map(WhikLibraryItem.asset)
    }

    private var items: [WhikLibraryItem] {
        state.query.apply(allItems, locale: AppLanguage.shared.locale)
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center) {
                        Text(L("Library"))
                            .font(WhikFont.largeTitle())
                            .foregroundStyle(WhikColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        WhikCircleButton(systemImage: "person", label: L("Profile and settings"), action: onProfile)
                    }
                    .padding(.top, 8)
                    WhikChips(items: [(.all, L("All")), (.spaces, L("Spaces")), (.objects, L("Objects"))],
                              selection: $state.query.category)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    if signedIn {
                        searchRow
                        // Captures that never finished uploading stay resumable (original package on device).
                        if state.query.category != .objects { UnsentCapturesSection(products: false) }
                        if state.query.category != .spaces { UnsentCapturesSection(products: true) }
                        if allItems.isEmpty {
                            emptyLibrary
                        } else if items.isEmpty {
                            noResults
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
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await refresh(force: true) }
            .background(WhikColors.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $detail) { space in
                SpaceDetailView(space: space)
            }
            .fullScreenCover(item: $openedAsset) { asset in
                WhikObjectViewer(snapshot: asset) { openedAsset = nil }
            }
            .confirmationDialog(L("Delete this 3D Object?"), isPresented: Binding(
                get: { assetToDelete != nil },
                set: { if !$0 { assetToDelete = nil } }
            ), titleVisibility: .visible, presenting: assetToDelete) { asset in
                Button(L("Delete"), role: .destructive) { Task { await delete(asset) } }
                Button(L("Cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("It will be deleted from both 3D Locker and WHIK, and removed from any space it's placed in. This can't be undone."))
            }
            .alert(L("Couldn't delete"), isPresented: $deleteFailed) {
                Button(L("OK"), role: .cancel) {}
            } message: {
                Text(L("Couldn't delete the object. Please try again in a moment."))
            }
            .sheet(isPresented: $showFilters) {
                WhikLibraryFilterSheet(query: $state.query)
                    .presentationDetents([.medium, .large])
            }
            .task(id: signedIn) { await refresh(force: false) }
            .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
                let jobId = note.userInfo?["jobId"] as? String
                if detail?.id == jobId { detail = nil }
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(WhikColors.textTertiary)
                    .accessibilityHidden(true)
                TextField(L("Search captures"), text: $state.query.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(WhikColors.textPrimary)
                if !state.query.search.isEmpty {
                    Button {
                        state.query.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(WhikColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WhikColors.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WhikColors.border, lineWidth: 1))

            Button {
                showFilters = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(WhikColors.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WhikColors.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
                    if state.query.extraFilterCount > 0 {
                        Text("\(state.query.extraFilterCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(WhikColors.onMint)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Circle().fill(WhikColors.mint))
                            .offset(x: 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Sort and filter"))
            .accessibilityValue(state.query.extraFilterCount > 0 ? L("%@ filters on", "\(state.query.extraFilterCount)") : "")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Text(L("No captures yet"))
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(WhikColors.textPrimary)
                .multilineTextAlignment(.center)
            pillButton(L("Capture"), action: onCapture)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private var noResults: some View {
        VStack(spacing: 14) {
            Text(L("No matching captures"))
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(WhikColors.textPrimary)
                .multilineTextAlignment(.center)
            pillButton(L("Clear filters")) {
                withAnimation(.easeOut(duration: 0.18)) { state.query.clearAll() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body).weight(.semibold))
                .foregroundStyle(WhikColors.onMint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(Capsule().fill(WhikColors.mint))
        }
        .buttonStyle(.plain)
    }

    private var guestState: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                Text(L("No captures yet"))
                    .font(.system(.title3).weight(.semibold))
                    .foregroundStyle(WhikColors.textPrimary)
                pillButton(L("Capture"), action: onCapture)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            Divider().overlay(WhikColors.border)
            Button {
                gate.signIn(reason: L("Sign in to see your captures."))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                    Text(L("Sign in to see your captures"))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text(L("Sign in")).foregroundStyle(WhikColors.mint)
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
                Button { open(item) } label: { Label(L("Open"), systemImage: "play.circle") }
            }
            Button { detail = r } label: { Label(L("Details, rename or delete"), systemImage: "info.circle") }
        case .asset(let a):
            Button { openedAsset = a } label: { Label(L("Open"), systemImage: "cube") }
            Button(role: .destructive) { assetToDelete = a } label: { Label(L("Delete object"), systemImage: "trash") }
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
            openedAsset = a
        }
    }

    private func delete(_ asset: MobileAssetDTO) async {
        do {
            try await MobileAssetsAPIClient().deleteAsset(id: asset.id)
            await VRUsdzCache().invalidate(assetId: asset.id)
            assets.removeAsset(id: asset.id)
            GonggiHaptics.medium()
        } catch {
            deleteFailed = true
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

/// Sort and extra filters in a sheet (kept off the main screen).
struct WhikLibraryFilterSheet: View {
    @Binding var query: WhikLibraryQuery
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L("Sort")) {
                    ForEach(WhikLibrarySort.allCases, id: \.self) { sort in
                        row(sort.label, on: query.sort == sort) { query.sort = sort }
                    }
                }
                Section(L("Type")) {
                    ForEach(WhikLibraryItem.Kind.allCases, id: \.self) { kind in
                        row(kind.label, on: query.kinds.contains(kind)) { toggle(&query.kinds, kind) }
                    }
                }
                Section(L("Status")) {
                    ForEach(WhikItemStatus.allCases, id: \.self) { status in
                        row(status.label, on: query.statuses.contains(status)) { toggle(&query.statuses, status) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WhikColors.background.ignoresSafeArea())
            .navigationTitle(L("Sort and filter"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Reset")) {
                        query.sort = .newest
                        query.kinds = []
                        query.statuses = []
                    }
                    .disabled(query.sort == .newest && query.extraFilterCount == 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func row(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(WhikColors.textPrimary)
                Spacer()
                if on {
                    Image(systemName: "checkmark").foregroundStyle(WhikColors.mint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .listRowBackground(WhikColors.surface)
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
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                            if let p = WhikRecordStatus.progress(r) {
                                ProgressView(value: p)
                                    .tint(WhikColors.mint)
                                    .accessibilityLabel(L("Server progress"))
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
                Text(item.displayTitle)
                    .font(.system(.body).weight(.semibold))
                    .foregroundStyle(WhikColors.textPrimary)
                    .lineLimit(1)
                Text(item.kind.label)
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
            if r.id.hasPrefix("gaussian:") {
                // 3D results: persistent thumbnail store (saved image → sharpest capture photo → viewer snapshot).
                WhikRecordThumbnail(
                    libraryId: r.id,
                    savedThumbnail: r.remoteImageURL.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil },
                    sessionId: GaussianGenerationStore.shared.spaceId(fromLibraryId: r.id)
                        .flatMap { GaussianGenerationStore.shared.record(spaceId: $0)?.sessionId },
                    placeholderSymbol: r.isProductResult ? "cube" : "cube.transparent"
                )
                .frame(width: width, height: height)
            } else {
                // 360° results: existing latlong thumbnail pipeline (memory + disk cache).
                SpaceThumbnailView(space: r, height: height, width: width, cornerRadius: 0, showsActivityOverlay: false)
            }
        case .asset(let a):
            ZStack {
                WhikColors.surface
                AssetThumbnailView(urlString: a.thumbUrl, size: min(width, height))
            }
            .frame(width: width, height: height)
        }
    }
}

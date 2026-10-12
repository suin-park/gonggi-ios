import SwiftUI

// 고객용 「제품 찾기」: choose a registered store (nearby first, or by name), download its published release, then search.
// No recording, editing or deleting exists on this path. Location is only used to sort the list: the store list can
// always be searched by name, and being near a store does not align the space (that happens in the camera).

final class StoreShelfCustomerModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case syncing(String)
        case failed(String)
        case ready
    }

    @Published var stores: [RemoteStoreItem] = []
    @Published var query = ""
    @Published var selectedId: String?
    @Published var phase: Phase = .choosing
    @Published var listError: String?
    @Published var isLoadingList = false
    @Published var source: StoreShelfSearchSource?

    private let api = StoreShelfAPIClient()
    private let cache = StoreShelfReleaseCache.shared

    var selected: RemoteStoreItem? { stores.first { $0.id == selectedId } }

    @MainActor
    func loadStores(latitude: Double?, longitude: Double?) async {
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            let items = try await api.listStores(latitude: latitude, longitude: longitude, query: nil)
            stores = items
            listError = items.isEmpty ? "아직 게시된 매장이 없어요" : nil
            if selectedId == nil || !items.contains(where: { $0.id == selectedId }) {
                // The store used last, else the nearest one.
                if let last = StoreShelfSelection.lastStoreId, items.contains(where: { $0.id == last }) {
                    selectedId = last
                } else {
                    selectedId = items.first?.id
                }
            }
        } catch let e as StoreShelfAPIError {
            listError = e.isServerWithoutFeature ? "이 서버에서는 아직 매장 기능을 사용할 수 없어요" : e.userMessage
        } catch {
            listError = StoreShelfAPIError.transport.userMessage
        }
    }

    var filtered: [RemoteStoreItem] {
        let q = ShelfNameSearch.normalize(query)
        guard !q.isEmpty else { return stores }
        return stores.filter {
            ShelfNameSearch.normalize($0.displayName).contains(q) || ShelfNameSearch.normalize($0.address).contains(q)
        }
    }

    @MainActor
    func openSelected() async {
        guard let store = selected else { return }
        phase = .syncing("매장 정보를 확인하고 있어요")
        do {
            let published = try await cache.sync(storeId: store.id, api: api) { [weak self] text in
                Task { @MainActor in self?.phase = .syncing(text) }
            }
            source = StoreShelfSearchSource.published(published, storeName: store.displayName)
            StoreShelfSelection.lastStoreId = store.id
            phase = .ready
        } catch let e as StoreShelfAPIError {
            phase = .failed(e.isServerWithoutFeature ? "이 매장은 아직 게시된 매대 정보가 없어요" : e.userMessage)
        } catch StoreShelfSyncError.integrity {
            phase = .failed("내려받은 자료가 올바르지 않아요. 다시 시도해 주세요")
        } catch StoreShelfSyncError.offlineNoCache {
            phase = .failed("네트워크에 연결할 수 없고 저장된 자료도 없어요")
        } catch {
            phase = .failed("매장 자료를 불러오지 못했어요")
        }
    }
}

struct StoreShelfCustomerView: View {
    let onClose: () -> Void

    @StateObject private var model = StoreShelfCustomerModel()
    @StateObject private var location = StoreShelfLocationProvider()

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            if model.phase == .ready, let source = model.source {
                // The camera screen: customers get no recording entry.
                StoreShelfSearchView(source: source, onBack: {
                    model.source = nil
                    model.phase = .choosing
                })
            } else {
                chooser
            }
        }
        .task { await model.loadStores(latitude: nil, longitude: nil) }
        .onChange(of: location.state) { _, state in
            if case .located(let lat, let lng) = state {
                Task { await model.loadStores(latitude: lat, longitude: lng) }
            }
        }
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                HStack {
                    Text(StoreShelfCopy.findTitle)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("닫기", action: onClose).foregroundStyle(GonggiColors.textSecondary)
                }
                .padding(.top, GonggiSpacing.md)

                Text("매장을 고르고 제품을 비추면 진열 위치를 안내해요")
                    .font(.subheadline)
                    .foregroundStyle(GonggiColors.textSecondary)

                locationRow

                TextField("매장 이름이나 주소로 찾기", text: $model.query)
                    .textFieldStyle(.roundedBorder)

                if model.isLoadingList && model.stores.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error = model.listError, model.stores.isEmpty {
                    Text(error).font(.subheadline).foregroundStyle(GonggiColors.warningCritical)
                } else {
                    storeMenu
                    if let s = model.selected { selectedCard(s) }
                }

                switch model.phase {
                case .syncing(let text):
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(text).font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                    }
                case .failed(let text):
                    Text(text).font(.footnote).foregroundStyle(GonggiColors.warningCritical)
                default:
                    EmptyView()
                }

                PrimaryButton(title: "이 매장에서 제품 찾기", icon: "magnifyingglass") {
                    Task { await model.openSelected() }
                }
                .disabled(model.selected == nil || model.phase != .choosing && !isFailed)
                .opacity(model.selected == nil ? 0.5 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.xxl)
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var locationRow: some View {
        switch location.state {
        case .idle, .failed:
            SecondaryButton(title: "내 주변 매장 보기", icon: "location") { location.request() }
        case .requesting:
            HStack(spacing: 8) {
                ProgressView()
                Text("위치를 확인하고 있어요").font(.footnote).foregroundStyle(GonggiColors.textSecondary)
            }
        case .located:
            Label("가까운 매장 순으로 보여요", systemImage: "location.fill")
                .font(.footnote)
                .foregroundStyle(GonggiColors.textSecondary)
        case .denied:
            Text("위치 권한이 없어요. 매장 이름으로 선택할 수 있어요.")
                .font(.footnote)
                .foregroundStyle(GonggiColors.textSecondary)
        }
    }

    private var storeMenu: some View {
        Menu {
            ForEach(model.filtered) { s in
                Button {
                    model.selectedId = s.id
                } label: {
                    Text(label(for: s))
                }
            }
        } label: {
            HStack {
                Text(model.selected.map { $0.displayName } ?? "매장을 선택하세요")
                    .foregroundStyle(GonggiColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.down").foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(GonggiColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .accessibilityLabel("매장 선택")
    }

    private func label(for s: RemoteStoreItem) -> String {
        var t = s.displayName + " · " + s.address
        if let d = s.distanceM { t += d < 1000 ? " · \(d)m" : String(format: " · %.1fkm", Double(d) / 1000) }
        return t
    }

    private func selectedCard(_ s: RemoteStoreItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.displayName).font(.headline).foregroundStyle(GonggiColors.textPrimary)
            Text(s.address).font(.subheadline).foregroundStyle(GonggiColors.textSecondary)
            Text("등록된 제품 \(s.productCount)개 · 게시본 v\(s.publishedVersion)")
                .font(.footnote)
                .foregroundStyle(GonggiColors.textTertiary)
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

import SwiftUI

// Manager-only screens: publish a saved record to customers, and confirm which catalog product (with its existing 3D
// asset) each store product is. Both are authorised again on the server; the app only decides what to show.

final class StoreShelfPublishModel: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case published(version: Int)
        case failed(String)
    }

    @Published var state: State = .idle
    private let publisher = StoreShelfPublisher()

    @MainActor
    func publish(storeId: String) async {
        state = .working("준비하고 있어요")
        do {
            let version = try await publisher.publishLocalRecord(storeId: storeId) { [weak self] text in
                Task { @MainActor in self?.state = .working(text) }
            }
            state = .published(version: version)
        } catch let e as StoreShelfAPIError {
            state = .failed(e.userMessage)
        } catch StoreShelfPublishError.noMap {
            state = .failed("저장된 공간 지도가 없어요. 매대를 다시 기록해 주세요")
        } catch StoreShelfPublishError.noProducts {
            state = .failed("게시할 제품이 없어요")
        } catch let e as StoreReleasePackerError {
            switch e {
            case .fileTooLarge(let name): state = .failed("파일이 너무 커서 게시하지 못했어요 (\(name))")
            default: state = .failed("게시 자료를 만들지 못했어요")
            }
        } catch {
            state = .failed("게시하지 못했어요")
        }
    }
}

struct StoreShelfPublishView: View {
    let store: StoreRecord
    @StateObject private var model = StoreShelfPublishModel()
    @State private var showLinks = false

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            switch model.state {
            case .idle:
                Text("게시하면 고객이 이 매장에서 제품을 찾을 수 있어요. 검토를 마친 기록만 게시해 주세요.")
                    .font(.footnote)
                    .foregroundStyle(GonggiColors.textSecondary)
                PrimaryButton(title: "고객에게 게시하기", icon: "paperplane") {
                    Task { await model.publish(storeId: store.id) }
                }
            case .working(let text):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(text).font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                }
            case .published(let version):
                Label("게시했어요 (v\(version))", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(GonggiColors.accentTeal)
                SecondaryButton(title: "제품에 3D 자산 연결하기", icon: "cube") { showLinks = true }
            case .failed(let text):
                Text(text).font(.footnote).foregroundStyle(GonggiColors.warningCritical)
                PrimaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                    Task { await model.publish(storeId: store.id) }
                }
            }
        }
        .sheet(isPresented: $showLinks) { StoreShelfLinkView(store: store) }
    }
}

final class StoreShelfLinkModel: ObservableObject {
    @Published var products: [ShelfProduct] = []
    @Published var links: [String: RemoteProductLink] = [:]
    @Published var message: String?
    @Published var catalog: [CatalogProduct] = []
    @Published var loadingCatalog = false

    let store: StoreRecord
    private let api = StoreShelfAPIClient()
    private let repository = StoreShelfRepository.shared

    init(store: StoreRecord) {
        self.store = store
        products = repository.shelfData(storeId: store.id)?.products ?? []
    }

    @MainActor
    func refreshLinks() async {
        do {
            let view = try await api.publishedRelease(storeId: store.id)
            links = Dictionary(view.productLinks.map { ($0.storeProductId, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            message = "연결 상태를 불러오지 못했어요"
        }
    }

    @MainActor
    func loadCatalog() async {
        guard catalog.isEmpty else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            let payload = try await CatalogAPIClient().fetchCatalogList()
            catalog = payload.products.filter { $0.placementType == .furniture3D }
        } catch {
            message = "카탈로그를 불러오지 못했어요"
        }
    }

    @MainActor
    func link(productId: String, to catalogProductId: String) async {
        do {
            try await api.linkProduct(storeId: store.id, storeProductId: productId, catalogProductId: catalogProductId)
            await refreshLinks()
            message = nil
        } catch let e as StoreShelfAPIError {
            message = e.userMessage
        } catch {
            message = "연결하지 못했어요"
        }
    }

    @MainActor
    func unlink(productId: String) async {
        do {
            try await api.unlinkProduct(storeId: store.id, storeProductId: productId)
            await refreshLinks()
        } catch {
            message = "연결을 해제하지 못했어요"
        }
    }
}

struct StoreShelfLinkView: View {
    @StateObject private var model: StoreShelfLinkModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFor: ShelfProduct?
    @State private var search = ""

    init(store: StoreRecord) {
        _model = StateObject(wrappedValue: StoreShelfLinkModel(store: store))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("제품이 비슷하다는 이유로 자동 연결하지 않아요. 맞는 카탈로그 상품을 직접 확인해 연결해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                if let m = model.message {
                    Section { Text(m).font(.footnote).foregroundStyle(GonggiColors.warningCritical) }
                }
                Section("제품") {
                    ForEach(model.products) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body)
                                if let link = model.links[p.id] {
                                    Text("연결됨: " + (link.catalogName ?? link.catalogProductId))
                                        .font(.caption)
                                        .foregroundStyle(GonggiColors.accentTeal)
                                } else {
                                    Text("연결 안 됨").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(model.links[p.id] == nil ? "연결" : "변경") { pickingFor = p }
                            if model.links[p.id] != nil {
                                Button("해제", role: .destructive) { Task { await model.unlink(productId: p.id) } }
                            }
                        }
                    }
                }
            }
            .navigationTitle("3D 자산 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .task { await model.refreshLinks() }
            .sheet(item: $pickingFor) { product in
                NavigationStack {
                    List {
                        if model.loadingCatalog { ProgressView() }
                        ForEach(filteredCatalog) { c in
                            Button {
                                Task { await model.link(productId: product.id, to: c.id) }
                                pickingFor = nil
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(c.productName)
                                    Text(c.partnerDisplayName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "카탈로그 상품 검색")
                    .navigationTitle(product.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { pickingFor = nil } } }
                    .task { await model.loadCatalog() }
                }
            }
        }
    }

    private var filteredCatalog: [CatalogProduct] {
        let q = ShelfNameSearch.normalize(search)
        guard !q.isEmpty else { return model.catalog }
        return model.catalog.filter { ShelfNameSearch.normalize($0.productName).contains(q) }
    }
}

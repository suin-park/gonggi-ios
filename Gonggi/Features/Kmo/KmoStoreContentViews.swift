import SwiftUI
import UIKit

// 고객의 「매장 둘러보기」: 게시된 매장 목록, 매장 화면, 매장에 연결된 360 공간.
// 일반 공개 공간과는 다른 자료다. 사장님이 공개를 선택한 공간의 복사본만 읽는다.

// MARK: - 매장 목록

@MainActor
final class KmoBrowseModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var stores: [RemoteBrowsableStore] = []
    private let api = StoreShelfAPIClient()

    func load(latitude: Double?, longitude: Double?) async {
        phase = .loading
        do {
            stores = try await api.browseStores(latitude: latitude, longitude: longitude)
            phase = .loaded
        } catch let e as StoreShelfAPIError {
            phase = .failed(e.isServerWithoutFeature ? "매장 목록을 지금은 볼 수 없어요" : e.userMessage)
        } catch {
            phase = .failed(StoreShelfAPIError.transport.userMessage)
        }
    }
}

struct KmoStoreBrowseView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = KmoBrowseModel()
    @StateObject private var location = StoreShelfLocationProvider()
    @State private var selected: RemoteBrowsableStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { dismiss() } label: {
                        Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Text(KmoCopy.browseStores)
                    .font(.title.weight(.bold))
                    .foregroundStyle(KmoColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(KmoBackground())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selected) { store in
            KmoStoreHomeView(store: store)
        }
        .task {
            if case .idle = location.state { location.request() }
            await model.load(latitude: nil, longitude: nil)
        }
        .onChange(of: location.state) { _, state in
            if case .located(let lat, let lng) = state {
                Task { await model.load(latitude: lat, longitude: lng) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
        case .failed(let text):
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.headline).foregroundStyle(KmoColors.warning)
                KmoSecondaryButton(title: "다시 시도") { Task { await model.load(latitude: nil, longitude: nil) } }
            }
        case .loaded:
            if model.stores.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("게시된 매장이 아직 없어요").font(.headline).foregroundStyle(KmoColors.textPrimary)
                    Text("사장님이 매장을 게시하면 여기에 나타나요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                }
                .kmoCard()
            } else {
                ForEach(model.stores) { store in
                    Button { selected = store } label: { KmoStoreListCard(store: store) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct KmoStoreListCard: View {
    let store: RemoteBrowsableStore

    private var hasPhoto: Bool { KmoImageSlot.initial(urlString: store.coverUrl).reservesPhotoHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasPhoto {
                KmoPhotoView(urlString: store.coverUrl, height: 120, cornerRadius: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.displayName).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if let d = ProductAvailabilityText.distance(store.distanceM) {
                        Text(d).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    }
                }
                Text(store.address).font(.subheadline).foregroundStyle(KmoColors.textSecondary).multilineTextAlignment(.leading)
                Text(store.hasTour ? "360 둘러보기 가능" : KmoTourText.notReady)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(store.hasTour ? KmoColors.accent : KmoColors.textSecondary)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KmoColors.card)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 매장 화면

struct KmoStoreHomeView: View {
    let store: RemoteBrowsableStore

    @Environment(\.dismiss) private var dismiss
    @State private var products: [RemotePublicProduct]?
    @State private var productsFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { dismiss() } label: {
                        Text("뒤로").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                if KmoImageSlot.initial(urlString: store.coverUrl).reservesPhotoHeight {
                    KmoPhotoView(urlString: store.coverUrl, height: 160, cornerRadius: 14)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName).font(.title2.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                    Text(store.address).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    if let d = ProductAvailabilityText.distance(store.distanceM) {
                        Text(d).font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
                    }
                }
                KmoTourEntry(storeId: store.id, hasTour: store.hasTour)
                KmoMapBlock(name: store.displayName, latitude: store.latitude, longitude: store.longitude)
                productsSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(KmoBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            do {
                products = try await StoreShelfAPIClient().storeProducts(storeId: store.id)
            } catch {
                productsFailed = true
            }
        }
    }

    @ViewBuilder
    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KmoSectionTitle(text: "이 매장의 제품")
            if let products {
                if products.isEmpty {
                    Text("게시된 제품이 아직 없어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                } else {
                    ForEach(products) { p in
                        HStack(spacing: 12) {
                            if KmoImageSlot.initial(urlString: p.imageUrl).reservesPhotoHeight {
                                KmoProductThumb(urlString: p.imageUrl, size: 52)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.headline).foregroundStyle(KmoColors.textPrimary).multilineTextAlignment(.leading)
                                if !p.subtitle.isEmpty {
                                    Text(p.subtitle).font(.footnote).foregroundStyle(KmoColors.textSecondary)
                                }
                                Text(KmoConfirmedText.line(iso: p.lastConfirmedAt)).font(.footnote).foregroundStyle(KmoColors.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(KmoColors.card)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Text(ProductAvailabilityText.short).font(.footnote).foregroundStyle(KmoColors.textSecondary)
                }
            } else if productsFailed {
                Text("제품 목록을 불러오지 못했어요").font(.subheadline).foregroundStyle(KmoColors.warning)
            } else {
                ProgressView()
            }
        }
    }
}

// MARK: - 360 둘러보기

/// 매장 화면과 제품 결과의 매장 상세에서 함께 쓰는 입구. 공개된 360이 없으면 짧은 안내만 보여 준다.
struct KmoTourEntry: View {
    let storeId: String
    let hasTour: Bool

    @State private var showTour = false

    var body: some View {
        Group {
            if hasTour {
                KmoSecondaryButton(title: "매장 둘러보기") { showTour = true }
            } else {
                Text(KmoTourText.notReady)
                    .font(.subheadline)
                    .foregroundStyle(KmoColors.textSecondary)
            }
        }
        .fullScreenCover(isPresented: $showTour) {
            KmoTourScreen(storeId: storeId, onClose: { showTour = false })
        }
    }
}

@MainActor
final class KmoTourModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case empty
        case failed(String)
        case choose([RemotePublicTourSpace])
        case opening(String)
        case viewing(SpaceViewerSession)
    }

    @Published var phase: Phase = .loading
    private let api = StoreShelfAPIClient()
    private var spaces: [RemotePublicTourSpace] = []

    func load(storeId: String) async {
        phase = .loading
        do {
            spaces = try await api.publicTour(storeId: storeId)
        } catch let e as StoreShelfAPIError {
            phase = .failed(e.userMessage)
            return
        } catch {
            phase = .failed(StoreShelfAPIError.transport.userMessage)
            return
        }
        switch spaces.count {
        case 0: phase = .empty
        case 1: await open(spaces[0])
        default: phase = .choose(spaces)
        }
    }

    func open(_ space: RemotePublicTourSpace) async {
        phase = .opening(space.title)
        do {
            let file = try await download(space)
            phase = .viewing(SpaceViewerSession(id: "kmo-tour-\(space.id)", fileURL: file, allowsOwnerControls: false))
        } catch {
            phase = .failed("360 공간을 불러오지 못했어요. 잠시 후 다시 시도해 주세요")
        }
    }

    func backToList() {
        phase = spaces.count > 1 ? .choose(spaces) : .empty
    }

    /// One bounded download (30 seconds); a bad or partial file is never handed to the viewer.
    private func download(_ space: RemotePublicTourSpace) async throws -> URL {
        guard let url = URL(string: space.imageUrl), url.scheme == "https" else { throw StoreShelfAPIError.invalidResponse }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("kmo-tour", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(space.id).jpg")
        if SpaceLatLongStore.isValidLocalFile(at: file.path) { return file }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (tmp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw StoreShelfAPIError.invalidResponse }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        guard SpaceLatLongStore.isValidLocalFile(at: file.path) else {
            try? FileManager.default.removeItem(at: file)
            throw StoreShelfAPIError.invalidResponse
        }
        return file
    }
}

struct KmoTourScreen: View {
    let storeId: String
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState
    @StateObject private var model = KmoTourModel()

    var body: some View {
        ZStack {
            KmoBackground()
            switch model.phase {
            case .loading:
                ProgressView()
            case .opening(let title):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("\(title)을 불러오고 있어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                }
            case .empty:
                message(KmoTourText.notReady, retry: false)
            case .failed(let text):
                message(text, retry: true)
            case .choose(let spaces):
                chooser(spaces)
            case .viewing(let session):
                SpaceVRNavigationHost(root: session, onClose: { model.backToList(); onClose() })
                    .environmentObject(appState)
                    .ignoresSafeArea()
            }
        }
        .task { await model.load(storeId: storeId) }
    }

    private func message(_ text: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text).font(.headline).foregroundStyle(KmoColors.textPrimary)
            if retry {
                KmoPrimaryButton(title: "다시 시도") { Task { await model.load(storeId: storeId) } }
            }
            KmoSecondaryButton(title: "닫기", action: onClose)
        }
        .padding(20)
    }

    private func chooser(_ spaces: [RemotePublicTourSpace]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    KmoSectionTitle(text: "매장 둘러보기")
                    Spacer()
                    Button(action: onClose) {
                        Text("닫기").font(.headline).foregroundStyle(KmoColors.textPrimary).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(spaces) { s in
                    Button { Task { await model.open(s) } } label: {
                        Text(s.title)
                            .font(.headline)
                            .foregroundStyle(KmoColors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .padding(.horizontal, 14)
                            .background(KmoColors.card)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KmoColors.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }
}

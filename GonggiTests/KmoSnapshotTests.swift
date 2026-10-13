import SwiftUI
import XCTest
@testable import Gonggi

/// 시안과 비교하기 위한 화면 캡처. 실제 서버나 계정 없이 고정된 시험 자료로 그린다(실제 데이터가 아님).
/// 출력 위치는 환경 변수 KMO_SHOT_DIR (CI에서는 TEST_RUNNER_KMO_SHOT_DIR).
@MainActor
final class KmoSnapshotTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 393, height: 852),
                                 dynamic: DynamicTypeSize = .large) throws {
        let root = view
            .environmentObject(AppState(isMockMode: true))
            .environment(\.dynamicTypeSize, dynamic)
            .preferredColorScheme(.dark)
        let host = UIHostingController(rootView: root)
        // 장면에 붙은 창이어야 화면이 그려진다.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.backgroundColor = UIColor(KmoColors.background)
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let dir = ProcessInfo.processInfo.environment["KMO_SHOT_DIR"] ?? NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var sample: RemoteProductSearchResult {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        let yesterday = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-27 * 3600))
        return RemoteProductSearchResult(
            identity: "sample-1", name: "코카콜라 오리지널", brand: nil, variant: nil, volumeText: "355ml", imageUrl: nil,
            stores: [
                RemoteProductStoreEntry(storeId: "s1", name: "커모 테스트 편의점", branchName: nil, address: "서울시 테스트로 1",
                                        latitude: 37.5, longitude: 127.0, distanceM: 350, lastConfirmedAt: iso,
                                        recordedQuantity: nil, quantityVerifiedAt: nil, shelves: ["음료 매대"], productIds: ["p1"]),
                RemoteProductStoreEntry(storeId: "s2", name: "커모 테스트 마트", branchName: nil, address: "서울시 테스트로 2",
                                        latitude: 37.51, longitude: 127.01, distanceM: 800, lastConfirmedAt: yesterday,
                                        recordedQuantity: 6, quantityVerifiedAt: yesterday, shelves: ["음료 매대"], productIds: ["p2"]),
            ])
    }

    private var recents: [KmoRecentProduct] {
        [KmoRecentProduct(identity: "a", name: "코카콜라", subtitle: "", imageUrl: nil, viewedAt: Date()),
         KmoRecentProduct(identity: "b", name: "노트", subtitle: "", imageUrl: nil, viewedAt: Date()),
         KmoRecentProduct(identity: "c", name: "사이드 테이블", subtitle: "", imageUrl: nil, viewedAt: Date())]
    }

    func testCustomerHome() throws {
        try render(KmoCustomerHomeView(previewRecent: recents), name: "01-customer-home")
        try render(KmoCustomerHomeView(previewRecent: []), name: "01b-customer-home-no-recent")
        try render(KmoCustomerHomeView(previewRecent: recents), name: "01c-customer-home-small-large-text",
                   size: CGSize(width: 375, height: 667), dynamic: .accessibility3)
        try render(MainTabView(), name: "01d-main-tab-customer")
    }

    func testResultsAndStore() throws {
        let model = StoreProductSearchModel()
        model.query = "코카콜라"
        model.results = [sample]
        model.selected = sample
        try render(NavigationStack { KmoResultsView(model: model, recent: KmoRecentModel(preview: []), path: .constant([]), autoSearch: false) },
                   name: "02-results")
        try render(NavigationStack { KmoResultsView(model: model, recent: KmoRecentModel(preview: []), path: .constant([]), autoSearch: false) },
                   name: "02c-results-small-large-text", size: CGSize(width: 375, height: 667), dynamic: .accessibility3)
        try render(NavigationStack { KmoStoreDetailView(model: model, storeId: "s1") }, name: "02b-store-detail")
    }

    func testOwnerHome() throws {
        _ = StoreShelfRepository.shared.ensureStore(id: "kmo-shot-store", name: "커모 테스트 편의점")
        try render(KmoOwnerHomeView(), name: "03-owner-home")
        try render(KmoOwnerHomeView(), name: "03c-owner-home-small-large-text",
                   size: CGSize(width: 375, height: 667), dynamic: .accessibility3)
    }

    // 사진 칸 상태와 매장 목록: 사진 없음은 작은 카드, 불러오기 실패는 다시 시도, 사진이 없는 카드는 큰 빈 상자를 쓰지 않는다.
    func testPhotoStatesAndStoreList() throws {
        let noPhoto = RemoteBrowsableStore(id: "a", name: "커모 테스트 편의점", branchName: nil, address: "서울시 테스트로 1",
                                           latitude: 37.5, longitude: 127, distanceM: 350, coverUrl: nil, hasTour: true)
        let failing = RemoteBrowsableStore(id: "b", name: "커모 테스트 마트", branchName: "2호점", address: "서울시 테스트로 2",
                                           latitude: nil, longitude: nil, distanceM: 800,
                                           coverUrl: "https://invalid.kmo-test.invalid/cover.jpg", hasTour: false)
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KmoStoreListCard(store: noPhoto)
                KmoStoreListCard(store: failing)
                KmoBrowseCard(title: KmoCopy.browseStores, subtitle: "게시된 매장 2곳", photoURL: nil)
                KmoBrowseCard(title: KmoCopy.mySpace, subtitle: nil, photoURL: nil)
            }
            .padding(20)
        }
        .background(KmoBackground())
        try render(view, name: "04-store-list-photo-states")
    }

    // 큰 글씨에서도 마지막 카드와 버튼까지 닿는지: 화면 높이를 내용 전체로 늘려 한 장에 담는다.
    func testLargeTextFullContent() throws {
        let small = CGSize(width: 375, height: 2600)
        try render(KmoCustomerHomeView(previewRecent: recents), name: "05-home-large-text-full", size: small, dynamic: .accessibility3)
        let model = StoreProductSearchModel()
        model.query = "코카콜라"
        model.results = [sample]
        model.selected = sample
        try render(NavigationStack { KmoResultsView(model: model, recent: KmoRecentModel(preview: []), path: .constant([]), autoSearch: false) },
                   name: "05b-results-large-text-full", size: CGSize(width: 375, height: 2200), dynamic: .accessibility3)
        try render(NavigationStack { KmoStoreDetailView(model: model, storeId: "s1") },
                   name: "05c-store-detail-large-text-full", size: CGSize(width: 375, height: 2200), dynamic: .accessibility3)
        _ = StoreShelfRepository.shared.ensureStore(id: "kmo-shot-store", name: "커모 테스트 편의점")
        try render(KmoOwnerHomeView(), name: "05d-owner-large-text-full", size: CGSize(width: 375, height: 2200), dynamic: .accessibility3)
    }

    func testStoreInfoScreen() throws {
        let store = StoreRecord(id: "kmo-shot-store", name: "커모 테스트 편의점", createdAt: Date())
        let tours = [
            RemoteTourSpace(id: "t1", title: "매장 입구에서 계산대까지", status: "DRAFT", width: 4096, height: 2048,
                            imageUrl: "https://invalid.kmo-test.invalid/t1.jpg", linkedAt: nil, publishedAt: nil),
            RemoteTourSpace(id: "t2", title: "음료 매대", status: "PUBLISHED", width: 4096, height: 2048,
                            imageUrl: "https://invalid.kmo-test.invalid/t2.jpg", linkedAt: nil, publishedAt: nil),
        ]
        try render(KmoStoreInfoView(store: store, coverUrl: nil, previewTours: tours, onClose: {}), name: "06-store-info")
    }
}

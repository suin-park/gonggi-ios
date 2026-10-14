import Metal
import SceneKit
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
        try render(KmoCustomerHomeView(previewRecent: recents, isMockMode: true), name: "01-customer-home")
        try render(KmoCustomerHomeView(previewRecent: [], isMockMode: true), name: "01b-customer-home-no-recent")
        try render(KmoCustomerHomeView(previewRecent: recents, isMockMode: true), name: "01c-customer-home-small-large-text",
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
        try render(KmoCustomerHomeView(previewRecent: recents, isMockMode: true), name: "05-home-large-text-full", size: small, dynamic: .accessibility3)
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

    // 고정 시험 모델: 도형으로 만든 의자. 실제 상품이 아니다. 무대, 웨이브, 버튼 배치와 회전을 확인한다.
    static func testScene() -> SCNScene {
        let scene = SCNScene()
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ x: Float, _ y: Float, _ z: Float, _ color: UIColor) {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: 0.02)
            g.firstMaterial?.diffuse.contents = color
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(x, y, z)
            scene.rootNode.addChildNode(n)
        }
        let fabric = UIColor(red: 0.45, green: 0.52, blue: 0.47, alpha: 1)
        let wood = UIColor(red: 0.78, green: 0.58, blue: 0.36, alpha: 1)
        box(0.8, 0.18, 0.8, 0, 0.45, 0, fabric)
        box(0.8, 0.7, 0.14, 0, 0.85, -0.33, fabric)
        for (x, z) in [(-0.34, -0.34), (0.34, -0.34), (-0.34, 0.34), (0.34, 0.34)] {
            box(0.06, 0.4, 0.06, Float(x), 0.2, Float(z), wood)
        }
        _ = KmoModelLoader.normalize(scene)
        return scene
    }

    func testHeroStageAndOfferButtons() throws {
        let scene = Self.testScene()
        let view = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(KmoCopy.brand).font(.title.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                        Text(KmoCopy.tagline).font(.footnote).foregroundStyle(KmoColors.textSecondary)
                    }
                    .padding(.horizontal, 20)
                    KmoProductStage(phase: .ready(KmoModelSceneBox(scene)), thumbnailUrl: nil, height: 280, forceActive: true, onRetry: {})
                    VStack(alignment: .leading, spacing: 4) {
                        Text("시험용 의자").font(.title2.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                        Text("시험 판매자").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                        Text("80,000원").font(.headline).foregroundStyle(KmoColors.textPrimary)
                    }
                    .padding(.horizontal, 20)
                    KmoOfferButtons(actions: [.ar, .buy("https://example.test/buy")], isLoadingAR: false, onAR: {}, onOpen: { _, _ in })
                        .padding(.horizontal, 20)
                }
                .padding(.vertical, 6)
                .background(KmoSurface.hero)
                KmoWaveTop(amplitude: 12).fill(KmoSurface.panel).frame(height: 26).background(KmoSurface.hero)
                VStack(alignment: .leading, spacing: 12) {
                    Text("제품 찾기").font(.title3.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                    KmoSecondaryButton(title: KmoCopy.camera) {}
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KmoSurface.panel)
            }
        }
        .background(KmoSurface.hero)
        try render(view, name: "07-hero-stage-test-model")
        try render(view, name: "07b-hero-stage-large-text", size: CGSize(width: 375, height: 1800), dynamic: .accessibility3)
    }

    /// 장면 자체가 보이는지: 화면에 올리지 않고 SceneKit 렌더러로 그려 모델이 그림 안에 있는지 확인한다.
    func testSceneRendersOffscreenAndTheModelIsInFrame() throws {
        let scene = Self.testScene()
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal을 쓸 수 없는 환경") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "kmo.camera", recursively: false)
        renderer.autoenablesDefaultLighting = true
        let size = CGSize(width: 480, height: 480)
        func shot(_ name: String) throws -> UIImage {
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            let dir = ProcessInfo.processInfo.environment["KMO_SHOT_DIR"] ?? NSTemporaryDirectory()
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            return image
        }
        func litFraction(_ image: UIImage) -> Double {
            guard let cg = image.cgImage else { return 0 }
            let w = cg.width, h = cg.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var lit = 0
            for i in stride(from: 0, to: data.count, by: 4) where Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]) > 60 { lit += 1 }
            return Double(lit) / Double(w * h)
        }
        let before = try shot("07d-model-offscreen-front")
        let fractionBefore = litFraction(before)
        XCTAssertGreaterThan(fractionBefore, 0.03, "모델이 화면 안에 보여야 한다")
        XCTAssertLessThan(fractionBefore, 0.95, "모델이 화면 전체를 덮지 않는다")
        KmoModelLoader.rotate(scene: scene, byDx: 120)
        let after = try shot("07e-model-offscreen-rotated")
        XCTAssertNotEqual(before.pngData(), after.pngData(), "손으로 돌리면 보이는 모습이 바뀐다")
    }

    func testStageLoadingAndFailureStates() throws {
        let view = VStack(spacing: 12) {
            KmoProductStage(phase: .loading, thumbnailUrl: nil, height: 160, onRetry: {})
            KmoProductStage(phase: .failed("3D 모델을 불러오지 못했어요"), thumbnailUrl: nil, height: 160, onRetry: {})
        }
        .background(KmoSurface.hero)
        try render(view, name: "07c-stage-loading-failed")
    }

    func testCustomTabBar() throws {
        let items = [KmoTabItem(id: "h", tab: .home, title: "홈"), KmoTabItem(id: "r", tab: nil, title: "기록하기"),
                     KmoTabItem(id: "l", tab: .library, title: "보관함"), KmoTabItem(id: "p", tab: .profile, title: "내 정보")]
        let bar = VStack {
            Spacer()
            KmoTabBar(items: items, selection: .constant(.home))
        }
        .background(KmoBackground())
        try render(bar, name: "08-tab-bar-customer")
        try render(bar, name: "08b-tab-bar-large-text", size: CGSize(width: 375, height: 300), dynamic: .accessibility3)
    }

    // 홈만이 아니라 보관함, 내 정보, 기록 선택, 상품 관리와 편집, 로그인까지 같은 톤인지 확인하는 캡처.
    func testToneUnifiedScreens() throws {
        try render(LibraryView(), name: "10-library")
        try render(ProfileView(), name: "11-profile")
        try render(KmoRecordChooserCover(onClose: {}), name: "12-record-chooser")
        try render(KmoOwnerRecordSheet(onClose: {}, onPick: { _ in }), name: "12b-owner-record-chooser")
        try render(AuthShellView(session: AuthSessionController.shared, decoration: .wireframeSphere), name: "13-sign-in")

        let store = StoreRecord(id: "kmo-shot-store", name: "커모 테스트 편의점", createdAt: Date())
        let item = RemoteCatalogItem(
            productId: "p1", shelfId: "sh1", shelfName: "음료 매대", name: "코카콜라 오리지널", brand: "코카콜라", variant: nil,
            volumeText: "355ml", status: "ACTIVE", quantity: 6, quantityBasis: "admin_confirmed", quantityVerifiedAt: nil,
            lastConfirmedAt: nil, infoUpdatedAt: "2026-10-14T00:00:00Z", nameLocked: true, origin: "release", imageUrl: nil, unpublishedChange: true)
        let catalog = RemoteCatalogView(
            editVersion: 3, publishedEditVersion: 2, publishedAt: nil,
            shelves: [RemoteCatalogShelf(id: "sh1", name: "음료 매대")],
            items: [item, RemoteCatalogItem(
                productId: "p2", shelfId: "sh1", shelfName: "음료 매대", name: "사이다", brand: nil, variant: nil, volumeText: "500ml",
                status: "ACTIVE", quantity: nil, quantityBasis: nil, quantityVerifiedAt: nil, lastConfirmedAt: nil,
                infoUpdatedAt: "2026-10-14T00:00:00Z", nameLocked: false, origin: "release", imageUrl: nil, unpublishedChange: false)])
        try render(StoreProductManagementView(store: store, showsClose: true, previewCatalog: catalog, onClose: {}), name: "14-product-management")
        let model = StoreProductManagementModel(store: store, previewCatalog: catalog)
        try render(NavigationStack {
            StoreProductEditSheet(item: item, shelves: catalog.shelves, model: model, onDone: {})
        }, name: "15-product-edit")
        try render(NavigationStack {
            StoreProductEditSheet(item: item, shelves: catalog.shelves, model: model, onDone: {})
        }, name: "15b-product-edit-large-text", size: CGSize(width: 375, height: 1400), dynamic: .accessibility3)
        try render(KmoTabBar(items: [KmoTabItem(id: "h", tab: .home, title: "우리 매장"), KmoTabItem(id: "r", tab: nil, title: "기록하기"),
                                     KmoTabItem(id: "l", tab: .library, title: "상품"), KmoTabItem(id: "p", tab: .profile, title: "내 정보")],
                             selection: .constant(.home)), name: "16-tab-bar-owner", size: CGSize(width: 320, height: 120))
    }
}

@MainActor
final class KmoModelTests: XCTestCase {
    func testUsdzFileOpensIsCenteredAndRotatesByHand() async throws {
        let source = KmoSnapshotTests.testScene()
        // 파일로 내보낸 USDZ를 다시 열어 같은 경로(파일 열기, 크기 맞춤)를 확인한다.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kmo-test-\(UUID().uuidString).usdz")
        let raw = SCNScene()
        if let pivot = source.rootNode.childNode(withName: KmoModelLoader.pivotName, recursively: false) {
            raw.rootNode.addChildNode(pivot.clone())
        }
        XCTAssertTrue(raw.write(to: url, options: nil, delegate: nil, progressHandler: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let box = await KmoModelLoader.load(url: url)
        let loaded = try XCTUnwrap(box).scene
        let pivot = try XCTUnwrap(loaded.rootNode.childNode(withName: KmoModelLoader.pivotName, recursively: false))
        let (lo, hi) = pivot.boundingBox
        let extent = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z)) * pivot.scale.x
        XCTAssertGreaterThan(extent, 0.5)
        XCTAssertLessThan(extent, 3.0)
        let before = pivot.eulerAngles.y
        let delta = KmoModelLoader.rotate(scene: loaded, byDx: 100)
        XCTAssertGreaterThan(delta, 0)
        XCTAssertEqual(pivot.eulerAngles.y, before + delta, accuracy: 0.0001)
        let back = KmoModelLoader.rotate(scene: loaded, byDx: -100)
        XCTAssertEqual(pivot.eulerAngles.y, before, accuracy: 0.0001)
        XCTAssertEqual(back, -delta, accuracy: 0.0001)
    }

    func testMissingFileIsAFailureNotAnEmptyScene() async {
        let box = await KmoModelLoader.load(url: URL(fileURLWithPath: "/nonexistent/none.usdz"))
        XCTAssertNil(box)
    }

    func testEmptySceneIsRejected() {
        XCTAssertNil(KmoModelLoader.normalize(SCNScene()))
    }
}

/// 현재 공개 카탈로그의 실제 가구 USDZ로 확인한다. 파일 주소는 CI 비밀값(KMO_REAL_USDZ_URLS, 줄바꿈으로 구분)에서만
/// 받고, 없으면 건너뛴다. 주소와 서명은 어디에도 출력하지 않는다.
@MainActor
final class KmoRealAssetTests: XCTestCase {
    private func urls() -> [URL] {
        (ProcessInfo.processInfo.environment["KMO_REAL_USDZ_URLS"] ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private func outDir() throws -> URL {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KMO_SHOT_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func png(_ renderer: SCNRenderer, _ size: CGSize) -> (UIImage, Data) {
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return (image, image.pngData() ?? Data())
    }

    func testRealFurnitureAssets() async throws {
        let list = urls()
        if list.isEmpty { throw XCTSkip("실제 자산 주소가 없어 건너뜀") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal을 쓸 수 없는 환경") }
        let dir = try outDir()
        var report = ["실제 공개 카탈로그 가구 자산 검증 (파일 주소와 서명은 기록하지 않음)"]
        for (i, url) in list.enumerated() {
            let (tmp, response) = try await URLSession.shared.download(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("kmo-real-\(i).usdz")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0

            let scene = try SCNScene(url: file, options: [.checkConsistency: false])
            let diag = try XCTUnwrap(KmoModelLoader.normalize(scene), "자산 \(i + 1)을 열 수 없음")
            report.append("자산 \(i + 1): \(bytes) 바이트, 파일 위쪽 축=\(diag.upAxis ?? "미기재"), 모델에 걸린 회전 최대=\(diag.maxAuthoredRotation) 라디안, 크기(장면 단위)=\(diag.extents), 처음 자세 좌우=\(diag.initialYaw) 위아래=\(diag.initialPitch)")

            // 모델 자체에 기울어짐이 없고, 처음 자세에도 위아래 기울기를 더하지 않는다.
            let pivot = try XCTUnwrap(scene.rootNode.childNode(withName: KmoModelLoader.pivotName, recursively: false))
            XCTAssertEqual(pivot.eulerAngles.x, 0, accuracy: 0.0001)
            XCTAssertEqual(pivot.eulerAngles.z, 0, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(scene.rootNode.childNode(withName: KmoModelLoader.cameraName, recursively: false)).position.y, 0, accuracy: 0.0001)

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = scene.rootNode.childNode(withName: KmoModelLoader.cameraName, recursively: false)
            renderer.autoenablesDefaultLighting = true
            let size = CGSize(width: 480, height: 640)
            let (_, initial) = png(renderer, size)
            try initial.write(to: dir.appendingPathComponent("real-\(i + 1)-a-initial.png"))

            KmoModelLoader.rotate(scene: scene, byDx: 130)
            let (_, rotated) = png(renderer, size)
            try rotated.write(to: dir.appendingPathComponent("real-\(i + 1)-b-rotated.png"))
            XCTAssertNotEqual(initial, rotated)

            let zoomedIn = KmoModelLoader.zoom(scene: scene, by: 1.5)
            let (_, zin) = png(renderer, size)
            try zin.write(to: dir.appendingPathComponent("real-\(i + 1)-c-zoom-in.png"))
            let clampedIn = KmoModelLoader.zoom(scene: scene, by: 10)
            XCTAssertEqual(clampedIn, KmoModelLoader.zoomRange.upperBound, accuracy: 0.001, "확대는 범위에서 멈춘다")
            let clampedOut = KmoModelLoader.zoom(scene: scene, by: 0.01)
            XCTAssertEqual(clampedOut, KmoModelLoader.zoomRange.lowerBound, accuracy: 0.001, "축소는 범위에서 멈춘다")
            let (_, zout) = png(renderer, size)
            try zout.write(to: dir.appendingPathComponent("real-\(i + 1)-d-zoom-out.png"))
            XCTAssertTrue(KmoModelLoader.isChanged(scene: scene))

            KmoModelLoader.reset(scene: scene)
            let (_, back) = png(renderer, size)
            try back.write(to: dir.appendingPathComponent("real-\(i + 1)-e-reset.png"))
            XCTAssertEqual(initial, back, "처음 모습으로 돌아온다")
            XCTAssertFalse(KmoModelLoader.isChanged(scene: scene))
            report.append("  확대 \(zoomedIn)배, 확대 한계 \(clampedIn), 축소 한계 \(clampedOut), 처음 모습 복원 일치")

            // 짧은 회전 영상(GIF): 24프레임, 한 바퀴 반
            let gif = dir.appendingPathComponent("real-\(i + 1)-rotate.gif") as CFURL
            if let dest = CGImageDestinationCreateWithURL(gif, "com.compuserve.gif" as CFString, 24, nil) {
                CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
                KmoModelLoader.reset(scene: scene)
                for _ in 0..<24 {
                    KmoModelLoader.rotate(scene: scene, byDx: 22)
                    let frame = renderer.snapshot(atTime: 0, with: CGSize(width: 240, height: 320), antialiasingMode: .multisampling4X)
                    if let cg = frame.cgImage {
                        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.08]] as CFDictionary)
                    }
                }
                CGImageDestinationFinalize(dest)
            }
        }
        try report.joined(separator: "\n").write(to: dir.appendingPathComponent("real-asset-report.txt"), atomically: true, encoding: .utf8)
    }
}

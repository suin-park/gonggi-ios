import PhotosUI
import SwiftUI
import UIKit

// 관리자 전용: 매장 상세 → 제품 관리.
//
// 이미 등록한 지점에서 제품 이름, 확인한 수량, 새 제품, 매대 연결, 취급 중단을 고친다. 매대를 다시 촬영하거나 공간 지도를
// 다시 만들지 않는다. 수정은 변경본에 저장되고 "고객에게 게시"를 눌러야 고객에게 보인다. 서버가 담당자인지 다시 확인한다.

@MainActor
final class StoreProductManagementModel: ObservableObject {
    let store: StoreRecord
    @Published var catalog: RemoteCatalogView?
    @Published var loading = false
    @Published var busy = false
    @Published var message: String?
    @Published var error: String?

    private let api = StoreShelfAPIClient()

    init(store: StoreRecord) {
        self.store = store
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            catalog = try await api.catalog(storeId: store.id)
            error = nil
        } catch let e as StoreShelfAPIError {
            error = e == .forbidden ? "이 매장의 담당자만 볼 수 있어요" : e.userMessage
        } catch {
            error = StoreShelfAPIError.transport.userMessage
        }
    }

    /// Runs one edit; a stale screen is refreshed instead of overwriting what was changed elsewhere.
    private func run(_ okText: String?, _ work: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await work()
            message = okText
            await load()
            return true
        } catch let e as StoreShelfAPIError {
            if case .server(_, let code) = e, code == "STALE_CATALOG" {
                await load()
                message = "다른 곳에서 먼저 바뀌어서 새로 불러왔어요. 다시 확인해 주세요."
            } else {
                error = e.userMessage
            }
            return false
        } catch {
            self.error = StoreShelfAPIError.transport.userMessage
            return false
        }
    }

    func save(item: RemoteCatalogItem, body: [String: StoreJSONValue]) async -> Bool {
        guard CatalogEditBody.hasChanges(body) else { return true }
        return await run("저장했어요. 고객에게는 게시하면 보여요.") {
            _ = try await api.catalogUpdate(storeId: store.id, productId: item.productId, shelfId: item.shelfId, body: body)
        }
    }

    func setStatus(_ item: RemoteCatalogItem, status: String) async -> Bool {
        guard let v = catalog?.editVersion else { return false }
        return await run(status == "ACTIVE" ? "다시 취급 중으로 바꿨어요." : "저장했어요. 고객에게는 게시하면 반영돼요.") {
            _ = try await api.catalogUpdate(storeId: store.id, productId: item.productId, shelfId: item.shelfId,
                                            body: ["baseVersion": .int(v), "status": .string(status)])
        }
    }

    func relink(_ item: RemoteCatalogItem, to shelfId: String) async -> Bool {
        guard let v = catalog?.editVersion else { return false }
        return await run("매대를 옮겼어요.") {
            _ = try await api.catalogRelink(storeId: store.id, productId: item.productId, fromShelfId: item.shelfId, toShelfId: shelfId, baseVersion: v)
        }
    }

    func publish() async -> Bool {
        guard let v = catalog?.editVersion else { return false }
        return await run("고객에게 게시했어요.") {
            _ = try await api.catalogPublish(storeId: store.id, baseVersion: v)
        }
    }

    func add(name: String, brand: String, variant: String, volume: String, shelfId: String, quantity: Int?, photo: ProductPhoto?) async -> Bool {
        guard let v = catalog?.editVersion else { return false }
        return await run("제품을 추가했어요. 고객에게는 게시하면 보여요.") {
            var body: [String: StoreJSONValue] = ["baseVersion": .int(v), "name": .string(name), "shelfId": .string(shelfId)]
            if !brand.isEmpty { body["brand"] = .string(brand) }
            if !variant.isEmpty { body["variant"] = .string(variant) }
            if !volume.isEmpty { body["volumeText"] = .string(volume) }
            if let quantity { body["quantity"] = .int(quantity) }
            if let photo {
                body["imageBytes"] = .int(photo.jpeg.count)
                if let e = photo.embedding { body["embedding"] = .string(e) }
                body["featureModel"] = .string(photo.featureModel)
            }
            let created = try await api.catalogAdd(storeId: store.id, body: body)
            if let photo, let up = created.upload {
                try await api.upload(photo.jpeg, to: RemoteUploadTarget(path: up.key, url: up.url, contentType: up.contentType, expiresInSec: 1800))
            }
        }
    }

    func changeImage(_ item: RemoteCatalogItem, photo: ProductPhoto) async -> Bool {
        guard let v = catalog?.editVersion else { return false }
        return await run("제품 사진을 바꿨어요.") {
            let r = try await api.catalogImage(storeId: store.id, productId: item.productId, baseVersion: v, imageBytes: photo.jpeg.count,
                                               embedding: photo.embedding, featureModel: photo.featureModel)
            try await api.upload(photo.jpeg, to: RemoteUploadTarget(path: r.upload.key, url: r.upload.url, contentType: r.upload.contentType, expiresInSec: 1800))
        }
    }
}

/// A product photo made on the device: the JPEG that is uploaded and the image feature used for the camera search.
struct ProductPhoto {
    var jpeg: Data
    var embedding: String?
    var featureModel: String

    static func make(from data: Data) -> ProductPhoto? {
        guard let image = UIImage(data: data) else { return nil }
        let longSide = max(image.size.width, image.size.height)
        let scale = longSide > 1024 ? 1024 / longSide : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8), jpeg.count <= 1_400_000 else { return nil }
        var embedding: String?
        let model = StoreShelfFeatureModelInfo.current(elementCount: 768)
        if let cg = resized.cgImage {
            let ex = ShelfAppearanceExtractor()
            if let crop = ex.crop(photo: cg), let app = ex.appearance(of: crop) { embedding = StoreVector(app.embedding).base64 }
        }
        return ProductPhoto(jpeg: jpeg, embedding: embedding, featureModel: model)
    }
}

struct StoreProductManagementView: View {
    let store: StoreRecord
    let onClose: () -> Void

    @StateObject private var model: StoreProductManagementModel
    @State private var editing: RemoteCatalogItem?
    @State private var adding = false
    @State private var confirmPublish = false

    init(store: StoreRecord, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _model = StateObject(wrappedValue: StoreProductManagementModel(store: store))
    }

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: 0) {
                topBar
                content
            }
        }
        .task { await model.load() }
        .sheet(item: $editing) { item in
            StoreProductEditSheet(item: item, shelves: model.catalog?.shelves ?? [], model: model) { editing = nil }
        }
        .sheet(isPresented: $adding) {
            StoreProductAddSheet(shelves: model.catalog?.shelves ?? [], model: model) { adding = false }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("닫기") }
                    .font(.headline).foregroundStyle(GonggiColors.textPrimary).frame(minHeight: 48).padding(.horizontal, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading, model.catalog == nil {
            ProgressView().frame(maxHeight: .infinity)
        } else if let error = model.error, model.catalog == nil {
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                Text(error).font(.headline).foregroundStyle(GonggiColors.warningCritical)
                SecondaryButton(title: "다시 불러오기", icon: "arrow.clockwise") { Task { await model.load() } }
                Spacer()
            }
            .padding(20)
        } else if let c = model.catalog {
            list(c)
        }
    }

    private func list(_ c: RemoteCatalogView) -> some View {
        let groups = Dictionary(grouping: c.items, by: { $0.shelfName ?? "매대 없음" })
        return ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                Text("제품 관리").font(.largeTitle.weight(.bold)).foregroundStyle(GonggiColors.textPrimary)
                Text(store.name).font(.title3).foregroundStyle(GonggiColors.textSecondary)
                if let m = model.message {
                    Text(m).font(.subheadline).foregroundStyle(GonggiColors.accentTeal)
                }
                if let e = model.error {
                    Text(e).font(.subheadline).foregroundStyle(GonggiColors.warningCritical)
                }
                publishCard(c)
                PrimaryButton(title: "새 제품 추가", icon: "plus") { adding = true }
                    .disabled(c.shelves.isEmpty)
                if c.shelves.isEmpty {
                    Text("매대가 게시된 뒤에 제품을 추가할 수 있어요.").font(.footnote).foregroundStyle(GonggiColors.textSecondary)
                }
                ForEach(groups.keys.sorted(), id: \.self) { shelf in
                    VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                        Text(shelf).font(.headline).foregroundStyle(GonggiColors.textPrimary)
                        ForEach(groups[shelf] ?? []) { item in
                            Button { editing = item } label: { row(item) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, GonggiSpacing.xxl)
        }
        .refreshable { await model.load() }
    }

    private func publishCard(_ c: RemoteCatalogView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let pending = c.unpublishedCount
            Text(pending > 0 ? "고객에게 아직 게시하지 않은 변경 \(pending)개" : "고객에게 보이는 내용과 같아요")
                .font(.headline)
                .foregroundStyle(pending > 0 ? GonggiColors.warningCritical : GonggiColors.textPrimary)
            if let at = ProductAvailabilityText.day(c.publishedAt) {
                Text("마지막 게시 \(at)").font(.footnote).foregroundStyle(GonggiColors.textTertiary)
            }
            PrimaryButton(title: "고객에게 게시", icon: "paperplane") { confirmPublish = true }
                .disabled(pending == 0 || model.busy)
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .confirmationDialog("고객에게 게시할까요?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("게시") { Task { _ = await model.publish() } }
            Button("취소", role: .cancel) {}
        }
    }

    private func row(_ item: RemoteCatalogItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.isEmpty ? "이름 없음" : item.name).font(.headline)
                    .foregroundStyle(item.name.isEmpty ? GonggiColors.warningCritical : GonggiColors.textPrimary)
                let detail = [item.brand, item.variant, item.volumeText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(GonggiColors.textSecondary) }
                Text(ProductAvailabilityText.quantityLine(quantity: item.quantity, verifiedIso: item.quantityVerifiedAt))
                    .font(.footnote).foregroundStyle(GonggiColors.textTertiary)
                if let s = item.statusText { Text(s).font(.footnote.weight(.semibold)).foregroundStyle(GonggiColors.warningCritical) }
            }
            Spacer()
            if item.unpublishedChange {
                Text("게시 전").font(.caption.weight(.semibold)).foregroundStyle(GonggiColors.warningCritical)
            }
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

struct StoreProductEditSheet: View {
    let item: RemoteCatalogItem
    let shelves: [RemoteCatalogShelf]
    @ObservedObject var model: StoreProductManagementModel
    let onDone: () -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var variant = ""
    @State private var volume = ""
    @State private var quantityText = ""
    @State private var quantityKnown = false
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmDiscontinue = false

    var body: some View {
        NavigationStack {
            Form {
                Section("제품 정보") {
                    TextField("제품 이름", text: $name)
                    TextField("브랜드", text: $brand)
                    TextField("맛이나 종류", text: $variant)
                    TextField("용량", text: $volume)
                }
                Section("확인한 수량 (\(item.shelfName ?? "매대 없음"))") {
                    Toggle("수량을 확인했어요", isOn: $quantityKnown)
                    if quantityKnown {
                        TextField("개수 (0도 입력할 수 있어요)", text: $quantityText).keyboardType(.numberPad)
                    }
                    Text("고객에게는 '확인했을 때 N개'로만 보여요. 지금 재고를 뜻하지 않아요.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("이 매장에서 지금 확인했어요") { Task { await saveConfirm() } }
                    PhotosPicker(selection: $photoItem, matching: .images) { Text("제품 사진 바꾸기") }
                    if item.status == "ACTIVE" {
                        Menu("다른 매대로 옮기기") {
                            ForEach(shelves.filter { $0.id != item.shelfId }) { s in
                                Button(s.name) { Task { if await model.relink(item, to: s.id) { onDone() } } }
                            }
                        }
                        Button("취급 중단", role: .destructive) { confirmDiscontinue = true }
                        Button("매대 연결 해제", role: .destructive) { Task { if await model.setStatus(item, status: "UNLINKED") { onDone() } } }
                    } else {
                        Button("다시 취급 중으로 바꾸기") { Task { if await model.setStatus(item, status: "ACTIVE") { onDone() } } }
                    }
                }
                if let e = model.error { Section { Text(e).foregroundStyle(.red) } }
            }
            .navigationTitle(item.name.isEmpty ? "제품" : item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { Task { await saveEdits() } }.disabled(model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("취급을 중단할까요?", isPresented: $confirmDiscontinue, titleVisibility: .visible) {
                Button("취급 중단", role: .destructive) { Task { if await model.setStatus(item, status: "DISCONTINUED") { onDone() } } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("기록은 남고, 게시하면 고객 검색에서 빠져요.")
            }
            .onChange(of: photoItem) { _, picked in
                guard let picked else { return }
                Task {
                    if let data = try? await picked.loadTransferable(type: Data.self), let photo = ProductPhoto.make(from: data) {
                        if await model.changeImage(item, photo: photo) { onDone() }
                    }
                    photoItem = nil
                }
            }
        }
        .onAppear {
            name = item.name
            brand = item.brand ?? ""
            variant = item.variant ?? ""
            volume = item.volumeText ?? ""
            quantityKnown = item.quantity != nil
            quantityText = item.quantity.map(String.init) ?? ""
        }
    }

    private func editBody(confirm: Bool) -> [String: StoreJSONValue] {
        CatalogEditBody.make(old: item, name: name, brand: brand, variant: variant, volume: volume,
                             quantity: Int(quantityText.trimmingCharacters(in: .whitespaces)), quantityKnown: quantityKnown && Int(quantityText.trimmingCharacters(in: .whitespaces)) != nil,
                             confirmNow: confirm, baseVersion: model.catalog?.editVersion ?? 0)
    }

    private func saveEdits() async {
        if await model.save(item: item, body: editBody(confirm: false)) { onDone() }
    }

    private func saveConfirm() async {
        if await model.save(item: item, body: editBody(confirm: true)) { onDone() }
    }
}

struct StoreProductAddSheet: View {
    let shelves: [RemoteCatalogShelf]
    @ObservedObject var model: StoreProductManagementModel
    let onDone: () -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var variant = ""
    @State private var volume = ""
    @State private var shelfId = ""
    @State private var quantityText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: ProductPhoto?

    var body: some View {
        NavigationStack {
            Form {
                Section("어느 매대에 있나요") {
                    Picker("매대", selection: $shelfId) {
                        ForEach(shelves) { Text($0.name).tag($0.id) }
                    }
                }
                Section("제품 정보") {
                    TextField("제품 이름", text: $name)
                    TextField("브랜드", text: $brand)
                    TextField("맛이나 종류", text: $variant)
                    TextField("용량", text: $volume)
                    TextField("확인한 수량 (모르면 비워 두세요)", text: $quantityText).keyboardType(.numberPad)
                }
                Section("제품 사진 (카메라로 찾을 때 쓰여요)") {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(photo == nil ? "사진 고르기" : "사진을 골랐어요. 다시 고르기")
                    }
                }
                if let e = model.error { Section { Text(e).foregroundStyle(.red) } }
            }
            .navigationTitle("새 제품 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        Task {
                            let ok = await model.add(
                                name: name.trimmingCharacters(in: .whitespaces), brand: brand.trimmingCharacters(in: .whitespaces),
                                variant: variant.trimmingCharacters(in: .whitespaces), volume: volume.trimmingCharacters(in: .whitespaces),
                                shelfId: shelfId, quantity: Int(quantityText.trimmingCharacters(in: .whitespaces)), photo: photo)
                            if ok { onDone() }
                        }
                    }
                    .disabled(model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || shelfId.isEmpty)
                }
            }
            .onChange(of: photoItem) { _, picked in
                guard let picked else { return }
                Task {
                    if let data = try? await picked.loadTransferable(type: Data.self) { photo = ProductPhoto.make(from: data) }
                }
            }
        }
        .onAppear { if shelfId.isEmpty { shelfId = shelves.first?.id ?? "" } }
    }
}

import PhotosUI
import SwiftUI
import UIKit

// 사장님 「매장 정보 수정」: 대표 사진과 매장 둘러보기(360 공간 연결).
// 대표 사진과 둘러보기 공간은 서로 다른 자료다. 둘러보기 공간은 초안으로 연결되고, 사장님이 어떤 공간이
// 공개되는지 확인한 뒤에만 고객에게 보인다. 모든 권한은 서버가 이 매장의 담당자인지로 정한다.

@MainActor
final class KmoStoreInfoModel: ObservableObject {
    let store: StoreRecord
    @Published var coverUrl: String?
    @Published var tours: [RemoteTourSpace] = []
    @Published var loading = false
    @Published var busy = false
    @Published var message: String?
    @Published var error: String?

    private let api = StoreShelfAPIClient()
    /// 화면 확인용 고정 목록. 서버를 부르지 않는다.
    private let previewTours: [RemoteTourSpace]?

    init(store: StoreRecord, coverUrl: String?, previewTours: [RemoteTourSpace]? = nil) {
        self.store = store
        self.coverUrl = coverUrl
        self.previewTours = previewTours
        if let previewTours { tours = previewTours }
    }

    func load() async {
        if previewTours != nil { return }
        loading = true
        defer { loading = false }
        do {
            tours = try await api.tourSpaces(storeId: store.id)
            error = nil
        } catch let e as StoreShelfAPIError {
            error = e == .forbidden ? "이 매장의 담당자만 볼 수 있어요" : e.userMessage
        } catch {
            self.error = StoreShelfAPIError.transport.userMessage
        }
    }

    /// The old photo stays until the new one was seen by the server; a failure changes nothing.
    func uploadCover(_ image: UIImage) async {
        guard let jpeg = KmoCoverImage.jpeg(from: image) else {
            error = "사진 용량이 너무 커요. 다른 사진을 골라 주세요"
            return
        }
        busy = true
        message = nil
        error = nil
        defer { busy = false }
        do {
            let target = try await api.coverUpload(storeId: store.id, bytes: jpeg.count)
            try await api.upload(jpeg, to: RemoteUploadTarget(path: target.key, url: target.url, contentType: target.contentType, expiresInSec: 900))
            coverUrl = try await api.coverConfirm(storeId: store.id, key: target.key)
            message = "대표 사진을 바꿨어요"
            await StoreShelfRoleModel.shared.refresh()
        } catch let e as StoreShelfAPIError {
            error = "사진을 올리지 못했어요. 이전 사진은 그대로예요. " + e.userMessage
        } catch {
            self.error = "사진을 올리지 못했어요. 이전 사진은 그대로예요"
        }
    }

    func link(spaceId: String, title: String?) async {
        busy = true
        message = nil
        error = nil
        defer { busy = false }
        do {
            _ = try await api.linkTourSpace(storeId: store.id, spaceId: spaceId, title: title)
            message = "초안으로 연결했어요. 확인한 뒤 공개해 주세요"
            await load()
        } catch let e as StoreShelfAPIError {
            if case .server(_, let code) = e {
                error = KmoTourText.linkError(code: code)
            } else if e == .notFound {
                error = "이 계정의 완료된 공간만 연결할 수 있어요"
            } else {
                error = e.userMessage
            }
        } catch {
            self.error = StoreShelfAPIError.transport.userMessage
        }
    }

    func act(_ tour: RemoteTourSpace, action: String, confirm: Bool = false) async {
        busy = true
        message = nil
        error = nil
        defer { busy = false }
        do {
            _ = try await api.tourAction(storeId: store.id, tourId: tour.id, action: action, confirm: confirm)
            message = action == "publish" ? "고객에게 공개했어요" : "공개를 중지했어요"
            await load()
        } catch let e as StoreShelfAPIError {
            error = e.userMessage
        } catch {
            self.error = StoreShelfAPIError.transport.userMessage
        }
    }

    func remove(_ tour: RemoteTourSpace) async {
        busy = true
        defer { busy = false }
        do {
            try await api.removeTourSpace(storeId: store.id, tourId: tour.id)
            message = "연결을 해제했어요"
            await load()
        } catch let e as StoreShelfAPIError {
            error = e.userMessage
        } catch {
            self.error = StoreShelfAPIError.transport.userMessage
        }
    }
}

struct KmoStoreInfoView: View {
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState
    @StateObject private var model: KmoStoreInfoModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSpacePicker = false
    @State private var publishing: RemoteTourSpace?
    @State private var removing: RemoteTourSpace?

    init(store: StoreRecord, coverUrl: String?, previewTours: [RemoteTourSpace]? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _model = StateObject(wrappedValue: KmoStoreInfoModel(store: store, coverUrl: coverUrl, previewTours: previewTours))
    }

    var body: some View {
        ZStack {
            KmoBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button(action: onClose) {
                            Text("닫기").font(.body).foregroundStyle(KmoColors.textSecondary).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    Text("매장 정보 수정").font(.title.weight(.bold)).foregroundStyle(KmoColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.store.name).font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    if let m = model.message { Text(m).font(.subheadline).foregroundStyle(KmoColors.accent) }
                    if let e = model.error { Text(e).font(.subheadline).foregroundStyle(KmoColors.warning) }
                    coverSection
                    toursSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .task { await model.load() }
        .onChange(of: photoItem) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await model.uploadCover(image)
                } else {
                    model.error = "사진을 읽지 못했어요. 다른 사진을 골라 주세요"
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            KmoCameraPicker(
                onImage: { image in
                    showCamera = false
                    Task { await model.uploadCover(image) }
                },
                onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSpacePicker) {
            KmoSpacePickerSheet(onPick: { space in
                showSpacePicker = false
                Task { await model.link(spaceId: space.id, title: space.name) }
            }, onClose: { showSpacePicker = false })
            .environmentObject(appState)
        }
        .confirmationDialog(
            publishing.map { KmoTourText.publishConfirm(title: $0.title) } ?? "",
            isPresented: Binding(get: { publishing != nil }, set: { if !$0 { publishing = nil } }),
            titleVisibility: .visible
        ) {
            Button("고객에게 공개") {
                if let t = publishing { Task { await model.act(t, action: "publish", confirm: true) } }
                publishing = nil
            }
            Button("취소", role: .cancel) { publishing = nil }
        }
        .confirmationDialog(
            "연결을 해제할까요?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("연결 해제", role: .destructive) {
                if let t = removing { Task { await model.remove(t) } }
                removing = nil
            }
            Button("취소", role: .cancel) { removing = nil }
        } message: {
            Text("보관함의 원래 공간은 그대로 남아요")
        }
    }

    // MARK: 대표 사진

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KmoSectionTitle(text: "대표 사진")
            if KmoImageSlot.initial(urlString: model.coverUrl).reservesPhotoHeight {
                KmoPhotoView(urlString: model.coverUrl, height: 160, cornerRadius: 14)
            } else {
                Text("아직 등록한 사진이 없어요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text(model.coverUrl == nil ? "사진 선택" : "사진 바꾸기")
                        .font(.headline)
                        .foregroundStyle(KmoColors.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(KmoColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(model.busy)
                if KmoCameraPicker.isAvailable {
                    KmoSecondaryButton(title: "사진 촬영") { showCamera = true }
                        .disabled(model.busy)
                }
            }
            if model.busy { HStack(spacing: 8) { ProgressView(); Text("올리는 중이에요").font(.footnote).foregroundStyle(KmoColors.textSecondary) } }
        }
    }

    // MARK: 매장 둘러보기

    private var toursSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KmoSectionTitle(text: "매장 둘러보기 공간")
            Text("보관함의 360 공간을 연결하면 초안이 돼요. 공개를 눌러야 고객에게 보여요")
                .font(.footnote)
                .foregroundStyle(KmoColors.textSecondary)
            if model.loading && model.tours.isEmpty { ProgressView() }
            ForEach(model.tours) { tour in tourCard(tour) }
            KmoSecondaryButton(title: "보관함에서 공간 연결") { showSpacePicker = true }
                .disabled(model.busy)
        }
    }

    private func tourCard(_ tour: RemoteTourSpace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if KmoImageSlot.initial(urlString: tour.imageUrl).reservesPhotoHeight {
                KmoPhotoView(urlString: tour.imageUrl, height: 100, cornerRadius: 10)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tour.title).font(.headline).foregroundStyle(KmoColors.textPrimary)
                Spacer(minLength: 8)
                Text(KmoTourText.statusLabel(tour.status))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tour.isPublished ? KmoColors.accent : KmoColors.textSecondary)
            }
            HStack(spacing: 8) {
                if tour.isPublished {
                    textAction("공개 중지") { Task { await model.act(tour, action: "unpublish") } }
                } else {
                    textAction("공개") { publishing = tour }
                }
                textAction("연결 해제") { removing = tour }
            }
        }
        .kmoCard()
    }

    private func textAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(KmoColors.accent)
                .frame(minWidth: 64, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }
}

/// 보관함의 내 공간 중 완성된 것만. 다른 사용자의 공간은 목록에 없고, 서버가 소유권을 다시 확인한다.
struct KmoSpacePickerSheet: View {
    let onPick: (SpaceRecord) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState

    private var ready: [SpaceRecord] {
        appState.spaces.filter { $0.status == .ready }
    }

    var body: some View {
        ZStack {
            KmoBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        KmoSectionTitle(text: "연결할 공간")
                        Spacer()
                        Button(action: onClose) {
                            Text("닫기").font(.headline).foregroundStyle(KmoColors.textPrimary).frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    if ready.isEmpty {
                        Text("완성된 공간이 아직 없어요. 매장 촬영으로 만들어 보세요").font(.subheadline).foregroundStyle(KmoColors.textSecondary)
                    }
                    ForEach(ready) { space in
                        Button { onPick(space) } label: {
                            HStack(spacing: 12) {
                                if space.remoteImageURL != nil || space.localLatLongPath != nil {
                                    SpaceThumbnailView(space: space, height: 56, width: 84, cornerRadius: 8, showsActivityOverlay: false)
                                }
                                Text(space.name)
                                    .font(.headline)
                                    .foregroundStyle(KmoColors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
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
}

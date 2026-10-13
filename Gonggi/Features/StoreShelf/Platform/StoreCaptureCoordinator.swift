import Foundation
import UIKit

/// Moves one capture through upload, analysis and import. Every step is idempotent on the server and recorded in the
/// capture's manifest, so it can be called again after a lost connection or an app restart and continues where it
/// stopped. It asks for ONE analysis per submit: starting another one is an explicit action of the person.
@MainActor
final class StoreCaptureCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case uploading(done: Int, total: Int)
        case analyzing
        case importing
        case ready
        case failed(StoreCaptureFailure)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var run: RemoteAnalysisRun?
    @Published private(set) var elapsedAnalysisSeconds = 0
    private(set) var manifest: CaptureSessionManifest
    private(set) var imported: AnalysisImportResult?
    private(set) var remoteDraft: RemoteAnalysisDraft?

    private let api: StoreShelfAPIClient
    private let store: StoreCaptureStore
    private let repository: StoreShelfRepository
    private var task: Task<Void, Never>?

    /// Polling of the analysis: every `pollSeconds` for at most `maxPollSeconds`.
    var pollSeconds: UInt64 = 3
    var maxPollSeconds = 360

    init(manifest: CaptureSessionManifest, api: StoreShelfAPIClient = StoreShelfAPIClient(), store: StoreCaptureStore = .shared,
         repository: StoreShelfRepository = .shared) {
        self.manifest = manifest
        self.api = api
        self.store = store
        self.repository = repository
    }

    var photoCount: Int { manifest.photos.count }

    func start(force: Bool = false) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.process(force: force)
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func persist() {
        try? store.save(manifest)
    }

    private func fail(_ failure: StoreCaptureFailure) {
        manifest.lastError = failure.message
        manifest.status = .failed
        persist()
        phase = .failed(failure)
    }

    private func failure(for error: Error) -> StoreCaptureFailure {
        switch error as? StoreShelfAPIError {
        case .transport?: return .network
        case .server(let status, let code)?: return StoreCaptureFailure.fromServer(status: status, code: code)
        case .notSignedIn?: return StoreCaptureFailure(kind: .unavailable, message: "로그인이 필요해요")
        case .forbidden?: return StoreCaptureFailure(kind: .unavailable, message: "이 매장의 담당자가 아니에요")
        case .notFound?, .invalidResponse?: return StoreCaptureFailure(kind: .other, message: "서버 응답을 확인하지 못했어요")
        case nil: return StoreCaptureFailure(kind: .other, message: "알 수 없는 오류가 발생했어요")
        }
    }

    func process(force: Bool) async {
        manifest.lastError = nil
        // A draft that was already fetched is imported without any request.
        if manifest.status == .draftReady, let data = store.readDraft(sessionId: manifest.clientSessionId),
           let view = try? JSONDecoder().decode(RemoteCaptureView.self, from: data), let draft = view.draft {
            run = view.run
            await importDraft(draft)
            return
        }
        do {
            // 1. Session on the server (idempotent on the client session id).
            if manifest.serverSessionId == nil {
                let started = try await api.startCapture(
                    storeId: manifest.storeId,
                    body: StartCaptureBody(clientSessionId: manifest.clientSessionId, storeContext: manifest.storeContext,
                                           contextLabel: manifest.contextLabel,
                                           device: ["model": manifest.device, "build": manifest.appBuild, "os": UIDevice.current.systemVersion]))
                manifest.serverSessionId = started.sessionId
                for id in started.uploadedPhotoIds {
                    if let i = manifest.photos.firstIndex(where: { $0.id == id }) { manifest.photos[i].uploaded = true }
                }
                persist()
            }
            guard let sid = manifest.serverSessionId else { return fail(StoreCaptureFailure(kind: .other, message: "서버 세션을 만들지 못했어요")) }

            // 2. Photos: register, upload, confirm.
            manifest.status = .uploading
            persist()
            try await uploadPending(sessionId: sid)
            try Task.checkCancellation()

            // 3. Analysis: one request; the server returns the same run for a repeated request.
            manifest.status = .analyzing
            persist()
            phase = .analyzing
            let started = try await api.startAnalysis(storeId: manifest.storeId, sessionId: sid, force: force)
            manifest.runId = started.runId
            manifest.analysisRequests += 1
            persist()

            // 4. Wait for the draft.
            var waited = 0
            while waited <= maxPollSeconds {
                try Task.checkCancellation()
                let view = try await api.capture(storeId: manifest.storeId, sessionId: sid)
                run = view.run
                elapsedAnalysisSeconds = waited
                if view.session.status == "DRAFT", let draft = view.draft {
                    if let data = try? JSONEncoder().encode(view) { try? store.writeDraft(sessionId: manifest.clientSessionId, data: data) }
                    manifest.status = .draftReady
                    persist()
                    await importDraft(draft)
                    return
                }
                if view.session.status == "FAILED" || view.run?.status == "FAILED" {
                    return fail(StoreCaptureFailure.fromRun(errorCode: view.run?.errorCode))
                }
                try await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
                waited += Int(pollSeconds)
            }
            fail(StoreCaptureFailure(kind: .analysisFailed, message: "분석이 오래 걸리고 있어요. 잠시 후 다시 확인해 주세요"))
        } catch is CancellationError {
            phase = .idle
        } catch {
            fail(failure(for: error))
        }
    }

    private func uploadPending(sessionId: String) async throws {
        for _ in 0..<2 {
            let pending = manifest.pendingUploads
            guard !pending.isEmpty else { break }
            phase = .uploading(done: manifest.photos.count - pending.count, total: manifest.photos.count)
            let registered = try await api.registerPhotos(
                storeId: manifest.storeId, sessionId: sessionId,
                body: RegisterPhotosBody(photos: manifest.photos.map { $0.registerBody(iso: { Self.isoString($0) }) }, planes: manifest.planes))
            let already = Set(registered.alreadyUploaded)
            for id in already {
                if let i = manifest.photos.firstIndex(where: { $0.id == id }) { manifest.photos[i].uploaded = true }
            }
            var done = manifest.photos.filter(\.uploaded).count
            for target in registered.uploads {
                try Task.checkCancellation()
                guard let i = manifest.photos.firstIndex(where: { $0.id == target.photoId }),
                      let data = store.readPhoto(sessionId: manifest.clientSessionId, fileName: manifest.photos[i].fileName) else { continue }
                try await api.uploadPhoto(data, to: target)
                manifest.photos[i].uploaded = true
                done += 1
                phase = .uploading(done: done, total: manifest.photos.count)
                persist()
            }
            let confirmed = try await api.confirmUploads(storeId: manifest.storeId, sessionId: sessionId)
            if confirmed.missing.isEmpty { return }
            // The server does not have these: upload them again in the next round.
            for id in confirmed.missing {
                if let i = manifest.photos.firstIndex(where: { $0.id == id }) { manifest.photos[i].uploaded = false }
            }
            persist()
        }
        if !manifest.pendingUploads.isEmpty { throw StoreShelfAPIError.server(status: 409, code: "UPLOAD_INCOMPLETE") }
    }

    nonisolated static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // MARK: Import

    private func importDraft(_ draft: RemoteAnalysisDraft) async {
        phase = .importing
        remoteDraft = draft
        let sessionId = manifest.clientSessionId
        let storeId = manifest.storeId
        let existing = repository.shelfData(storeId: storeId) ?? StoreShelfData.empty(storeId: storeId)
        let trail = manifest.walkTrail
        let capturedAt = manifest.createdAt
        let store = self.store
        let result = await Task.detached(priority: .userInitiated) { () -> AnalysisImportResult in
            let extractor = ShelfAppearanceExtractor()
            let cache = PhotoCache(store: store, sessionId: sessionId)
            let hooks = AnalysisImportHooks(
                productImage: { photoId, box in
                    guard let image = cache.image(photoId) else { return nil }
                    let w = Float(image.width), h = Float(image.height)
                    let rect = StoreImageSpace.PixelRect(minU: box.x0 * w, minV: box.y0 * h, maxU: box.x1 * w, maxV: box.y1 * h)
                    guard let crop = extractor.crop(uprightPhoto: image, rect: rect, padding: 0.03),
                          let appearance = extractor.appearance(of: crop) else { return nil }
                    return AnalysisProductImage(jpeg: crop.jpeg, embedding: appearance.embedding, color: appearance.color)
                },
                shelfPhoto: { cache.data($0) })
            return AnalysisImporter.importDraft(draft: draft, existing: existing, storeId: storeId, capturedAt: capturedAt,
                                                walkTrail: trail, newId: { UUID().uuidString }, hooks: hooks)
        }.value
        imported = result
        phase = .ready
    }

    /// Marks the capture as taken over by the review (after it was saved).
    func markImported() {
        manifest.status = .imported
        persist()
    }

    /// Photo files by id of this capture, decoded once.
    private final class PhotoCache: @unchecked Sendable {
        private let store: StoreCaptureStore
        private let sessionId: String
        private var images: [String: CGImage] = [:]
        private var names: [String: String] = [:]
        private let lock = NSLock()

        init(store: StoreCaptureStore, sessionId: String) {
            self.store = store
            self.sessionId = sessionId
            if let m = store.load(sessionId) {
                for p in m.photos { names[p.id] = p.fileName }
            }
        }

        func data(_ id: String) -> Data? {
            guard let name = names[id] else { return nil }
            return store.readPhoto(sessionId: sessionId, fileName: name)
        }

        func image(_ id: String) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            if let i = images[id] { return i }
            guard let d = data(id), let img = UIImage(data: d)?.cgImage else { return nil }
            images[id] = img
            return img
        }
    }
}

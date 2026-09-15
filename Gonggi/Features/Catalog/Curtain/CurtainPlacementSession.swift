import Foundation
import SwiftUI

enum CurtainPlacementPhase: Equatable {
    case idle
    case awaitingSeed
    case seedSelected(CurtainSeedCapture)
    case creatingJob
    case polling(String)
    case awaitingConfirmation(CurtainPlacementJob)
    case compositing
    case comparing(originalPath: String, resultPath: String, revisionId: String?)
    case failed(String)
    case saved
}

@MainActor
final class CurtainPlacementSession: ObservableObject {
    @Published private(set) var phase: CurtainPlacementPhase = .idle
    @Published private(set) var pending: PendingCurtainPlacement?
    @Published private(set) var markerYawDeg: Float?
    @Published private(set) var markerPitchDeg: Float?
    @Published private(set) var windowPolygon: [CurtainUVPoint]?
    @Published private(set) var warnings: [CurtainSeedWarning] = []
    @Published var showConsentSheet = false
    @Published var bannerMessage: String?
    @Published var errorMessage: String?

    private var job: CurtainPlacementJob?
    private var pollTask: Task<Void, Never>?
    private var client: (any CurtainPlacementServing)?
    private var sessionId: String = ""
    private var latLongWidth: Int = 3840
    private var latLongHeight: Int = 1920
    private var aiConsentAccepted = false

    func configure(useMock: Bool) {
        client = useMock ? CurtainPlacementMockClient() : MobileCurtainPlacementAPIClient()
    }

    func start(with pending: PendingCurtainPlacement, sessionId: String) {
        self.pending = pending
        self.sessionId = sessionId
        phase = .awaitingSeed
        bannerMessage = "커튼을 설치할 창문을 눌러주세요"
        markerYawDeg = nil
        markerPitchDeg = nil
        windowPolygon = nil
        warnings = []
        job = nil
        aiConsentAccepted = false
        showConsentSheet = false
        errorMessage = nil
    }

    var isActive: Bool {
        switch phase {
        case .idle, .saved: return false
        default: return true
        }
    }

    func handleSeedTap(yawDeg: Float, pitchDeg: Float, tapPoint: CGPoint?, viewSize: CGSize) {
        guard case .awaitingSeed = phase, let pending else { return }
        let capture = CurtainSeedMath.captureFromEquirectTap(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            tapPoint: tapPoint,
            viewSize: viewSize,
            latLongWidth: latLongWidth,
            latLongHeight: latLongHeight,
            spaceId: sessionId,
            baseRevisionId: pending.baseRevisionId
        )
        markerYawDeg = yawDeg
        markerPitchDeg = pitchDeg
        warnings = capture.clientWarnings
        phase = .seedSelected(capture)
        showConsentSheet = true
    }

    func cancelConsent() {
        showConsentSheet = false
        phase = .awaitingSeed
        markerYawDeg = nil
        markerPitchDeg = nil
        warnings = []
        bannerMessage = "커튼을 설치할 창문을 눌러주세요"
    }

    func acceptConsentAndCreateJob() {
        guard case .seedSelected(let capture) = phase, let pending, let client else { return }
        aiConsentAccepted = true
        showConsentSheet = false
        phase = .creatingJob
        bannerMessage = "창문을 찾고 있어요…"
        let request = CurtainPlacementCreateRequest(
            aiConsentAccepted: true,
            catalogProductId: pending.productId,
            catalogVariantId: pending.variantId,
            productRevision: pending.productRevision,
            catalog2DAssetId: pending.catalog2DAssetId,
            seed: capture.seed
        )
        let idempotencyKey = Self.idempotencyKey(
            spaceId: sessionId,
            baseRevisionId: pending.baseRevisionId,
            productId: pending.productId,
            variantId: pending.variantId,
            seed: capture.seed
        )
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do {
                let created: CurtainPlacementJob
                if let existingId = job?.id {
                    created = try await client.reselectWindow(
                        jobId: existingId,
                        seedU: capture.seed.u,
                        seedV: capture.seed.v
                    )
                } else {
                    created = try await client.createJob(request: request, idempotencyKey: idempotencyKey)
                }
                job = created
                warnings = CurtainSeedMath.mergedWarnings(client: capture.clientWarnings, server: created.warnings)
                beginPolling(jobId: created.id)
            } catch {
                phase = .failed(error.localizedDescription)
                errorMessage = (error as? CurtainPlacementAPIError)?.userMessage ?? error.localizedDescription
                bannerMessage = nil
            }
        }
    }

    func reselectWindow() {
        pollTask?.cancel()
        pollTask = nil
        // Keep job id for Cloud reselect with the next seed; clear detection UI only.
        windowPolygon = nil
        markerYawDeg = nil
        markerPitchDeg = nil
        warnings = []
        phase = .awaitingSeed
        bannerMessage = "커튼을 설치할 창문을 눌러주세요"
    }

    func confirmWindowAndComposite() {
        guard let job, let client else { return }
        phase = .compositing
        bannerMessage = "커튼 미리보기를 만들고 있어요…"
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do {
                _ = try await client.confirmWindow(jobId: job.id)
                _ = try await client.composite(jobId: job.id)
                beginPolling(jobId: job.id)
            } catch {
                phase = .failed(error.localizedDescription)
                errorMessage = (error as? CurtainPlacementAPIError)?.userMessage ?? error.localizedDescription
                bannerMessage = nil
            }
        }
    }

    func saveCompositeRevision(originalTexturePath: String) async {
        guard case .comparing(_, let resultPath, let revisionId) = phase else { return }
        do {
            let latest = try SpaceLatLongStore.latestLatLongURL(sessionId: sessionId)
            let src = URL(fileURLWithPath: resultPath)
            guard SpaceLatLongStore.validateImage(at: src) != nil else {
                throw CurtainPlacementAPIError.invalidResponse
            }
            try? FileManager.default.removeItem(at: latest)
            try FileManager.default.copyItem(at: src, to: latest)
            let token = SpaceThumbnailCacheKey.revisionToken(
                latestRevisionId: revisionId,
                remoteImageURL: job?.compositeImageUrl,
                catalogUpdatedAt: nil
            )
            let stamp = SpaceLatLongRevisionStamp(
                revisionId: revisionId,
                revisionToken: token,
                sourceURL: job?.compositeImageUrl ?? resultPath,
                accountId: nil,
                spaceId: sessionId,
                catalogUpdatedAt: nil
            )
            SpaceLatLongStore.writeRevisionStamp(stamp, forImageAt: latest)
            phase = .saved
            bannerMessage = "미리보기를 저장했어요"
        } catch {
            errorMessage = "미리보기를 저장하지 못했어요"
        }
    }

    func dismiss() {
        pollTask?.cancel()
        pollTask = nil
        phase = .idle
        pending = nil
        bannerMessage = nil
    }

    func updateLatLongDimensions(width: Int, height: Int) {
        latLongWidth = max(1, width)
        latLongHeight = max(1, height)
    }

    private func beginPolling(jobId: String) {
        guard let client else { return }
        phase = .polling("DETECTING_WINDOW")
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            for _ in 0..<120 {
                if Task.isCancelled { return }
                do {
                    let status = try await client.fetchJob(id: jobId)
                    job = status
                    warnings = CurtainSeedMath.mergedWarnings(
                        client: warnings,
                        server: status.warnings
                    )
                    windowPolygon = status.windowPolygon
                    switch status.status {
                    case "WINDOW_CONFIRMATION_REQUIRED", "AWAITING_CONFIRMATION":
                        phase = .awaitingConfirmation(status)
                        bannerMessage = "창문 위치를 확인해 주세요"
                        return
                    case "COMPLETED":
                        await handleCompleted(status, client: client)
                        return
                    case "FAILED":
                        phase = .failed(status.userFacingSummaryKo ?? "미리보기를 만들지 못했어요")
                        errorMessage = status.userFacingSummaryKo ?? "미리보기를 만들지 못했어요"
                        bannerMessage = nil
                        return
                    case "COMPOSITING":
                        phase = .compositing
                        bannerMessage = "커튼 미리보기를 만들고 있어요…"
                    default:
                        phase = .polling(status.status)
                    }
                } catch {
                    // transient — keep polling
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            phase = .failed("시간이 초과됐어요")
            errorMessage = "시간이 초과됐어요"
            bannerMessage = nil
        }
    }

    private func handleCompleted(_ status: CurtainPlacementJob, client: any CurtainPlacementServing) async {
        do {
            let dest = try SpaceLatLongStore.directory(sessionId: sessionId)
                .appendingPathComponent("latlong-curtain-\(status.id).jpg")
            if let urlStr = status.compositeImageUrl,
               let url = URL(string: urlStr),
               !(url.host ?? "").contains("example.invalid") {
                try await downloadImage(from: url, to: dest)
            } else if let base = try? SpaceLatLongStore.latLongURL(sessionId: sessionId),
                      SpaceLatLongStore.isValidLocalFile(at: base.path) {
                try FileManager.default.copyItem(at: base, to: dest)
            } else {
                throw CurtainPlacementAPIError.invalidResponse
            }
            guard SpaceLatLongStore.validateImage(at: dest) != nil else {
                throw CurtainPlacementAPIError.invalidResponse
            }
            let originalPath = texturePathForCompare(fallbackRemote: status.originalImageUrl)
            phase = .comparing(
                originalPath: originalPath,
                resultPath: dest.path,
                revisionId: status.revisionId
            )
            bannerMessage = "원본과 미리보기를 비교해 보세요"
        } catch {
            phase = .failed("결과를 불러오지 못했어요")
            errorMessage = "결과를 불러오지 못했어요"
            bannerMessage = nil
        }
    }

    private func texturePathForCompare(fallbackRemote: String?) -> String {
        if let latest = try? SpaceLatLongStore.latestLatLongURL(sessionId: sessionId),
           SpaceLatLongStore.isValidLocalFile(at: latest.path) {
            return latest.path
        }
        if let base = try? SpaceLatLongStore.latLongURL(sessionId: sessionId),
           SpaceLatLongStore.isValidLocalFile(at: base.path) {
            return base.path
        }
        return fallbackRemote ?? ""
    }

    private func downloadImage(from url: URL, to dest: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CurtainPlacementAPIError.invalidResponse
        }
        try data.write(to: dest, options: .atomic)
    }

    static func idempotencyKey(
        spaceId: String,
        baseRevisionId: String,
        productId: String,
        variantId: String,
        seed: CurtainPlacementSeedPayload
    ) -> String {
        let raw = "\(spaceId)|\(baseRevisionId)|\(productId)|\(variantId)|\(seed.u)|\(seed.v)|create"
        return "curtain-\(stableHash(raw))"
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

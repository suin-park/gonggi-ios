import Foundation

enum ProductPlacementResultType: String, Codable, Sendable, Equatable {
    case furniture3D = "FURNITURE_3D"
    case curtain2D = "CURTAIN_2D"
    case spaceCleanup = "SPACE_CLEANUP"
    case unsupported = "UNSUPPORTED"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProductPlacementResultType(rawValue: raw) ?? .unsupported
    }

    var badgeTitle: String {
        switch self {
        case .curtain2D: return "커튼"
        case .furniture3D: return "가구"
        case .spaceCleanup: return "공간 정리"
        case .unsupported: return "작업"
        }
    }
}

enum ProductPlacementResultStatus: String, Codable, Sendable, Equatable {
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case needsConfirmation = "NEEDS_CONFIRMATION"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case unsupported = "UNSUPPORTED"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Treat legacy curtain awaiting as needs confirmation.
        if raw == "AWAITING_CONFIRMATION" {
            self = .needsConfirmation
            return
        }
        self = ProductPlacementResultStatus(rawValue: raw) ?? .unsupported
    }

    var isInFlight: Bool {
        switch self {
        case .queued, .inProgress: return true
        default: return false
        }
    }

    var statusTitle: String {
        switch self {
        case .queued, .inProgress: return "처리 중"
        case .needsConfirmation: return "확인 필요"
        case .completed: return "완료"
        case .failed: return "실패"
        case .unsupported: return "상태 확인 중"
        }
    }
}

struct ProductPlacementResultDTO: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var type: ProductPlacementResultType
    var status: ProductPlacementResultStatus
    var sourceSpaceId: String?
    /// GonggiSpace.sessionId when provided by API — preferred viewer / local job key.
    var sourceSessionId: String? = nil
    var sourceRevisionId: String?
    var resultRevisionId: String?
    var curtainCompositeJobId: String?
    var spaceCleanupJobId: String? = nil
    var catalogPartnerId: String?
    var catalogProductId: String?
    var catalogVariantId: String?
    var productName: String?
    var partnerName: String?
    var optionName: String?
    var productNameSnapshot: String?
    var partnerNameSnapshot: String?
    var optionNameSnapshot: String?
    var widthMm: Int?
    var depthMm: Int?
    var heightMm: Int?
    var previewUrl: String?
    var originalPreviewUrl: String?
    var resultPreviewUrl: String?
    var progress: Double?
    var failureCode: String?
    var createdAt: String?
    var updatedAt: String?

    var displayProductName: String {
        if type == .spaceCleanup {
            return productNameSnapshot ?? productName ?? "공간 정리 결과"
        }
        return productNameSnapshot ?? productName ?? "제휴 상품"
    }

    var displayPartnerName: String {
        partnerNameSnapshot ?? partnerName ?? ""
    }

    /// Prefer result preview when completed; otherwise original / generic preview.
    var cardPreviewURLString: String? {
        switch status {
        case .completed:
            return resultPreviewUrl ?? previewUrl ?? originalPreviewUrl
        default:
            return originalPreviewUrl ?? previewUrl ?? resultPreviewUrl
        }
    }

    var createdAtDate: Date? {
        guard let createdAt else { return nil }
        return ProductPlacementResultDTO.parseDate(createdAt)
    }

    static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}

struct ProductPlacementResultsListResponse: Codable, Sendable {
    var ok: Bool?
    var results: [ProductPlacementResultDTO]?
    var items: [ProductPlacementResultDTO]?
    var nextCursor: String?

    var resolvedResults: [ProductPlacementResultDTO] {
        results ?? items ?? []
    }
}

struct ProductPlacementResultDetailResponse: Codable, Sendable {
    var ok: Bool?
    var result: ProductPlacementResultDTO?
}

enum MobilePlacementResultsAPIError: Error, Equatable {
    case unauthorized
    case notFound
    case invalidResponse
    case server(status: Int)
    case offline

    var userMessage: String {
        switch self {
        case .unauthorized:
            return "로그인이 필요해요"
        case .notFound:
            return "배치 결과를 찾을 수 없어요"
        case .invalidResponse:
            return "서버 응답을 읽지 못했어요"
        case .server:
            return "서버에 문제가 있어요. 잠시 후 다시 시도해 주세요"
        case .offline:
            return "네트워크 연결을 확인해 주세요"
        }
    }
}

protocol PlacementResultsServing: Sendable {
    func listResults() async throws -> [ProductPlacementResultDTO]
    func fetchResult(id: String) async throws -> ProductPlacementResultDTO
    func retryCurtain(placementResultId: String) async throws -> ProductPlacementResultDTO
    func confirmCurtainJob(jobId: String) async throws
    func confirmSpaceCleanupJob(jobId: String) async throws
    func retrySpaceCleanupJob(jobId: String) async throws -> ProductPlacementResultDTO
    func deleteResult(id: String) async throws
}

actor MobilePlacementResultsAPIClient: PlacementResultsServing {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func listResults() async throws -> [ProductPlacementResultDTO] {
        let req = try makeRequest(path: ["api", "gonggi", "placement-results"], method: "GET")
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ProductPlacementResultsListResponse.self, from: data) {
            return envelope.resolvedResults
        }
        if let list = try? decoder.decode([ProductPlacementResultDTO].self, from: data) {
            return list
        }
        throw MobilePlacementResultsAPIError.invalidResponse
    }

    func fetchResult(id: String) async throws -> ProductPlacementResultDTO {
        let req = try makeRequest(path: ["api", "gonggi", "placement-results", id], method: "GET")
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ProductPlacementResultDetailResponse.self, from: data),
           let result = envelope.result {
            return result
        }
        if let result = try? decoder.decode(ProductPlacementResultDTO.self, from: data) {
            return result
        }
        throw MobilePlacementResultsAPIError.invalidResponse
    }

    func retryCurtain(placementResultId: String) async throws -> ProductPlacementResultDTO {
        var req = try makeRequest(
            path: ["api", "gonggi", "placement-results", "curtain-retry"],
            method: "POST"
        )
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "placementResultId": placementResultId,
        ])
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ProductPlacementResultDetailResponse.self, from: data),
           let result = envelope.result {
            return result
        }
        if let result = try? decoder.decode(ProductPlacementResultDTO.self, from: data) {
            return result
        }
        // Some servers return only ok + id; refetch.
        return try await fetchResult(id: placementResultId)
    }

    func confirmCurtainJob(jobId: String) async throws {
        var req = try makeRequest(
            path: ["api", "gonggi", "curtain-composites", jobId, "confirm"],
            method: "POST"
        )
        req.httpBody = Data("{}".utf8)
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
    }

    func confirmSpaceCleanupJob(jobId: String) async throws {
        var req = try makeRequest(
            path: ["api", "gonggi", "space-cleanups", jobId, "confirm"],
            method: "POST"
        )
        req.httpBody = Data("{}".utf8)
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
    }

    func retrySpaceCleanupJob(jobId: String) async throws -> ProductPlacementResultDTO {
        var req = try makeRequest(
            path: ["api", "gonggi", "space-cleanups", jobId, "retry"],
            method: "POST"
        )
        req.httpBody = Data("{}".utf8)
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
        if let envelope = try? JSONDecoder().decode(ProductPlacementResultDetailResponse.self, from: data),
           let result = envelope.result {
            return result
        }
        // Cloud retry returns `{ ok, job }` (job envelope). Refresh locker card by job id.
        struct JobEnvelope: Codable {
            var ok: Bool?
            var job: SpaceCleanupJobDTO?
        }
        if let jobEnv = try? JSONDecoder().decode(JobEnvelope.self, from: data),
           jobEnv.job != nil {
            if let placementId = jobEnv.job?.placementResultId,
               let refreshed = try? await fetchResult(id: placementId) {
                return refreshed
            }
            let listed = try await listResults()
            if let match = listed.first(where: { $0.spaceCleanupJobId == jobId }) {
                return match
            }
        }
        let listed = try await listResults()
        if let match = listed.first(where: { $0.spaceCleanupJobId == jobId }) {
            return match
        }
        throw MobilePlacementResultsAPIError.invalidResponse
    }

    func deleteResult(id: String) async throws {
        let req = try makeRequest(path: ["api", "gonggi", "placement-results", id], method: "DELETE")
        let (data, http) = try await perform(req)
        try throwIfNeeded(http: http, data: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MobilePlacementResultsAPIError.invalidResponse
            }
            return (data, http)
        } catch let error as MobilePlacementResultsAPIError {
            throw error
        } catch {
            throw MobilePlacementResultsAPIError.offline
        }
    }

    private func throwIfNeeded(http: HTTPURLResponse, data: Data) throws {
        if http.statusCode == 401 { throw MobilePlacementResultsAPIError.unauthorized }
        if http.statusCode == 404 { throw MobilePlacementResultsAPIError.notFound }
        if (200..<300).contains(http.statusCode) { return }
        throw MobilePlacementResultsAPIError.server(status: http.statusCode)
    }

    private func makeRequest(path: [String], method: String) throws -> URLRequest {
        let url = path.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Simulator / `-mock` placement results without cloud.
actor PlacementResultsMockClient: PlacementResultsServing {
    private var results: [ProductPlacementResultDTO]

    init(seed: [ProductPlacementResultDTO] = PlacementResultsMockClient.defaultSeed) {
        self.results = seed
    }

    static let defaultSeed: [ProductPlacementResultDTO] = [
        ProductPlacementResultDTO(
            id: "mock-pr-progress",
            type: .curtain2D,
            status: .inProgress,
            sourceSpaceId: "mock-space-1",
            sourceRevisionId: nil,
            resultRevisionId: nil,
            curtainCompositeJobId: "mock-curtain-1",
            catalogPartnerId: "jd-homedressing",
            catalogProductId: "mock-catalog-curtain-sample",
            catalogVariantId: nil,
            productName: nil,
            partnerName: nil,
            optionName: nil,
            productNameSnapshot: "커튼 샘플 (Mock)",
            partnerNameSnapshot: "JD홈드레싱",
            optionNameSnapshot: nil,
            widthMm: 2000,
            depthMm: 50,
            heightMm: 2400,
            previewUrl: nil,
            originalPreviewUrl: nil,
            resultPreviewUrl: nil,
            progress: 0.45,
            failureCode: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            updatedAt: nil
        ),
        ProductPlacementResultDTO(
            id: "mock-pr-done",
            type: .furniture3D,
            status: .completed,
            sourceSpaceId: "mock-space-1",
            sourceRevisionId: nil,
            resultRevisionId: nil,
            curtainCompositeJobId: nil,
            catalogPartnerId: "jd-homedressing",
            catalogProductId: CatalogMockData.roundCabinetProductId,
            catalogVariantId: CatalogMockData.roundCabinetVariantId,
            productName: nil,
            partnerName: nil,
            optionName: nil,
            productNameSnapshot: "3단 라운드 마감장",
            partnerNameSnapshot: "JD홈드레싱",
            optionNameSnapshot: "기본",
            widthMm: 290,
            depthMm: 290,
            heightMm: 1084,
            previewUrl: nil,
            originalPreviewUrl: nil,
            resultPreviewUrl: nil,
            progress: 1,
            failureCode: nil,
            createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
            updatedAt: nil
        ),
    ]

    func listResults() async throws -> [ProductPlacementResultDTO] {
        results.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    func fetchResult(id: String) async throws -> ProductPlacementResultDTO {
        guard let result = results.first(where: { $0.id == id }) else {
            throw MobilePlacementResultsAPIError.notFound
        }
        return result
    }

    func retryCurtain(placementResultId: String) async throws -> ProductPlacementResultDTO {
        guard let idx = results.firstIndex(where: { $0.id == placementResultId }) else {
            throw MobilePlacementResultsAPIError.notFound
        }
        results[idx].status = .inProgress
        results[idx].failureCode = nil
        results[idx].progress = 0.1
        return results[idx]
    }

    func confirmCurtainJob(jobId: String) async throws {
        if let idx = results.firstIndex(where: { $0.curtainCompositeJobId == jobId }) {
            results[idx].status = .inProgress
            results[idx].progress = 0.6
        }
    }

    func confirmSpaceCleanupJob(jobId: String) async throws {
        if let idx = results.firstIndex(where: { $0.spaceCleanupJobId == jobId }) {
            results[idx].status = .inProgress
            results[idx].progress = 0.6
        }
    }

    func retrySpaceCleanupJob(jobId: String) async throws -> ProductPlacementResultDTO {
        guard let idx = results.firstIndex(where: { $0.spaceCleanupJobId == jobId }) else {
            throw MobilePlacementResultsAPIError.notFound
        }
        results[idx].status = .inProgress
        results[idx].failureCode = nil
        results[idx].progress = 0.1
        return results[idx]
    }

    func deleteResult(id: String) async throws {
        results.removeAll { $0.id == id }
    }
}

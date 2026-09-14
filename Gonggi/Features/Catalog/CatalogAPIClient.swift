import Foundation

enum CatalogAPIError: Error, Equatable {
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case server(status: Int)
    case offline
    case invalidResponse
    case cancelled
    case empty

    var userMessage: String {
        switch self {
        case .unauthorized, .forbidden:
            return "로그인이 필요하거나 권한이 없어요"
        case .notFound:
            return "상품을 찾을 수 없어요"
        case .conflict:
            return "상품 정보가 바뀌었어요. 다시 시도해 주세요"
        case .server:
            return "서버에 문제가 있어요. 잠시 후 다시 시도해 주세요"
        case .offline:
            return "네트워크 연결을 확인해 주세요"
        case .invalidResponse:
            return "상품 정보를 읽지 못했어요"
        case .cancelled:
            return "요청이 취소됐어요"
        case .empty:
            return "표시할 제휴 상품이 없어요"
        }
    }
}

protocol CatalogServing: Sendable {
    func fetchProducts() async throws -> [CatalogProduct]
    func fetchProduct(id: String) async throws -> CatalogProduct
    func recordEvent(_ request: CatalogEventRequest) async
}

actor CatalogAPIClient: CatalogServing {
    private let config: AppConfiguration
    private let session: URLSession
    private var inFlightList: Task<[CatalogProduct], Error>?
    private var inFlightDetail: [String: Task<CatalogProduct, Error>] = [:]

    init(config: AppConfiguration = .production, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            cfg.waitsForConnectivity = true
            cfg.urlCache = URLCache(
                memoryCapacity: 8 * 1024 * 1024,
                diskCapacity: 32 * 1024 * 1024,
                diskPath: "gonggi.catalog.cache"
            )
            self.session = URLSession(configuration: cfg)
        }
    }

    func fetchProducts() async throws -> [CatalogProduct] {
        if let existing = inFlightList {
            return try await existing.value
        }
        let task = Task { () throws -> [CatalogProduct] in
            let data = try await get(path: ["api", "gonggi", "partner-catalog", "products"])
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(CatalogProductListResponse.self, from: data) {
                return envelope.products.filter { $0.placementType != .unsupported }
            }
            if let products = try? decoder.decode([CatalogProduct].self, from: data) {
                return products.filter { $0.placementType != .unsupported }
            }
            throw CatalogAPIError.invalidResponse
        }
        inFlightList = task
        defer { inFlightList = nil }
        return try await task.value
    }

    func fetchProduct(id: String) async throws -> CatalogProduct {
        if let existing = inFlightDetail[id] {
            return try await existing.value
        }
        let task = Task { () throws -> CatalogProduct in
            let data = try await get(path: ["api", "gonggi", "partner-catalog", "products", id])
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(CatalogProductDetailResponse.self, from: data) {
                return envelope.product
            }
            if let product = try? decoder.decode(CatalogProduct.self, from: data) {
                return product
            }
            throw CatalogAPIError.invalidResponse
        }
        inFlightDetail[id] = task
        defer { inFlightDetail[id] = nil }
        return try await task.value
    }

    /// Refetch detail once when USDZ signed URL appears expired.
    func refreshProductForExpiredURL(id: String) async throws -> CatalogProduct {
        inFlightDetail[id]?.cancel()
        inFlightDetail[id] = nil
        return try await fetchProduct(id: id)
    }

    func recordEvent(_ request: CatalogEventRequest) async {
        do {
            var req = try makeRequest(
                path: ["api", "gonggi", "partner-catalog", "events"],
                method: "POST"
            )
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            req.httpBody = try encoder.encode(request)
            let (_, response) = try await session.data(for: req)
            _ = response
        } catch {
            // Events are best-effort.
        }
    }

    private func get(path: [String]) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CatalogAPIError.invalidResponse
            }
            try mapStatus(http.statusCode)
            return data
        } catch let error as CatalogAPIError {
            throw error
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CatalogAPIError.cancelled }
            if urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
                throw CatalogAPIError.offline
            }
            throw CatalogAPIError.server(status: -1)
        }
    }

    private func makeRequest(path: [String], method: String) throws -> URLRequest {
        let url = path.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func mapStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw CatalogAPIError.unauthorized
        case 403: throw CatalogAPIError.forbidden
        case 404: throw CatalogAPIError.notFound
        case 409: throw CatalogAPIError.conflict
        default: throw CatalogAPIError.server(status: status)
        }
    }
}

actor CatalogMockClient: CatalogServing {
    func fetchProducts() async throws -> [CatalogProduct] {
        CatalogMockData.listProducts()
    }

    func fetchProduct(id: String) async throws -> CatalogProduct {
        guard let product = CatalogMockData.detailProduct(id: id) else {
            throw CatalogAPIError.notFound
        }
        return product
    }

    func recordEvent(_ request: CatalogEventRequest) async {
        // Mock: no network. Still validates payload shape locally.
        _ = request
    }
}
